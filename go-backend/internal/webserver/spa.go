package webserver

import (
	"bytes"
	"embed"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

// 前端构建产物在构建前会被拷进 dist/（见 Makefile 的 web 目标）
//
//go:embed all:dist
var embedded embed.FS

const basePlaceholder = "__FLVX_BASE__"

// 没有内嵌前端时的兜底页面（例如只 `go build ./...` 做编译检查、
// 或从源码直接启动但没执行过 build-panel.sh）
var fallbackIndex = []byte(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>FLVX</title>
<style>body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#f6f7fb;color:#1f2937;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.card{max-width:560px;padding:28px 32px;background:#fff;border-radius:14px;box-shadow:0 8px 30px rgba(15,23,42,.08)}
h1{font-size:18px;margin:0 0 10px}p{font-size:14px;line-height:1.7;color:#4b5563;margin:6px 0}
code{background:#f3f4f6;padding:2px 6px;border-radius:4px;font-size:13px}</style></head>
<body><div class="card"><h1>前端资源未构建</h1>
<p>paneld 已启动，但这个二进制里没有内嵌面板前端。</p>
<p>请用 <code>go-backend/scripts/build-panel.sh</code> 构建（会先构建 vite-frontend 再 embed 进二进制）。</p>
<p>接口本身是可用的：<code>/api/v1/...</code>、<code>/flow/test</code>。</p>
</div></body></html>`)

// SPA 把内嵌的前端与后端 mux 合成一个 handler：
//   - <前缀>/             → 静态文件 / index.html
//   - <前缀>/api/v1/...   → 后端 API
//   - <前缀>/system-info  → 后端 WebSocket（面板实时数据）
//   - <前缀>/flow/...     → 后端节点上报（agent 走独立端口时用不到，留着兜底）
//   - 前缀之外             → 404，或根路径 302 跳到前缀
type SPA struct {
	base     string // "" 表示根路径
	prefix   string // "/" 或 "/kunta/"
	hideRoot bool
	index    []byte
	files    map[string][]byte
	inner    http.Handler
}

// NewSPA 构造 handler；inner 为后端 mux
func NewSPA(inner http.Handler, s Settings) (*SPA, error) {
	dist, err := fs.Sub(embedded, "dist")
	if err != nil {
		return nil, err
	}

	rawIndex, err := fs.ReadFile(dist, "index.html")
	if err != nil {
		// 没有前端产物时不阻塞启动（CI 里的 go build / 纯接口使用场景）
		log.Printf("警告：未内嵌前端（dist/index.html 缺失），面板页面将显示占位提示；请用 scripts/build-panel.sh 构建")
		rawIndex = fallbackIndex
	}

	files := make(map[string][]byte, 64)
	err = fs.WalkDir(dist, ".", func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		if p == "index.html" {
			return nil
		}
		data, readErr := fs.ReadFile(dist, p)
		if readErr != nil {
			return readErr
		}
		files[p] = data
		return nil
	})
	if err != nil {
		return nil, err
	}

	return &SPA{
		base:     s.BasePath(),
		prefix:   s.Prefix(),
		hideRoot: s.HideRoot,
		index:    injectBase(rawIndex, s.Prefix()),
		files:    files,
		inner:    inner,
	}, nil
}

// injectBase 把构建产物里的占位符替换成真实前缀：
//   - 根路径："/__FLVX_BASE__/" → "/"
//   - 子路径：__FLVX_BASE__ → "kunta"（得到 "/kunta/" 与 "/kunta/assets/..."）
func injectBase(raw []byte, prefix string) []byte {
	if prefix == "/" {
		return bytes.ReplaceAll(raw, []byte("/"+basePlaceholder+"/"), []byte("/"))
	}
	return bytes.ReplaceAll(raw, []byte(basePlaceholder), []byte(strings.Trim(prefix, "/")))
}

func (spa *SPA) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path

	if spa.base == "" {
		if isBackendPath(p) {
			spa.inner.ServeHTTP(w, r)
			return
		}
		spa.serveStatic(w, r, strings.TrimPrefix(p, "/"))
		return
	}

	if p == spa.base {
		redirect(w, r, spa.prefix, http.StatusMovedPermanently)
		return
	}

	if !strings.HasPrefix(p, spa.prefix) {
		if p == "/" && !spa.hideRoot {
			redirect(w, r, spa.prefix, http.StatusFound)
			return
		}
		http.NotFound(w, r)
		return
	}

	rest := strings.TrimPrefix(p, spa.prefix)
	if isBackendPath("/" + rest) {
		spa.inner.ServeHTTP(w, stripPrefix(r, spa.prefix))
		return
	}
	spa.serveStatic(w, r, rest)
}

func (spa *SPA) serveStatic(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	clean := strings.TrimPrefix(path.Clean("/"+name), "/")
	if clean == "" || clean == "." || strings.HasSuffix(r.URL.Path, "/") {
		spa.serveIndex(w, r)
		return
	}

	data, ok := spa.files[clean]
	if !ok {
		// 未知路径按 SPA 路由处理，交回前端
		spa.serveIndex(w, r)
		return
	}

	w.Header().Set("Content-Type", contentType(clean))
	if strings.HasPrefix(clean, "assets/") {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	} else if strings.HasSuffix(clean, ".webmanifest") || strings.HasPrefix(clean, "sw") ||
		strings.HasPrefix(clean, "workbox-") {
		w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	} else {
		w.Header().Set("Cache-Control", "public, max-age=3600")
	}
	http.ServeContent(w, r, clean, time.Time{}, bytes.NewReader(data))
}

func (spa *SPA) serveIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(spa.index)
}

// IsAgentPath 供 agent 专用端口判断某个路径是否属于节点通道
func IsAgentPath(p string) bool {
	switch p {
	case "/system-info", "/flow/test", "/flow/upload", "/flow/config":
		return true
	default:
		return false
	}
}

func isBackendPath(p string) bool {
	if IsAgentPath(p) {
		return true
	}
	switch {
	case strings.HasPrefix(p, "/api/"), p == "/api":
		return true
	case p == "/status", strings.HasPrefix(p, "/status/"):
		// 公开状态页由后端渲染（面板路径下也要能访问）
		return true
	case p == "/error":
		return true
	default:
		return false
	}
}

func stripPrefix(r *http.Request, prefix string) *http.Request {
	r2 := new(http.Request)
	*r2 = *r
	u := new(url.URL)
	*u = *r.URL
	u.Path = "/" + strings.TrimPrefix(r.URL.Path, prefix)
	if r.URL.RawPath != "" {
		u.RawPath = "/" + strings.TrimPrefix(r.URL.RawPath, prefix)
	}
	r2.URL = u
	return r2
}

// redirect 一律输出相对 Location，避免监听端口与对外端口不一致时丢端口
func redirect(w http.ResponseWriter, r *http.Request, target string, code int) {
	w.Header().Set("Location", target)
	w.WriteHeader(code)
}

func contentType(name string) string {
	switch path.Ext(name) {
	case ".html":
		return "text/html; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".json", ".webmanifest":
		return "application/manifest+json"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".webp":
		return "image/webp"
	case ".ico":
		return "image/x-icon"
	case ".woff2":
		return "font/woff2"
	case ".woff":
		return "font/woff"
	case ".ttf":
		return "font/ttf"
	case ".map":
		return "application/json"
	case ".txt":
		return "text/plain; charset=utf-8"
	default:
		return "application/octet-stream"
	}
}
