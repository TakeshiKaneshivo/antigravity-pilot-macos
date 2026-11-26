import Foundation

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

    init(support: AppSupport = AppSupport()) {
        self.support = support
        self.lastKnownTier = StoredSubscriptionTier.load(from: support.lastKnownTierURL)
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
                self.rescheduleTimer()

                if !catalog.isEmpty && !self.didInitialModelCatalogSync {
                    self.didInitialModelCatalogSync = true
                    self.refreshHistory()
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

    func refreshHistory() {
        guard !isRefreshingHistory else { return }
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

    var compactMenuBarText: String? {
        guard liveHub != nil else { return nil }
        let runningPrefix: String
        if activeRunningSessionCount > 1 {
            runningPrefix = "●\(activeRunningSessionCount) · "
        } else if activeRunningSessionCount == 1 {
            runningPrefix = "● "
        } else {
            runningPrefix = ""
        }

        var parts: [String] = []
        if let ctx = activeContext {
            parts.append(TokenFormatting.compactTokensShort(ctx.activeContextTokens))
        }
        if let quota = primaryQuotaPool {
            parts.append("\(quota.remainingPercent)%")
        }
        if parts.isEmpty {
            return activeRunningSessionCount > 0 ? "●\(activeRunningSessionCount)" : nil
        }
        return runningPrefix + parts.joined(separator: " · ")
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
