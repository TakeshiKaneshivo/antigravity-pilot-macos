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

enum SubscriptionTierKind: String, Codable, Equatable {
    case free
    case pro
    case ultra
    case unknown

    var monthlyReferenceUSD: Double? {
        switch self {
        case .pro: return 20.0
        case .ultra: return 249.99
        case .free, .unknown: return nil
        }
    }

    var shortBadgeLabel: String? {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        case .ultra: return "Ultra"
        case .unknown: return nil
        }
    }

    static func infer(tierId: String, tierName: String, planName: String) -> SubscriptionTierKind {
        let combined = "\(tierId) \(tierName) \(planName)".lowercased()
        if combined.contains("ultra") {
            return .ultra
        }
        if combined.contains("pro") {
            return .pro
        }
        if combined.contains("free") || combined.contains("individual") || combined.contains("starter") || combined.contains("standard") {
            return .free
        }
        return .unknown
    }
}

struct StoredSubscriptionTier: Codable, Equatable {
    let tierId: String
    let tierName: String
    let tierKind: SubscriptionTierKind
    let monthlyReferenceUSD: Double?
    let updatedAtISO: String

    static func load(from url: URL) -> StoredSubscriptionTier? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredSubscriptionTier.self, from: data)
    }

    static func save(_ tier: StoredSubscriptionTier, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(tier) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct UserProfileInfo: Equatable {
    let name: String
    let email: String
    let tierName: String
    let tierId: String
    let tierKind: SubscriptionTierKind
    let monthlyReferenceUSD: Double?

    init(
        name: String,
        email: String,
        tierName: String,
        tierId: String = "",
        tierKind: SubscriptionTierKind? = nil
    ) {
        self.name = name
        self.email = email
        self.tierName = tierName
        self.tierId = tierId
        let resolvedKind = tierKind ?? SubscriptionTierKind.infer(tierId: tierId, tierName: tierName, planName: tierName)
        self.tierKind = resolvedKind
        self.monthlyReferenceUSD = resolvedKind.monthlyReferenceUSD
    }

    func toStoredTier(updatedAt: Date = Date()) -> StoredSubscriptionTier? {
        guard tierKind != .unknown || !tierName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return StoredSubscriptionTier(
            tierId: tierId,
            tierName: tierName,
            tierKind: tierKind,
            monthlyReferenceUSD: monthlyReferenceUSD,
            updatedAtISO: iso.string(from: updatedAt)
        )
    }
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

enum QuotaWindowKind: String, Codable, Equatable {
    case fiveHour = "5h"
    case weekly = "weekly"
    case unknown = "unknown"

    func shortLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .fiveHour:
            return L10n.t(zhHans: "5小时", zhHant: "5小時", en: "5h", ru: "5ч", lang)
        case .weekly:
            return L10n.t(zhHans: "每周", zhHant: "每週", en: "Weekly", ru: "Неделя", lang)
        case .unknown:
            return L10n.t(zhHans: "配额", zhHant: "配額", en: "Quota", ru: "Квота", lang)
        }
    }

    func popoverLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .fiveHour:
            return "5h"
        case .weekly:
            return L10n.t(zhHans: "周", zhHant: "週", en: "Wk", ru: "Нед", lang)
        case .unknown:
            return L10n.t(zhHans: "池", zhHant: "池", en: "Pool", ru: "Пул", lang)
        }
    }
}

struct QuotaWindowBucket: Identifiable, Equatable, Codable {
    let id: String
    let windowKind: QuotaWindowKind
    let displayName: String
    let remainingFraction: Double
    let resetTime: Date?
    let resetTimeISO: String?
    let description: String?

    var remainingPercent: Int {
        Int((min(max(remainingFraction, 0), 1) * 100).rounded())
    }

    func resetCountdownText(_ lang: AppLanguage) -> String {
        QuotaCountdownFormatter.full(resetTime: resetTime, lang: lang)
    }

    func shortCountdownText(_ lang: AppLanguage) -> String {
        QuotaCountdownFormatter.compact(resetTime: resetTime, lang: lang)
    }
}

enum QuotaCountdownFormatter {
    static func full(resetTime: Date?, lang: AppLanguage) -> String {
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

    static func compact(resetTime: Date?, lang: AppLanguage) -> String {
        guard let resetTime else {
            return "--"
        }
        let diff = Int(resetTime.timeIntervalSinceNow)
        if diff <= 0 {
            return L10n.t(zhHans: "即将", zhHant: "即將", en: "Soon", ru: "Скоро", lang)
        }
        let hours = diff / 3600
        let mins = (diff % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            let remHours = hours % 24
            return L10n.t(
                zhHans: "\(days)天\(remHours)时",
                zhHant: "\(days)天\(remHours)時",
                en: "\(days)d \(remHours)h",
                ru: "\(days)д \(remHours)ч",
                lang
            )
        }
        if hours > 0 {
            return L10n.t(
                zhHans: "\(hours)时\(mins)分",
                zhHant: "\(hours)時\(mins)分",
                en: "\(hours)h \(mins)m",
                ru: "\(hours)ч \(mins)м",
                lang
            )
        }
        return L10n.t(
            zhHans: "\(max(1, mins))分",
            zhHant: "\(max(1, mins))分",
            en: "\(max(1, mins))m",
            ru: "\(max(1, mins))м",
            lang
        )
    }
}

struct QuotaPoolGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let remainingFraction: Double
    let resetTime: Date?
    let models: [ModelQuotaItem]
    let buckets: [QuotaWindowBucket]
    let poolDescription: String?

