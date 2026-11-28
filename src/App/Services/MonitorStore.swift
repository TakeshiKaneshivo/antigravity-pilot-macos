import Foundation

struct QuotaRecoveryBucketState: Codable, Equatable {
    var lastRemainingFraction: Double
    var lastResetTimeEpoch: Double?
    var enteredLowState: Bool
    var lastNotifiedRecoveryEpoch: Double?
}

struct QuotaRecoveryEvent: Equatable {
    let poolId: String
    let poolTitle: String
    let windowKind: QuotaWindowKind
    let remainingPercent: Int
}

enum QuotaRecoveryEvaluator {
    static func evaluate(
        previous: [String: QuotaRecoveryBucketState],
        pools: [QuotaPoolGroup],
        now: Date = Date(),
        lowThreshold: Double = 0.20,
        recoveredThreshold: Double = 0.80,
        minJump: Double = 0.50,
        cooldownSec: TimeInterval = 600
    ) -> (nextState: [String: QuotaRecoveryBucketState], events: [QuotaRecoveryEvent]) {
        var next = previous
        var events: [QuotaRecoveryEvent] = []
        let nowEpoch = now.timeIntervalSince1970

        for pool in pools {
            let items: [(key: String, kind: QuotaWindowKind, frac: Double, resetEpoch: Double?)]
            if pool.buckets.isEmpty {
                items = [("\(pool.id)|pool", pool.tightestWindowKind, pool.remainingFraction, pool.resetTime?.timeIntervalSince1970)]
            } else {
                items = pool.buckets.map { b in
                    ("\(pool.id)|\(b.windowKind.rawValue)", b.windowKind, b.remainingFraction, b.resetTime?.timeIntervalSince1970)
                }
            }

            for item in items {
                let frac = min(max(item.frac, 0), 1)
                var state = next[item.key] ?? QuotaRecoveryBucketState(
                    lastRemainingFraction: frac,
                    lastResetTimeEpoch: item.resetEpoch,
                    enteredLowState: frac <= lowThreshold,
                    lastNotifiedRecoveryEpoch: nil
                )

                if previous[item.key] != nil {
                    let jumpedUp = (frac - state.lastRemainingFraction) >= minJump
                    let recovered = state.enteredLowState && (frac >= recoveredThreshold || jumpedUp)
                    let cooldownOK = state.lastNotifiedRecoveryEpoch.map { (nowEpoch - $0) >= cooldownSec } ?? true

                    if recovered {
                        if cooldownOK {
                            let pct = Int((frac * 100).rounded())
                            events.append(QuotaRecoveryEvent(
                                poolId: pool.id,
                                poolTitle: pool.title,
                                windowKind: item.kind,
                                remainingPercent: pct
                            ))
                            state.lastNotifiedRecoveryEpoch = nowEpoch
                        }
                        state.enteredLowState = false
                    } else if frac <= lowThreshold {
                        state.enteredLowState = true
                    }
                    state.lastRemainingFraction = frac
                    state.lastResetTimeEpoch = item.resetEpoch
                }
                next[item.key] = state
            }
        }
        return (next, events)
    }

