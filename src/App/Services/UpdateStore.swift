import AppKit
import Foundation

@MainActor
final class UpdateStore: ObservableObject {
    @Published var state: AppUpdateState = .idle
    @Published var lastCheckedAt: Date?
    @Published var openPopoverRequestCount: Int = 0

    let support: AppSupport
    private let lastCheckDefaultsKey = "pilot.lastUpdateCheckTimestamp"
    private let checkIntervalSeconds: TimeInterval = 12 * 3600

    private var checkTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var periodicTimer: Timer?
    private var cachedAvailableState: AppUpdateState?

    init(support: AppSupport = AppSupport()) {
        self.support = support
        let ts = UserDefaults.standard.double(forKey: lastCheckDefaultsKey)
        if ts > 0 {
            self.lastCheckedAt = Date(timeIntervalSince1970: ts)
        }
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.1.0"
    }

    func hasActionableUpdate(skippedVersion: String?) -> Bool {
        switch state {
        case .available(let manifest, _, _, _):
            return manifest.version != skippedVersion
        case .downloading, .verifying, .readyForManualInstall, .installing:
            return true
        case .idle, .checking, .upToDate, .failed:
            return false
        }
    }

    func availableVersionBadgeText(skippedVersion: String?) -> String? {
        guard hasActionableUpdate(skippedVersion: skippedVersion) else { return nil }
        return state.activeManifest?.version
    }

    func startAutoCheckSchedule(configProvider: @escaping @MainActor () -> ProxyConfig) {
        let updatesDir = support.updatesDirectory
        Task.detached(priority: .utility) {
            AppUpdateService.cleanupStaleUpdateFiles(in: updatesDir)
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            let cfg = configProvider()
            if cfg.autoCheckUpdates && self.isCheckDue() {
                self.checkForUpdates(config: cfg, userInitiated: false)
            }
        }

        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cfg = configProvider()
                if cfg.autoCheckUpdates && !self.state.isBusy {
                    self.checkForUpdates(config: cfg, userInitiated: false)
                }
            }
        }
    }

    private func isCheckDue() -> Bool {
        guard let lastCheckedAt else { return true }
        return Date().timeIntervalSince(lastCheckedAt) >= checkIntervalSeconds
    }

    func requestOpenUpdatePopover() {
        openPopoverRequestCount += 1
    }

    func checkForUpdates(config: ProxyConfig, userInitiated: Bool) {
        switch state {
        case .downloading, .verifying, .installing:
            return
        default:
            break
        }

        checkTask?.cancel()
        if userInitiated {
            state = .checking
        }

        let currentVer = currentVersion
        let lang = config.appLanguage
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (manifest, route) = try await AppUpdateService.fetchManifest(
                    config: config,
                    currentVersion: currentVer
                )
                try Task.checkCancellation()

                let now = Date()
                self.lastCheckedAt = now
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.lastCheckDefaultsKey)

                if let remoteVer = AppVersion(manifest.version),
                   let localVer = AppVersion(currentVer),
                   remoteVer > localVer {
                    let osOK = AppVersion.currentOSMeets(minMacOS: manifest.minMacOS)
                    let eligibility = AppUpdateService.checkInstallEligibility(lang: lang)
                    let nextState = AppUpdateState.available(
                        manifest: manifest,
                        route: route,
                        osSupported: osOK,
                        eligibility: eligibility
                    )
                    self.cachedAvailableState = nextState
                    self.state = nextState
                } else {
                    self.cachedAvailableState = nil
                    self.state = .upToDate(checkedAt: now, route: route)
                }
            } catch is CancellationError {
                if case .checking = self.state {
                    self.state = .idle
                }
            } catch {
                if userInitiated {
                    self.state = .failed(message: error.localizedDescription, canRetry: true)
                } else if case .checking = self.state {
                    self.state = .idle
                }
            }
        }
    }

    func startDownloadAndInstall(config: ProxyConfig) {
        guard let manifest = state.activeManifest else { return }
        if case .available(_, _, let osSupported, _) = state, !osSupported {
            return
        }

        let initialRoute: UpdateRoute
        let eligibility: InstallEligibility
        switch state {
        case .available(_, let route, _, let elig):
            initialRoute = route
            eligibility = elig
            cachedAvailableState = state
        default:
            initialRoute = .direct
            eligibility = AppUpdateService.checkInstallEligibility(lang: config.appLanguage)
        }

        downloadTask?.cancel()
        state = .downloading(
            manifest: manifest,
            downloadedBytes: 0,
            totalBytes: manifest.dmg.size ?? 0,
            route: initialRoute
        )

        let updatesDir = support.updatesDirectory
        let lang = config.appLanguage
        let resolvedFeed = AppUpdateService.resolvedFeedURL()

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (dmgURL, _) = try await AppUpdateService.downloadAndVerifyDMG(
                    manifest: manifest,
                    config: config,
                    updatesDir: updatesDir,
                    allowInsecureHTTP: resolvedFeed.allowInsecureHTTP
                ) { downloaded, total, activeRoute in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading = self.state {
                            self.state = .downloading(
                                manifest: manifest,
                                downloadedBytes: downloaded,
                                totalBytes: total,
                                route: activeRoute
                            )
                        }
                    }
                }

                try Task.checkCancellation()

                switch eligibility {
                case .manualFallbackRequired(let reason):
                    self.state = .readyForManualInstall(manifest: manifest, dmgURL: dmgURL, reason: reason)
                case .inPlaceSupported(let targetApp):
                    self.state = .verifying(
                        manifest: manifest,
                        stage: L10n.t("正在准备安装更新...", "Preparing update...", lang)
                    )
                    try await Task.detached(priority: .userInitiated) {
                        try AppUpdateService.prepareAndLaunchInPlaceUpdate(
                            dmgURL: dmgURL,
                            manifest: manifest,
                            targetAppURL: targetApp,
                            updatesDir: updatesDir,
                            lang: lang
                        ) { stageText in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.state = .verifying(manifest: manifest, stage: stageText)
                            }
                        }
                    }.value

                    self.state = .installing(manifest: manifest)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    NSApplication.shared.terminate(nil)
                }
            } catch is CancellationError {
                if let cached = self.cachedAvailableState {
                    self.state = cached
                } else {
                    self.state = .idle
                }
            } catch {
                self.state = .failed(message: error.localizedDescription, canRetry: true)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if let cached = cachedAvailableState {
            state = cached
        } else {
            state = .idle
        }
    }

    func openManualInstaller() {
        if case .readyForManualInstall(_, let dmgURL, _) = state {
            NSWorkspace.shared.open(dmgURL)
        }
    }

    func openReleasePage() {
        if let raw = state.activeManifest?.releasePageUrl,
           let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(AppUpdateService.defaultReleasesPageURL)
    }
}