    init(
        id: String,
        title: String,
        remainingFraction: Double,
        resetTime: Date?,
        models: [ModelQuotaItem],
        buckets: [QuotaWindowBucket] = [],
        poolDescription: String? = nil
    ) {
        self.id = id
        self.title = title
        self.buckets = buckets
        self.poolDescription = poolDescription
        self.models = models
        if let tightest = buckets.min(by: { $0.remainingFraction < $1.remainingFraction }) {
            self.remainingFraction = tightest.remainingFraction
            self.resetTime = tightest.resetTime ?? resetTime
        } else {
            self.remainingFraction = remainingFraction
            self.resetTime = resetTime
        }
    }

    var tightestBucket: QuotaWindowBucket? {
        buckets.min(by: { $0.remainingFraction < $1.remainingFraction })
    }

    var tightestWindowKind: QuotaWindowKind {
        tightestBucket?.windowKind ?? .unknown
    }

    var remainingPercent: Int {
        Int((min(max(remainingFraction, 0), 1) * 100).rounded())
    }

    var resetCountdownText: String {
        resetCountdownText(L10n.current)
    }

    func resetCountdownText(_ lang: AppLanguage) -> String {
        QuotaCountdownFormatter.full(resetTime: resetTime, lang: lang)
    }
}

struct SessionSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let stepCount: Int
    let lastModifiedTime: Date?
    let status: String
    let workspaceName: String?
    let workspacePath: String?
    let branchName: String?
    let parentConversationId: String?
    let rootConversationId: String?
    let nestingDepth: Int
    let agentRole: String?

    init(
        id: String,
        title: String,
        stepCount: Int,
        lastModifiedTime: Date?,
        status: String,
        workspaceName: String? = nil,
        workspacePath: String? = nil,
        branchName: String? = nil,
        parentConversationId: String? = nil,
        rootConversationId: String? = nil,
        nestingDepth: Int = 0,
        agentRole: String? = nil
    ) {
        self.id = id
        self.title = title
        self.stepCount = stepCount
        self.lastModifiedTime = lastModifiedTime
        self.status = status
        self.workspaceName = workspaceName
        self.workspacePath = workspacePath
        self.branchName = branchName
        self.parentConversationId = parentConversationId
        self.rootConversationId = rootConversationId
        self.nestingDepth = nestingDepth
        self.agentRole = agentRole
    }

    var isRunning: Bool {
        status.uppercased().contains("RUNNING")
    }

    var isSubagent: Bool {
        nestingDepth > 0 || (parentConversationId?.isEmpty == false && parentConversationId != id)
    }
}

enum ContextBreakdownCategory: String, CaseIterable, Codable, Equatable {
    case systemPrompt
    case systemTools
    case mcpTools
    case skills
    case userRules
    case userMessages
    case assistantResponses
    case toolResults
    case subagents
    case compaction

    var colorIndex: Int {
        switch self {
        case .userMessages: return 0
        case .assistantResponses: return 1
        case .toolResults: return 2
        case .systemPrompt: return 3
        case .systemTools: return 4
        case .mcpTools: return 5
        case .skills: return 6
        case .userRules: return 7
        case .subagents: return 8
        case .compaction: return 9
        }
    }

    func localizedTitle(_ lang: AppLanguage) -> String {
        switch self {
        case .systemPrompt:
            return L10n.t(zhHans: "系统提示词", zhHant: "系統提示詞", en: "System Prompt", ru: "Сист. промпт", lang)
        case .systemTools:
            return L10n.t(zhHans: "系统工具", zhHant: "系統工具", en: "System Tools", ru: "Сист. инстр.", lang)
        case .mcpTools:
            return L10n.t(zhHans: "MCP 工具", zhHant: "MCP 工具", en: "MCP Tools", ru: "MCP инстр.", lang)
        case .skills:
            return L10n.t(zhHans: "Skills 技能", zhHant: "Skills 技能", en: "Skills", ru: "Навыки", lang)
        case .userRules:
            return L10n.t(zhHans: "用户规则", zhHant: "使用者規則", en: "User Rules", ru: "Правила", lang)
        case .userMessages:
            return L10n.t(zhHans: "用户消息", zhHant: "使用者訊息", en: "User Messages", ru: "Сообщения", lang)
        case .assistantResponses:
            return L10n.t(zhHans: "模型回复", zhHant: "模型回覆", en: "Model Reply", ru: "Ответы ИИ", lang)
        case .toolResults:
            return L10n.t(zhHans: "工具结果", zhHant: "工具結果", en: "Tool Results", ru: "Вывод инстр.", lang)
        case .subagents:
            return L10n.t(zhHans: "子代理", zhHant: "子代理", en: "Subagents", ru: "Субагенты", lang)
        case .compaction:
            return L10n.t(zhHans: "压缩摘要", zhHant: "壓縮摘要", en: "Compaction", ru: "Сжатие", lang)
        }
    }
}

struct ContextBreakdownItem: Identifiable, Equatable, Codable {
    var id: String { category.rawValue }
    let category: ContextBreakdownCategory
    let tokens: Int
    let fraction: Double
}

enum StepAnomalyKind: String, Codable, Equatable {
    case rateLimit = "rate_limit"
    case timeout = "timeout"
    case capacity = "capacity"
    case disconnect = "disconnect"
    case upstream = "upstream"
    case modelOutput = "model_output"
    case safety = "safety"
    case canceled = "canceled"
    case other = "other"