    static func loadState(from url: URL) -> [String: QuotaRecoveryBucketState] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: QuotaRecoveryBucketState].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func saveState(_ state: [String: QuotaRecoveryBucketState], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var liveHub: DaemonHubInfo?
    @Published var userProfile: UserProfileInfo?
    @Published var lastKnownTier: StoredSubscriptionTier?
    @Published var modelCatalog: [String: ModelCatalogEntry] = [:]
    @Published var quotaPools: [QuotaPoolGroup] = []
    @Published var sessions: [SessionSummary] = []
    @Published var activeRunningSessionCount: Int = 0
    @Published var pinnedCascadeId: String? = nil
    @Published var selectedCascadeId: String?
    @Published var activeContext: SessionContextSnapshot?
    @Published var usageHistory: UsageHistorySnapshot = .empty
    @Published var isRefreshingLive = false
    @Published var isRefreshingHistory = false
    @Published var lastLiveError: String?
    @Published var lastUpdatedAt: Date?

    private let support: AppSupport
    private let rpcClient = LanguageServerClient()
    nonisolated(unsafe) private var liveTimer: Timer?
    private var currentPollingInterval: TimeInterval = 0
    private var liveRefreshTask: Task<Void, Never>?
    private var postTurnRefreshTask: Task<Void, Never>?
    private var lastHistoryScanAt: Date = .distantPast
    private var isInteractiveVisible = true
    private var liveRefreshGeneration = 0
    private var didInitialModelCatalogSync = false
    private var needsFollowUpHistoryRefresh = false
    private var previousSessionStatuses: [String: String] = [:]
    private var hasSeededSessionStatuses = false
    private var quotaRecoveryState: [String: QuotaRecoveryBucketState] = [:]

    var onQuotaRecovered: ((QuotaRecoveryEvent) -> Void)?
    var onSessionCompletedFallback: ((SessionSummary) -> Void)?
    var onSessionApprovalFallback: ((SessionSummary) -> Void)?

    init(support: AppSupport = AppSupport()) {
        self.support = support
        self.lastKnownTier = StoredSubscriptionTier.load(from: support.lastKnownTierURL)
        self.quotaRecoveryState = QuotaRecoveryEvaluator.loadState(from: support.quotaNotificationStateURL)
    }

    deinit {
        liveTimer?.invalidate()
        liveRefreshTask?.cancel()
        postTurnRefreshTask?.cancel()
    }

    nonisolated static func pollingInterval(
        isInteractiveVisible: Bool,
        activeRunningSessionCount: Int
    ) -> TimeInterval {
        if isInteractiveVisible {
            return 5.0
        }
        if activeRunningSessionCount > 0 {
            return 10.0
        }
        return 30.0
    }

    func start() {
        refreshAll(forceHistory: true)
        rescheduleTimer()
    }

    func setInteractiveVisible(_ visible: Bool) {
        guard isInteractiveVisible != visible else { return }
        isInteractiveVisible = visible
        rescheduleTimer()
        if visible {
            refreshLive()
        }
    }

    func selectSession(_ cascadeId: String?) {
        let normalized = (cascadeId?.isEmpty == false) ? cascadeId : nil
        pinnedCascadeId = normalized
        if let normalized {
            selectedCascadeId = normalized
        }
        refreshLive(force: true)
    }

    func refreshAll(forceHistory: Bool = true, forceLive: Bool = false) {
        refreshLive(force: forceLive)
        if forceHistory || Date().timeIntervalSince(lastHistoryScanAt) >= 60 {
            refreshHistory()
        }
    }

    func refreshLive(force: Bool = false) {
        guard force || !isRefreshingLive else { return }
        if force {
            liveRefreshTask?.cancel()
            postTurnRefreshTask?.cancel()
            postTurnRefreshTask = nil
        }
        isRefreshingLive = true
        liveRefreshGeneration += 1
        let generation = liveRefreshGeneration
        let preferredId = pinnedCascadeId
        let currentLang = L10n.current
        let supportCopy = support

        liveRefreshTask = Task { [weak self] in
            guard let self else { return }
            let hubs = await Task.detached(priority: .utility) {
                LanguageServerClient.discoverLiveHubs()
            }.value

            guard !Task.isCancelled, self.liveRefreshGeneration == generation else { return }

            let resolved = await self.rpcClient.resolveMostActiveHub(
                candidates: hubs,
                preferredCascadeId: preferredId
            )

            guard !Task.isCancelled, self.liveRefreshGeneration == generation else { return }

            guard let resolved else {
                self.postTurnRefreshTask?.cancel()
                self.postTurnRefreshTask = nil
                self.liveHub = nil
                self.userProfile = nil
                self.selectedCascadeId = nil
                self.activeContext = nil
                self.sessions = []
                self.activeRunningSessionCount = 0
                self.quotaPools = []
                self.lastLiveError = nil
                self.previousSessionStatuses = [:]
                self.hasSeededSessionStatuses = false
                self.isRefreshingLive = false
                self.rescheduleTimer()
                return
            }

            let hub = resolved.hub
            do {
                async let statusTask = self.rpcClient.fetchUserStatus(hub: hub, lang: currentLang)
                let sessionList: [SessionSummary]
                if let prefetched = resolved.prefetchedSessions {
                    sessionList = prefetched
                } else {
                    sessionList = try await self.rpcClient.fetchSessions(hub: hub)
                }

                let (profile, pools, labels, catalog) = try await statusTask

                guard !Task.isCancelled, self.liveRefreshGeneration == generation else { return }

                let targetSession = preferredId.flatMap { pid in sessionList.first(where: { $0.id == pid }) }
                    ?? sessionList.first
                let contextSnap: SessionContextSnapshot?
                if let targetSession {
                    let pricingSource = await Task.detached(priority: .utility) {
                        PricingCatalog.ResolvedPricingSource.load(
                            customPricingURL: supportCopy.customPricingURL,
                            syncedCatalogURL: supportCopy.syncedPricingCatalogURL,
                            bundledCatalogURL: PricingCatalog.defaultBundledCatalogURL(),
                            modelCatalog: catalog
                        )
                    }.value
                    contextSnap = try await self.rpcClient.fetchSessionContext(
                        hub: hub,
                        session: targetSession,
                        modelLabels: labels,
                        modelCatalog: catalog,
                        pricingSource: pricingSource
                    )
                } else {
                    contextSnap = nil
                }

                guard !Task.isCancelled, self.liveRefreshGeneration == generation else { return }

                let previousRunningCount = self.activeRunningSessionCount
                let newRunningCount = sessionList.filter(\.isRunning).count

                self.liveHub = hub
                self.userProfile = profile
                if let stored = profile?.toStoredTier() {
                    self.lastKnownTier = stored
                    Task.detached(priority: .utility) {
                        StoredSubscriptionTier.save(stored, to: supportCopy.lastKnownTierURL)
                    }
                }
                self.modelCatalog = catalog
                self.quotaPools = pools
                self.sessions = sessionList
                self.activeRunningSessionCount = newRunningCount
                self.selectedCascadeId = targetSession?.id
                self.activeContext = contextSnap
                self.lastLiveError = nil
                self.lastUpdatedAt = Date()
                self.evaluateMonitorNotifications(sessions: sessionList, pools: pools, supportCopy: supportCopy)
                self.rescheduleTimer()

                if !catalog.isEmpty && !self.didInitialModelCatalogSync {
                    self.didInitialModelCatalogSync = true
                    self.refreshHistory(queueIfBusy: true)
                }

                if newRunningCount > 0 {
                    self.postTurnRefreshTask?.cancel()
                    self.postTurnRefreshTask = nil
                } else if previousRunningCount > 0 && newRunningCount == 0 {
                    self.postTurnRefreshTask?.cancel()
                    self.postTurnRefreshTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled, let self else { return }
                        self.refreshLive(force: true)
                    }
                }
            } catch {
                guard !Task.isCancelled, self.liveRefreshGeneration == generation else { return }
                self.liveHub = hub
                self.lastLiveError = error.localizedDescription
            }

            if self.liveRefreshGeneration == generation {
                self.isRefreshingLive = false
            }
        }
    }

    func refreshHistory(queueIfBusy: Bool = false) {
        if isRefreshingHistory {
            if queueIfBusy {
                needsFollowUpHistoryRefresh = true
            }
            return
        }
        needsFollowUpHistoryRefresh = false
        isRefreshingHistory = true
        let supportCopy = support
        let catalogSnap = modelCatalog
        let sessionsSnap = sessions

        Task { [weak self] in
            guard let self else { return }
            let snapshot = await Task.detached(priority: .utility) {
                TranscriptScanner.scanMultiSource(
                    cacheURL: supportCopy.usageCacheURL,
                    support: supportCopy,
                    modelCatalog: catalogSnap,
                    liveSessions: sessionsSnap
                )
            }.value

            self.usageHistory = snapshot
            self.lastHistoryScanAt = Date()
            self.isRefreshingHistory = false
            if self.needsFollowUpHistoryRefresh {
                self.needsFollowUpHistoryRefresh = false
                self.refreshHistory()
            }
        }
    }

    var effectiveSubscriptionTier: (tierKind: SubscriptionTierKind, tierName: String, monthlyReferenceUSD: Double?) {
        if let profile = userProfile,
           (profile.tierKind != .unknown || !profile.tierName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return (profile.tierKind, profile.tierName, profile.monthlyReferenceUSD)
        }
        if let stored = lastKnownTier {
            return (stored.tierKind, stored.tierName, stored.monthlyReferenceUSD)
        }
        return (.unknown, "", nil)
    }

    var tightestQuotaPool: QuotaPoolGroup? {
        quotaPools.min { $0.remainingFraction < $1.remainingFraction }
    }

    var primaryQuotaPool: QuotaPoolGroup? {
        tightestQuotaPool ?? quotaPools.first
    }

    var compactMetricsText: String? {
        compactMetricsText(includeContext: true, includeQuota: true)
    }

    func compactMetricsText(includeContext: Bool, includeQuota: Bool) -> String? {
        guard liveHub != nil else { return nil }
        return Self.formatMetricsText(
            contextTokens: activeContext?.activeContextTokens,
            quotaRemainingPercent: primaryQuotaPool?.remainingPercent,
            quotaWindowKind: primaryQuotaPool?.tightestWindowKind ?? .unknown,
            includeContext: includeContext,
            includeQuota: includeQuota
        )
    }

    nonisolated static func formatMetricsText(
        contextTokens: Int?,
        quotaRemainingPercent: Int?,
        quotaWindowKind: QuotaWindowKind = .unknown,
        includeContext: Bool,
        includeQuota: Bool
    ) -> String? {
        var parts: [String] = []
        if includeContext, let tokens = contextTokens {
            parts.append(TokenFormatting.compactTokensShort(tokens))
        }
        if includeQuota, let pct = quotaRemainingPercent {
            switch quotaWindowKind {
            case .fiveHour:
                parts.append("5h \(pct)%")
            case .weekly:
                parts.append("7d \(pct)%")
            case .unknown:
                parts.append("\(pct)%")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func menuBarTooltip(lang: AppLanguage) -> String {
        let contextUsed = activeContext.map { TokenFormatting.compactTokens($0.activeContextTokens) }
        let contextLimit = activeContext.map { TokenFormatting.compactTokens($0.contextLimitTokens) }
        return Self.formatMenuBarTooltip(
            isLive: liveHub != nil,
            runningCount: activeRunningSessionCount,
            contextUsedText: contextUsed,
            contextLimitText: contextLimit,
            modelDisplayName: activeContext?.modelDisplayName,
            quotaTitle: primaryQuotaPool?.title,
            quotaWindowKind: primaryQuotaPool?.tightestWindowKind,
            quotaRemainingPercent: primaryQuotaPool?.remainingPercent,
            quotaResetText: primaryQuotaPool?.resetCountdownText(lang),
            lang: lang
        )
    }

    nonisolated static func formatMenuBarTooltip(
        isLive: Bool,
        runningCount: Int,
        contextUsedText: String?,
        contextLimitText: String?,
        modelDisplayName: String?,
        quotaTitle: String?,
        quotaWindowKind: QuotaWindowKind?,
        quotaRemainingPercent: Int?,
        quotaResetText: String?,
        lang: AppLanguage
    ) -> String {
        guard isLive else {
            return L10n.t(
                zhHans: "Antigravity Pilot · 等待 Antigravity 启动",
                zhHant: "Antigravity Pilot · 等待 Antigravity 啟動",
                en: "Antigravity Pilot · Waiting for Antigravity",
                ru: "Antigravity Pilot · Ожидание Antigravity",
                lang
            )
        }

        var lines: [String] = []
        if runningCount > 0 {
            lines.append(L10n.t(
                zhHans: "运行中：\(runningCount) 个活跃会话",
                zhHant: "執行中：\(runningCount) 個活躍工作階段",
                en: "Running: \(runningCount) active session\(runningCount == 1 ? "" : "s")",
                ru: "Активно: \(runningCount) сесс.",
                lang
            ))
        }

        if let used = contextUsedText, let limit = contextLimitText {
            let modelSuffix = modelDisplayName.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            lines.append(L10n.t(
                zhHans: "上下文：\(used) / \(limit)\(modelSuffix)",
                zhHant: "上下文：\(used) / \(limit)\(modelSuffix)",
                en: "Context: \(used) / \(limit)\(modelSuffix)",
                ru: "Контекст: \(used) / \(limit)\(modelSuffix)",
                lang
            ))
        }

        if let pct = quotaRemainingPercent {
            let windowLabel = (quotaWindowKind ?? .unknown).shortLabel(lang)
            let poolPrefix = (quotaTitle?.isEmpty == false) ? "\(quotaTitle!) · " : ""
            let isCJK = lang.resolved == .zhHans || lang.resolved == .zhHant
            let resetPart = (quotaResetText?.isEmpty == false)
                ? (isCJK ? "（\(quotaResetText!)）" : " (\(quotaResetText!))")
                : ""
            lines.append(L10n.t(
                zhHans: "最紧配额：\(poolPrefix)\(windowLabel) \(pct)%\(resetPart)",
                zhHant: "最緊配額：\(poolPrefix)\(windowLabel) \(pct)%\(resetPart)",
                en: "Tightest Quota: \(poolPrefix)\(windowLabel) \(pct)%\(resetPart)",
                ru: "Мин. квота: \(poolPrefix)\(windowLabel) \(pct)%\(resetPart)",
                lang
            ))
        }

        if lines.isEmpty {
            return L10n.t(
                zhHans: "Antigravity Pilot · 已连接",
                zhHant: "Antigravity Pilot · 已連線",
                en: "Antigravity Pilot · Connected",
                ru: "Antigravity Pilot · Подключён",
                lang
            )
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func formatMenuBarTitle(runningCount: Int, metricsText: String?) -> String {
        let trimmedMetrics = metricsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedMetrics.isEmpty ? "" : " \(trimmedMetrics)"
    }

    func lastUpdatedShortText(lang: AppLanguage, now: Date = Date()) -> String? {
        guard let lastUpdatedAt else { return nil }
        let diff = max(0, Int(now.timeIntervalSince(lastUpdatedAt)))
        if diff < 5 {
            return L10n.t(zhHans: "刚刚", zhHant: "剛剛", en: "just now", ru: "только что", lang)
        }
        if diff < 60 {
            return L10n.t(zhHans: "\(diff)秒前", zhHant: "\(diff)秒前", en: "\(diff)s ago", ru: "\(diff)с назад", lang)
        }
        if diff < 3600 {
            let mins = diff / 60
            return L10n.t(zhHans: "\(mins)分钟前", zhHant: "\(mins)分鐘前", en: "\(mins)m ago", ru: "\(mins)м назад", lang)
        }
        let hrs = diff / 3600
        return L10n.t(zhHans: "\(hrs)小时前", zhHant: "\(hrs)小時前", en: "\(hrs)h ago", ru: "\(hrs)ч назад", lang)
    }

    private func evaluateMonitorNotifications(
        sessions: [SessionSummary],
        pools: [QuotaPoolGroup],
        supportCopy: AppSupport
    ) {
        let (nextQuotaState, quotaEvents) = QuotaRecoveryEvaluator.evaluate(
            previous: quotaRecoveryState,
            pools: pools
        )
        if nextQuotaState != quotaRecoveryState {
            quotaRecoveryState = nextQuotaState
            Task.detached(priority: .utility) {
                QuotaRecoveryEvaluator.saveState(nextQuotaState, to: supportCopy.quotaNotificationStateURL)
            }
        }
        for event in quotaEvents {
            onQuotaRecovered?(event)
        }

        var nextStatuses: [String: String] = [:]
        for session in sessions where !session.isSubagent {
            let statusUpper = session.status.uppercased()
            nextStatuses[session.id] = statusUpper

            if hasSeededSessionStatuses, let prevUpper = previousSessionStatuses[session.id] {
                let wasRunning = prevUpper.contains("RUNNING")
                let isRunningNow = statusUpper.contains("RUNNING")
                let wasWaiting = prevUpper.contains("WAITING") || prevUpper.contains("APPROVAL")
                let isWaitingNow = statusUpper.contains("WAITING") || statusUpper.contains("APPROVAL")
                let isCanceledNow = statusUpper.contains("CANCEL")

                if !wasWaiting && isWaitingNow {
                    onSessionApprovalFallback?(session)
                } else if wasRunning && !isRunningNow && !isWaitingNow && !isCanceledNow {
                    onSessionCompletedFallback?(session)
                }
            }
        }
        previousSessionStatuses = nextStatuses
        hasSeededSessionStatuses = true
    }

    private func rescheduleTimer() {
        let interval = Self.pollingInterval(
            isInteractiveVisible: isInteractiveVisible,
            activeRunningSessionCount: activeRunningSessionCount
        )
        if liveTimer != nil && abs(currentPollingInterval - interval) < 0.01 {
            return
        }
        liveTimer?.invalidate()
        currentPollingInterval = interval
        liveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshLive()
                if Date().timeIntervalSince(self.lastHistoryScanAt) >= 60 {
                    self.refreshHistory()
                }
            }
        }
    }
}
