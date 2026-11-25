import {
  App,
  applyDocumentTheme,
  applyHostStyleVariables,
} from '@modelcontextprotocol/ext-apps';
import { getMonthNames, resolveLanguage, t, t4, type ResolvedLang } from './i18n';

type TabKey = 'monitor' | 'usage';
type PeriodKey = 'today' | 'days7' | 'days30' | 'all';

interface ProxyConfigDTO {
  configExists: boolean;
  host: string;
  hookPort: number;
  envScheme: string;
  envPort: number;
  hookProxyURL: string;
  envProxyURL: string;
  noProxy: string;
  useOriginalIcon: boolean;
  appLanguage?: string;
  resolvedLanguage?: ResolvedLang;
}

interface ProxyHealthDTO {
  level: 'checking' | 'healthy' | 'degraded' | 'failed';
  tcpReachable: boolean;
  socks5HandshakeOK: boolean;
  envPortReachable: boolean;
  internetReachable: boolean | null;
  latencyMs: number | null;
  summaryTitle: string;
  detailMessage: string;
  checkedAtISO: string;
}

interface SessionDTO {
  id: string;
  title: string;
  stepCount: number;
  status: string;
  isRunning: boolean;
}

interface ActiveContextDTO {
  cascadeId: string;
  title: string;
  modelId: string;
  modelDisplayName: string;
  inputTokens: number;
  cacheReadTokens: number;
  outputTokens: number;
  thinkingOutputTokens: number;
  responseOutputTokens: number;
  activeContextTokens: number;
  totalTurnTokens: number;
  contextLimitTokens: number;
  usageFraction: number;
  cacheHitRatio: number;
  timeToFirstTokenSec: number | null;
  tokensPerSecond: number | null;
}

interface QuotaPoolDTO {
  id: string;
  title: string;
  remainingFraction: number;
  remainingPercent: number;
  resetCountdownText: string;
  models: Array<{
    id: string;
    label: string;
    modelId: string;
  }>;
}

interface LiveSnapshotDTO {
  connected: boolean;
  hub?: {
    pid: number;
    lsVersion?: string;
  };
  userProfile?: {
    name: string;
    email: string;
    tierName: string;
  };
  sessions: SessionDTO[];
  selectedCascadeId?: string;
  activeContext?: ActiveContextDTO;
  quotaPools: QuotaPoolDTO[];
  proxyConfig: ProxyConfigDTO;
  proxyHealth: ProxyHealthDTO;
  liveError?: string;
  updatedAtISO: string;
}

interface DailyBucketDTO {
  dateKey: string;
  inputTokens: number;
  cacheReadTokens: number;
  outputTokens: number;
  totalTokens: number;
  requestCount: number;
  estimatedCostUSD: number;
}

interface HeatmapCellDTO {
  dateKey: string;
  level: number;
  totalTokens: number;
  requestCount: number;
  estimatedCostUSD: number;
}

interface ModelUsageDTO {
  modelKey: string;
  displayName: string;
  inputTokens: number;
  cacheReadTokens: number;
  outputTokens: number;
  totalTokens: number;
  requestCount: number;
  estimatedCostUSD: number;
}

interface UsageHistoryDTO {
  recent14Days: DailyBucketDTO[];
  heatmapWeeks: Array<Array<HeatmapCellDTO | null>>;
  totalsByPeriod: Record<PeriodKey, DailyBucketDTO>;
  modelSummariesByPeriod: Record<PeriodKey, ModelUsageDTO[]>;
  proSubscriptionMonthlyUSD: number;
  scannedFilesCount: number;
  scannedAtISO: string;
}

interface AppState {
  activeTab: TabKey;
  selectedPeriod: PeriodKey;
  selectedCascadeId: string | null;
  selectedHeatmapDate: string | null;
  hoveredBarDate: string | null;
  showNoProxy: boolean;
  expandedPools: Set<string>;
  collapsedCards: Set<string>;
  didAutoScrollHeatmap: boolean;
  live: LiveSnapshotDTO | null;
  usage: UsageHistoryDTO | null;
  isProbingProxy: boolean;
  isRefreshingLive: boolean;
  isRefreshingUsage: boolean;
  errorBanner: string | null;
  inFlightCount: number;
  liveRequestSeq: number;
}

const COLLAPSED_STORAGE_KEY = 'pilot.mcp.collapsedCards';

function loadCollapsedCards(): Set<string> {
  try {
    const raw = window.localStorage.getItem(COLLAPSED_STORAGE_KEY);
    if (!raw) return new Set<string>();
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      return new Set<string>(parsed.filter((item): item is string => typeof item === 'string'));
    }
  } catch {
    // Ignore storage errors inside restricted webview sandboxes
  }
  return new Set<string>();
}

function saveCollapsedCards(cards: Set<string>): void {
  try {
    window.localStorage.setItem(COLLAPSED_STORAGE_KEY, JSON.stringify(Array.from(cards)));
  } catch {
    // Ignore storage errors inside restricted webview sandboxes
  }
}

const state: AppState = {
  activeTab: 'monitor',
  selectedPeriod: 'days30',
  selectedCascadeId: null,
  selectedHeatmapDate: null,
  hoveredBarDate: null,
  showNoProxy: false,
  expandedPools: new Set<string>(),
  collapsedCards: loadCollapsedCards(),
  didAutoScrollHeatmap: false,
  live: null,
  usage: null,
  isProbingProxy: false,
  isRefreshingLive: false,
  isRefreshingUsage: false,
  errorBanner: null,
  inFlightCount: 0,
  liveRequestSeq: 0,
};

const PALETTE = ['#2563eb', '#16a34a', '#d97706', '#7c3aed', '#db2777', '#0891b2'];

function currentLang(): ResolvedLang {
  return resolveLanguage(state.live?.proxyConfig?.resolvedLanguage);
}

function tr(zhHans: string, en: string): string {
  return t(zhHans, en, currentLang());
}

function tr4(zhHans: string, zhHant: string, en: string, ru: string): string {
  return t4(zhHans, zhHant, en, ru, currentLang());
}