    func localizedLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .rateLimit:
            return L10n.t(zhHans: "限流 429", zhHant: "限流 429", en: "Rate Limit", ru: "Лимит 429", lang)
        case .timeout:
            return L10n.t(zhHans: "超时", zhHant: "逾時", en: "Timeout", ru: "Таймаут", lang)
        case .capacity:
            return L10n.t(zhHans: "过载 503", zhHant: "過載 503", en: "Capacity", ru: "Перегрузка", lang)
        case .disconnect:
            return L10n.t(zhHans: "断连", zhHant: "斷線", en: "Disconnect", ru: "Разрыв", lang)
        case .upstream:
            return L10n.t(zhHans: "服务端 5xx", zhHant: "伺服器 5xx", en: "Upstream 5xx", ru: "Ошибка 5xx", lang)
        case .modelOutput:
            return L10n.t(zhHans: "输出异常", zhHant: "輸出異常", en: "Output Error", ru: "Сбой вывода", lang)
        case .safety:
            return L10n.t(zhHans: "安全拦截", zhHant: "安全攔截", en: "Safety", ru: "Фильтр", lang)
        case .canceled:
            return L10n.t(zhHans: "已取消", zhHant: "已取消", en: "Canceled", ru: "Отменено", lang)
        case .other:
            return L10n.t(zhHans: "重试异常", zhHant: "重試異常", en: "Retry Error", ru: "Повтор", lang)
        }
    }
}

struct SessionStepItem: Identifiable, Equatable {
    let id: Int
    let stepNumber: Int
    let modelId: String
    let modelDisplayName: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let thinkingOutputTokens: Int
    let responseOutputTokens: Int
    let timeToFirstTokenSec: Double?
    let streamingDurationSec: Double?
    let tokensPerSecond: Double?
    let estimatedCostUSD: Double
    let isCompactionStep: Bool
    let retryCount: Int
    let anomalyKind: StepAnomalyKind?
    let anomalyExcerpt: String?

    var activeContextTokens: Int {
        inputTokens + cacheReadTokens
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
    let contextBreakdown: [ContextBreakdownItem]
    let sessionStepCount: Int
    let sessionAvgTokensPerSecond: Double?
    let sessionAvgTTFTSec: Double?
    let sessionTotalCostUSD: Double
    let anomalyStepCount: Int
    let recentSteps: [SessionStepItem]

    init(
        cascadeId: String,
        title: String,
        modelId: String,
        modelDisplayName: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        thinkingOutputTokens: Int,
        responseOutputTokens: Int,
        contextLimitTokens: Int,
        timeToFirstTokenSec: Double?,
        streamingDurationSec: Double?,
        updatedAt: Date,
        contextBreakdown: [ContextBreakdownItem] = [],
        sessionStepCount: Int = 1,
        sessionAvgTokensPerSecond: Double? = nil,
        sessionAvgTTFTSec: Double? = nil,
        sessionTotalCostUSD: Double = 0,
        anomalyStepCount: Int = 0,
        recentSteps: [SessionStepItem] = []
    ) {
        self.cascadeId = cascadeId
        self.title = title
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.thinkingOutputTokens = thinkingOutputTokens
        self.responseOutputTokens = responseOutputTokens
        self.contextLimitTokens = contextLimitTokens
        self.timeToFirstTokenSec = timeToFirstTokenSec
        self.streamingDurationSec = streamingDurationSec
        self.updatedAt = updatedAt
        self.contextBreakdown = contextBreakdown
        self.sessionStepCount = sessionStepCount
        self.sessionAvgTokensPerSecond = sessionAvgTokensPerSecond
        self.sessionAvgTTFTSec = sessionAvgTTFTSec
        self.sessionTotalCostUSD = sessionTotalCostUSD
        self.anomalyStepCount = anomalyStepCount
        self.recentSteps = recentSteps
    }

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

enum UsageClientSource: String, Codable, Equatable {
    case desktop
    case cli
}

struct DailyUsageBucket: Identifiable, Equatable, Codable {
    var id: String { dateKey }
    let dateKey: String // YYYY-MM-DD (local timezone)
    var inputTokens: Int
    var cacheReadTokens: Int
    var outputTokens: Int
    var requestCount: Int
    var estimatedCostUSD: Double
    var cacheSavingsUSD: Double
    var over200kRequestCount: Int
    var over200kTokens: Int
    var over200kPremiumUSD: Double

    init(
        dateKey: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        requestCount: Int,
        estimatedCostUSD: Double,
        cacheSavingsUSD: Double = 0,
        over200kRequestCount: Int = 0,
        over200kTokens: Int = 0,
        over200kPremiumUSD: Double = 0
    ) {
        self.dateKey = dateKey
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.requestCount = requestCount
        self.estimatedCostUSD = estimatedCostUSD
        self.cacheSavingsUSD = cacheSavingsUSD
        self.over200kRequestCount = over200kRequestCount
        self.over200kTokens = over200kTokens
        self.over200kPremiumUSD = over200kPremiumUSD
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateKey = try c.decode(String.self, forKey: .dateKey)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        requestCount = try c.decode(Int.self, forKey: .requestCount)
        estimatedCostUSD = try c.decode(Double.self, forKey: .estimatedCostUSD)
        cacheSavingsUSD = try c.decodeIfPresent(Double.self, forKey: .cacheSavingsUSD) ?? 0
        over200kRequestCount = try c.decodeIfPresent(Int.self, forKey: .over200kRequestCount) ?? 0
        over200kTokens = try c.decodeIfPresent(Int.self, forKey: .over200kTokens) ?? 0
        over200kPremiumUSD = try c.decodeIfPresent(Double.self, forKey: .over200kPremiumUSD) ?? 0
    }

    var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }

    var promptTokens: Int {
        inputTokens + cacheReadTokens
    }

    var cacheHitRate: Double {
        promptTokens > 0 ? Double(cacheReadTokens) / Double(promptTokens) : 0
    }

    var over200kRequestRate: Double {
        requestCount > 0 ? Double(over200kRequestCount) / Double(requestCount) : 0
    }

    var grossCostBeforeCacheUSD: Double {
        estimatedCostUSD + cacheSavingsUSD
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
    let cacheSavingsUSD: Double
    let over200kRequestCount: Int
    let over200kTokens: Int
    let over200kPremiumUSD: Double

    init(
        modelKey: String,
        displayName: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        requestCount: Int,
        estimatedCostUSD: Double,
        cacheSavingsUSD: Double = 0,
        over200kRequestCount: Int = 0,
        over200kTokens: Int = 0,
        over200kPremiumUSD: Double = 0
    ) {
        self.modelKey = modelKey
        self.displayName = displayName
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.requestCount = requestCount
        self.estimatedCostUSD = estimatedCostUSD
        self.cacheSavingsUSD = cacheSavingsUSD
        self.over200kRequestCount = over200kRequestCount
        self.over200kTokens = over200kTokens
        self.over200kPremiumUSD = over200kPremiumUSD
    }

    var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }

    var promptTokens: Int {
        inputTokens + cacheReadTokens
    }

    var cacheHitRate: Double {
        promptTokens > 0 ? Double(cacheReadTokens) / Double(promptTokens) : 0
    }

    var over200kRequestRate: Double {
        requestCount > 0 ? Double(over200kRequestCount) / Double(requestCount) : 0
    }

    var grossCostBeforeCacheUSD: Double {
        estimatedCostUSD + cacheSavingsUSD
    }
}

struct ProjectUsageSummary: Identifiable, Equatable {
    var id: String { projectKey }
    let projectKey: String
    let displayName: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let requestCount: Int
    let sessionCount: Int
    let estimatedCostUSD: Double
    let cacheSavingsUSD: Double
    let over200kRequestCount: Int
    let over200kTokens: Int
    let over200kPremiumUSD: Double

