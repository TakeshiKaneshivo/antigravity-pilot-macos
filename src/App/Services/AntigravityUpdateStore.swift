import AppKit
import Foundation

@MainActor
final class AntigravityUpdateStore: ObservableObject {
    @Published var state: AntigravityUpdateState = .idle
    @Published var lastCheckedAt: Date?

    let support: AppSupport
    private let lastCheckDefaultsKey = "pilot.lastAntigravityUpdateCheckTimestamp"
    private let checkIntervalSeconds: TimeInterval = 6 * 3600

    private var checkTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var periodicTimer: Timer?
    private var cachedAvailableState: AntigravityUpdateState?

    init(support: AppSupport = AppSupport()) {
        self.support = support
        let ts = UserDefaults.standard.double(forKey: lastCheckDefaultsKey)
        if ts > 0 {
            self.lastCheckedAt = Date(timeIntervalSince1970: ts)
        }
    }

    func hasActionableUpdate(skippedVersion: String?) -> Bool {
        switch state {
        case .available(_, let manifest, _, _):
            return manifest.version != skippedVersion
        case .downloading, .verifying, .replacingAndRebuilding, .readyForManualInstall:
            return true
        case .idle, .checking, .upToDate, .failed:
            return false
        }
    }

    func startAutoCheckSchedule(configProvider: @escaping @MainActor () -> ProxyConfig) {
        let updatesDir = support.antigravityUpdatesDirectory
        Task.detached(priority: .utility) {
            AntigravityUpdateService.cleanupStaleFiles(in: updatesDir)
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
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

    func checkForUpdates(config: ProxyConfig, userInitiated: Bool) {
        switch state {
        case .downloading, .verifying, .replacingAndRebuilding:
            return
        case .checking:
            if !userInitiated { return }
        default:
            break
        }

        checkTask?.cancel()
        if userInitiated {
            state = .checking
        }

        let currentSupport = support
        let lang = config.appLanguage
        let installedVersion = RuntimeBuilder.readBundleShortVersion(
            at: currentSupport.sourceApp.appendingPathComponent("Contents/Info.plist")
        )

        guard !installedVersion.isEmpty else {
            if userInitiated {
                state = .failed(
                    message: L10n.t(
                        "未检测到原版 /Applications/Antigravity.app",
                        "Original /Applications/Antigravity.app not found",
                        lang
                    ),
                    canRetry: true
                )
            } else if case .checking = state {
                state = .idle
            }
            return
        }

        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (result, route) = try await AntigravityUpdateService.fetchManifest(
                    sourceApp: currentSupport.sourceApp,
                    installedVersion: installedVersion,
                    config: config
                )
                try Task.checkCancellation()

                let now = Date()
                self.lastCheckedAt = now
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.lastCheckDefaultsKey)

                switch result {
                case .updateAvailable(let manifest):
                    if let remoteVer = AppVersion(manifest.version),
                       let localVer = AppVersion(installedVersion),
                       remoteVer > localVer {
                        let eligibility = AntigravityUpdateService.checkInstallEligibility(
                            sourceApp: currentSupport.sourceApp,
                            lang: lang
                        )
                        let nextState = AntigravityUpdateState.available(
                            installedVersion: installedVersion,
                            manifest: manifest,
                            route: route,
                            eligibility: eligibility
                        )
                        self.cachedAvailableState = nextState
                        self.state = nextState
                    } else {
                        self.cachedAvailableState = nil
                        self.state = .upToDate(installedVersion: installedVersion, checkedAt: now, route: route)
                    }
                case .upToDate:
                    self.cachedAvailableState = nil
                    self.state = .upToDate(installedVersion: installedVersion, checkedAt: now, route: route)
                }
            } catch is CancellationError {
                if case .checking = self.state {
                    self.state = self.cachedAvailableState ?? .idle
                }
            } catch {
                if userInitiated {
                    self.state = .failed(message: error.localizedDescription, canRetry: true)
                } else if case .checking = self.state {
                    self.state = self.cachedAvailableState ?? .idle
                }
            }
        }
    }

    func startUpdateAndRebuild(appModel: AppModel, onLaunchComplete: (() -> Void)? = nil) {
        guard !state.isBusy, !appModel.isWorking else { return }
        guard let manifest = state.activeManifest else { return }

        let currentConfig = appModel.config
        let lang = currentConfig.appLanguage
        let currentSupport = support

        let initialRoute: UpdateRoute
        let eligibility: AntigravityInstallEligibility
        switch state {
        case .available(_, _, let route, let elig):
            initialRoute = route
            eligibility = elig
            cachedAvailableState = state
        default:
            initialRoute = .direct
            eligibility = AntigravityUpdateService.checkInstallEligibility(
                sourceApp: currentSupport.sourceApp,
                lang: lang
            )
        }

        updateTask?.cancel()
        state = .downloading(
            manifest: manifest,
            downloadedBytes: 0,
            totalBytes: manifest.size ?? 0,
            route: initialRoute
        )

        let updatesDir = currentSupport.antigravityUpdatesDirectory
        let sharedPending = currentSupport.antigravitySharedPendingZipURL
        let resolvedFeed = AntigravityUpdateService.resolvedFeedURL(from: currentSupport.sourceApp)

        updateTask = Task { [weak self] in
            guard let self else { return }
            var activeRoute = initialRoute
            var stagingRootToClean: URL?
            defer {
                if let stagingRootToClean {
                    try? FileManager.default.removeItem(at: stagingRootToClean)
                }
            }

            do {
                let (zipURL, downloadRoute) = try await AntigravityUpdateService.downloadAndVerifyZip(
                    manifest: manifest,
                    config: currentConfig,
                    updatesDir: updatesDir,
                    sharedPendingZipURL: sharedPending,
                    allowInsecureHTTP: resolvedFeed.allowInsecureHTTP
                ) { downloaded, total, route in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading = self.state {
                            self.state = .downloading(
                                manifest: manifest,
                                downloadedBytes: downloaded,
                                totalBytes: total,
                                route: route
                            )
                        }
                    }
                }
                activeRoute = downloadRoute
                try Task.checkCancellation()

                switch eligibility {
                case .manualFallbackRequired(let reason):
                    self.state = .readyForManualInstall(manifest: manifest, zipURL: zipURL, reason: reason)
                    return

                case .inPlaceSupported(let targetApp):
                    let stagingRoot = updatesDir.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
                    stagingRootToClean = stagingRoot

                    self.state = .verifying(
                        manifest: manifest,
                        stage: L10n.t("正在解压并校验 Google 官方签名...", "Extracting & verifying Google signature...", lang)
                    )
                    let stagedApp = try await Task.detached(priority: .userInitiated) {
                        try AntigravityUpdateService.extractAndVerifyApp(
                            zipURL: zipURL,
                            manifest: manifest,
                            stagingRoot: stagingRoot,
                            requireOfficialSignature: true,
                            lang: lang
                        )
                    }.value

                    let instances = RunningInstanceManager.detectRunningInstances(support: currentSupport)
                    appModel.runningInstances = instances
                    if !instances.isEmpty {
                        self.state = .replacingAndRebuilding(
                            manifest: manifest,
                            stage: L10n.t("正在优雅退出运行中的 Antigravity...", "Gracefully quitting running Antigravity...", lang)
                        )
                        let exited = await RunningInstanceManager.terminateGracefully(instances, timeoutSeconds: 5.0)
                        appModel.refreshRunningInstances()
                        if !exited {
                            throw AntigravityUpdateError.runningInstancesNotExited(L10n.t(
                                "旧版 Antigravity 未能在 5 秒内退出，请手动 Cmd + Q 退出后重试。",
                                "Antigravity did not exit within 5s. Quit with Cmd + Q and try again.",
                                lang
                            ))
                        }
                    }

                    self.state = .replacingAndRebuilding(
                        manifest: manifest,
                        stage: L10n.t("正在原子更新原版 Antigravity...", "Atomically updating original Antigravity...", lang)
                    )
                    try await Task.detached(priority: .userInitiated) {
                        try AntigravityUpdateService.atomicallyReplaceSourceApp(
                            stagedApp: stagedApp,
                            targetApp: targetApp,
                            lang: lang
                        )
                    }.value
                    try? FileManager.default.removeItem(at: stagingRoot)
                    stagingRootToClean = nil
                    try? FileManager.default.removeItem(at: currentSupport.runtimeShipItCacheDirectory)

                    appModel.refreshRuntimeStatus()

                    self.state = .replacingAndRebuilding(
                        manifest: manifest,
                        stage: L10n.t("正在重建并启动代理副本...", "Rebuilding & launching proxy copy...", lang)
                    )
                    _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BuildApplyOutcome, Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                let builder = RuntimeBuilder(config: currentConfig, support: currentSupport) { message in
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        if case .replacingAndRebuilding = self.state {
                                            self.state = .replacingAndRebuilding(manifest: manifest, stage: message)
                                        }
                                    }
                                }
                                let outcome = try builder.applyAndLaunch(forceRebuild: true)
                                continuation.resume(returning: outcome)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }

                    appModel.config.skippedAntigravityVersion = nil
                    appModel.savePreferencesOnly()
                    appModel.refreshRuntimeStatus()
                    appModel.refreshRunningInstances()
                    appModel.errorMessage = nil
                    appModel.bannerSuccessMessage = L10n.t(
                        zhHans: "已更新原版 Antigravity 至 \(manifest.version) 并重建启动副本",
                        zhHant: "已更新原版 Antigravity 至 \(manifest.version) 並重建啟動副本",
                        en: "Updated Antigravity to \(manifest.version) & rebuilt runtime copy",
                        ru: "Antigravity обновлён до \(manifest.version), копия пересобрана и запущена",
                        lang
                    )

                    self.cachedAvailableState = nil
                    self.state = .upToDate(
                        installedVersion: manifest.version,
                        checkedAt: Date(),
                        route: activeRoute
                    )

                    if currentConfig.enableMenuBarMonitor {
                        onLaunchComplete?()
                    }
                }
            } catch is CancellationError {
                self.state = self.cachedAvailableState ?? .idle
            } catch {
                appModel.refreshRuntimeStatus()
                appModel.refreshRunningInstances()
                self.state = .failed(message: error.localizedDescription, canRetry: true)
            }
        }
    }

    func cancelDownload() {
        updateTask?.cancel()
        updateTask = nil
        state = cachedAvailableState ?? .idle
    }

    func dismissFailure() {
        if case .failed = state {
            state = cachedAvailableState ?? .idle
        }
    }

    func revealManualInstallerInFinder() {
        if case .readyForManualInstall(_, let zipURL, _) = state {
            NSWorkspace.shared.activateFileViewerSelecting([zipURL])
        }
    }
}
