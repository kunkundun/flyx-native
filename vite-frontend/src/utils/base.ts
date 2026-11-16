/**
 * 面板子路径辅助。
 *
 * paneld 在返回 index.html 时会把构建产物里的 `__FLVX_BASE__` 占位符替换成真实前缀，
 * 前端统一从这里取，因此**换面板路径不需要重新构建前端**。
 *
 *   panel_path 未设置 → APP_BASE "/"
 *   panel_path=/kunta → APP_BASE "/kunta/"
 */
const DEFAULT_BASE = "/";
const PLACEHOLDER = "__FLVX_BASE__";

const normalizeBase = (value?: string): string => {
  const raw = (value || "").trim();

  // 占位符未被替换（vite dev / 直接打开 dist）时回退到根路径
  if (!raw || raw.includes(PLACEHOLDER)) return DEFAULT_BASE;
  if (raw === "/") return DEFAULT_BASE;

  const withLeading = raw.startsWith("/") ? raw : `/${raw}`;

  return withLeading.endsWith("/") ? withLeading : `${withLeading}/`;
};

const injected = typeof window !== "undefined" ? window.BASE_URL : undefined;

export const APP_BASE: string = normalizeBase(
  injected || import.meta.env.BASE_URL || DEFAULT_BASE,
);

/** 供 React Router 使用的 basename（根路径为 "/"，子路径不带结尾斜杠） */
export const ROUTER_BASENAME: string =
  APP_BASE === "/" ? "/" : APP_BASE.replace(/\/$/, "");

/** 后端 API 前缀，形如 "/api/v1/" 或 "/kunta/api/v1/" */
export const apiBaseUrl = (): string => `${APP_BASE}api/v1/`;

/** 面板首页地址（登录失效后跳回） */
export const appHomeUrl = (): string => APP_BASE;

/** 当前是否已经站在面板首页（考虑子路径前缀） */
export const isAtHome = (): boolean => {
  const current = window.location.pathname;
  const home = APP_BASE === "/" ? "/" : APP_BASE.replace(/\/$/, "");

  return current === home || current === `${home}/`;
};

/** 生效的面板地址（设置页保存后提示用） */
export const currentPanelUrl = (
  port: string,
  path: string,
  tls: boolean,
): string => {
  const rawPath = (path || "/").trim();
  const normalized =
    rawPath === "/" ? "/" : `/${rawPath.replace(/^\/+|\/+$/g, "")}/`;
  const scheme = tls ? "https" : "http";
  const host =
    window.location.hostname +
    (port === "80" || port === "443" ? "" : `:${port}`);

  return `${scheme}://${host}${normalized}`;
};
