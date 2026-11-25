import Foundation

struct FlexibleInt: Codable, Hashable {
    let value: Int

    init(_ value: Int) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let strVal = try? container.decode(String.self),
                  let parsed = Int(strVal.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = parsed
        } else if let dblVal = try? container.decode(Double.self) {
            value = Int(dblVal)
        } else {
            value = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct DaemonHubInfo: Codable, Equatable {
    let pid: Int32
    let httpsPort: Int?
    let httpPort: Int?
    let lsVersion: String?
    let csrfToken: String
}

struct UserProfileInfo: Equatable {
    let name: String
    let email: String
    let tierName: String
}

struct ModelQuotaItem: Identifiable, Equatable {
    let id: String
    let label: String
    let modelId: String
    let remainingFraction: Double?
    let resetTime: Date?
    let resetTimeISO: String?
    let tagTitle: String?
}

struct QuotaPoolGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let remainingFraction: Double
    let resetTime: Date?
    let models: [ModelQuotaItem]

    var remainingPercent: Int {
        Int((min(max(remainingFraction, 0), 1) * 100).rounded())
    }

    var resetCountdownText: String {
        resetCountdownText(L10n.current)
    }

    func resetCountdownText(_ lang: AppLanguage) -> String {
        guard let resetTime else {
            return L10n.t("未知重置时间", "Reset time unknown", lang)
        }
        let diff = Int(resetTime.timeIntervalSinceNow)
        if diff <= 0 {
            return L10n.t("即将重置", "Resetting soon", lang)
        }
        let hours = diff / 3600
        let mins = (diff % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            let remHours = hours % 24
            return L10n.t(
                zhHans: "\(days)天 \(remHours)小时后重置",
                zhHant: "\(days)天 \(remHours)小時後重置",
                en: "Resets in \(days)d \(remHours)h",
                ru: "Сброс через \(days)д \(remHours)ч",
                lang
            )
        }
        if hours > 0 {
            return L10n.t(
                zhHans: "\(hours)小时 \(mins)分后重置",
                zhHant: "\(hours)小時 \(mins)分後重置",
                en: "Resets in \(hours)h \(mins)m",
                ru: "Сброс через \(hours)ч \(mins)м",
                lang
            )
        }
        return L10n.t(
            zhHans: "\(max(1, mins))分钟后重置",
            zhHant: "\(max(1, mins))分鐘後重置",
            en: "Resets in \(max(1, mins))m",
            ru: "Сброс через \(max(1, mins))м",
            lang
        )
    }
}

struct SessionSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let stepCount: Int
    let lastModifiedTime: Date?
    let status: String

    var isRunning: Bool {
        status.uppercased().contains("RUNNING")
    }
}

struct SessionContextSnapshot: Equatable {
    let cascadeId: String
    let title: String
    let modelId: String
    let modelDisplayName: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let thinkingOutputTokens: Int
    let responseOutputTokens: Int
    let contextLimitTokens: Int
    let timeToFirstTokenSec: Double?
    let streamingDurationSec: Double?
    let updatedAt: Date

    var activeContextTokens: Int {
        inputTokens + cacheReadTokens
    }

    var totalTurnTokens: Int {
        activeContextTokens + outputTokens
    }

    var usageFraction: Double {
        guard contextLimitTokens > 0 else { return 0 }
        return min(1.0, Double(activeContextTokens) / Double(contextLimitTokens))
    }

    var cacheHitRatio: Double {
        guard activeContextTokens > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(activeContextTokens)
    }

    var tokensPerSecond: Double? {
        guard let dur = streamingDurationSec, dur > 0.05, outputTokens > 0 else { return nil }
        return Double(outputTokens) / dur
    }
}

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today = "今日"
    case days7 = "近 7 天"
    case days30 = "近 30 天"
    case all = "全部"

    var id: String { rawValue }

    func localizedTitle(_ lang: AppLanguage) -> String {
        switch self {
        case .today: return L10n.t("今日", "Today", lang)
        case .days7: return L10n.t("近 7 天", "7 Days", lang)
        case .days30: return L10n.t("近 30 天", "30 Days", lang)
        case .all: return L10n.t("全部", "All", lang)
        }
    }
}

struct DailyUsageBucket: Identifiable, Equatable, Codable {
    var id: String { dateKey }
    let dateKey: String // YYYY-MM-DD (local timezone)
    var inputTokens: Int
    var cacheReadTokens: Int
    var outputTokens: Int
    var requestCount: Int
    var estimatedCostUSD: Double