function getPeriodLabels(): Array<{ key: PeriodKey; label: string }> {
  return [
    { key: 'today', label: tr('今日', 'Today') },
    { key: 'days7', label: tr('近 7 天', '7 Days') },
    { key: 'days30', label: tr('近 30 天', '30 Days') },
    { key: 'all', label: tr('全部', 'All') },
  ];
}

function getActiveTabCardIds(): string[] {
  if (state.activeTab === 'monitor') {
    return state.live?.connected ? ['proxy', 'context', 'quota'] : ['proxy', 'context'];
  }
  return ['heatmap', 'daily', 'models'];
}

function collapseChevron(cardId: string, collapsed: boolean): string {
  return `<button type="button" class="collapse-btn" data-action="toggle-card" data-card-id="${escapeHtml(cardId)}" aria-expanded="${collapsed ? 'false' : 'true'}" title="${collapsed ? tr('展开面板', 'Expand panel') : tr('收起面板', 'Collapse panel')}">▾</button>`;
}

const app = new App({ name: 'Antigravity Pilot', version: '0.1.0' }, {});

function applyTheme(theme?: string, variables?: Record<string, string>) {
  if (theme) {
    applyDocumentTheme(theme as 'light' | 'dark');
    document.documentElement.setAttribute('data-theme', theme);
  }
  if (variables) {
    applyHostStyleVariables(variables);
  }
}

app.ontoolinput = ({ arguments: args }) => {
  if (args && typeof args === 'object') {
    if (typeof args.cascadeId === 'string') {
      state.selectedCascadeId = args.cascadeId;
    }
    if (typeof args.period === 'string' && ['today', 'days7', 'days30', 'all'].includes(args.period)) {
      state.selectedPeriod = args.period as PeriodKey;
    }
  }
  render();
};

app.ontoolresult = (result) => {
  const sc = (result?.structuredContent ?? {}) as Record<string, unknown>;
  if (sc.initialTab === 'monitor' || sc.initialTab === 'usage') {
    state.activeTab = sc.initialTab;
  }
  if (typeof sc.initialPeriod === 'string' && ['today', 'days7', 'days30', 'all'].includes(sc.initialPeriod)) {
    state.selectedPeriod = sc.initialPeriod as PeriodKey;
  }
  if (sc.live && typeof sc.live === 'object') {
    state.live = sc.live as LiveSnapshotDTO;
    if (state.live.selectedCascadeId) {
      state.selectedCascadeId = state.live.selectedCascadeId;
    }
  }
  if (sc.usage && typeof sc.usage === 'object') {
    state.usage = sc.usage as UsageHistoryDTO;
  }
  state.errorBanner = result?.isError
    ? tr('工具调用返回异常，请点击刷新重试。', 'Tool call returned an error. Click Refresh to retry.')
    : null;
  render();
};

app.onhostcontextchanged = (ctx) => {
  applyTheme(ctx.theme, ctx.styles?.variables as Record<string, string> | undefined);
};

async function callServerToolSafe(name: string, args: Record<string, unknown>): Promise<Record<string, unknown> | null> {
  const caps = app.getHostCapabilities();
  if (!caps?.serverTools || state.inFlightCount >= 3) {
    return null;
  }
  state.inFlightCount += 1;
  try {
    const res = await app.callServerTool({ name, arguments: args });
    if (res.isError) {
      state.errorBanner = tr('刷新数据时服务端返回错误。', 'Server returned an error while refreshing data.');
      return null;
    }
    state.errorBanner = null;
    return (res.structuredContent ?? null) as Record<string, unknown> | null;
  } catch (err) {
    state.errorBanner = err instanceof Error ? err.message : String(err);
    return null;
  } finally {
    state.inFlightCount = Math.max(0, state.inFlightCount - 1);
  }
}

async function refreshLive(includeInternetCheck: boolean, force = false) {
  if (!force && state.isRefreshingLive) return;
  state.liveRequestSeq += 1;
  const seq = state.liveRequestSeq;
  state.isRefreshingLive = true;
  render();
  const data = await callServerToolSafe('pilot_get_live_snapshot', {
    ...(state.selectedCascadeId ? { cascadeId: state.selectedCascadeId } : {}),
    includeInternetCheck,
  });
  if (seq !== state.liveRequestSeq) return;
  state.isRefreshingLive = false;
  if (data) {
    state.live = data as unknown as LiveSnapshotDTO;
    if (state.live.selectedCascadeId) {
      state.selectedCascadeId = state.live.selectedCascadeId;
    }
  }
  render();
}

async function runProxyProbe() {
  if (state.isProbingProxy) return;
  state.isProbingProxy = true;
  render();
  const data = await callServerToolSafe('pilot_probe_proxy', {});
  state.isProbingProxy = false;
  if (data && state.live) {
    if (data.proxyConfig) state.live.proxyConfig = data.proxyConfig as ProxyConfigDTO;
    if (data.proxyHealth) state.live.proxyHealth = data.proxyHealth as ProxyHealthDTO;
  }
  render();
}

async function refreshUsage() {
  if (state.isRefreshingUsage) return;
  state.isRefreshingUsage = true;
  render();
  const data = await callServerToolSafe('pilot_get_usage_history', {});
  state.isRefreshingUsage = false;
  if (data) {
    state.usage = data as unknown as UsageHistoryDTO;
  }
  render();
}

function escapeHtml(raw: string): string {
  return raw
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function compactTokens(n: number): string {
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(2)}B`;
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return String(Math.max(0, Math.round(n)));
}

function compactTokensShort(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${Math.round(n / 1_000)}K`;
  return String(Math.max(0, Math.round(n)));
}

function formatUSD(v: number): string {
  if (v > 0 && v < 0.01) return `$${v.toFixed(4)}`;
  return `$${v.toFixed(2)}`;
}

function healthLevelClass(level: ProxyHealthDTO['level']): 'ok' | 'warn' | 'err' {
  if (level === 'healthy') return 'ok';
  if (level === 'degraded') return 'warn';
  return 'err';
}