    init(
        projectKey: String,
        displayName: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        requestCount: Int,
        sessionCount: Int,
        estimatedCostUSD: Double,
        cacheSavingsUSD: Double = 0,
        over200kRequestCount: Int = 0,
        over200kTokens: Int = 0,
        over200kPremiumUSD: Double = 0
    ) {
        self.projectKey = projectKey
        self.displayName = displayName
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.requestCount = requestCount
        self.sessionCount = sessionCount
        self.estimatedCostUSD = estimatedCostUSD
        self.cacheSavingsUSD = cacheSavingsUSD
        self.over200kRequestCount = over200kRequestCount
        self.over200kTokens = over200kTokens
        self.over200kPremiumUSD = over200kPremiumUSD
    }

    var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }

    var promptTokens: Int {
        inputTokens + cacheReadTokens
    }

    var cacheHitRate: Double {
        promptTokens > 0 ? Double(cacheReadTokens) / Double(promptTokens) : 0
    }

    var over200kRequestRate: Double {
        requestCount > 0 ? Double(over200kRequestCount) / Double(requestCount) : 0
    }

    var grossCostBeforeCacheUSD: Double {
        estimatedCostUSD + cacheSavingsUSD
    }
}

struct SessionUsageSummary: Identifiable, Equatable {
    var id: String { "\(clientSource.rawValue)|\(cascadeId)" }
    let cascadeId: String
    let title: String
    let projectName: String?
    let clientSource: UsageClientSource
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let requestCount: Int
    let estimatedCostUSD: Double
    let cacheSavingsUSD: Double
    let over200kRequestCount: Int
    let over200kTokens: Int
    let over200kPremiumUSD: Double
    let lastDateKey: String

    init(
        cascadeId: String,
        title: String,
        projectName: String?,
        clientSource: UsageClientSource,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        requestCount: Int,
        estimatedCostUSD: Double,
        cacheSavingsUSD: Double = 0,
        over200kRequestCount: Int = 0,
        over200kTokens: Int = 0,
        over200kPremiumUSD: Double = 0,
        lastDateKey: String
    ) {
        self.cascadeId = cascadeId
        self.title = title
        self.projectName = projectName
        self.clientSource = clientSource
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.requestCount = requestCount
        self.estimatedCostUSD = estimatedCostUSD
        self.cacheSavingsUSD = cacheSavingsUSD
        self.over200kRequestCount = over200kRequestCount
        self.over200kTokens = over200kTokens
        self.over200kPremiumUSD = over200kPremiumUSD
        self.lastDateKey = lastDateKey
    }

    var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }

    var promptTokens: Int {
        inputTokens + cacheReadTokens
    }

    var cacheHitRate: Double {
        promptTokens > 0 ? Double(cacheReadTokens) / Double(promptTokens) : 0
    }

    var over200kRequestRate: Double {
        requestCount > 0 ? Double(over200kRequestCount) / Double(requestCount) : 0
    }

    var grossCostBeforeCacheUSD: Double {
        estimatedCostUSD + cacheSavingsUSD
    }
}

struct UsageHistorySnapshot: Equatable {
    let dailyBuckets: [DailyUsageBucket] // sorted ascending by dateKey
    let modelSummariesByPeriod: [UsagePeriod: [ModelUsageSummary]]
    let projectSummariesByPeriod: [UsagePeriod: [ProjectUsageSummary]]
    let sessionSummariesByPeriod: [UsagePeriod: [SessionUsageSummary]]
    let totalsByPeriod: [UsagePeriod: DailyUsageBucket]
    let scannedFilesCount: Int
    let desktopArchiveCount: Int
    let cliArchiveCount: Int
    let scannedAt: Date

