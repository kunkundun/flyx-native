package app

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"go-backend/internal/config"
	"go-backend/internal/geoip"
	httpserver "go-backend/internal/http"
	"go-backend/internal/http/handler"
	"go-backend/internal/store/repo"
	"go-backend/internal/webserver"
)

type App struct {
	cfg   config.Config
	repo  *repo.Repository
	h     *handler.Handler
	panel *PanelServer

	done     chan struct{}
	doneOnce sync.Once
}

// OpenRepository opens the database the config points at.
func OpenRepository(cfg config.Config) (*repo.Repository, error) {
	switch strings.ToLower(strings.TrimSpace(cfg.DBType)) {
	case "", "sqlite":
		r, err := repo.Open(cfg.DBPath)
		if err != nil {
			return nil, fmt.Errorf("open sqlite: %w", err)
		}
		return r, nil
	case "postgres", "postgresql":
		r, err := repo.OpenPostgres(cfg.DatabaseURL)
		if err != nil {
			return nil, fmt.Errorf("open postgres: %w", err)
		}
		return r, nil
	default:
		return nil, fmt.Errorf("unsupported DB_TYPE %q", cfg.DBType)
	}
}

func New(cfg config.Config) (*App, error) {
	r, err := OpenRepository(cfg)
	if err != nil {
		return nil, err
	}

	h := handler.New(r, cfg.JWTSecret)
	h.SetStatusThemesDir(cfg.StatusThemesDir)
	h.SetGeoIP(geoIPFromConfig(cfg))
	router := httpserver.NewRouter(h, cfg.JWTSecret)

	settings := loadPanelSettings(r)
	for _, warning := range settings.Validate(fileExists) {
		log.Printf("面板配置提示：%s", warning)
	}

	panel := NewPanelServer(router, settings)
	h.SetPanelReloadHook(func() {
		go func() {
			// 先把「保存成功」写回浏览器，再重绑监听
			time.Sleep(3 * time.Second)
			if err := appReload(panel, r); err != nil {
				log.Printf("应用面板配置失败：%v", err)
			}
		}()
	})

	return &App{cfg: cfg, repo: r, h: h, panel: panel, done: make(chan struct{})}, nil
}

// loadPanelSettings 从数据库读面板参数，未配置时回落到环境变量
func loadPanelSettings(r *repo.Repository) webserver.Settings {
	getter := func(key string) string {
		if v, err := r.GetViteConfigValue(key); err == nil && strings.TrimSpace(v) != "" {
			return v
		}
		return os.Getenv(envNameForPanelKey(key))
	}
	return webserver.ParseSettings(getter)
}

func envNameForPanelKey(key string) string {
	switch key {
	case webserver.KeyPanelPort:
		return "PANEL_PORT"
	case webserver.KeyAgentPort:
		return "AGENT_PORT"
	case webserver.KeyPath:
		return "PANEL_PATH"
	case webserver.KeyHideRoot:
		return "PANEL_HIDE_ROOT"
	case webserver.KeyTLSEnabled:
		return "PANEL_TLS_ENABLED"
	case webserver.KeyCertFile:
		return "PANEL_CERT_FILE"
	case webserver.KeyKeyFile:
		return "PANEL_KEY_FILE"
	case webserver.KeyListen:
		return "PANEL_LISTEN"
	case webserver.KeyAgentBind:
		return "AGENT_LISTEN"
	default:
		return ""
	}
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func appReload(panel *PanelServer, r *repo.Repository) error {
	settings := loadPanelSettings(r)
	for _, warning := range settings.Validate(fileExists) {
		log.Printf("面板配置提示：%s", warning)
	}
	return panel.Apply(settings)
}

func (a *App) Run() error {
	if a.h != nil {
		a.h.StartBackgroundJobs()
	}
	if err := a.panel.Apply(a.panel.Settings()); err != nil {
		return err
	}
	<-a.done
	return nil
}

// Reload 重新读取数据库里的面板配置并重绑监听（SIGHUP 或设置页保存后触发）
func (a *App) Reload() error {
	return appReload(a.panel, a.repo)
}

func (a *App) Shutdown(ctx context.Context) error {
	a.doneOnce.Do(func() { close(a.done) })
	if a.h != nil {
		a.h.StopBackgroundJobs()
	}
	shutdownErr := a.panel.Stop(ctx)
	closeErr := a.repo.Close()
	if shutdownErr != nil {
		return shutdownErr
	}
	return closeErr
}

// geoIPFromConfig picks the country database for node region detection.
func geoIPFromConfig(cfg config.Config) *geoip.DB {
	switch path := strings.TrimSpace(cfg.GeoIPCountryDB); {
	case strings.EqualFold(path, "off"):
		return nil
	case path != "":
		return geoip.New(path, false)
	default:
		return geoip.New(filepath.Join(filepath.Dir(cfg.DBPath), "geoip", geoip.FileName), true)
	}
}