function stepBadge(val: boolean | null): string {
  if (val === true) return '<span class="step-mark pass">✓</span>';
  if (val === false) return '<span class="step-mark fail">✕</span>';
  return '<span class="step-mark wait">•</span>';
}

function renderTopBar(): string {
  const live = state.live;
  const connected = live?.connected ?? false;
  const lsVersion = live?.hub?.lsVersion ? `v${escapeHtml(live.hub.lsVersion)}` : '';
  const pidText = live?.hub?.pid ? `PID ${live.hub.pid}` : '';
  const lsJoined = [lsVersion, pidText].filter(Boolean).join(' · ');
  const connText = connected
    ? tr4(
        `已连接 Local LS ${lsJoined}`,
        `已連線 Local LS ${lsJoined}`,
        `Connected Local LS ${lsJoined}`,
        `Подключён Local LS ${lsJoined}`
      )
    : tr('等待 Antigravity 运行', 'Waiting for Antigravity');
  const userPill = live?.userProfile?.email
    ? `<span class="pill">${escapeHtml(live.userProfile.email)} · ${escapeHtml(live.userProfile.tierName)}</span>`
    : '';

  const isBusy = state.isRefreshingLive || state.isRefreshingUsage;
  const tabCardIds = getActiveTabCardIds();
  const allCollapsed = tabCardIds.length > 0 && tabCardIds.every((id) => state.collapsedCards.has(id));

  return `
    <div class="topbar">
      <div class="brand-status">
        <span class="status-dot ${connected ? 'ok' : ''}"></span>
        <span class="status-label">${connText}</span>
        ${userPill}
      </div>
      <div class="topbar-controls">
        <div class="segmented" role="tablist">
          <button type="button" data-action="tab" data-tab="monitor" class="${state.activeTab === 'monitor' ? 'active' : ''}">${tr('实时监控', 'Live Monitor')}</button>
          <button type="button" data-action="tab" data-tab="usage" class="${state.activeTab === 'usage' ? 'active' : ''}">${tr('用量与账单', 'Usage & Billing')}</button>
        </div>
        <button type="button" class="btn" data-action="toggle-all-cards">
          ${allCollapsed ? tr('全部展开', 'Expand All') : tr('全部收起', 'Collapse All')}
        </button>
        <button type="button" class="btn" data-action="refresh-all" ${isBusy ? 'disabled' : ''}>
          ${isBusy ? tr('刷新中…', 'Refreshing…') : tr('刷新', 'Refresh')}
        </button>
      </div>
    </div>
  `;
}

function chainNode(title: string, sub: string, val: boolean | null): string {
  const cls = val === true ? 'pass' : val === false ? 'fail' : '';
  return `
    <div class="chain-node ${cls}">
      ${stepBadge(val)}
      <div class="chain-text">
        <span class="chain-title">${escapeHtml(title)}</span>
        <span class="chain-sub">${escapeHtml(sub)}</span>
      </div>
    </div>
  `;
}

function renderProxyCard(live: LiveSnapshotDTO | null): string {
  if (!live) return '';
  const cfg = live.proxyConfig;
  const h = live.proxyHealth;
  const cls = healthLevelClass(h.level);
  const collapsed = state.collapsedCards.has('proxy');

  return `
    <div class="card ${collapsed ? 'is-collapsed' : ''}">
      <div class="card-header collapsible-header" data-collapse-card="proxy">
        <div class="card-title-group">
          ${collapseChevron('proxy', collapsed)}
          <div>
            <h3 class="card-title">${tr('代理健康监控（只读）', 'Proxy Health Monitor (Read-only)')}</h3>
            ${collapsed ? '' : `<div class="muted">${cfg.configExists
              ? tr('同步自 Antigravity Pilot 配置', 'Synced from Antigravity Pilot config')
              : tr('未检测到本地 config.json，使用默认配置探测', 'No local config.json found; probing with defaults')}</div>`}
          </div>
        </div>
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
          <span class="pill ${cls}">${escapeHtml(h.summaryTitle)}</span>
          <button type="button" class="btn" data-action="probe-proxy" ${state.isProbingProxy ? 'disabled' : ''}>
            ${state.isProbingProxy ? tr('探测中…', 'Probing…') : tr('三阶重测', 'Re-test')}
          </button>
        </div>
      </div>

      <div class="card-body">
        <div class="kv-grid">
          <div class="kv-item">
            <div class="kv-label">dylib Hook (SOCKS5)</div>
            <div class="kv-val mono">${escapeHtml(cfg.hookProxyURL)}</div>
          </div>
          <div class="kv-item">
            <div class="kv-label">${tr('Env / Chromium 代理', 'Env / Chromium Proxy')}</div>
            <div class="kv-val mono">${escapeHtml(cfg.envProxyURL)}</div>
          </div>
        </div>

        <div class="health-chain">
          ${chainNode('1. TCP', `:${cfg.hookPort}`, h.tcpReachable)}
          <span class="chain-arrow">›</span>
          ${chainNode('2. SOCKS5', '05 01 00', h.socks5HandshakeOK)}
          <span class="chain-arrow">›</span>
          ${chainNode(tr('3. 外网', '3. Net'), h.latencyMs != null ? `${h.latencyMs} ms` : '204', h.internetReachable)}
          <span class="chain-arrow">›</span>
          ${chainNode('ENV', `${cfg.envScheme}:${cfg.envPort}`, h.envPortReachable)}
        </div>

        <div class="muted" style="margin-top:8px;">${escapeHtml(h.detailMessage)}</div>

        <button type="button" class="details-toggle" data-action="toggle-noproxy">
          ${state.showNoProxy
            ? tr('▾ 隐藏 NO_PROXY 绕过规则', '▾ Hide NO_PROXY Bypass Rules')
            : tr('▸ 查看 NO_PROXY 绕过规则', '▸ Show NO_PROXY Bypass Rules')}
        </button>
        ${state.showNoProxy ? `<div class="details-box mono">${escapeHtml(cfg.noProxy)}</div>` : ''}
      </div>
    </div>
  `;
}

