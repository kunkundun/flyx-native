package app

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"go-backend/internal/webserver"
)

// PanelServer 负责面板端口与节点端口的双监听，并支持运行期换配置（路径/端口/TLS）。
//
//	面板端口：内嵌前端 + /api/v1 + /system-info(type=0)
//	节点端口：仅 /system-info(type=1) 与 /flow/*（不给面板页面和 API）
type PanelServer struct {
	mu       sync.Mutex
	settings webserver.Settings
	inner    http.Handler

	panelSrv *http.Server
	agentSrv *http.Server
}

// NewPanelServer 构造（不启动）
func NewPanelServer(inner http.Handler, s webserver.Settings) *PanelServer {
	return &PanelServer{inner: inner, settings: s}
}

// Settings 返回当前生效的设置
func (p *PanelServer) Settings() webserver.Settings {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.settings
}

// Apply 用新配置重建监听；新配置起不来时回退到旧配置，避免把面板锁在门外
func (p *PanelServer) Apply(s webserver.Settings) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	previous := p.settings
	if err := p.applyLocked(s); err != nil {
		log.Printf("应用面板配置失败：%v", err)
		if fallbackErr := p.applyLocked(previous); fallbackErr != nil {
			return fmt.Errorf("新配置失败(%v)，回退旧配置也失败: %w", err, fallbackErr)
		}
		return fmt.Errorf("新配置失败，已回退上一份配置: %w", err)
	}
	p.settings = s
	return nil
}

func (p *PanelServer) applyLocked(s webserver.Settings) error {
	panelHandler, err := webserver.NewSPA(p.inner, s)
	if err != nil {
		return fmt.Errorf("构建面板 handler 失败: %w", err)
	}
	agentHandler := agentOnlyHandler(p.inner)

	p.stopLocked(2 * time.Second)

	panelListener, err := net.Listen("tcp", s.PanelAddr())
	if err != nil {
		return fmt.Errorf("监听面板端口 %s 失败: %w", s.PanelAddr(), err)
	}

	if s.TLSActive() {
		tlsConfig, tlsErr := webserver.NewTLSConfig(s.CertFile, s.KeyFile)
		if tlsErr != nil {
			_ = panelListener.Close()
			return tlsErr
		}
		panelListener = webserver.WrapTLS(panelListener, tlsConfig, s.PortSuffix())
	}

	agentListener, err := net.Listen("tcp", s.AgentAddr())
	if err != nil {
		_ = panelListener.Close()
		return fmt.Errorf("监听节点端口 %s 失败: %w", s.AgentAddr(), err)
	}

	p.panelSrv = &http.Server{
		Handler:           panelHandler,
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	p.agentSrv = &http.Server{
		Handler:           agentHandler,
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       90 * time.Second,
	}

	panelSrv, agentSrv := p.panelSrv, p.agentSrv
	go func() {
		if serveErr := panelSrv.Serve(panelListener); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			log.Printf("面板端口服务异常退出: %v", serveErr)
		}
	}()
	go func() {
		if serveErr := agentSrv.Serve(agentListener); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			log.Printf("节点端口服务异常退出: %v", serveErr)
		}
	}()

	log.Printf("面板监听 %s（path=%s tls=%v），节点通道监听 %s",
		s.PanelAddr(), s.Prefix(), s.TLSActive(), s.AgentAddr())
	return nil
}

// Stop 关闭两个监听
func (p *PanelServer) Stop(ctx context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.stopLockedContext(ctx)
}

func (p *PanelServer) stopLocked(timeout time.Duration) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	_ = p.stopLockedContext(ctx)
}

func (p *PanelServer) stopLockedContext(ctx context.Context) error {
	var firstErr error
	for _, srv := range []*http.Server{p.panelSrv, p.agentSrv} {
		if srv == nil {
			continue
		}
		if err := srv.Shutdown(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) && firstErr == nil {
			firstErr = err
		}
	}
	p.panelSrv = nil
	p.agentSrv = nil
	return firstErr
}

// agentOnlyHandler 只放行节点通道，其它路径一律 404
func agentOnlyHandler(inner http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !webserver.IsAgentPath(r.URL.Path) {
			http.NotFound(w, r)
			return
		}
		inner.ServeHTTP(w, r)
	})
}
