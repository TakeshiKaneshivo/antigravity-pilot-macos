import Darwin
import Foundation

final class PilotMCPService: MCPServiceHandling, @unchecked Sendable {
    let serverVersion: String
    private let explicitHTMLPath: String?
    private let support = AppSupport()
    private let rpcClient = LanguageServerClient()

    init(htmlPath: String?, version: String) {
        self.explicitHTMLPath = htmlPath
        self.serverVersion = version
    }

    func currentLanguage() -> AppLanguage {
        let (config, _) = loadProxyConfig()
        return config.appLanguage
    }

    func loadDashboardHTML() throws -> String {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let envPath = ProcessInfo.processInfo.environment["PILOT_MCP_HTML"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envPath.isEmpty {
            candidates.append(URL(fileURLWithPath: envPath))
        }
        if let explicitHTMLPath, !explicitHTMLPath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitHTMLPath))
        }

        let execURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
        let execDir = execURL.deletingLastPathComponent()
        candidates.append(
            execDir.deletingLastPathComponent()
                .appendingPathComponent("assets/dashboard.html")
        )
        candidates.append(execDir.appendingPathComponent("pilot-mcp-dashboard.html"))

        for url in candidates where fm.fileExists(atPath: url.path) {
            let html = try String(contentsOf: url, encoding: .utf8)
            if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return html
            }
        }

        throw NSError(
            domain: "PilotMCPService",
            code: 404,
            userInfo: [
                NSLocalizedDescriptionKey: "Dashboard HTML not found. Searched: \(candidates.map(\.path).joined(separator: ", "))"
            ]
        )
    }

    func callTool(name: String, arguments: [String: Any]) async -> MCPToolResult {
        switch name {
        case "open_pilot_monitor":
            let cascadeId = arguments["cascadeId"] as? String
            let (config, configExists) = loadProxyConfig()
            let lang = config.appLanguage
            async let liveTask = buildLiveSnapshot(config: config, configExists: configExists, cascadeId: cascadeId, includeInternetCheck: true)
            async let usageTask = buildUsageHistoryAsync()
            let (live, usage) = await (liveTask, usageTask)
            let summary = formatMonitorSummary(live: live, usage: usage, lang: lang)
            return MCPToolResult(
                text: summary,
                structuredContent: [
                    "initialTab": "monitor",
                    "live": live,
                    "usage": usage
                ]
            )

        case "open_pilot_usage":
            let period = normalizePeriodKey(arguments["period"] as? String)
            let (config, configExists) = loadProxyConfig()
            let lang = config.appLanguage
            async let liveTask = buildLiveSnapshot(config: config, configExists: configExists, cascadeId: nil, includeInternetCheck: true)
            async let usageTask = buildUsageHistoryAsync()
            let (live, usage) = await (liveTask, usageTask)
            let summary = formatUsageSummary(usage: usage, period: period, lang: lang)
            return MCPToolResult(
                text: summary,
                structuredContent: [
                    "initialTab": "usage",
                    "initialPeriod": period,
                    "live": live,
                    "usage": usage
                ]
            )

        case "pilot_get_live_snapshot":
            let cascadeId = arguments["cascadeId"] as? String
            let includeInternetCheck = (arguments["includeInternetCheck"] as? Bool) ?? false
            let (config, configExists) = loadProxyConfig()
            let live = await buildLiveSnapshot(config: config, configExists: configExists, cascadeId: cascadeId, includeInternetCheck: includeInternetCheck)
            return MCPToolResult(text: "ok", structuredContent: live)

        case "pilot_probe_proxy":
            let (config, configExists) = loadProxyConfig()
            let report = await ProxyHealthService.probe(config: config, includeInternetCheck: true)
            return MCPToolResult(
                text: report.summaryTitle,
                structuredContent: [
                    "proxyConfig": encodeProxyConfig(config, exists: configExists),
                    "proxyHealth": encodeProxyHealth(report)
                ]
            )

        case "pilot_get_usage_history":
            let usage = await buildUsageHistoryAsync()
            return MCPToolResult(text: "ok", structuredContent: usage)

        default:
            return MCPToolResult(
                text: "Unknown tool: \(name)",
                structuredContent: [:],
                isError: true
            )
        }
    }

    private func loadProxyConfig() -> (ProxyConfig, Bool) {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: support.configURL.path) || fm.fileExists(atPath: support.legacyConfigURL.path)
        let config = (try? support.loadConfig()) ?? .defaultConfig
        L10n.current = config.appLanguage
        return (config, exists)
    }

    private func buildLiveSnapshot(
        config: ProxyConfig,
        configExists: Bool,
        cascadeId preferredId: String?,
        includeInternetCheck: Bool
    ) async -> [String: Any] {
        let lang = config.appLanguage
        async let healthTask = ProxyHealthService.probe(config: config, includeInternetCheck: includeInternetCheck)
        async let hubTask = Task.detached(priority: .utility) {
            LanguageServerClient.discoverLiveHub()
        }.value

        let report = await healthTask
        let hub = await hubTask

        let isoFormatter = Self.makeISOFormatter()
        var out: [String: Any] = [
            "connected": hub != nil,
            "proxyConfig": encodeProxyConfig(config, exists: configExists),
            "proxyHealth": encodeProxyHealth(report),
            "sessions": [] as [[String: Any]],
            "quotaPools": [] as [[String: Any]],
            "updatedAtISO": isoFormatter.string(from: Date())
        ]

        guard let hub else {
            return out
        }

        out["hub"] = [
            "pid": Int(hub.pid),
            "httpPort": hub.httpPort as Any,
            "httpsPort": hub.httpsPort as Any,
            "lsVersion": hub.lsVersion ?? ""
        ]

        do {
            async let statusTask = rpcClient.fetchUserStatus(hub: hub, lang: lang)
            async let sessionsTask = rpcClient.fetchSessions(hub: hub)

            let (profile, pools, labels) = try await statusTask
            let sessionList = try await sessionsTask

            if let profile {
                out["userProfile"] = [
                    "name": profile.name,
                    "email": profile.email,
                    "tierName": profile.tierName
                ]
            }

            let targetSession = sessionList.first(where: { $0.id == preferredId }) ?? sessionList.first
            var displayedSessions = Array(sessionList.prefix(20))
            if let target = targetSession, !displayedSessions.contains(where: { $0.id == target.id }) {
                displayedSessions.append(target)
            }

            out["sessions"] = displayedSessions.map { s in
                [
                    "id": s.id,
                    "title": s.title,
                    "stepCount": s.stepCount,
                    "status": s.status,
                    "isRunning": s.isRunning,
                    "lastModifiedISO": s.lastModifiedTime.map { isoFormatter.string(from: $0) } ?? ""
                ]
            }

            if let targetSession {
                out["selectedCascadeId"] = targetSession.id
                if let ctx = try await rpcClient.fetchSessionContext(hub: hub, session: targetSession, modelLabels: labels) {
                    out["activeContext"] = [
                        "cascadeId": ctx.cascadeId,
                        "title": ctx.title,
                        "modelId": ctx.modelId,
                        "modelDisplayName": ctx.modelDisplayName,
                        "inputTokens": ctx.inputTokens,
                        "cacheReadTokens": ctx.cacheReadTokens,
                        "outputTokens": ctx.outputTokens,
                        "thinkingOutputTokens": ctx.thinkingOutputTokens,
                        "responseOutputTokens": ctx.responseOutputTokens,
                        "activeContextTokens": ctx.activeContextTokens,
                        "totalTurnTokens": ctx.totalTurnTokens,
                        "contextLimitTokens": ctx.contextLimitTokens,
                        "usageFraction": ctx.usageFraction,
                        "cacheHitRatio": ctx.cacheHitRatio,
                        "timeToFirstTokenSec": ctx.timeToFirstTokenSec as Any,
                        "streamingDurationSec": ctx.streamingDurationSec as Any,
                        "tokensPerSecond": ctx.tokensPerSecond as Any
                    ]
                }
            }

            out["quotaPools"] = pools.map { pool in
                [
                    "id": pool.id,
                    "title": pool.title,
                    "remainingFraction": pool.remainingFraction,
                    "remainingPercent": pool.remainingPercent,
                    "resetCountdownText": pool.resetCountdownText(lang),
                    "models": pool.models.map { m in
                        [
                            "id": m.id,
                            "label": m.label,
                            "modelId": m.modelId,
                            "remainingFraction": m.remainingFraction as Any,
                            "tagTitle": m.tagTitle ?? ""
                        ]
                    }
                ]
            }
        } catch {
            out["liveError"] = error.localizedDescription
        }

        return out
    }

    private func buildUsageHistoryAsync() async -> [String: Any] {
        await Task.detached(priority: .utility) { [support] in
            let snapshot = TranscriptScanner.scan(
                cacheURL: support.usageCacheURL,
                customPricingURL: support.customPricingURL
            )
            return Self.encodeUsageHistory(snapshot)
        }.value
    }

    private func encodeProxyConfig(_ config: ProxyConfig, exists: Bool) -> [String: Any] {
        [
            "configExists": exists,
            "host": config.host,
            "hookPort": config.hookPort,
            "envScheme": config.envScheme,
            "envPort": config.envPort,
            "hookProxyURL": config.hookProxyURL,
            "envProxyURL": config.envProxyURL,
            "noProxy": config.effectiveNoProxy,
            "useOriginalIcon": config.useOriginalIcon,
            "appLanguage": config.appLanguage.rawValue,
            "resolvedLanguage": config.appLanguage.resolved.rawValue
        ]
    }

    private func encodeProxyHealth(_ report: ProxyHealthReport) -> [String: Any] {
        let levelStr: String
        switch report.level {
        case .checking: levelStr = "checking"
        case .healthy: levelStr = "healthy"
        case .degraded: levelStr = "degraded"
        case .failed: levelStr = "failed"
        }

        return [
            "level": levelStr,
            "tcpReachable": report.tcpReachable,
            "socks5HandshakeOK": report.socks5HandshakeOK,
            "envPortReachable": report.envPortReachable,
            "internetReachable": report.internetReachable as Any,
            "latencyMs": report.latencyMs as Any,
            "summaryTitle": report.summaryTitle,
            "detailMessage": report.detailMessage,
            "checkedAtISO": Self.makeISOFormatter().string(from: report.checkedAt)
        ]
    }

    private static func encodeUsageHistory(_ snapshot: UsageHistorySnapshot) -> [String: Any] {
        let recent14 = Array(snapshot.dailyBuckets.suffix(14)).map(encodeDailyBucket)
        let heatmapWeeks = buildHeatmapMatrix(buckets: snapshot.dailyBuckets, weeksCount: 52)

        var totalsDict: [String: Any] = [:]
        var modelsDict: [String: Any] = [:]

        for period in UsagePeriod.allCases {
            let key = periodJSONKey(period)
            let bucket = snapshot.totalsByPeriod[period]
                ?? DailyUsageBucket(dateKey: "", inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0)
            totalsDict[key] = encodeDailyBucket(bucket)

            let models = (snapshot.modelSummariesByPeriod[period] ?? []).map { m in
                [
                    "modelKey": m.modelKey,
                    "displayName": m.displayName,
                    "inputTokens": m.inputTokens,
                    "cacheReadTokens": m.cacheReadTokens,
                    "outputTokens": m.outputTokens,
                    "totalTokens": m.totalTokens,
                    "requestCount": m.requestCount,
                    "estimatedCostUSD": m.estimatedCostUSD
                ] as [String: Any]
            }
            modelsDict[key] = models
        }

        return [
            "recent14Days": recent14,
            "heatmapWeeks": heatmapWeeks,
            "totalsByPeriod": totalsDict,
            "modelSummariesByPeriod": modelsDict,
            "proSubscriptionMonthlyUSD": PricingCatalog.proSubscriptionMonthlyUSD,
            "scannedFilesCount": snapshot.scannedFilesCount,
            "scannedAtISO": makeISOFormatter().string(from: snapshot.scannedAt)
        ]
    }

    private static func encodeDailyBucket(_ b: DailyUsageBucket) -> [String: Any] {
        [
            "dateKey": b.dateKey,
            "inputTokens": b.inputTokens,
            "cacheReadTokens": b.cacheReadTokens,
            "outputTokens": b.outputTokens,
            "totalTokens": b.totalTokens,
            "requestCount": b.requestCount,
            "estimatedCostUSD": b.estimatedCostUSD
        ]
    }

    private static func buildHeatmapMatrix(buckets: [DailyUsageBucket], weeksCount: Int = 52) -> [[[String: Any]?]] {
        let map = Dictionary(uniqueKeysWithValues: buckets.map { ($0.dateKey, $0) })
        let nonZero = buckets.map(\.totalTokens).filter { $0 > 0 }.sorted()
        let q1 = nonZero.isEmpty ? 1 : nonZero[nonZero.count / 4]
        let q2 = nonZero.isEmpty ? 1 : nonZero[nonZero.count / 2]
        let q3 = nonZero.isEmpty ? 1 : nonZero[(nonZero.count * 3) / 4]

        let cal = Calendar(identifier: .gregorian)
        let df = DateFormatter()
        df.calendar = cal
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"

        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let currentMonday = cal.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
        let startMonday = cal.date(byAdding: .weekOfYear, value: -(weeksCount - 1), to: currentMonday) ?? currentMonday

        var weeks: [[[String: Any]?]] = []
        for w in 0..<weeksCount {
            var col: [[String: Any]?] = []
            for d in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: w * 7 + d, to: startMonday),
                      date <= today else {
                    col.append(nil)
                    continue
                }
                let key = df.string(from: date)
                let bucket = map[key]
                let tokens = bucket?.totalTokens ?? 0
                let level: Int
                if tokens <= 0 {
                    level = 0
                } else if tokens <= q1 {
                    level = 1
                } else if tokens <= q2 {
                    level = 2
                } else if tokens <= q3 {
                    level = 3
                } else {
                    level = 4
                }
                col.append([
                    "dateKey": key,
                    "level": level,
                    "totalTokens": tokens,
                    "requestCount": bucket?.requestCount ?? 0,
                    "estimatedCostUSD": bucket?.estimatedCostUSD ?? 0.0
                ])
            }
            weeks.append(col)
        }
        return weeks
    }

    private func formatMonitorSummary(live: [String: Any], usage: [String: Any], lang: AppLanguage) -> String {
        let health = (live["proxyHealth"] as? [String: Any])?["summaryTitle"] as? String ?? L10n.t("未知", "Unknown", lang)
        let connected = (live["connected"] as? Bool) ?? false
        var parts = [L10n.t(
            zhHans: "代理健康：\(health)",
            zhHant: "代理健康：\(health)",
            en: "Proxy Health: \(health)",
            ru: "Прокси: \(health)",
            lang
        )]
        if connected, let ctx = live["activeContext"] as? [String: Any] {
            let model = ctx["modelDisplayName"] as? String ?? L10n.t("模型", "Model", lang)
            let active = TokenFormatting.compactTokens(ctx["activeContextTokens"] as? Int ?? 0)
            let limit = TokenFormatting.compactTokens(ctx["contextLimitTokens"] as? Int ?? 0)
            parts.append(L10n.t(
                zhHans: "当前上下文（\(model)）：\(active) / \(limit)",
                zhHant: "目前上下文（\(model)）：\(active) / \(limit)",
                en: "Active Context (\(model)): \(active) / \(limit)",
                ru: "Контекст (\(model)): \(active) / \(limit)",
                lang
            ))
        }
        if let pools = live["quotaPools"] as? [[String: Any]], let first = pools.first {
            let title = first["title"] as? String ?? L10n.t("主配额池", "Primary Pool", lang)
            let pct = first["remainingPercent"] as? Int ?? 0
            parts.append(L10n.t(
                zhHans: "\(title) 余量：\(pct)%",
                zhHant: "\(title) 餘量：\(pct)%",
                en: "\(title) Remaining: \(pct)%",
                ru: "\(title) Остаток: \(pct)%",
                lang
            ))
        }
        if let today = (usage["totalsByPeriod"] as? [String: Any])?["today"] as? [String: Any] {
            let toks = TokenFormatting.compactTokens(today["totalTokens"] as? Int ?? 0)
            let usd = TokenFormatting.usd(today["estimatedCostUSD"] as? Double ?? 0)
            parts.append(L10n.t(
                zhHans: "今日用量：\(toks)（约 \(usd)）",
                zhHant: "今日用量：\(toks)（約 \(usd)）",
                en: "Today Usage: \(toks) (~\(usd))",
                ru: "За сегодня: \(toks) (~\(usd))",
                lang
            ))
        }
        return parts.joined(separator: " | ")
    }

    private func formatUsageSummary(usage: [String: Any], period: String, lang: AppLanguage) -> String {
        let totals = (usage["totalsByPeriod"] as? [String: Any])?[period] as? [String: Any]
        let toks = TokenFormatting.compactTokens(totals?["totalTokens"] as? Int ?? 0)
        let reqs = totals?["requestCount"] as? Int ?? 0
        let usd = TokenFormatting.usd(totals?["estimatedCostUSD"] as? Double ?? 0)
        let scanned = usage["scannedFilesCount"] as? Int ?? 0
        let periodLabel = usagePeriod(for: period).localizedTitle(lang)
        return L10n.t(
            zhHans: "周期（\(periodLabel)）累计 \(toks) Tokens，\(reqs) 次模型调用，估算 API 账单 \(usd)（已扫描 \(scanned) 个会话归档）。",
            zhHant: "週期（\(periodLabel)）累計 \(toks) Tokens，\(reqs) 次模型呼叫，估算 API 帳單 \(usd)（已掃描 \(scanned) 個工作階段歸檔）。",
            en: "Period (\(periodLabel)): \(toks) tokens, \(reqs) calls, est. API cost \(usd) (\(scanned) transcripts scanned).",
            ru: "Период (\(periodLabel)): \(toks) токенов, \(reqs) вызовов, оценка API \(usd) (просканировано логов: \(scanned)).",
            lang
        )
    }

    private func usagePeriod(for key: String) -> UsagePeriod {
        switch key {
        case "today": return .today
        case "days7": return .days7
        case "all": return .all
        default: return .days30
        }
    }

    private static func periodJSONKey(_ period: UsagePeriod) -> String {
        switch period {
        case .today: return "today"
        case .days7: return "days7"
        case .days30: return "days30"
        case .all: return "all"
        }
    }

    private func normalizePeriodKey(_ raw: String?) -> String {
        switch raw {
        case "today", "days7", "days30", "all": return raw!
        default: return "days30"
        }
    }

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        return df
    }
}

func parseArgs() -> (htmlPath: String?, version: String) {
    var htmlPath: String?
    var version = "0.1.0"
    let args = CommandLine.arguments
    var idx = 1
    while idx < args.count {
        let arg = args[idx]
        if arg == "--html", idx + 1 < args.count {
            htmlPath = args[idx + 1]
            idx += 2
        } else if arg == "--version", idx + 1 < args.count {
            version = args[idx + 1]
            idx += 2
        } else {
            idx += 1
        }
    }
    return (htmlPath, version)
}

signal(SIGPIPE, SIG_IGN)
let parsed = parseArgs()
let service = PilotMCPService(htmlPath: parsed.htmlPath, version: parsed.version)
let server = MCPStdioServer(handler: service)

let semaphore = DispatchSemaphore(value: 0)
Task {
    await server.run()
    semaphore.signal()
}
semaphore.wait()