function renderContextCard(live: LiveSnapshotDTO | null): string {
  if (!live) return '';
  const collapsed = state.collapsedCards.has('context');

  if (!live.connected) {
    return `
      <div class="card ${collapsed ? 'is-collapsed' : ''}">
        <div class="card-header collapsible-header" data-collapse-card="context">
          <div class="card-title-group">
            ${collapseChevron('context', collapsed)}
            <h3 class="card-title">${tr('当前会话上下文', 'Active Session Context')}</h3>
          </div>
          <span class="pill">${tr('未连接', 'Offline')}</span>
        </div>
        <div class="card-body empty-box" style="padding:14px 8px;">
          <div style="font-weight:600;margin-bottom:4px;color:var(--text-primary);">${tr('暂未连接到本地 Language Server', 'Not Connected to Local Language Server')}</div>
          <div class="muted">${tr('请确认 Antigravity 已完成初始化；应用内看板会自动发现当前会话与配额。', 'Ensure Antigravity has finished initializing; the dashboard discovers sessions & quotas automatically.')}</div>
        </div>
      </div>
    `;
  }

  const sessions = live.sessions ?? [];
  const selectHtml = sessions.length > 0
    ? `<select class="select" data-action="select-session">
        ${sessions.map((s) => `<option value="${escapeHtml(s.id)}" ${s.id === state.selectedCascadeId ? 'selected' : ''}>${escapeHtml(s.title)}</option>`).join('')}
      </select>`
    : '';

  const ctx = live.activeContext;
  if (!ctx) {
    return `
      <div class="card ${collapsed ? 'is-collapsed' : ''}">
        <div class="card-header collapsible-header" data-collapse-card="context">
          <div class="card-title-group">
            ${collapseChevron('context', collapsed)}
            <h3 class="card-title">${tr('当前会话上下文', 'Active Session Context')}</h3>
          </div>
          ${collapsed ? '' : selectHtml}
        </div>
        <div class="card-body">
          <div class="muted">${tr('当前选定会话暂无模型调用记录。', 'No model usage recorded in the selected session.')}</div>
        </div>
      </div>
    `;
  }

  const pct = Math.min(100, Math.max(0, Math.round(ctx.usageFraction * 100)));
  const r = 27;
  const circ = 2 * Math.PI * r;
  const dashOffset = circ * (1 - Math.min(1, Math.max(0, ctx.usageFraction)));
  const gaugeColor = ctx.usageFraction >= 0.85 ? 'var(--danger)' : ctx.usageFraction >= 0.65 ? 'var(--warning)' : 'var(--accent)';

  const limit = Math.max(1, ctx.contextLimitTokens);
  const cachePct = Math.min(100, (ctx.cacheReadTokens / limit) * 100);
  const inputPct = Math.min(100 - cachePct, (ctx.inputTokens / limit) * 100);
  const cacheRate = Math.round(ctx.cacheHitRatio * 100);

  return `
    <div class="card ${collapsed ? 'is-collapsed' : ''}">
      <div class="card-header collapsible-header" data-collapse-card="context">
        <div class="card-title-group">
          ${collapseChevron('context', collapsed)}
          <h3 class="card-title">${tr('当前会话上下文', 'Active Session Context')}</h3>
        </div>
        ${collapsed
          ? `<span class="pill">${escapeHtml(ctx.modelDisplayName)} · ${pct}%</span>`
          : selectHtml}
      </div>

      <div class="card-body">
        <div class="context-hero">
          <div class="gauge-wrap">
            <svg viewBox="0 0 68 68" width="68" height="68">
              <circle cx="34" cy="34" r="${r}" fill="none" stroke="var(--bg-tertiary)" stroke-width="6" />
              <circle cx="34" cy="34" r="${r}" fill="none" stroke="${gaugeColor}" stroke-width="6"
                stroke-linecap="round" stroke-dasharray="${circ.toFixed(2)}" stroke-dashoffset="${dashOffset.toFixed(2)}"
                transform="rotate(-90 34 34)" />
            </svg>
            <div class="gauge-label">${pct}%</div>
          </div>

          <div class="context-main">
            <div class="context-top">
              <span style="font-weight:600;">${escapeHtml(ctx.modelDisplayName)}</span>
              <span class="mono" style="font-size:12px;font-weight:600;">${compactTokens(ctx.activeContextTokens)} / ${compactTokens(ctx.contextLimitTokens)}</span>
            </div>
            <div class="stacked-bar">
              <div class="bar-cache" style="width:${cachePct.toFixed(2)}%"></div>
              <div class="bar-input" style="width:${inputPct.toFixed(2)}%"></div>
            </div>
            <div class="legend-row">
              <span class="legend-item"><span class="dot" style="background:var(--accent)"></span>${tr('缓存命中', 'Cached')} ${compactTokens(ctx.cacheReadTokens)}</span>
              <span class="legend-item"><span class="dot" style="background:var(--warning)"></span>${tr('新增输入', 'New In')} ${compactTokens(ctx.inputTokens)}</span>
              <span class="legend-item"><span class="dot" style="background:var(--success)"></span>${tr('输出', 'Output')} ${compactTokens(ctx.outputTokens)}</span>
            </div>
          </div>
        </div>

        <div class="metrics-grid">
          <div class="metric-cell">
            <div class="metric-title">${tr('缓存命中率', 'Cache Hit Rate')}</div>
            <div class="metric-value">${cacheRate}%</div>
          </div>
          <div class="metric-cell">
            <div class="metric-title">${tr('首字延迟 (TTFT)', 'TTFT')}</div>
            <div class="metric-value">${ctx.timeToFirstTokenSec != null ? `${ctx.timeToFirstTokenSec.toFixed(2)} s` : '--'}</div>
          </div>
          <div class="metric-cell">
            <div class="metric-title">${tr('输出速度', 'Output Speed')}</div>
            <div class="metric-value">${ctx.tokensPerSecond != null ? `${ctx.tokensPerSecond.toFixed(1)} tok/s` : '--'}</div>
          </div>
          <div class="metric-cell">
            <div class="metric-title">${tr('思考 / 回复', 'Thinking / Reply')}</div>
            <div class="metric-value">${compactTokens(ctx.thinkingOutputTokens)} / ${compactTokens(ctx.responseOutputTokens)}</div>
          </div>
        </div>
      </div>
    </div>
  `;
}

