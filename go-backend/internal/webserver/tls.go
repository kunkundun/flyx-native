package webserver

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// certReloader 按文件 mtime 热加载证书：续期后不必重启进程
type certReloader struct {
	certFile string
	keyFile  string

	mu      sync.RWMutex
	cert    *tls.Certificate
	certMod time.Time
	keyMod  time.Time
}

func newCertReloader(certFile, keyFile string) (*certReloader, error) {
	r := &certReloader{certFile: certFile, keyFile: keyFile}
	if err := r.load(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *certReloader) load() error {
	cert, err := tls.LoadX509KeyPair(r.certFile, r.keyFile)
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cert = &cert
	if info, statErr := os.Stat(r.certFile); statErr == nil {
		r.certMod = info.ModTime()
	}
	if info, statErr := os.Stat(r.keyFile); statErr == nil {
		r.keyMod = info.ModTime()
	}
	return nil
}

func (r *certReloader) changed() bool {
	certInfo, certErr := os.Stat(r.certFile)
	keyInfo, keyErr := os.Stat(r.keyFile)
	if certErr != nil || keyErr != nil {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	return certInfo.ModTime().After(r.certMod) || keyInfo.ModTime().After(r.keyMod)
}

func (r *certReloader) getCertificate() *tls.Certificate {
	if r.changed() {
		// 加载失败就继续用旧证书，避免续期瞬间把面板打挂
		_ = r.load()
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.cert
}

// NewTLSConfig 构造带热加载的 TLS 配置
func NewTLSConfig(certFile, keyFile string) (*tls.Config, error) {
	reloader, err := newCertReloader(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("加载证书失败: %w", err)
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS12,
		GetCertificate: func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			cert := reloader.getCertificate()
			if cert == nil {
				return nil, fmt.Errorf("证书不可用")
			}
			return cert, nil
		},
	}, nil
}

// WrapTLS 把普通 listener 包成「同一个端口同时接受 TLS 与明文 HTTP」：
// 首字节是 TLS 握手记录就按 TLS 处理，否则回一个 301 跳到 https 同端口。
func WrapTLS(ln net.Listener, tlsConfig *tls.Config, portSuffix string) net.Listener {
	// 先包一层识别明文 HTTP 的 listener，再交给 tls.NewListener 做真正的握手：
	//   TLS 首字节 → 原样交给握手
	//   明文请求   → 直接回 301 到 https 同端口
	return tls.NewListener(&autoHTTPSListener{Listener: ln, portSuffix: portSuffix}, tlsConfig)
}

type autoHTTPSListener struct {
	net.Listener
	portSuffix string
}

func (l *autoHTTPSListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &autoHTTPSConn{Conn: conn, portSuffix: l.portSuffix}, nil
}

const firstByteTimeout = 15 * time.Second

// autoHTTPSConn 看首字节决定走 TLS 还是回跳转
type autoHTTPSConn struct {
	net.Conn
	portSuffix string

	once       bool
	pending    []byte
	pendingErr error
	closed     bool
}

func (c *autoHTTPSConn) Read(p []byte) (int, error) {
	if !c.once {
		c.once = true
		_ = c.Conn.SetReadDeadline(time.Now().Add(firstByteTimeout))
		buf := make([]byte, 4096)
		n, err := c.Conn.Read(buf)
		_ = c.Conn.SetReadDeadline(time.Time{})

		if n > 0 && buf[0] == 0x16 { // TLS handshake
			c.pending = append([]byte(nil), buf[:n]...)
			c.pendingErr = err
		} else {
			c.replyRedirect(buf[:n])
			c.closed = true
			return 0, io.EOF
		}
	}

	if c.closed {
		return 0, io.EOF
	}
	if len(c.pending) > 0 {
		n := copy(p, c.pending)
		c.pending = c.pending[n:]
		return n, nil
	}
	if c.pendingErr != nil {
		err := c.pendingErr
		c.pendingErr = nil
		return 0, err
	}
	return c.Conn.Read(p)
}

// replyRedirect 用明文请求里的 Host / URI 拼出 https 地址回 301
func (c *autoHTTPSConn) replyRedirect(head []byte) {
	target := "/"
	host := ""
	if req, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(head))); err == nil {
		target = req.URL.RequestURI()
		host = req.Host
		if host == "" {
			host = req.URL.Host
		}
	}
	if host == "" {
		if addr, ok := c.Conn.LocalAddr().(*net.TCPAddr); ok {
			host = addr.IP.String()
		}
	}
	if host != "" && !hasPort(host) && c.portSuffix != "" {
		host += c.portSuffix
	}

	location := "https://" + host + target
	resp := fmt.Sprintf("HTTP/1.1 301 Moved Permanently\r\nLocation: %s\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", location)
	_, _ = c.Conn.Write([]byte(resp))
}

func hasPort(host string) bool {
	if strings.HasPrefix(host, "[") {
		return strings.Contains(host, "]:")
	}
	return strings.Count(host, ":") == 1
}
