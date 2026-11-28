import Darwin
import Foundation

enum RuntimeIconStyle: String, Codable, Equatable, CaseIterable, Sendable {
    case originalWithBadge
    case pilotCat
    case original
}

enum ChartPalettePreset: String, Codable, Equatable, CaseIterable, Identifiable, Sendable {
    case morandiClassic = "morandi-classic"
    case morandiWarm = "morandi-warm"
    case morandiNordic = "morandi-nordic"
    case systemVibrant = "system-vibrant"

    var id: String { rawValue }

    func displayName(in lang: AppLanguage) -> String {
        switch self {
        case .morandiClassic:
            return L10n.t(zhHans: "经典莫兰迪", zhHant: "經典莫蘭迪", en: "Classic Morandi", ru: "Классический Моранди", lang)
        case .morandiWarm:
            return L10n.t(zhHans: "暖陶画廊", zhHant: "暖陶畫廊", en: "Warm Terracotta", ru: "Тёплая терракота", lang)
        case .morandiNordic:
            return L10n.t(zhHans: "北欧冷雾", zhHant: "北歐冷霧", en: "Nordic Mist", ru: "Северный туман", lang)
        case .systemVibrant:
            return L10n.t(zhHans: "经典原色", zhHant: "經典原色", en: "Classic Vibrant", ru: "Классический яркий", lang)
        }
    }
}

struct ProxyConfig: Codable, Equatable {
    static let defaultNoProxy = "localhost,127.0.0.1,::1,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.local,<local>"

    var host: String
    var hookPort: Int
    var envScheme: String
    var envPort: Int
    var runtimeIconStyle: RuntimeIconStyle
    var noProxy: String
    var enableMenuBarMonitor: Bool
    var showMenuBarMetrics: Bool
    var showMenuBarRunningStatus: Bool
    var showMenuBarContextUsage: Bool
    var showMenuBarQuotaPercent: Bool
    var appLanguage: AppLanguage
    var chartPalette: ChartPalettePreset
    var autoCheckUpdates: Bool
    var skippedUpdateVersion: String?
    var skippedAntigravityVersion: String?
    var preventSleepWhileRunning: Bool
    var notifyOnTaskComplete: Bool
    var notifyOnApprovalNeeded: Bool
    var notifyOnQuotaRecovered: Bool
    var notifyOnlyWhenBackground: Bool

    var useOriginalIcon: Bool {
        get { runtimeIconStyle == .original }
        set { runtimeIconStyle = newValue ? .original : .originalWithBadge }
    }

    var hasAnyMenuBarContent: Bool {
        showMenuBarRunningStatus || showMenuBarContextUsage || showMenuBarQuotaPercent
    }

    mutating func syncMenuBarMetricsMasterFlag() {
        showMenuBarMetrics = hasAnyMenuBarContent
    }

    mutating func setMenuBarMetricsMaster(_ enabled: Bool) {
        showMenuBarMetrics = enabled
        if !enabled {
            showMenuBarRunningStatus = false
            showMenuBarContextUsage = false
            showMenuBarQuotaPercent = false
        } else if !hasAnyMenuBarContent {
            showMenuBarRunningStatus = true
            showMenuBarContextUsage = true
            showMenuBarQuotaPercent = true
        }
    }

    static let defaultConfig = ProxyConfig(
        host: "127.0.0.1",
        hookPort: 7890,
        envScheme: "http",
        envPort: 7890,
        runtimeIconStyle: .originalWithBadge,
        noProxy: defaultNoProxy,
        enableMenuBarMonitor: true,
        showMenuBarMetrics: true,
        showMenuBarRunningStatus: true,
        showMenuBarContextUsage: true,
        showMenuBarQuotaPercent: true,
        appLanguage: .system,
        chartPalette: .morandiClassic,
        autoCheckUpdates: true,
        skippedUpdateVersion: nil,
        skippedAntigravityVersion: nil,
        preventSleepWhileRunning: true,
        notifyOnTaskComplete: true,
        notifyOnApprovalNeeded: true,
        notifyOnQuotaRecovered: true,
        notifyOnlyWhenBackground: true
    )