function renderQuotaCard(live: LiveSnapshotDTO | null): string {
  if (!live || !live.connected) return '';
  const pools = live.quotaPools ?? [];
  const collapsed = state.collapsedCards.has('quota');
  const firstPool = pools[0];
  const firstColor = firstPool
    ? (firstPool.remainingPercent <= 15 ? 'err' : firstPool.remainingPercent <= 35 ? 'warn' : 'ok')
    : '';

  return `
    <div class="card ${collapsed ? 'is-collapsed' : ''}">
      <div class="card-header collapsible-header" data-collapse-card="quota">
        <div class="card-title-group">
          ${collapseChevron('quota', collapsed)}
          <h3 class="card-title">${tr4(
            `模型共享配额池（${pools.length} 组）`,
            `模型共享配額池（${pools.length} 組）`,
            `Shared Model Quota Pools (${pools.length})`,
            `Пулы квот моделей (${pools.length})`
          )}</h3>
        </div>
        ${collapsed && firstPool
          ? `<span class="pill ${firstColor}">${escapeHtml(firstPool.title)} · ${firstPool.remainingPercent}%</span>`
          : ''}
      </div>
      <div class="card-body">
        ${pools.length === 0
          ? `<div class="muted">${tr('暂未获取到模型配额信息。', 'No model quota information available yet.')}</div>`
          : `<div class="pool-list">
              ${pools.map((p) => {
                const barColor = p.remainingPercent <= 15 ? 'var(--danger)' : p.remainingPercent <= 35 ? 'var(--warning)' : 'var(--success)';
                const expanded = state.expandedPools.has(p.id);
                return `
                  <div class="pool-item">
                    <div class="pool-row">
                      <span class="pool-title" title="${escapeHtml(p.title)}">${escapeHtml(p.title)}</span>
                      <div class="pool-meta">
                        <span class="muted">${escapeHtml(p.resetCountdownText)}</span>
                        <span class="pool-pct" style="color:${barColor}">${p.remainingPercent}%</span>
                      </div>
                    </div>
                    <div class="linear-track">
                      <div class="linear-fill" style="width:${Math.min(100, Math.max(0, p.remainingPercent))}%;background:${barColor}"></div>
                    </div>
                    ${p.models.length > 1 ? `
                      <button type="button" class="details-toggle" data-action="toggle-pool" data-pool-id="${escapeHtml(p.id)}">
                        ${expanded ? '▾' : '▸'} ${tr4(
                          `包含 ${p.models.length} 个模型档位`,
                          `包含 ${p.models.length} 個模型檔位`,
                          `Includes ${p.models.length} model tiers`,
                          `Моделей в пуле: ${p.models.length}`
                        )}
                      </button>
                      ${expanded ? `<div class="details-box">${escapeHtml(p.models.map((m) => m.label).join(' · '))}</div>` : ''}
                    ` : ''}
                  </div>
                `;
              }).join('')}
            </div>`
        }
      </div>
    </div>
  `;
}

function buildMonthLabels(weeks: Array<Array<HeatmapCellDTO | null>>): Array<{ col: number; label: string }> {
  const names = getMonthNames(currentLang());

  const labels: Array<{ col: number; label: string }> = [];
  let prevMonth = -1;

  for (let ci = 0; ci < weeks.length; ci += 1) {
    const firstCell = weeks[ci].find((c): c is HeatmapCellDTO => c != null);
    if (!firstCell) continue;
    const monthNum = Number.parseInt(firstCell.dateKey.slice(5, 7), 10);
    if (!Number.isFinite(monthNum) || monthNum < 1 || monthNum > 12) continue;
    if (monthNum !== prevMonth) {
      labels.push({ col: ci, label: names[monthNum - 1] });
      prevMonth = monthNum;
    }
  }

  if (labels.length >= 2 && labels[0].col === 0 && labels[1].col <= 2) {
    labels.shift();
  }
  return labels;
}

function heatmapFill(level: number): string {
  switch (level) {
    case 0: return 'var(--bg-tertiary)';
    case 1: return 'color-mix(in srgb, var(--success) 30%, var(--bg-tertiary))';
    case 2: return 'color-mix(in srgb, var(--success) 52%, var(--bg-tertiary))';
    case 3: return 'color-mix(in srgb, var(--success) 76%, var(--bg-tertiary))';
    default: return 'var(--success)';
  }
}

