package webserver

import (
	"fmt"
	"strconv"
	"strings"
)

// 面板 web 参数在数据库 vite_config 里的键名（前端设置页保存的也是这些）
const (
	KeyPanelPort  = "panel_port"
	KeyAgentPort  = "panel_agent_port"
	KeyPath       = "panel_path"
	KeyHideRoot   = "panel_hide_root"
	KeyTLSEnabled = "panel_tls_enable"
	KeyCertFile   = "panel_cert_file"
	KeyKeyFile    = "panel_key_file"
	KeyListen     = "panel_listen"
	KeyAgentBind  = "panel_agent_listen"
)

// PanelKeys 列出所有由本包消费的配置键（保存这些键之后需要重建监听）
var PanelKeys = []string{
	KeyPanelPort,
	KeyAgentPort,
	KeyPath,
	KeyHideRoot,
	KeyTLSEnabled,
	KeyCertFile,
	KeyKeyFile,
	KeyListen,
	KeyAgentBind,
}

// IsPanelKey 判断某个配置键是否影响监听/界面呈现
func IsPanelKey(key string) bool {
	switch strings.TrimSpace(key) {
	case KeyPanelPort, KeyAgentPort, KeyPath, KeyHideRoot,
		KeyTLSEnabled, KeyCertFile, KeyKeyFile, KeyListen, KeyAgentBind:
		return true
	default:
		return false
	}
}

// Settings 是面板 web 层的运行参数
type Settings struct {
	// Listen / AgentListen 是监听地址的 host 部分，空表示全部网卡
	Listen      string
	AgentListen string
	Port        int
	AgentPort   int
	// Path 是面板挂载路径，"/" 或 "/kunta"
	Path     string
	HideRoot bool
	TLS      bool
	CertFile string
	KeyFile  string
}

// DefaultSettings 返回内置默认值（可被环境变量覆盖，便于首次启动）
func DefaultSettings() Settings {
	return Settings{
		Port:      6366,
		AgentPort: 6365,
		Path:      "/",
		HideRoot:  true,
	}
}

// ParseSettings 从键值读取器构造设置；get 返回空字符串表示未配置
func ParseSettings(get func(key string) string) Settings {
	s := DefaultSettings()
	s.Listen = strings.TrimSpace(get(KeyListen))
	s.AgentListen = strings.TrimSpace(get(KeyAgentBind))
	s.Port = parsePort(get(KeyPanelPort), s.Port)
	s.AgentPort = parsePort(get(KeyAgentPort), s.AgentPort)
	s.Path = NormalizePath(get(KeyPath))
	s.HideRoot = parseBool(get(KeyHideRoot), s.HideRoot)
	s.TLS = parseBool(get(KeyTLSEnabled), false)
	s.CertFile = strings.TrimSpace(get(KeyCertFile))
	s.KeyFile = strings.TrimSpace(get(KeyKeyFile))
	return s
}

// Validate 校正非法值；TLS 相关配置不可用时返回说明而不是直接报错，
// 让面板先以 HTTP 起来，方便登录后修正。
func (s *Settings) Validate(fileExists func(string) bool) []string {
	var warnings []string

	if s.Port < 1 || s.Port > 65535 {
		s.Port = 6366
		warnings = append(warnings, "面板端口非法，已回退 6366")
	}
	if s.AgentPort < 1 || s.AgentPort > 65535 {
		s.AgentPort = 6365
		warnings = append(warnings, "节点端口非法，已回退 6365")
	}
	if s.AgentPort == s.Port {
		s.AgentPort = 6365
		if s.AgentPort == s.Port {
			s.AgentPort = 6365
		}
		warnings = append(warnings, "面板端口与节点端口相同，节点端口已回退 6365")
	}

	s.Path = NormalizePath(s.Path)

	if s.TLS {
		if s.CertFile == "" || s.KeyFile == "" {
			s.TLS = false
			warnings = append(warnings, "未填写证书或私钥路径，已按 HTTP 启动")
		} else if fileExists != nil && (!fileExists(s.CertFile) || !fileExists(s.KeyFile)) {
			s.TLS = false
			warnings = append(warnings, "证书或私钥文件不存在，已按 HTTP 启动")
		}
	}
	return warnings
}

// BasePath 返回不带结尾斜杠的挂载路径（根路径返回空字符串）
func (s Settings) BasePath() string {
	if s.Path == "/" || s.Path == "" {
		return ""
	}
	return strings.TrimSuffix(s.Path, "/")
}

// Prefix 返回带结尾斜杠的挂载路径（根路径返回 "/"）
func (s Settings) Prefix() string {
	return s.BasePath() + "/"
}

// TLSActive 表示本次监听是否真的启用 TLS
func (s Settings) TLSActive() bool {
	return s.TLS && s.CertFile != "" && s.KeyFile != ""
}

// PanelAddr / AgentAddr 是对外展示与监听用的地址
func (s Settings) PanelAddr() string {
	return joinHostPort(s.Listen, s.Port)
}

func (s Settings) AgentAddr() string {
	return joinHostPort(s.AgentListen, s.AgentPort)
}

// PortSuffix 用于把明文 HTTP 跳转到 HTTPS 时拼端口（443 时省略）
func (s Settings) PortSuffix() string {
	if s.Port == 443 {
		return ""
	}
	return ":" + strconv.Itoa(s.Port)
}

// Scheme 返回当前协议的字符串表示
func (s Settings) Scheme() string {
	if s.TLSActive() {
		return "https"
	}
	return "http"
}

// URL 返回面板的完整访问地址（用于日志与设置页提示）
func (s Settings) URL(host string) string {
	if host == "" {
		host = "127.0.0.1"
	}
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	port := s.PortSuffix()
	if s.Port == 80 || s.Port == 443 {
		port = ""
	}
	return fmt.Sprintf("%s://%s%s%s/", s.Scheme(), host, port, s.BasePath())
}

// String 便于日志输出
func (s Settings) String() string {
	return fmt.Sprintf("panel=%d agent=%d path=%q hide_root=%v tls=%v",
		s.Port, s.AgentPort, s.Path, s.HideRoot, s.TLSActive())
}

// NormalizePath 只放行安全的路径字符，避免把路由写坏
func NormalizePath(raw string) string {
	allowed := func(r rune) bool {
		return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || r == '/' || r == '-' || r == '_' || r == '.'
	}
	cleaned := strings.Builder{}
	for _, r := range strings.TrimSpace(raw) {
		if allowed(r) {
			cleaned.WriteRune(r)
		}
	}
	p := "/" + strings.Trim(cleaned.String(), "/")
	if p == "/" || p == "" {
		return "/"
	}
	return p
}

func parsePort(raw string, fallback int) int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return fallback
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > 65535 {
		return fallback
	}
	return n
}

func parseBool(raw string, fallback bool) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "":
		return fallback
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

func joinHostPort(host string, port int) string {
	host = strings.TrimSpace(host)
	if host == "" {
		return fmt.Sprintf(":%d", port)
	}
	if strings.HasPrefix(host, "[") {
		return fmt.Sprintf("%s:%d", host, port)
	}
	if strings.Contains(host, ":") {
		return fmt.Sprintf("[%s]:%d", host, port)
	}
	return fmt.Sprintf("%s:%d", host, port)
}