    init(
        host: String,
        hookPort: Int,
        envScheme: String,
        envPort: Int,
        runtimeIconStyle: RuntimeIconStyle = .originalWithBadge,
        noProxy: String = ProxyConfig.defaultNoProxy,
        enableMenuBarMonitor: Bool = true,
        showMenuBarMetrics: Bool = true,
        showMenuBarRunningStatus: Bool = true,
        showMenuBarContextUsage: Bool = true,
        showMenuBarQuotaPercent: Bool = true,
        appLanguage: AppLanguage = .system,
        chartPalette: ChartPalettePreset = .morandiClassic,
        autoCheckUpdates: Bool = true,
        skippedUpdateVersion: String? = nil,
        skippedAntigravityVersion: String? = nil,
        preventSleepWhileRunning: Bool = true,
        notifyOnTaskComplete: Bool = true,
        notifyOnApprovalNeeded: Bool = true,
        notifyOnQuotaRecovered: Bool = true,
        notifyOnlyWhenBackground: Bool = true
    ) {
        self.host = host
        self.hookPort = hookPort
        self.envScheme = envScheme
        self.envPort = envPort
        self.runtimeIconStyle = runtimeIconStyle
        self.noProxy = noProxy
        self.enableMenuBarMonitor = enableMenuBarMonitor
        self.showMenuBarMetrics = showMenuBarMetrics
        self.showMenuBarRunningStatus = showMenuBarRunningStatus
        self.showMenuBarContextUsage = showMenuBarContextUsage
        self.showMenuBarQuotaPercent = showMenuBarQuotaPercent
        self.appLanguage = appLanguage
        self.chartPalette = chartPalette
        self.autoCheckUpdates = autoCheckUpdates
        self.skippedUpdateVersion = skippedUpdateVersion
        self.skippedAntigravityVersion = skippedAntigravityVersion
        self.preventSleepWhileRunning = preventSleepWhileRunning
        self.notifyOnTaskComplete = notifyOnTaskComplete
        self.notifyOnApprovalNeeded = notifyOnApprovalNeeded
        self.notifyOnQuotaRecovered = notifyOnQuotaRecovered
        self.notifyOnlyWhenBackground = notifyOnlyWhenBackground
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case hookPort
        case envScheme
        case envPort
        case runtimeIconStyle
        case useOriginalIcon
        case noProxy
        case enableMenuBarMonitor
        case showMenuBarMetrics
        case showMenuBarRunningStatus
        case showMenuBarContextUsage
        case showMenuBarQuotaPercent
        case appLanguage
        case chartPalette
        case autoCheckUpdates
        case skippedUpdateVersion
        case skippedAntigravityVersion
        case preventSleepWhileRunning
        case notifyOnTaskComplete
        case notifyOnApprovalNeeded
        case notifyOnQuotaRecovered
        case notifyOnlyWhenBackground
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        hookPort = try container.decode(Int.self, forKey: .hookPort)
        envScheme = try container.decode(String.self, forKey: .envScheme)
        envPort = try container.decode(Int.self, forKey: .envPort)
        if let style = try container.decodeIfPresent(RuntimeIconStyle.self, forKey: .runtimeIconStyle) {
            runtimeIconStyle = style
        } else {
            let legacyOriginal = try container.decodeIfPresent(Bool.self, forKey: .useOriginalIcon) ?? false
            runtimeIconStyle = legacyOriginal ? .original : .originalWithBadge
        }
        let decodedNoProxy = try container.decodeIfPresent(String.self, forKey: .noProxy)
        noProxy = (decodedNoProxy?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? decodedNoProxy!
            : ProxyConfig.defaultNoProxy
        enableMenuBarMonitor = try container.decodeIfPresent(Bool.self, forKey: .enableMenuBarMonitor) ?? true
        let legacyMetrics = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarMetrics) ?? true
        showMenuBarRunningStatus = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarRunningStatus) ?? legacyMetrics
        showMenuBarContextUsage = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarContextUsage) ?? legacyMetrics
        showMenuBarQuotaPercent = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarQuotaPercent) ?? legacyMetrics
        showMenuBarMetrics = showMenuBarRunningStatus || showMenuBarContextUsage || showMenuBarQuotaPercent
        appLanguage = try container.decodeIfPresent(AppLanguage.self, forKey: .appLanguage) ?? .system
        chartPalette = (try? container.decodeIfPresent(ChartPalettePreset.self, forKey: .chartPalette)) ?? .morandiClassic
        autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        skippedUpdateVersion = try container.decodeIfPresent(String.self, forKey: .skippedUpdateVersion)
        skippedAntigravityVersion = try container.decodeIfPresent(String.self, forKey: .skippedAntigravityVersion)
        preventSleepWhileRunning = try container.decodeIfPresent(Bool.self, forKey: .preventSleepWhileRunning) ?? true
        notifyOnTaskComplete = try container.decodeIfPresent(Bool.self, forKey: .notifyOnTaskComplete) ?? true
        notifyOnApprovalNeeded = try container.decodeIfPresent(Bool.self, forKey: .notifyOnApprovalNeeded) ?? true
        notifyOnQuotaRecovered = try container.decodeIfPresent(Bool.self, forKey: .notifyOnQuotaRecovered) ?? true
        notifyOnlyWhenBackground = try container.decodeIfPresent(Bool.self, forKey: .notifyOnlyWhenBackground) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(hookPort, forKey: .hookPort)
        try container.encode(envScheme, forKey: .envScheme)
        try container.encode(envPort, forKey: .envPort)
        try container.encode(runtimeIconStyle, forKey: .runtimeIconStyle)
        try container.encode(useOriginalIcon, forKey: .useOriginalIcon)
        try container.encode(noProxy, forKey: .noProxy)
        try container.encode(enableMenuBarMonitor, forKey: .enableMenuBarMonitor)
        try container.encode(hasAnyMenuBarContent, forKey: .showMenuBarMetrics)
        try container.encode(showMenuBarRunningStatus, forKey: .showMenuBarRunningStatus)
        try container.encode(showMenuBarContextUsage, forKey: .showMenuBarContextUsage)
        try container.encode(showMenuBarQuotaPercent, forKey: .showMenuBarQuotaPercent)
        try container.encode(appLanguage, forKey: .appLanguage)
        try container.encode(chartPalette, forKey: .chartPalette)
        try container.encode(autoCheckUpdates, forKey: .autoCheckUpdates)
        try container.encodeIfPresent(skippedUpdateVersion, forKey: .skippedUpdateVersion)
        try container.encodeIfPresent(skippedAntigravityVersion, forKey: .skippedAntigravityVersion)
        try container.encode(preventSleepWhileRunning, forKey: .preventSleepWhileRunning)
        try container.encode(notifyOnTaskComplete, forKey: .notifyOnTaskComplete)
        try container.encode(notifyOnApprovalNeeded, forKey: .notifyOnApprovalNeeded)
        try container.encode(notifyOnQuotaRecovered, forKey: .notifyOnQuotaRecovered)
        try container.encode(notifyOnlyWhenBackground, forKey: .notifyOnlyWhenBackground)
    }

    static func normalizeHost(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        if trimmed.caseInsensitiveCompare("localhost") == .orderedSame {
            return "127.0.0.1"
        }
        return trimmed
    }

    static func isValidNumericIP(_ host: String) -> Bool {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return false }
        var addr4 = in_addr()
        if inet_pton(AF_INET, normalized, &addr4) == 1 {
            return true
        }
        var addr6 = in6_addr()
        return inet_pton(AF_INET6, normalized, &addr6) == 1
    }

    var normalizedHost: String {
        Self.normalizeHost(host)
    }

    var urlFormattedHost: String {
        let h = normalizedHost
        return h.contains(":") ? "[\(h)]" : h
    }

    var displayHookHostPort: String {
        "\(urlFormattedHost):\(hookPort)"
    }

    var displayEnvHostPort: String {
        "\(urlFormattedHost):\(envPort)"
    }

    var hookProxyURL: String {
        "socks5://\(displayHookHostPort)"
    }

    var envProxyURL: String {
        "\(envScheme)://\(displayEnvHostPort)"
    }

    var effectiveNoProxy: String {
        let trimmed = noProxy
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        return trimmed.isEmpty ? ProxyConfig.defaultNoProxy : trimmed
    }
}

