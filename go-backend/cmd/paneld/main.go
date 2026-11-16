package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	// The runtime image has no zoneinfo; embed it so TZ (e.g. Asia/Shanghai
	// in the compose files) applies to logs and notification times.
	_ "time/tzdata"

	"go-backend/internal/app"
	"go-backend/internal/config"
)

// version 由构建脚本注入：-X main.version=<版本>
var version = "dev"

func main() {
	cfg := config.FromEnv()
	if len(os.Args) > 1 && os.Args[1] == "enable-password-login" {
		enablePasswordLogin(cfg)
		return
	}
	generated, err := config.EnsureJWTSecret(&cfg)
	if err != nil {
		log.Fatalf("JWT_SECRET is empty and no secret could be stored: %v", err)
	}
	if generated {
		log.Printf("JWT_SECRET is empty; generated one and saved it next to the database")
	}
	log.Printf("flyx-native %s starting (db=%s)", version, cfg.DBPath)

	a, err := app.New(cfg)
	if err != nil {
		log.Fatalf("failed to create app: %v", err)
	}

	errCh := make(chan error, 1)
	go func() {
		errCh <- a.Run()
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	for {
		select {
		case sig := <-sigCh:
			if sig == syscall.SIGHUP {
				// 设置页保存了端口/路径/证书后重绑监听，而不是退出进程
				log.Printf("received SIGHUP, reloading panel settings")
				if reloadErr := a.Reload(); reloadErr != nil {
					log.Printf("reload failed: %v", reloadErr)
				}
				continue
			}
			log.Printf("received signal %s, shutting down", sig)
		case runErr := <-errCh:
			if runErr != nil && !errors.Is(runErr, http.ErrServerClosed) {
				log.Printf("server stopped unexpectedly: %v", runErr)
				os.Exit(1)
			}
		}
		break
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := a.Shutdown(ctx); err != nil {
		log.Fatalf("shutdown failed: %v", err)
	}
}

// enablePasswordLogin turns password login back on, for an admin locked out
// after turning it off (e.g. GitHub unreachable):
// docker compose exec backend /app/paneld enable-password-login
func enablePasswordLogin(cfg config.Config) {
	r, err := app.OpenRepository(cfg)
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	defer r.Close()
	if err := r.UpsertConfig("admin_password_login_disabled", "false", time.Now().UnixMilli()); err != nil {
		log.Fatalf("enable password login: %v", err)
	}
	fmt.Println("已重新开启密码登录，现在可以在登录页用账号密码登录")
}
