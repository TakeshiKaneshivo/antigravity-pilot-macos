import Darwin
import Foundation

struct ProxyConfig: Codable, Equatable {
    static let defaultNoProxy = "localhost,127.0.0.1,::1,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.local,<local>"

    var host: String
    var hookPort: Int
    var envScheme: String
    var envPort: Int
    var useOriginalIcon: Bool
    var noProxy: String
    var enableMenuBarMonitor: Bool
    var showMenuBarMetrics: Bool
    var appLanguage: AppLanguage
    var autoCheckUpdates: Bool
    var skippedUpdateVersion: String?
    var skippedAntigravityVersion: String?

    static let defaultConfig = ProxyConfig(
        host: "127.0.0.1",
        hookPort: 7890,
        envScheme: "http",
        envPort: 7890,
        useOriginalIcon: false,
        noProxy: defaultNoProxy,
        enableMenuBarMonitor: true,
        showMenuBarMetrics: true,
        appLanguage: .system,
        autoCheckUpdates: true,
        skippedUpdateVersion: nil,
        skippedAntigravityVersion: nil
    )

    init(
        host: String,
        hookPort: Int,
        envScheme: String,
        envPort: Int,
        useOriginalIcon: Bool = false,
        noProxy: String = ProxyConfig.defaultNoProxy,
        enableMenuBarMonitor: Bool = true,
        showMenuBarMetrics: Bool = true,
        appLanguage: AppLanguage = .system,
        autoCheckUpdates: Bool = true,
        skippedUpdateVersion: String? = nil,
        skippedAntigravityVersion: String? = nil
    ) {
        self.host = host
        self.hookPort = hookPort
        self.envScheme = envScheme
        self.envPort = envPort
        self.useOriginalIcon = useOriginalIcon
        self.noProxy = noProxy
        self.enableMenuBarMonitor = enableMenuBarMonitor
        self.showMenuBarMetrics = showMenuBarMetrics
        self.appLanguage = appLanguage
        self.autoCheckUpdates = autoCheckUpdates
        self.skippedUpdateVersion = skippedUpdateVersion
        self.skippedAntigravityVersion = skippedAntigravityVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        hookPort = try container.decode(Int.self, forKey: .hookPort)
        envScheme = try container.decode(String.self, forKey: .envScheme)
        envPort = try container.decode(Int.self, forKey: .envPort)
        useOriginalIcon = try container.decodeIfPresent(Bool.self, forKey: .useOriginalIcon) ?? false
        let decodedNoProxy = try container.decodeIfPresent(String.self, forKey: .noProxy)
        noProxy = (decodedNoProxy?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? decodedNoProxy!
            : ProxyConfig.defaultNoProxy
        enableMenuBarMonitor = try container.decodeIfPresent(Bool.self, forKey: .enableMenuBarMonitor) ?? true
        showMenuBarMetrics = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarMetrics) ?? true
        appLanguage = try container.decodeIfPresent(AppLanguage.self, forKey: .appLanguage) ?? .system
        autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        skippedUpdateVersion = try container.decodeIfPresent(String.self, forKey: .skippedUpdateVersion)
        skippedAntigravityVersion = try container.decodeIfPresent(String.self, forKey: .skippedAntigravityVersion)
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