    init(
        dailyBuckets: [DailyUsageBucket],
        modelSummariesByPeriod: [UsagePeriod: [ModelUsageSummary]],
        projectSummariesByPeriod: [UsagePeriod: [ProjectUsageSummary]] = [:],
        sessionSummariesByPeriod: [UsagePeriod: [SessionUsageSummary]] = [:],
        totalsByPeriod: [UsagePeriod: DailyUsageBucket],
        scannedFilesCount: Int,
        desktopArchiveCount: Int? = nil,
        cliArchiveCount: Int = 0,
        scannedAt: Date
    ) {
        self.dailyBuckets = dailyBuckets
        self.modelSummariesByPeriod = modelSummariesByPeriod
        self.projectSummariesByPeriod = projectSummariesByPeriod
        self.sessionSummariesByPeriod = sessionSummariesByPeriod
        self.totalsByPeriod = totalsByPeriod
        self.scannedFilesCount = scannedFilesCount
        self.desktopArchiveCount = desktopArchiveCount ?? scannedFilesCount
        self.cliArchiveCount = cliArchiveCount
        self.scannedAt = scannedAt
    }

    static let empty = UsageHistorySnapshot(
        dailyBuckets: [],
        modelSummariesByPeriod: [:],
        projectSummariesByPeriod: [:],
        sessionSummariesByPeriod: [:],
        totalsByPeriod: [:],
        scannedFilesCount: 0,
        desktopArchiveCount: 0,
        cliArchiveCount: 0,
        scannedAt: Date()
    )
}

struct ModelCatalogEntry: Equatable {
    let modelSlug: String
    let placeholderId: String
    let displayName: String
    let maxTokens: Int
    let maxOutputTokens: Int?
    let tagTitle: String?
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

struct ExternalPricingPhase: Codable, Equatable {
    let from: String?
    let until: String?
    let input: Double?
    let cache: Double?
    let output: Double?
}

struct ExternalPricingTier: Codable, Equatable {
    let maxPromptTokens: Int?
    let minPromptTokens: Int?
    let input: Double?
    let cache: Double?
    let output: Double?
}

struct ExternalPricingEntry: Codable, Equatable {
    let input: Double
    let cache: Double
    let output: Double
    let short: String?
    let family: String?
    let phases: [ExternalPricingPhase]?
    let tiers: [ExternalPricingTier]?
}

struct ExternalPlaceholderEntry: Codable, Equatable {
    let modelId: String
    let label: String?
}

struct ExternalPricingCatalog: Codable, Equatable {
    let schemaVersion: Int?
    let catalogVersion: String?
    let updatedAt: String?
    let pricing: [String: ExternalPricingEntry]
    let placeholders: [String: ExternalPlaceholderEntry]?

    var isValid: Bool {
        guard !pricing.isEmpty else { return false }
        for entry in pricing.values {
            guard entry.input.isFinite, entry.input >= 0,
                  entry.cache.isFinite, entry.cache >= 0,
                  entry.output.isFinite, entry.output >= 0 else {
                return false
            }
            if let phases = entry.phases {
                for p in phases {
                    if let v = p.input, (!v.isFinite || v < 0) { return false }
                    if let v = p.cache, (!v.isFinite || v < 0) { return false }
                    if let v = p.output, (!v.isFinite || v < 0) { return false }
                }
            }
            if let tiers = entry.tiers {
                for t in tiers {
                    if let v = t.input, (!v.isFinite || v < 0) { return false }
                    if let v = t.cache, (!v.isFinite || v < 0) { return false }
                    if let v = t.output, (!v.isFinite || v < 0) { return false }
                }
            }
        }
        return true
    }
}

enum PricingCatalog {
    static let proSubscriptionMonthlyUSD: Double = 20.0

    struct ResolvedPricingSource {
        let customRules: [String: [PricingRule]]
        let syncedEntries: [String: ExternalPricingEntry]
        let bundledEntries: [String: ExternalPricingEntry]
        let syncedPlaceholders: [String: ExternalPlaceholderEntry]
        let bundledPlaceholders: [String: ExternalPlaceholderEntry]
        let modelCatalog: [String: ModelCatalogEntry]

        static let empty = ResolvedPricingSource(
            customRules: [:],
            syncedEntries: [:],
            bundledEntries: [:],
            syncedPlaceholders: [:],
            bundledPlaceholders: [:],
            modelCatalog: [:]
        )

        static func load(
            customPricingURL: URL? = AppSupport().customPricingURL,
            syncedCatalogURL: URL? = AppSupport().syncedPricingCatalogURL,
            bundledCatalogURL: URL? = PricingCatalog.defaultBundledCatalogURL(),
            modelCatalog: [String: ModelCatalogEntry] = [:]
        ) -> ResolvedPricingSource {
            let custom = PricingCatalog.loadCustomRules(from: customPricingURL)
            let synced = PricingCatalog.loadExternalCatalog(from: syncedCatalogURL)
            let bundled = PricingCatalog.loadExternalCatalog(from: bundledCatalogURL)
            return ResolvedPricingSource(
                customRules: custom,
                syncedEntries: Self.lowercaseMap(synced?.pricing ?? [:]),
                bundledEntries: Self.lowercaseMap(bundled?.pricing ?? [:]),
                syncedPlaceholders: Self.uppercaseMap(synced?.placeholders ?? [:]),
                bundledPlaceholders: Self.uppercaseMap(bundled?.placeholders ?? [:]),
                modelCatalog: modelCatalog
            )
        }

