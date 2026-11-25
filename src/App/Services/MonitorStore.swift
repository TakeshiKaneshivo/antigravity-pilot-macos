import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    @Published var liveHub: DaemonHubInfo?
    @Published var userProfile: UserProfileInfo?
    @Published var quotaPools: [QuotaPoolGroup] = []
    @Published var sessions: [SessionSummary] = []
    @Published var pinnedCascadeId: String? = nil
    @Published var selectedCascadeId: String?
    @Published var activeContext: SessionContextSnapshot?
    @Published var usageHistory: UsageHistorySnapshot = .empty
    @Published var isRefreshingLive = false
    @Published var isRefreshingHistory = false
    @Published var lastLiveError: String?
    @Published var lastUpdatedAt: Date?

    private let rpcClient = LanguageServerClient()
    nonisolated(unsafe) private var liveTimer: Timer?
    private var lastHistoryScanAt: Date = .distantPast
    private var isInteractiveVisible = true
    private var liveRefreshGeneration = 0

    deinit {
        liveTimer?.invalidate()
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

    func refreshAll(forceHistory: Bool = true) {
        refreshLive()
        if forceHistory || Date().timeIntervalSince(lastHistoryScanAt) >= 60 {
            refreshHistory()
        }
    }

    func refreshLive(force: Bool = false) {
        guard force || !isRefreshingLive else { return }
        isRefreshingLive = true
        liveRefreshGeneration += 1
        let generation = liveRefreshGeneration
        let preferredId = pinnedCascadeId
        let currentLang = L10n.current

        Task { [weak self] in
            guard let self else { return }
            let hub = await Task.detached(priority: .utility) {
                LanguageServerClient.discoverLiveHub()
            }.value

            guard self.liveRefreshGeneration == generation else { return }

            guard let hub else {
                self.liveHub = nil
                self.userProfile = nil
                self.selectedCascadeId = nil
                self.activeContext = nil
                self.sessions = []
                self.quotaPools = []
                self.lastLiveError = nil
                self.isRefreshingLive = false
                return
            }

            do {
                async let statusTask = self.rpcClient.fetchUserStatus(hub: hub, lang: currentLang)
                async let sessionsTask = self.rpcClient.fetchSessions(hub: hub)

                let (profile, pools, labels) = try await statusTask
                let sessionList = try await sessionsTask

                let targetSession = preferredId.flatMap { pid in sessionList.first(where: { $0.id == pid }) }
                    ?? sessionList.first
                let contextSnap: SessionContextSnapshot?
                if let targetSession {
                    contextSnap = try await self.rpcClient.fetchSessionContext(
                        hub: hub,
                        session: targetSession,
                        modelLabels: labels
                    )
                } else {
                    contextSnap = nil
                }

                guard self.liveRefreshGeneration == generation else { return }

                self.liveHub = hub
                self.userProfile = profile
                self.quotaPools = pools
                self.sessions = sessionList
                self.selectedCascadeId = targetSession?.id
                self.activeContext = contextSnap
                self.lastLiveError = nil
                self.lastUpdatedAt = Date()
            } catch {
                guard self.liveRefreshGeneration == generation else { return }
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

        Task { [weak self] in
            guard let self else { return }
            let snapshot = await Task.detached(priority: .utility) {
                TranscriptScanner.scan()
            }.value

            self.usageHistory = snapshot
            self.lastHistoryScanAt = Date()
            self.isRefreshingHistory = false
        }
    }

    var primaryQuotaPool: QuotaPoolGroup? {
        quotaPools.first
    }

    var compactMenuBarText: String? {
        guard liveHub != nil else { return nil }
        var parts: [String] = []
        if let ctx = activeContext {
            parts.append(TokenFormatting.compactTokensShort(ctx.activeContextTokens))
        }
        if let quota = primaryQuotaPool {
            parts.append("\(quota.remainingPercent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func rescheduleTimer() {
        liveTimer?.invalidate()
        let interval: TimeInterval = isInteractiveVisible ? 5.0 : 30.0
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