function renderUsageTab(usage: UsageHistoryDTO | null): string {
  if (!usage) {
    return `<div class="card empty-box">${tr('正在加载本地会话用量归档…', 'Loading local session usage archives…')}</div>`;
  }

  const period = state.selectedPeriod;
  const total: DailyBucketDTO = usage.totalsByPeriod[period] ?? {
    dateKey: '',
    inputTokens: 0,
    cacheReadTokens: 0,
    outputTokens: 0,
    totalTokens: 0,
    requestCount: 0,
    estimatedCostUSD: 0,
  };
  const models = usage.modelSummariesByPeriod[period] ?? [];
  const promptTotal = total.inputTokens + total.cacheReadTokens;
  const cacheRate = promptTotal > 0 ? Math.round((total.cacheReadTokens / promptTotal) * 100) : 0;
  const subMonthly = usage.proSubscriptionMonthlyUSD || 20;
  const subRatio = total.estimatedCostUSD / subMonthly;

  const weeks = usage.heatmapWeeks ?? [];
  let selectedCell: HeatmapCellDTO | null = null;
  for (const col of weeks) {
    for (const c of col) {
      if (c && c.dateKey === state.selectedHeatmapDate) {
        selectedCell = c;
      }
    }
  }

  const cellSize = 13;
  const gap = 3;
  const svgW = Math.max(1, weeks.length) * (cellSize + gap) - gap;
  const svgH = 7 * (cellSize + gap) - gap;

  const recent = usage.recent14Days ?? [];
  const hoveredDay = recent.find((d) => d.dateKey === state.hoveredBarDate) ?? null;

  const periodLabels = getPeriodLabels();
  const periodLabel = periodLabels.find((p) => p.key === period)?.label ?? period;

  const heatmapCollapsed = state.collapsedCards.has('heatmap');
  const dailyCollapsed = state.collapsedCards.has('daily');
  const modelsCollapsed = state.collapsedCards.has('models');

  return `
    <div class="stack">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;">
        <div class="segmented">
          ${periodLabels.map((p) => `<button type="button" data-action="period" data-period="${p.key}" class="${period === p.key ? 'active' : ''}">${p.label}</button>`).join('')}
        </div>
        <span class="muted">${tr4(
          `已扫描 ${usage.scannedFilesCount} 个本地会话归档`,
          `已掃描 ${usage.scannedFilesCount} 個本機工作階段歸檔`,
          `${usage.scannedFilesCount} local archives scanned`,
          `Просканировано архивов: ${usage.scannedFilesCount}`
        )}</span>
      </div>

      <div class="kpi-grid">
        <div class="kpi-card">
          <div class="kpi-title">${tr('总消耗 Token', 'Total Tokens')}</div>
          <div class="kpi-value">${compactTokens(total.totalTokens)}</div>
          <div class="kpi-sub">${tr4(
            `输入 ${compactTokens(total.inputTokens)} · 输出 ${compactTokens(total.outputTokens)}`,
            `輸入 ${compactTokens(total.inputTokens)} · 輸出 ${compactTokens(total.outputTokens)}`,
            `In ${compactTokens(total.inputTokens)} · Out ${compactTokens(total.outputTokens)}`,
            `Вх ${compactTokens(total.inputTokens)} · Вых ${compactTokens(total.outputTokens)}`
          )}</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-title">${tr('缓存命中率', 'Cache Hit Rate')}</div>
          <div class="kpi-value">${cacheRate}%</div>
          <div class="kpi-sub">${tr4(
            `命中 ${compactTokens(total.cacheReadTokens)}`,
            `命中 ${compactTokens(total.cacheReadTokens)}`,
            `Cached ${compactTokens(total.cacheReadTokens)}`,
            `Кэш ${compactTokens(total.cacheReadTokens)}`
          )}</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-title">${tr('模型调用次数', 'Model Calls')}</div>
          <div class="kpi-value">${total.requestCount}</div>
          <div class="kpi-sub">${tr4(
            `${periodLabel} PLANNER 轮次`,
            `${periodLabel} PLANNER 輪次`,
            `${periodLabel} turns`,
            `${periodLabel} шагов`
          )}</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-title">${tr('估算 API 账单', 'Est. API Cost')}</div>
          <div class="kpi-value">${formatUSD(total.estimatedCostUSD)}</div>
          <div class="kpi-sub">${tr4(
            `≈ ${subRatio.toFixed(1)}x $20 Pro 月费`,
            `≈ ${subRatio.toFixed(1)}x $20 Pro 月費`,
            `≈ ${subRatio.toFixed(1)}x $20 Pro/mo`,
            `≈ ${subRatio.toFixed(1)}x $20 Pro/мес`
          )}</div>
        </div>
      </div>

      <div class="card ${heatmapCollapsed ? 'is-collapsed' : ''}">
        <div class="card-header collapsible-header" data-collapse-card="heatmap">
          <div class="card-title-group">
            ${collapseChevron('heatmap', heatmapCollapsed)}
            <h3 class="card-title">${tr('近一年 Token 活跃热力图', '1-Year Token Heatmap')}</h3>
          </div>
          <span class="muted">
            ${selectedCell
              ? tr4(
                  `${selectedCell.dateKey}：${compactTokens(selectedCell.totalTokens)} · ${selectedCell.requestCount} 次 · ${formatUSD(selectedCell.estimatedCostUSD)}`,
                  `${selectedCell.dateKey}：${compactTokens(selectedCell.totalTokens)} · ${selectedCell.requestCount} 次 · ${formatUSD(selectedCell.estimatedCostUSD)}`,
                  `${selectedCell.dateKey}: ${compactTokens(selectedCell.totalTokens)} · ${selectedCell.requestCount} req · ${formatUSD(selectedCell.estimatedCostUSD)}`,
                  `${selectedCell.dateKey}: ${compactTokens(selectedCell.totalTokens)} · ${selectedCell.requestCount} вызов. · ${formatUSD(selectedCell.estimatedCostUSD)}`
                )
              : tr('点击方格查看单日明细', 'Click a cell for day details')}
          </span>
        </div>
        <div class="card-body">
          <div class="heatmap-wrap">
            <div class="heatmap-weekdays">
              <span style="grid-row:1">${tr('一', 'M')}</span>
              <span style="grid-row:3">${tr('三', 'W')}</span>
              <span style="grid-row:5">${tr('五', 'F')}</span>
            </div>
            <div class="heatmap-scroll">
              <div class="heatmap-track">
                <div class="heatmap-months" style="grid-template-columns:repeat(${Math.max(1, weeks.length)}, minmax(0, 1fr));">
                  ${buildMonthLabels(weeks).map((m) => `<span class="heatmap-month-label" style="grid-column:${m.col + 1} / span 4;">${m.label}</span>`).join('')}
                </div>
                <svg class="heatmap-svg" viewBox="0 0 ${svgW} ${svgH}">
                  ${weeks.map((col, ci) => col.map((cell, ri) => {
                    if (!cell) return '';
                    const x = ci * (cellSize + gap);
                    const y = ri * (cellSize + gap);
                    const isSelected = cell.dateKey === state.selectedHeatmapDate;
                    return `<rect class="heatmap-cell" data-date="${escapeHtml(cell.dateKey)}" x="${x}" y="${y}" width="${cellSize}" height="${cellSize}" rx="3" fill="${heatmapFill(cell.level)}" ${isSelected ? 'stroke="var(--text-primary)" stroke-width="1.3"' : ''}><title>${cell.dateKey}: ${compactTokens(cell.totalTokens)} (${formatUSD(cell.estimatedCostUSD)})</title></rect>`;
                  }).join('')).join('')}
                </svg>
              </div>
            </div>
          </div>
          <div class="heatmap-legend">
            <span class="legend-squares">
              <span>${tr('低', 'Less')}</span>
              ${[0, 1, 2, 3, 4].map((lv) => `<span class="legend-sq" style="background:${heatmapFill(lv)}"></span>`).join('')}
              <span>${tr('高', 'More')}</span>
            </span>
            <span>${tr('按本地自然日统计', 'By local calendar day')}</span>
          </div>
        </div>
      </div>

      <div class="card ${dailyCollapsed ? 'is-collapsed' : ''}">
        <div class="card-header collapsible-header" data-collapse-card="daily">
          <div class="card-title-group">
            ${collapseChevron('daily', dailyCollapsed)}
            <h3 class="card-title">${tr('近 14 日 Token 趋势', '14-Day Token Trend')}</h3>
          </div>
          <span class="muted">
            ${hoveredDay
              ? `${hoveredDay.dateKey} · ${compactTokens(hoveredDay.totalTokens)} · ${formatUSD(hoveredDay.estimatedCostUSD)}`
              : tr('悬停或点击柱条查看当日详情', 'Hover or click a bar for details')}
          </span>
        </div>
        <div class="card-body">
          ${renderDailyChart(recent)}
        </div>
      </div>

      <div class="card ${modelsCollapsed ? 'is-collapsed' : ''}">
        <div class="card-header collapsible-header" data-collapse-card="models">
          <div class="card-title-group">
            ${collapseChevron('models', modelsCollapsed)}
            <h3 class="card-title">${tr4(
              `按模型用量与预估费用（${periodLabel}）`,
              `按模型用量與預估費用（${periodLabel}）`,
              `Usage & Est. Cost by Model (${periodLabel})`,
              `По моделям (${periodLabel})`
            )}</h3>
          </div>
          <span class="muted">${tr('参考 API 定价估算，非实际扣费', 'Estimated via API pricing, not actual billing')}</span>
        </div>
        <div class="card-body">
          ${renderModelBreakdown(models)}
        </div>
      </div>
    </div>
  `;
}