enum BuilderError: LocalizedError {
    case missingSourceApp(String)
    case missingResource(String)
    case invalidPort(String)
    case commandFailed(String)
    case asarFormat(String)

    var errorDescription: String? {
        switch self {
        case .missingSourceApp(let path):
            return L10n.t(
                zhHans: "找不到原版 Antigravity：\(path)",
                zhHant: "找不到原版 Antigravity：\(path)",
                en: "Original Antigravity not found: \(path)",
                ru: "Не найден оригинальный Antigravity: \(path)"
            )
        case .missingResource(let name):
            return L10n.t(
                zhHans: "Builder App 缺少资源：\(name)",
                zhHant: "Builder App 缺少資源：\(name)",
                en: "Missing resource in Builder App: \(name)",
                ru: "В Builder App отсутствует ресурс: \(name)"
            )
        case .invalidPort(let message):
            return message
        case .commandFailed(let message):
            return message
        case .asarFormat(let message):
            return L10n.t(
                zhHans: "app.asar patch 失败：\(message)",
                zhHant: "app.asar patch 失敗：\(message)",
                en: "app.asar patch failed: \(message)",
                ru: "Ошибка патча app.asar: \(message)"
            )
        }
    }
}

enum RuntimeStatusKind {
    case ready
    case updateNeeded
    case notBuilt
    case missingSource
}

enum BuildApplyOutcome {
    case fastHotUpdated
    case fullRebuilt
}

enum ProxyHealthLevel: Equatable {
    case checking
    case healthy
    case degraded
    case failed
}

struct ProxyHealthReport: Equatable {
    let tcpReachable: Bool
    let socks5HandshakeOK: Bool
    let envPortReachable: Bool
    let internetReachable: Bool?
    let latencyMs: Int?
    let level: ProxyHealthLevel
    let summaryTitle: String
    let detailMessage: String
    let checkedAt: Date

    static var checking: ProxyHealthReport {
        checking(lang: L10n.current)
    }

    static func checking(lang: AppLanguage = L10n.current) -> ProxyHealthReport {
        ProxyHealthReport(
            tcpReachable: false,
            socks5HandshakeOK: false,
            envPortReachable: false,
            internetReachable: nil,
            latencyMs: nil,
            level: .checking,
            summaryTitle: L10n.t("检测中...", "Checking...", lang),
            detailMessage: L10n.t(
                "正在执行本地端口、SOCKS5 握手与出网验证...",
                "Probing local port, SOCKS5 handshake, and internet connectivity...",
                lang
            ),
            checkedAt: Date()
        )
    }
}