    var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }
}

struct ModelUsageSummary: Identifiable, Equatable {
    var id: String { modelKey }
    let modelKey: String
    let displayName: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let requestCount: Int
    let estimatedCostUSD: Double

    var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }
}

struct UsageHistorySnapshot: Equatable {
    let dailyBuckets: [DailyUsageBucket] // sorted ascending by dateKey
    let modelSummariesByPeriod: [UsagePeriod: [ModelUsageSummary]]
    let totalsByPeriod: [UsagePeriod: DailyUsageBucket]
    let scannedFilesCount: Int
    let scannedAt: Date

    static let empty = UsageHistorySnapshot(
        dailyBuckets: [],
        modelSummariesByPeriod: [:],
        totalsByPeriod: [:],
        scannedFilesCount: 0,
        scannedAt: Date()
    )
}

struct PricingRule: Codable, Equatable {
    let effectiveFrom: String?
    let effectiveTo: String?
    let maxPromptTokens: Int?
    let minPromptTokens: Int?
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheReadPerMillion: Double
}

enum PricingCatalog {
    static let proSubscriptionMonthlyUSD: Double = 20.0

    static let builtInRules: [String: [PricingRule]] = [
        "gemini-4-neon": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 3.00, outputPerMillion: 15.00, cacheReadPerMillion: 0.15)
        ],
        "gemini-4-carbon": [
            PricingRule(effectiveFrom: nil, effectiveTo: "2026-11-30", maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 2.00, outputPerMillion: 10.00, cacheReadPerMillion: 0.10),
            PricingRule(effectiveFrom: "2026-12-01", effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 4.00, outputPerMillion: 20.00, cacheReadPerMillion: 0.20)
        ],
        "gemini-4-argon": [
            PricingRule(effectiveFrom: nil, effectiveTo: "2026-11-30", maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 2.00, outputPerMillion: 10.00, cacheReadPerMillion: 0.10),
            PricingRule(effectiveFrom: "2026-12-01", effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 4.00, outputPerMillion: 20.00, cacheReadPerMillion: 0.20)
        ],
        "gemini-4-hydrogen": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 1.50, outputPerMillion: 7.50, cacheReadPerMillion: 0.075)
        ],
        "gemini-3.8-flash": [
            PricingRule(effectiveFrom: nil, effectiveTo: "2026-12-31", maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 0.75, outputPerMillion: 3.75, cacheReadPerMillion: 0.075),
            PricingRule(effectiveFrom: "2027-01-01", effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 1.50, outputPerMillion: 7.50, cacheReadPerMillion: 0.15)
        ],
        "gemini-3.5-flash-lite": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 0.30, outputPerMillion: 2.50, cacheReadPerMillion: 0.03)
        ],
        "gemini-3.1-pro": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: 200_000, minPromptTokens: nil,
                        inputPerMillion: 2.00, outputPerMillion: 12.00, cacheReadPerMillion: 0.20),
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: 200_001,
                        inputPerMillion: 4.00, outputPerMillion: 18.00, cacheReadPerMillion: 0.40)
        ],
        "gemini-2.5-pro": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: 200_000, minPromptTokens: nil,
                        inputPerMillion: 1.25, outputPerMillion: 10.00, cacheReadPerMillion: 0.125),
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: 200_001,
                        inputPerMillion: 2.50, outputPerMillion: 15.00, cacheReadPerMillion: 0.25)
        ],
        "claude-opus": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 4.00, outputPerMillion: 20.00, cacheReadPerMillion: 0.20)
        ],
        "claude-sonnet": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 2.00, outputPerMillion: 10.00, cacheReadPerMillion: 0.10)
        ]
    ]

    static func loadCustomRules(from url: URL?) -> [String: [PricingRule]] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [PricingRule]].self, from: data) else {
            return [:]
        }
        var normalized: [String: [PricingRule]] = [:]
        for (rawKey, rules) in decoded {
            let trimmedLower = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmedLower.isEmpty {
                normalized[trimmedLower] = rules
            }
            let canonical = normalizeModelKey(rawKey)
            if normalized[canonical] == nil {
                normalized[canonical] = rules
            }
        }
        return normalized
    }

    static func normalizeModelKey(_ rawModel: String) -> String {
        let low = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.isEmpty { return "gemini-3.8-flash" }
        if low.contains("neon") { return "gemini-4-neon" }
        if low.contains("carbon") { return "gemini-4-carbon" }
        if low.contains("argon") { return "gemini-4-argon" }
        if low.contains("hydrogen") { return "gemini-4-hydrogen" }
        if low.contains("3.8") && low.contains("flash") { return "gemini-3.8-flash" }
        if low.contains("3.5") && low.contains("flash") { return "gemini-3.5-flash-lite" }
        if low.contains("3.1") && low.contains("pro") { return "gemini-3.1-pro" }
        if low.contains("2.5") && low.contains("pro") { return "gemini-2.5-pro" }
        if low.contains("opus") { return "claude-opus" }
        if low.contains("sonnet") { return "claude-sonnet" }
        if low.contains("flash") { return "gemini-3.8-flash" }
        if low.contains("claude") { return "claude-sonnet" }
        return low
    }

    static func displayName(for modelKey: String) -> String {
        switch modelKey {
        case "gemini-4-neon": return "Gemini 4 Neon"
        case "gemini-4-carbon": return "Gemini 4 Carbon"
        case "gemini-4-argon": return "Gemini 4 Argon"
        case "gemini-4-hydrogen": return "Gemini 4 Hydrogen"
        case "gemini-3.8-flash": return "Gemini 3.8 Flash"
        case "gemini-3.5-flash-lite": return "Gemini 3.5 Flash Lite"
        case "gemini-3.1-pro": return "Gemini 3.1 Pro"
        case "gemini-2.5-pro": return "Gemini 2.5 Pro"
        case "claude-opus": return "Claude Opus"
        case "claude-sonnet": return "Claude Sonnet"
        default: return modelKey
        }
    }

    static func contextLimit(for rawModel: String) -> Int {
        let low = rawModel.lowercased()
        if low.contains("claude") {
            return 200_000
        }
        return 1_000_000
    }

    private static let fallbackRule = PricingRule(
        effectiveFrom: nil,
        effectiveTo: nil,
        maxPromptTokens: nil,
        minPromptTokens: nil,
        inputPerMillion: 0.75,
        outputPerMillion: 3.75,
        cacheReadPerMillion: 0.075
    )

    static func estimateCostUSD(
        model rawModel: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        dateKey: String,
        customRules: [String: [PricingRule]] = [:],
        promptTokensForTier: Int? = nil
    ) -> Double {
        let trimmedLower = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normKey = normalizeModelKey(rawModel)
        let candidateRules: [PricingRule]
        if let customExact = customRules[trimmedLower], !customExact.isEmpty {
            candidateRules = customExact
        } else if let custom = customRules[normKey], !custom.isEmpty {
            candidateRules = custom
        } else if let builtIn = builtInRules[normKey], !builtIn.isEmpty {
            candidateRules = builtIn
        } else if let defaultBuiltIn = builtInRules["gemini-3.8-flash"], !defaultBuiltIn.isEmpty {
            candidateRules = defaultBuiltIn
        } else {
            candidateRules = [fallbackRule]
        }
        let promptTotal = promptTokensForTier ?? (inputTokens + cacheReadTokens)

        let matched = candidateRules.first { rule in
            if let from = rule.effectiveFrom, dateKey < from { return false }
            if let to = rule.effectiveTo, dateKey > to { return false }
            if let maxP = rule.maxPromptTokens, promptTotal > maxP { return false }
            if let minP = rule.minPromptTokens, promptTotal < minP { return false }
            return true
        } ?? candidateRules.first ?? fallbackRule

        let inpCost = (Double(max(0, inputTokens)) / 1_000_000.0) * matched.inputPerMillion
        let cacheCost = (Double(max(0, cacheReadTokens)) / 1_000_000.0) * matched.cacheReadPerMillion
        let outCost = (Double(max(0, outputTokens)) / 1_000_000.0) * matched.outputPerMillion
        return inpCost + cacheCost + outCost
    }
}

enum TokenFormatting {
    static func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.2fB", Double(count) / 1_000_000_000.0)
        }
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    static func compactTokensShort(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000.0)
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return "\(Int((Double(count) / 1_000.0).rounded()))K"
        }
        return "\(count)"
    }

    static func usd(_ value: Double) -> String {
        if value < 0.01 && value > 0 {
            return String(format: "$%.4f", value)
        }
        return String(format: "$%.2f", value)
    }
}