function renderDailyChart(recent: DailyBucketDTO[]): string {
  if (recent.length === 0) {
    return `<div class="empty-box">${tr('暂无近 14 日用量记录', 'No usage data in the last 14 days')}</div>`;
  }
  const maxVal = Math.max(1, ...recent.map((d) => d.totalTokens));
  const yLabels = [
    compactTokensShort(maxVal),
    compactTokensShort(Math.round(maxVal * 0.5)),
    '0',
  ];

  const colsHtml = recent.map((d) => {
    const pctH = d.totalTokens > 0 ? Math.max(2, (d.totalTokens / maxVal) * 100) : 0;
    const active = d.dateKey === state.hoveredBarDate;
    return `
      <div class="bar-col">
        <button type="button" class="bar-item ${active ? 'active' : ''}" data-bar-date="${escapeHtml(d.dateKey)}" style="height:${pctH.toFixed(2)}%" title="${escapeHtml(d.dateKey)}: ${compactTokens(d.totalTokens)} (${formatUSD(d.estimatedCostUSD)})"></button>
      </div>
    `;
  }).join('');

  const xLabelsHtml = recent.map((d, idx) => {
    const showLabel = recent.length <= 8 || idx % 2 === 0 || idx === recent.length - 1;
    return `<span class="bar-x-label">${showLabel ? escapeHtml(d.dateKey.slice(5)) : ''}</span>`;
  }).join('');

  return `
    <div class="bar-chart">
      <div class="bar-chart-main">
        <div class="bar-y-axis mono">
          ${yLabels.map((lbl) => `<span>${lbl}</span>`).join('')}
        </div>
        <div class="bar-plot">
          <div class="bar-grid">
            <div class="bar-grid-line"></div>
            <div class="bar-grid-line"></div>
            <div class="bar-grid-line"></div>
          </div>
          <div class="bar-cols">${colsHtml}</div>
        </div>
      </div>
      <div class="bar-x-axis mono">${xLabelsHtml}</div>
    </div>
  `;
}

function renderModelBreakdown(models: ModelUsageDTO[]): string {
  if (models.length === 0) {
    return `<div class="muted">${tr('所选周期暂无模型调用记录。', 'No model usage recorded in this period.')}</div>`;
  }
  const top6 = models.slice(0, 6);
  const sumTop6 = Math.max(1, top6.reduce((acc, m) => acc + Math.max(1, m.totalTokens), 0));
  const r = 42;
  const circ = 2 * Math.PI * r;
  let offset = 0;

  const slices = top6.map((m, idx) => {
    const frac = Math.max(1, m.totalTokens) / sumTop6;
    const len = frac * circ;
    const strokeDash = `${Math.max(1, len - 2).toFixed(2)} ${(circ - Math.max(1, len - 2)).toFixed(2)}`;
    const seg = `<circle cx="58" cy="58" r="${r}" fill="none" stroke="${PALETTE[idx % PALETTE.length]}" stroke-width="16" stroke-dasharray="${strokeDash}" stroke-dashoffset="${(-offset).toFixed(2)}" transform="rotate(-90 58 58)" />`;
    offset += len;
    return seg;
  }).join('');

  const maxTokens = Math.max(1, ...models.map((m) => m.totalTokens));
  const rows = models.slice(0, 8).map((m, idx) => {
    const pct = Math.max(2, (m.totalTokens / maxTokens) * 100);
    const color = PALETTE[idx % PALETTE.length];
    return `
      <div class="model-row">
        <span class="model-name" title="${escapeHtml(m.displayName)}">
          <span class="dot" style="display:inline-block;margin-right:5px;background:${color}"></span>${escapeHtml(m.displayName)}
        </span>
        <div class="linear-track">
          <div class="linear-fill" style="width:${pct.toFixed(1)}%;background:${color}"></div>
        </div>
        <span class="model-num mono">${compactTokens(m.totalTokens)}</span>
        <span class="model-num mono" style="font-weight:600;">${formatUSD(m.estimatedCostUSD)}</span>
      </div>
    `;
  }).join('');

  return `
    <div class="model-breakdown">
      <svg class="donut-svg" viewBox="0 0 116 116">${slices}</svg>
      <div class="model-rows">${rows}</div>
    </div>
  `;
}