        private static func lowercaseMap<V>(_ src: [String: V]) -> [String: V] {
            var out: [String: V] = [:]
            out.reserveCapacity(src.count)
            for (k, v) in src {
                out[k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = v
            }
            return out
        }

        private static func uppercaseMap<V>(_ src: [String: V]) -> [String: V] {
            var out: [String: V] = [:]
            out.reserveCapacity(src.count)
            for (k, v) in src {
                out[k.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()] = v
            }
            return out
        }
    }

    static func defaultBundledCatalogURL(resourceBaseURL: URL? = Bundle.main.resourceURL) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let base = resourceBaseURL {
            candidates.append(base.appendingPathComponent("pricing-catalog.json"))
        }
        let execURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let execDir = execURL.deletingLastPathComponent()
        candidates.append(execDir.appendingPathComponent("pricing-catalog.json"))
        candidates.append(execDir.deletingLastPathComponent().appendingPathComponent("assets/pricing-catalog.json"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("pricing-catalog.json"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    static func loadExternalCatalog(from url: URL?) -> ExternalPricingCatalog? {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ExternalPricingCatalog.self, from: data),
              decoded.isValid else {
            return nil
        }
        return decoded
    }

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
        "gemini-4-helix": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 0.30, outputPerMillion: 2.50, cacheReadPerMillion: 0.015)
        ],
        "gemini-3.8-flash": [
            PricingRule(effectiveFrom: nil, effectiveTo: "2026-12-31", maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 0.75, outputPerMillion: 3.75, cacheReadPerMillion: 0.075),
            PricingRule(effectiveFrom: "2027-01-01", effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 1.50, outputPerMillion: 7.50, cacheReadPerMillion: 0.15)
        ],
        "gemini-3.8-flash-low": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 0.30, outputPerMillion: 2.50, cacheReadPerMillion: 0.03)
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
        "claude-opus-5.5": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 4.00, outputPerMillion: 20.00, cacheReadPerMillion: 0.20)
        ],
        "claude-opus": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 5.00, outputPerMillion: 25.00, cacheReadPerMillion: 0.50)
        ],
        "claude-sonnet-5.5": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 2.00, outputPerMillion: 10.00, cacheReadPerMillion: 0.10)
        ],
        "claude-sonnet": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 3.00, outputPerMillion: 15.00, cacheReadPerMillion: 0.30)
        ],
        "claude-haiku-5.5": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 0.10, outputPerMillion: 0.50, cacheReadPerMillion: 0.01)
        ],
        "claude-haiku": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 1.00, outputPerMillion: 5.00, cacheReadPerMillion: 0.10)
        ],
        "gpt-oss-120b": [
            PricingRule(effectiveFrom: nil, effectiveTo: nil, maxPromptTokens: nil, minPromptTokens: nil,
                        inputPerMillion: 0.80, outputPerMillion: 2.40, cacheReadPerMillion: 0.10)
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

    static func resolvePlaceholder(_ rawModel: String, source: ResolvedPricingSource = .empty) -> (modelSlug: String, label: String?)? {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if let entry = source.modelCatalog[upper] ?? source.modelCatalog[trimmed] {
            return (entry.modelSlug, entry.displayName)
        }
        if let ph = source.syncedPlaceholders[upper] {
            return (ph.modelId, ph.label)
        }
        if let ph = source.bundledPlaceholders[upper] {
            return (ph.modelId, ph.label)
        }
        return nil
    }

    static func normalizeModelKey(_ rawModel: String, source: ResolvedPricingSource = .empty) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSlug = resolvePlaceholder(trimmed, source: source)?.modelSlug ?? trimmed
        let low = resolvedSlug.lowercased()
        if low.isEmpty { return "gemini-3.8-flash" }
        if low.contains("neon") { return "gemini-4-neon" }
        if low.contains("carbon") || low == "gemini-pro-orchestrator" { return "gemini-4-carbon" }
        if low.contains("argon") { return "gemini-4-argon" }
        if low.contains("hydrogen") || low == "gemini-flash-worker-agy" { return "gemini-4-hydrogen" }
        if low.contains("helix") { return "gemini-4-helix" }
        if (low.contains("3.8") || low.contains("3.7") || low.contains("3.6")) && low.contains("flash") && low.contains("low") {
            return "gemini-3.8-flash-low"
        }
        if low.contains("3.8") && low.contains("flash") { return "gemini-3.8-flash" }
        if low.contains("3.5") && low.contains("flash") { return "gemini-3.5-flash-lite" }
        if low.contains("3.1") && low.contains("pro") { return "gemini-3.1-pro" }
        if low.contains("2.5") && low.contains("pro") { return "gemini-2.5-pro" }
        if low.contains("opus") {
            return (low.contains("5-5") || low.contains("5.5")) ? "claude-opus-5.5" : "claude-opus"
        }
        if low.contains("sonnet") {
            return (low.contains("5-5") || low.contains("5.5") || low.contains("sonnet-5")) ? "claude-sonnet-5.5" : "claude-sonnet"
        }
        if low.contains("haiku") {
            return (low.contains("5-5") || low.contains("5.5")) ? "claude-haiku-5.5" : "claude-haiku"
        }
        if low.contains("gpt-oss") { return "gpt-oss-120b" }
        if low.contains("flash") { return "gemini-3.8-flash" }
        if low.contains("claude") { return "claude-sonnet" }
        return low
    }

    static func displayName(for modelKey: String, source: ResolvedPricingSource = .empty) -> String {
        if let ph = resolvePlaceholder(modelKey, source: source), let lbl = ph.label, !lbl.isEmpty {
            return lbl
        }
        switch modelKey {
        case "gemini-4-neon": return "Gemini 4 Neon"
        case "gemini-4-carbon": return "Gemini 4 Carbon"
        case "gemini-4-argon": return "Gemini 4 Argon"
        case "gemini-4-hydrogen": return "Gemini 4 Hydrogen"
        case "gemini-4-helix": return "Gemini 4 Helix"
        case "gemini-3.8-flash": return "Gemini 3.8 Flash"
        case "gemini-3.8-flash-low": return "Gemini 3.8 Flash (Low)"
        case "gemini-3.5-flash-lite": return "Gemini 3.5 Flash Lite"
        case "gemini-3.1-pro": return "Gemini 3.1 Pro"
        case "gemini-2.5-pro": return "Gemini 2.5 Pro"
        case "claude-opus-5.5": return "Claude Opus 5.5"
        case "claude-opus": return "Claude Opus"
        case "claude-sonnet-5.5": return "Claude Sonnet 5.5"
        case "claude-sonnet": return "Claude Sonnet"
        case "claude-haiku-5.5": return "Claude Haiku 5.5"
        case "claude-haiku": return "Claude Haiku"
        case "gpt-oss-120b": return "GPT-OSS 120B"
        default: return modelKey
        }
    }

    static func contextLimit(for rawModel: String, modelCatalog: [String: ModelCatalogEntry] = [:]) -> Int {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        let lower = trimmed.lowercased()
        if let entry = modelCatalog[upper] ?? modelCatalog[lower] ?? modelCatalog[trimmed],
           entry.maxTokens > 0 {
            return entry.maxTokens
        }
        if lower.contains("claude") {
            if lower.contains("5-5") || lower.contains("5.5") {
                return 1_000_000
            }
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

    private static func adjustExclusiveUntilDateKey(_ rawUntil: String) -> String {
        let prefix = String(rawUntil.prefix(10))
        guard rawUntil.contains("T00:00:00") else {
            return prefix
        }
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: prefix),
           let prev = df.calendar.date(byAdding: .day, value: -1, to: d) {
            return df.string(from: prev)
        }
        return prefix
    }

    private static func convertExternalEntry(_ entry: ExternalPricingEntry) -> [PricingRule] {
        var rules: [PricingRule] = []
        let phases = entry.phases ?? []
        let tiers = entry.tiers ?? []

        if !phases.isEmpty && !tiers.isEmpty {
            for p in phases {
                let fromKey = p.from.map { String($0.prefix(10)) }
                let toKey = p.until.map { adjustExclusiveUntilDateKey($0) }
                for t in tiers {
                    rules.append(PricingRule(
                        effectiveFrom: fromKey,
                        effectiveTo: toKey,
                        maxPromptTokens: t.maxPromptTokens,
                        minPromptTokens: t.minPromptTokens,
                        inputPerMillion: t.input ?? p.input ?? entry.input,
                        outputPerMillion: t.output ?? p.output ?? entry.output,
                        cacheReadPerMillion: t.cache ?? p.cache ?? entry.cache
                    ))
                }
            }
        } else if !tiers.isEmpty {
            for t in tiers {
                rules.append(PricingRule(
                    effectiveFrom: nil,
                    effectiveTo: nil,
                    maxPromptTokens: t.maxPromptTokens,
                    minPromptTokens: t.minPromptTokens,
                    inputPerMillion: t.input ?? entry.input,
                    outputPerMillion: t.output ?? entry.output,
                    cacheReadPerMillion: t.cache ?? entry.cache
                ))
            }
        } else if !phases.isEmpty {
            for p in phases {
                let fromKey = p.from.map { String($0.prefix(10)) }
                let toKey = p.until.map { adjustExclusiveUntilDateKey($0) }
                rules.append(PricingRule(
                    effectiveFrom: fromKey,
                    effectiveTo: toKey,
                    maxPromptTokens: nil,
                    minPromptTokens: nil,
                    inputPerMillion: p.input ?? entry.input,
                    outputPerMillion: p.output ?? entry.output,
                    cacheReadPerMillion: p.cache ?? entry.cache
                ))
            }
        }
        if rules.isEmpty {
            rules.append(PricingRule(
                effectiveFrom: nil,
                effectiveTo: nil,
                maxPromptTokens: nil,
                minPromptTokens: nil,
                inputPerMillion: entry.input,
                outputPerMillion: entry.output,
                cacheReadPerMillion: entry.cache
            ))
        }
        return rules
    }

    private static func resolveCandidateRules(
        rawModel: String,
        source: ResolvedPricingSource,
        promptTotal: Int
    ) -> [PricingRule] {
        let resolvedSlug = resolvePlaceholder(rawModel, source: source)?.modelSlug ?? rawModel
        let trimmedLower = resolvedSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawLower = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normKey = normalizeModelKey(rawModel, source: source)

        // 1. User custom_pricing.json always wins
        if let customExact = source.customRules[trimmedLower] ?? source.customRules[rawLower], !customExact.isEmpty {
            return customExact
        }
        if let custom = source.customRules[normKey], !custom.isEmpty {
            return custom
        }

        // 2. Preserve Pilot's >200K tier rules when an external entry lacks tiers
        let syncedMatch = source.syncedEntries[trimmedLower] ?? source.syncedEntries[rawLower] ?? source.syncedEntries[normKey]
        let bundledMatch = source.bundledEntries[trimmedLower] ?? source.bundledEntries[rawLower] ?? source.bundledEntries[normKey]

        if let synced = syncedMatch {
            let hasSyncedTiers = (synced.tiers?.isEmpty == false)
            if !hasSyncedTiers && promptTotal > 200_000 {
                if let bundled = bundledMatch, let bundledTiers = bundled.tiers, !bundledTiers.isEmpty {
                    return convertExternalEntry(bundled)
                }
                if let builtIn = builtInRules[normKey], builtIn.contains(where: { $0.minPromptTokens != nil }) {
                    return builtIn
                }
            }
            return convertExternalEntry(synced)
        }

        // 3. Bundled pricing-catalog.json (preserve >200K tiers if bundled entry lacks tiers)
        if let bundled = bundledMatch {
            let hasBundledTiers = (bundled.tiers?.isEmpty == false)
            if !hasBundledTiers && promptTotal > 200_000,
               let builtIn = builtInRules[normKey], builtIn.contains(where: { $0.minPromptTokens != nil }) {
                return builtIn
            }
            return convertExternalEntry(bundled)
        }

        // 4. Built-in Swift fallback rules
        if let builtIn = builtInRules[normKey], !builtIn.isEmpty {
            return builtIn
        }
        if let defaultBuiltIn = builtInRules["gemini-3.8-flash"], !defaultBuiltIn.isEmpty {
            return defaultBuiltIn
        }
        return [fallbackRule]
    }

    static func estimateCostUSD(
        model rawModel: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        dateKey: String,
        customRules: [String: [PricingRule]] = [:],
        promptTokensForTier: Int? = nil
    ) -> Double {
        let source = ResolvedPricingSource(
            customRules: customRules,
            syncedEntries: [:],
            bundledEntries: [:],
            syncedPlaceholders: [:],
            bundledPlaceholders: [:],
            modelCatalog: [:]
        )
        return estimateCostAndSavingsUSD(
            model: rawModel,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            dateKey: dateKey,
            source: source,
            promptTokensForTier: promptTokensForTier
        ).costUSD
    }

    struct CostEstimateBreakdown: Equatable {
        let costUSD: Double
        let cacheSavingsUSD: Double
        let over200kPremiumUSD: Double
    }

    private static func matchRule(
        in candidateRules: [PricingRule],
        dateKey: String,
        promptTotal: Int
    ) -> PricingRule {
        candidateRules.first { rule in
            if let from = rule.effectiveFrom, dateKey < from { return false }
            if let to = rule.effectiveTo, !to.isEmpty {
                // "until" from phases is exclusive upper bound if ISO, or inclusive YYYY-MM-DD in built-in rules
                if dateKey > to { return false }
            }
            if let maxP = rule.maxPromptTokens, promptTotal > maxP { return false }
            if let minP = rule.minPromptTokens, promptTotal < minP { return false }
            return true
        } ?? candidateRules.first ?? fallbackRule
    }

    private static func computeCost(
        rule: PricingRule,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int
    ) -> (costUSD: Double, cacheSavingsUSD: Double) {
        let inp = Double(max(0, inputTokens))
        let cache = Double(max(0, cacheReadTokens))
        let out = Double(max(0, outputTokens))

        let inpCost = (inp / 1_000_000.0) * rule.inputPerMillion
        let cacheCost = (cache / 1_000_000.0) * rule.cacheReadPerMillion
        let outCost = (out / 1_000_000.0) * rule.outputPerMillion
        let savings = max(0, (cache / 1_000_000.0) * (rule.inputPerMillion - rule.cacheReadPerMillion))
        return (inpCost + cacheCost + outCost, savings)
    }

    static func estimateCostBreakdownUSD(
        model rawModel: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        dateKey: String,
        source: ResolvedPricingSource,
        promptTokensForTier: Int? = nil
    ) -> CostEstimateBreakdown {
        let promptTotal = promptTokensForTier ?? (inputTokens + cacheReadTokens)
        let candidateRules = resolveCandidateRules(rawModel: rawModel, source: source, promptTotal: promptTotal)
        let matched = matchRule(in: candidateRules, dateKey: dateKey, promptTotal: promptTotal)
        let actual = computeCost(
            rule: matched,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens
        )

        var over200kPremiumUSD = 0.0
        if promptTotal > 200_000 {
            let baseRules = resolveCandidateRules(rawModel: rawModel, source: source, promptTotal: 200_000)
            let baseMatched = matchRule(in: baseRules, dateKey: dateKey, promptTotal: 200_000)
            let baseCost = computeCost(
                rule: baseMatched,
                inputTokens: inputTokens,
                cacheReadTokens: cacheReadTokens,
                outputTokens: outputTokens
            ).costUSD
            over200kPremiumUSD = max(0, actual.costUSD - baseCost)
        }

        return CostEstimateBreakdown(
            costUSD: actual.costUSD,
            cacheSavingsUSD: actual.cacheSavingsUSD,
            over200kPremiumUSD: over200kPremiumUSD
        )
    }

    static func estimateCostAndSavingsUSD(
        model rawModel: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        dateKey: String,
        source: ResolvedPricingSource,
        promptTokensForTier: Int? = nil
    ) -> (costUSD: Double, cacheSavingsUSD: Double) {
        let breakdown = estimateCostBreakdownUSD(
            model: rawModel,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            dateKey: dateKey,
            source: source,
            promptTokensForTier: promptTokensForTier
        )
        return (breakdown.costUSD, breakdown.cacheSavingsUSD)
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