function render() {
  const root = document.getElementById('app');
  if (!root) return;

  document.documentElement.lang = currentLang();
  const prevScroller = root.querySelector('.heatmap-scroll') as HTMLElement | null;
  const prevScrollLeft = prevScroller ? prevScroller.scrollLeft : null;

  const bodyHtml = state.activeTab === 'monitor'
    ? (state.live
        ? `<div class="stack">${renderProxyCard(state.live)}${renderContextCard(state.live)}${renderQuotaCard(state.live)}</div>`
        : `<div class="card empty-box">${tr('正在加载实时监控…', 'Loading live monitor…')}</div>`)
    : renderUsageTab(state.usage);

  root.innerHTML = `
    <div class="shell">
      ${renderTopBar()}
      ${state.errorBanner ? `<div class="banner" style="margin-bottom:12px;">${escapeHtml(state.errorBanner)}</div>` : ''}
      ${state.live?.liveError ? `<div class="banner" style="margin-bottom:12px;">${tr('本地监控刷新异常：', 'Local monitor refresh error: ')}${escapeHtml(state.live.liveError)}</div>` : ''}
      ${bodyHtml}
    </div>
  `;

  if (state.activeTab === 'usage') {
    const scroller = root.querySelector('.heatmap-scroll') as HTMLElement | null;
    if (scroller) {
      if (!state.didAutoScrollHeatmap) {
        if (scroller.scrollWidth > scroller.clientWidth) {
          scroller.scrollLeft = scroller.scrollWidth;
        }
        state.didAutoScrollHeatmap = true;
      } else if (prevScrollLeft !== null) {
        scroller.scrollLeft = prevScrollLeft;
      }
    }
  } else {
    state.didAutoScrollHeatmap = false;
  }
}

document.addEventListener('click', (e) => {
  const target = e.target as HTMLElement | null;
  if (!target) return;

  const cell = target.closest('.heatmap-cell') as HTMLElement | null;
  if (cell?.dataset.date) {
    state.selectedHeatmapDate = cell.dataset.date;
    render();
    return;
  }

  const bar = target.closest('.bar-item') as HTMLElement | null;
  if (bar?.dataset.barDate) {
    state.hoveredBarDate = bar.dataset.barDate;
    render();
    return;
  }

  const actionEl = target.closest('[data-action]') as HTMLElement | null;
  const action = actionEl?.dataset.action;

  if (action === 'tab') {
    const tab = actionEl?.dataset.tab as TabKey;
    if (tab === 'monitor' || tab === 'usage') {
      state.activeTab = tab;
      render();
    }
    return;
  }
  if (action === 'period') {
    const p = actionEl?.dataset.period as PeriodKey;
    if (p) {
      state.selectedPeriod = p;
      render();
    }
    return;
  }
  if (action === 'refresh-all') {
    void refreshLive(true);
    void refreshUsage();
    return;
  }
  if (action === 'probe-proxy') {
    void runProxyProbe();
    return;
  }
  if (action === 'toggle-noproxy') {
    state.showNoProxy = !state.showNoProxy;
    render();
    return;
  }
  if (action === 'toggle-pool' && actionEl?.dataset.poolId) {
    const id = actionEl.dataset.poolId;
    if (state.expandedPools.has(id)) state.expandedPools.delete(id);
    else state.expandedPools.add(id);
    render();
    return;
  }
  if (action === 'toggle-all-cards') {
    const ids = getActiveTabCardIds();
    const allCollapsed = ids.length > 0 && ids.every((id) => state.collapsedCards.has(id));
    for (const id of ids) {
      if (allCollapsed) state.collapsedCards.delete(id);
      else state.collapsedCards.add(id);
    }
    saveCollapsedCards(state.collapsedCards);
    render();
    return;
  }
  if (action === 'toggle-card' && actionEl?.dataset.cardId) {
    const id = actionEl.dataset.cardId;
    if (state.collapsedCards.has(id)) state.collapsedCards.delete(id);
    else state.collapsedCards.add(id);
    saveCollapsedCards(state.collapsedCards);
    render();
    return;
  }

  const headerEl = target.closest('[data-collapse-card]') as HTMLElement | null;
  if (headerEl?.dataset.collapseCard) {
    if (target.closest('button:not([data-action="toggle-card"]), select, input, a')) {
      return;
    }
    const id = headerEl.dataset.collapseCard;
    if (state.collapsedCards.has(id)) state.collapsedCards.delete(id);
    else state.collapsedCards.add(id);
    saveCollapsedCards(state.collapsedCards);
    render();
  }
});

document.addEventListener('change', (e) => {
  const target = e.target as HTMLSelectElement | null;
  if (target?.dataset.action === 'select-session') {
    state.selectedCascadeId = target.value || null;
    void refreshLive(false, true);
  }
});

async function bootstrap() {
  render();
  try {
    await app.connect();
    const ctx = app.getHostContext();
    applyTheme(ctx?.theme, ctx?.styles?.variables as Record<string, string> | undefined);
  } catch (err) {
    state.errorBanner = err instanceof Error ? err.message : String(err);
    render();
  }

  let tick = 0;
  setInterval(() => {
    if (document.visibilityState !== 'visible') return;
    tick += 1;
    if (state.activeTab === 'monitor') {
      void refreshLive(false);
    } else if (tick % 12 === 0) {
      void refreshUsage();
    }
  }, 5000);
}

void bootstrap();
