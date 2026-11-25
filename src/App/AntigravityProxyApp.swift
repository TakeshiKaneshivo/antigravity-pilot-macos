import AppKit
import Combine
import CryptoKit
import Darwin
import SwiftUI

@main
enum AppEntry {
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTestRunner.runAndExit()
        } else {
            AntigravityProxyApp.main()
        }
    }
}

struct AntigravityProxyApp: App {
    @NSApplicationDelegateAdaptor(BuilderAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Antigravity Pilot", id: "main") {
            MainWindowView(
                appModel: appDelegate.appModel,
                monitorStore: appDelegate.monitorStore,
                updateStore: appDelegate.updateStore,
                onHideToMenuBar: {
                    appDelegate.hideMainWindowToMenuBar()
                }
            )
            .onAppear {
                appDelegate.registerMainWindowIfNeeded()
            }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class BuilderAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appModel = AppModel()
    let monitorStore = MonitorStore()
    let updateStore = UpdateStore()
    private var statusBarController: StatusBarController?
    private weak var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.load()
        monitorStore.start()
        updateStore.startAutoCheckSchedule { [weak self] in
            self?.appModel.config ?? .defaultConfig
        }

        statusBarController = StatusBarController(
            appModel: appModel,
            monitorStore: monitorStore,
            updateStore: updateStore,
            onOpenMainWindow: { [weak self] in self?.showMainWindow() },
            onOpenUpdatePopover: { [weak self] in
                self?.showMainWindow()
                self?.updateStore.requestOpenUpdatePopover()
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        statusBarController?.updateVisibilityAndTitle()

        appModel.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.statusBarController?.updateVisibilityAndTitle()
                if !config.enableMenuBarMonitor {
                    NSApp.setActivationPolicy(.regular)
                }
            }
            .store(in: &cancellables)

        monitorStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.statusBarController?.updateVisibilityAndTitle()
                }
            }
            .store(in: &cancellables)

        registerMainWindowIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !appModel.config.enableMenuBarMonitor
    }

    private func findAndConfigureMainWindow() -> NSWindow? {
        if let existing = mainWindow {
            return existing
        }
        for window in NSApplication.shared.windows where !(window is NSPanel) {
            if window.className.contains("NSStatusBar") { continue }
            self.mainWindow = window
            window.delegate = self
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            return window
        }
        return nil
    }

    func registerMainWindowIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            _ = self?.findAndConfigureMainWindow()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if appModel.config.enableMenuBarMonitor {
            hideMainWindowToMenuBar()
            return false
        }
        return true
    }

    func hideMainWindowToMenuBar() {
        let window = findAndConfigureMainWindow()
        window?.orderOut(nil)
        monitorStore.setInteractiveVisible(statusBarController?.isPopoverShown == true)
        NSApp.setActivationPolicy(.accessory)
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        statusBarController?.closePopover()
        monitorStore.setInteractiveVisible(true)
        appModel.refreshRuntimeStatus()
        appModel.refreshRunningInstances()

        if let window = mainWindow ?? NSApplication.shared.windows.first(where: { !($0 is NSPanel) && !$0.className.contains("NSStatusBar") }) {
            mainWindow = window
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let appModel: AppModel
    private let monitorStore: MonitorStore
    private let updateStore: UpdateStore
    private let onOpenMainWindow: () -> Void
    private let onOpenUpdatePopover: () -> Void
    private let onQuit: () -> Void

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var contextMenu: NSMenu?

    var isPopoverShown: Bool {
        popover.isShown
    }

    init(
        appModel: AppModel,
        monitorStore: MonitorStore,
        updateStore: UpdateStore,
        onOpenMainWindow: @escaping () -> Void,
        onOpenUpdatePopover: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.monitorStore = monitorStore
        self.updateStore = updateStore
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenUpdatePopover = onOpenUpdatePopover
        self.onQuit = onQuit
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 344, height: 430)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                appModel: appModel,
                monitorStore: monitorStore,
                onOpenMainWindow: onOpenMainWindow,
                onClosePopover: { [weak self] in self?.closePopover() },
                onQuit: onQuit
            )
        )
    }

    func updateVisibilityAndTitle() {
        if !appModel.config.enableMenuBarMonitor {
            closePopover()
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            return
        }

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: "Antigravity Pilot")
                button.imagePosition = .imageLeading
                button.target = self
                button.action = #selector(handleStatusButtonClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            statusItem = item
        }

        guard let button = statusItem?.button else { return }
        if appModel.config.showMenuBarMetrics, let compact = monitorStore.compactMenuBarText {
            button.title = " \(compact)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else {
            button.title = ""
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }

        if event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            closePopover()
            showContextMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            appModel.refreshRunningInstances()
            monitorStore.setInteractiveVisible(true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let lang = appModel.config.appLanguage
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: L10n.t("打开主窗口...", "Open Main Window...", lang),
            action: #selector(menuOpenMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let launchItem = NSMenuItem(
            title: L10n.t("启动 Antigravity Pilot", "Launch Antigravity Pilot", lang),
            action: #selector(menuLaunchRuntime),
            keyEquivalent: ""
        )
        launchItem.target = self
        menu.addItem(launchItem)

        let refreshItem = NSMenuItem(
            title: L10n.t("立即刷新监控与代理状态", "Refresh Monitor & Proxy Now", lang),
            action: #selector(menuRefreshAll),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let updateTitle: String = {
            if let ver = updateStore.availableVersionBadgeText(skippedVersion: appModel.config.skippedUpdateVersion) {
                return L10n.t(
                    zhHans: "发现新版本 v\(ver)...",
                    zhHant: "發現新版本 v\(ver)...",
                    en: "Update Available: v\(ver)...",
                    ru: "Доступно обновление v\(ver)...",
                    lang
                )
            }
            return L10n.t("检查更新...", "Check for Updates...", lang)
        }()
        let updateItem = NSMenuItem(
            title: updateTitle,
            action: #selector(menuCheckForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.t("退出 Antigravity Pilot", "Quit Antigravity Pilot", lang),
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        self.contextMenu = menu
        menu.delegate = self
        statusItem?.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        if statusItem?.menu === menu {
            statusItem?.menu = nil
        }
    }

    @objc private func menuOpenMainWindow() {
        onOpenMainWindow()
    }

    @objc private func menuLaunchRuntime() {
        appModel.launchExistingRuntimeOnly()
    }

    @objc private func menuRefreshAll() {
        appModel.checkProxyHealth()
        monitorStore.refreshAll(forceHistory: true)
    }

    @objc private func menuCheckForUpdates() {
        onOpenUpdatePopover()
    }

    @objc private func menuQuit() {
        onQuit()
    }

    func popoverDidClose(_ notification: Notification) {
        let hasVisibleMain = NSApplication.shared.windows.contains { !($0 is NSPanel) && !$0.className.contains("NSStatusBar") && $0.isVisible }
        if !hasVisibleMain {
            monitorStore.setInteractiveVisible(false)
        }
    }
}

enum SmokeTestRunner {
    private final class FailureFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false

        func record(_ cond: Bool, _ msg: String) {
            if !cond {
                fputs("[FAIL] \(msg)\n", stderr)
                lock.lock()
                failed = true
                lock.unlock()
            } else {
                print("[PASS] \(msg)")
            }
        }

        var hasFailed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failed
        }
    }

    static func runAndExit() -> Never {
        let tracker = FailureFlag()
        let check: @Sendable (Bool, String) -> Void = { cond, msg in
            tracker.record(cond, msg)
        }

        // 1. Entitlements extraction & merge
        let sourceApp = URL(fileURLWithPath: "/Applications/Antigravity.app")
        if FileManager.default.fileExists(atPath: sourceApp.path) {
            let entData = RuntimeBuilder.buildMergedEntitlementsData(fromSourceApp: sourceApp)
            let xml = String(data: entData, encoding: .utf8) ?? ""
            check(xml.contains("com.apple.security.cs.allow-dyld-environment-variables"), "Dynamic entitlements contain allow-dyld-environment-variables")
            check(xml.contains("com.apple.security.cs.disable-library-validation"), "Dynamic entitlements contain disable-library-validation")
        } else {
            print("[SKIP] /Applications/Antigravity.app not present for entitlements check")
        }

        // 2. ProxyHealthService 3-stage test (unreachable + HTTP mock + SOCKS5 mock)
        let unreachableReport = ProxyHealthService.probeSync(host: "127.0.0.1", hookPort: 59997, envPort: 59997, includeInternetCheck: false)
        check(!unreachableReport.tcpReachable && unreachableReport.level == .failed, "ProxyHealthService detects unreachable port")

        if let httpPort = spawnMockListener(response: Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)) {
            let httpReport = ProxyHealthService.probeSync(host: "127.0.0.1", hookPort: Int(httpPort), envPort: Int(httpPort), includeInternetCheck: false)
            check(httpReport.tcpReachable && !httpReport.socks5HandshakeOK && httpReport.level == .degraded, "ProxyHealthService rejects non-SOCKS5 HTTP port")
        }

        if let socksPort = spawnMockListener(response: [0x05, 0x00]) {
            let socksReport = ProxyHealthService.probeSync(host: "127.0.0.1", hookPort: Int(socksPort), envPort: Int(socksPort), includeInternetCheck: false)
            check(socksReport.tcpReachable && socksReport.socks5HandshakeOK && socksReport.level == .healthy, "ProxyHealthService accepts valid SOCKS5 greeting")
        }

        // 3. TranscriptScanner incremental scan into temp cache
        let tempCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("ag-proxy-smoke-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempCache) }

        let t0 = DispatchTime.now().uptimeNanoseconds
        let hist1 = TranscriptScanner.scan(cacheURL: tempCache)
        let coldMs = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)

        let t1 = DispatchTime.now().uptimeNanoseconds
        let hist2 = TranscriptScanner.scan(cacheURL: tempCache)
        let warmMs = Int((DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)

        check(hist1.scannedFilesCount == hist2.scannedFilesCount, "TranscriptScanner cold/warm file count consistent (\(hist1.scannedFilesCount) files, cold=\(coldMs)ms, warm=\(warmMs)ms)")
        check((hist1.totalsByPeriod[.all]?.requestCount ?? 0) == (hist2.totalsByPeriod[.all]?.requestCount ?? 0), "TranscriptScanner cache preserves totals")

        // 4. Live LanguageServerClient RPC check (non-fatal if Antigravity isn't running)
        let sem = DispatchSemaphore(value: 0)
        Task {
            if let hub = LanguageServerClient.discoverLiveHub() {
                let client = LanguageServerClient()
                do {
                    let (profile, pools, labels) = try await client.fetchUserStatus(hub: hub)
                    let sessions = try await client.fetchSessions(hub: hub)
                    check(!pools.isEmpty, "LanguageServerClient decoded \(pools.count) quota pools (tier=\(profile?.tierName ?? "?"))")
                    if let first = sessions.first {
                        let ctx = try await client.fetchSessionContext(hub: hub, session: first, modelLabels: labels)
                        check(ctx != nil, "LanguageServerClient decoded active context (\(ctx?.activeContextTokens ?? 0) tokens, model=\(ctx?.modelDisplayName ?? "?"))")
                    }
                } catch {
                    check(false, "LanguageServerClient RPC failed: \(error.localizedDescription)")
                }
            } else {
                print("[SKIP] No live daemon/hub_*.json found")
            }
            sem.signal()
        }
        sem.wait()

        // 5. McpPluginInstaller isolated temp-dir install -> current -> uninstall check
        let tempPluginsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ag-pilot-plugins-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempPluginsRoot) }
        let tempSupport = AppSupport(pluginsRoot: tempPluginsRoot)
        let installer = McpPluginInstaller(support: tempSupport)
        if case .unavailable = installer.status(bundledVersion: "0.1.0") {
            print("[SKIP] Bundled MCP assets not present in current executable context")
        } else {
            do {
                check(installer.status(bundledVersion: "0.1.0") == .notInstalled, "McpPluginInstaller initial status is notInstalled")
                try installer.installOrUpdate(appVersion: "0.1.0")
                check(installer.status(bundledVersion: "0.1.0") == .installedCurrent(version: "0.1.0"), "McpPluginInstaller status becomes installedCurrent after install")
                let mcpConfigURL = tempSupport.mcpPluginDirectory.appendingPathComponent("mcp_config.json")
                let mcpConfigText = (try? String(contentsOf: mcpConfigURL, encoding: .utf8)) ?? ""
                check(!mcpConfigText.contains("${PLUGIN_ROOT}"), "mcp_config.json has no unexpanded PLUGIN_ROOT placeholder")
                if let mcpData = mcpConfigText.data(using: .utf8),
                   let mcpObj = try? JSONSerialization.jsonObject(with: mcpData) as? [String: Any],
                   let servers = mcpObj["mcpServers"] as? [String: Any],
                   let pilot = servers["pilot"] as? [String: Any],
                   let cmd = pilot["command"] as? String {
                    check(FileManager.default.isExecutableFile(atPath: cmd), "mcp_config.json command points to an executable file")
                    let args = (pilot["args"] as? [String]) ?? []
                    check(args.contains("--version") && args.contains("0.1.0"), "mcp_config.json passes --version 0.1.0")
                } else {
                    check(false, "mcp_config.json schema valid with mcpServers.pilot.command")
                }
                try installer.uninstall()
                check(installer.status(bundledVersion: "0.1.0") == .notInstalled, "McpPluginInstaller status returns to notInstalled after uninstall")
            } catch {
                check(false, "McpPluginInstaller smoke check failed: \(error.localizedDescription)")
            }
        }

        // 6. AppLanguage system preference resolution & 4-language lookup
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: ["zh-Hans-CN", "en-US"]) == .zhHans,
            "AppLanguage resolves zh-Hans-CN first to zhHans"
        )
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: ["zh-Hant-TW"]) == .zhHant,
            "AppLanguage resolves zh-Hant-TW to zhHant"
        )
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: ["zh-HK"]) == .zhHant,
            "AppLanguage resolves zh-HK to zhHant"
        )
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: ["ru-RU", "en-US"]) == .ru,
            "AppLanguage resolves ru-RU to ru"
        )
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: ["uk-UA", "ru-RU"]) == .ru,
            "AppLanguage skips unsupported language and resolves secondary ru-RU"
        )
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: ["ja-JP", "zh-Hans-CN", "en-US"]) == .zhHans,
            "AppLanguage skips unsupported language and resolves secondary zh-Hans-CN"
        )
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: ["ja-JP", "en-US", "zh-Hans-CN"]) == .en,
            "AppLanguage skips unsupported language and resolves secondary en-US"
        )
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: ["ja-JP", "ko-KR", "fr-FR"]) == .en,
            "AppLanguage falls back to English when no supported preferred language matches"
        )
        check(
            AppLanguage.resolveSystemLanguage(preferredLanguages: []) == .en,
            "AppLanguage falls back to English on empty preferredLanguages"
        )
        check(
            L10n.t("代理概览", "Proxy Overview", .zhHant) == "代理概覽"
                && L10n.t("代理概览", "Proxy Overview", .ru) == "Прокси",
            "L10n resolves zh-Hant and ru translations"
        )

        // 7. PilotIconCache must bake the icon at full size (regression: icon was drawn at half size)
        let redIcon = NSImage(size: NSSize(width: 44, height: 44), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let baked = PilotIconCache.baked(
            redIcon,
            key: "smoke-red",
            side: 44,
            cornerRadius: 10,
            shadowBlur: 6,
            shadowYOffset: 2,
            shadowAlpha: 0.14
        )
        if let bakedRep = baked.representations.first as? NSBitmapImageRep {
            func px(_ x: Int, _ y: Int) -> NSColor? {
                bakedRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            }
            let center = px(60, 60)
            let nearRightEdge = px(95, 60)
            let margin = px(6, 60)
            check(
                bakedRep.pixelsWide == 120
                    && (center?.alphaComponent ?? 0) > 0.95
                    && (center?.redComponent ?? 0) > 0.9
                    && (center?.greenComponent ?? 1) < 0.2,
                "PilotIconCache bakes icon opaque at center"
            )
            check(
                (nearRightEdge?.alphaComponent ?? 0) > 0.95,
                "PilotIconCache bakes icon at full size (not shrunk)"
            )
            check(
                (margin?.alphaComponent ?? 1) < 0.35,
                "PilotIconCache keeps margin area mostly transparent"
            )
        } else {
            check(false, "PilotIconCache returned a bitmap-backed image")
        }

        // 8. PricingCatalog empty custom rules & 200K per-request tiered pricing regression
        let emptyCustomCost = PricingCatalog.estimateCostUSD(
            model: "gemini-3.1-pro",
            inputTokens: 100_000,
            cacheReadTokens: 0,
            outputTokens: 0,
            dateKey: "2026-11-25",
            customRules: ["gemini-3.1-pro": []]
        )
        check(emptyCustomCost > 0, "PricingCatalog handles empty custom rule array without crashing")

        let tieredCost = PricingCatalog.estimateCostUSD(
            model: "gemini-3.1-pro",
            inputTokens: 500_000,
            cacheReadTokens: 0,
            outputTokens: 0,
            dateKey: "2026-11-25",
            promptTokensForTier: 50_000
        )
        check(abs(tieredCost - 1.0) < 0.0001, "PricingCatalog uses per-request tier (10x50K -> <=200K tier = $1.00, got \(tieredCost))")

        // 9. ProxyConfig host normalization & numeric IP validation
        var cfgLocal = ProxyConfig.defaultConfig
        cfgLocal.host = "localhost"
        var cfgV6 = ProxyConfig.defaultConfig
        cfgV6.host = "[::1]"
        check(
            cfgLocal.normalizedHost == "127.0.0.1"
                && cfgV6.normalizedHost == "::1"
                && cfgV6.hookProxyURL == "socks5://[::1]:7890"
                && cfgV6.displayHookHostPort == "[::1]:7890"
                && ProxyConfig.isValidNumericIP(cfgLocal.host)
                && ProxyConfig.isValidNumericIP(cfgV6.host)
                && !ProxyConfig.isValidNumericIP("example.com"),
            "ProxyConfig normalizes localhost/[::1] and rejects non-IP hostnames"
        )

        // 10. Protobuf3 omitted 0.0 quota fraction regression
        let zeroQuotaFrac = LanguageServerClient.effectiveRemainingFraction(
            fraction: nil,
            resetTimeISO: "2026-11-26T00:00:00Z",
            hasQuotaInfo: true
        )
        let missingQuotaFrac = LanguageServerClient.effectiveRemainingFraction(
            fraction: nil,
            resetTimeISO: nil,
            hasQuotaInfo: false
        )
        let zeroPool = LanguageServerClient.groupQuotaPools(
            items: [
                ModelQuotaItem(
                    id: "zero-model|Zero Model",
                    label: "Zero Model",
                    modelId: "zero-model",
                    remainingFraction: zeroQuotaFrac,
                    resetTime: Date().addingTimeInterval(3600),
                    resetTimeISO: "2026-11-26T00:00:00Z",
                    tagTitle: nil
                )
            ],
            lang: .en
        )
        check(
            zeroQuotaFrac == 0.0 && missingQuotaFrac == nil && zeroPool.count == 1 && zeroPool[0].remainingPercent == 0,
            "LanguageServerClient preserves 0% exhausted quota pools when Protobuf3 omits zero remainingFraction"
        )

        // 11. TranscriptScanner invalid UTF-8 byte tolerance regression
        let tempBrain = FileManager.default.temporaryDirectory
            .appendingPathComponent("ag-pilot-brain-\(UUID().uuidString)", isDirectory: true)
        let tempTranscriptCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("ag-pilot-utf8-cache-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: tempBrain)
            try? FileManager.default.removeItem(at: tempTranscriptCache)
        }
        let sessionLogDir = tempBrain.appendingPathComponent("sess-utf8/.system_generated/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionLogDir, withIntermediateDirectories: true)
        var transcriptBytes = Data("{\"type\":\"TOOL_OUTPUT\",\"text\":\"".utf8)
        transcriptBytes.append(contentsOf: [0xFF, 0xFE, 0x80])
        transcriptBytes.append(Data("\"}\n".utf8))
        transcriptBytes.append(Data("{\"step_index\":1,\"type\":\"PLANNER_RESPONSE\",\"created_at\":\"2026-11-25T10:00:00Z\",\"model\":\"gemini-4-neon\",\"input_tokens\":1000,\"cache_read_tokens\":2000,\"output_tokens\":500}\n".utf8))
        let transcriptFile = sessionLogDir.appendingPathComponent("transcript.jsonl")
        try? transcriptBytes.write(to: transcriptFile)
        let utf8Hist = TranscriptScanner.scan(brainDir: tempBrain, cacheURL: tempTranscriptCache, customPricingURL: nil)
        let utf8All = utf8Hist.totalsByPeriod[.all]
        check(
            utf8Hist.scannedFilesCount == 1 && utf8All?.requestCount == 1 && utf8All?.totalTokens == 3500,
            "TranscriptScanner tolerates invalid UTF-8 bytes in non-JSON lines without dropping file"
        )

        // 12. PricingCatalog mixed-case custom pricing key regression
        let tempPricingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ag-pilot-pricing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempPricingURL) }
        let customPricingJSON = "{\"Gemini-3.1-Pro\":[{\"inputPerMillion\":10.0,\"outputPerMillion\":20.0,\"cacheReadPerMillion\":1.0}]}"
        try? customPricingJSON.data(using: .utf8)?.write(to: tempPricingURL)
        let loadedCustomRules = PricingCatalog.loadCustomRules(from: tempPricingURL)
        let customCost = PricingCatalog.estimateCostUSD(
            model: "gemini-3.1-pro",
            inputTokens: 1_000_000,
            cacheReadTokens: 0,
            outputTokens: 0,
            dateKey: "2026-11-25",
            customRules: loadedCustomRules
        )
        check(abs(customCost - 10.0) < 0.0001, "PricingCatalog matches mixed-case custom_pricing.json keys (got \(customCost))")

        // 13. AppVersion SemVer comparison & macOS compatibility
        check(
            AppVersion("0.1.0")! < AppVersion("0.2.0")!
                && AppVersion("v0.2.0-beta.1")! < AppVersion("0.2.0")!
                && AppVersion("0.2.0-beta.2")! > AppVersion("0.2.0-beta.1")!
                && AppVersion("0.10.0")! > AppVersion("0.2.0")!
                && AppVersion("v0.1.0") == AppVersion("0.1.0")
                && AppVersion.currentOSMeets(minMacOS: "13.0")
                && !AppVersion.currentOSMeets(minMacOS: "99.0"),
            "AppVersion parses, compares SemVer/prerelease, and checks minMacOS"
        )

        // 14. UpdateManifest decoding, 4-language notes & security validation
        let samplePayload = Data("Antigravity-Pilot-DMG-Test-Payload-v0.2.0".utf8)
        let sampleSHA = SHA256.hash(data: samplePayload).map { String(format: "%02x", $0) }.joined()
        let manifestJSON = """
        {
          "version": "0.2.0",
          "tag": "v0.2.0",
          "minMacOS": "13.0",
          "dmg": {
            "fileName": "Antigravity-Pilot-v0.2.0.dmg",
            "url": "https://github.com/TakeshiKaneshivo/antigravity-pilot-macos/releases/download/v0.2.0/Antigravity-Pilot-v0.2.0.dmg",
            "sha256": "\(sampleSHA)",
            "size": \(samplePayload.count)
          },
          "releasePageUrl": "https://github.com/TakeshiKaneshivo/antigravity-pilot-macos/releases/tag/v0.2.0",
          "notes": {
            "zh-Hans": "中文更新日志",
            "en": "English release notes"
          }
        }
        """.data(using: .utf8)!
        if let decodedManifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestJSON) {
            var httpsValid = false
            do {
                try decodedManifest.validate(allowInsecureHTTP: false)
                httpsValid = true
            } catch {
                httpsValid = false
            }
            let noteFallback = decodedManifest.notes?.text(for: .ru) == "English release notes"
                && decodedManifest.notes?.text(for: .zhHans) == "中文更新日志"
            check(httpsValid && noteFallback, "UpdateManifest validates HTTPS/SHA256 and resolves localized notes fallback")
        } else {
            check(false, "UpdateManifest decodes valid JSON")
        }

        let insecureManifest = UpdateManifest(
            version: "0.2.0",
            tag: "v0.2.0",
            publishedAt: nil,
            minMacOS: "13.0",
            dmg: UpdateManifest.DMGAsset(
                fileName: "test.dmg",
                url: "http://example.com/test.dmg",
                sha256: sampleSHA,
                size: Int64(samplePayload.count)
            ),
            releasePageUrl: nil,
            notes: nil
        )
        var rejectedHTTP = false
        do {
            try insecureManifest.validate(allowInsecureHTTP: false)
        } catch {
            rejectedHTTP = true
        }
        check(rejectedHTTP, "UpdateManifest rejects non-HTTPS URLs in production mode")

        // 15. End-to-end loopback HTTP manifest fetch, streaming DMG download & SHA-256 verification
        let tempUpdatesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ag-pilot-updates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempUpdatesRoot) }

        if let httpServerPort = spawnMockUpdateServer(payload: samplePayload, sha256: sampleSHA) {
            let feedURL = URL(string: "http://127.0.0.1:\(httpServerPort)/latest.json")!
            let updateSem = DispatchSemaphore(value: 0)
            Task {
                do {
                    let (fetchedManifest, route) = try await AppUpdateService.fetchManifest(
                        config: ProxyConfig.defaultConfig,
                        currentVersion: "0.1.0",
                        feedOverride: feedURL,
                        allowInsecureHTTPOverride: true
                    )
                    check(fetchedManifest.version == "0.2.0" && route == .direct, "AppUpdateService fetches and validates manifest from loopback HTTP")

                    let (dmgURL, _) = try await AppUpdateService.downloadAndVerifyDMG(
                        manifest: fetchedManifest,
                        config: ProxyConfig.defaultConfig,
                        updatesDir: tempUpdatesRoot,
                        allowInsecureHTTP: true
                    ) { _, _, _ in }
                    let downloadedData = try Data(contentsOf: dmgURL)
                    check(downloadedData == samplePayload, "AppUpdateService streams DMG and verifies SHA-256")

                    let badManifest = UpdateManifest(
                        version: "0.2.1",
                        tag: "v0.2.1",
                        publishedAt: nil,
                        minMacOS: "13.0",
                        dmg: UpdateManifest.DMGAsset(
                            fileName: "bad.dmg",
                            url: "http://127.0.0.1:\(httpServerPort)/test.dmg",
                            sha256: String(repeating: "0", count: 64),
                            size: Int64(samplePayload.count)
                        ),
                        releasePageUrl: nil,
                        notes: nil
                    )
                    var rejectedBadHash = false
                    do {
                        _ = try await AppUpdateService.downloadAndVerifyDMG(
                            manifest: badManifest,
                            config: ProxyConfig.defaultConfig,
                            updatesDir: tempUpdatesRoot,
                            allowInsecureHTTP: true
                        ) { _, _, _ in }
                    } catch UpdateError.checksumMismatch {
                        rejectedBadHash = true
                    } catch {
                        rejectedBadHash = false
                    }
                    let badPartPath = tempUpdatesRoot.appendingPathComponent("v0.2.1/bad.dmg.part").path
                    check(rejectedBadHash && !FileManager.default.fileExists(atPath: badPartPath), "AppUpdateService rejects tampered SHA-256 and deletes .part file")
                } catch {
                    check(false, "AppUpdateService loopback E2E failed: \(error.localizedDescription)")
                }
                updateSem.signal()
            }
            updateSem.wait()
        } else {
            check(false, "Spawn loopback update HTTP server")
        }

        // 16. InstallEligibility path checks
        let writableApp = tempUpdatesRoot.appendingPathComponent("Antigravity Pilot.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: writableApp, withIntermediateDirectories: true)
        let eligible = AppUpdateService.checkInstallEligibility(bundleURL: writableApp, lang: .en)
        let nonApp = AppUpdateService.checkInstallEligibility(bundleURL: URL(fileURLWithPath: "/tmp/AntigravityProxyBuilder"), lang: .en)
        let translocated = AppUpdateService.checkInstallEligibility(bundleURL: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/Antigravity Pilot.app"), lang: .en)
        var eligibilityOK = false
        if case .inPlaceSupported = eligible,
           case .manualFallbackRequired = nonApp,
           case .manualFallbackRequired = translocated {
            eligibilityOK = true
        }
        check(eligibilityOK, "AppUpdateService.checkInstallEligibility distinguishes writable .app, non-.app, and AppTranslocation")

        exit(tracker.hasFailed ? 1 : 0)
    }

    private static func spawnMockListener(response: [UInt8]) -> UInt16? {
        let listenFd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenFd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOk = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0, Darwin.listen(listenFd, 1) == 0 else {
            close(listenFd)
            return nil
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(listenFd, sa, &len)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        DispatchQueue.global(qos: .userInitiated).async {
            let clientFd = Darwin.accept(listenFd, nil, nil)
            if clientFd >= 0 {
                var buf = [UInt8](repeating: 0, count: 64)
                _ = Darwin.recv(clientFd, &buf, buf.count, 0)
                _ = response.withUnsafeBytes { raw in
                    Darwin.send(clientFd, raw.baseAddress, response.count, 0)
                }
                close(clientFd)
            }
            close(listenFd)
        }
        return port
    }

    private static func spawnMockUpdateServer(payload: Data, sha256: String) -> UInt16? {
        let listenFd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenFd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOk = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0, Darwin.listen(listenFd, 8) == 0 else {
            close(listenFd)
            return nil
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(listenFd, sa, &len)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        let manifestText = """
        {
          "version": "0.2.0",
          "tag": "v0.2.0",
          "minMacOS": "13.0",
          "dmg": {
            "fileName": "test.dmg",
            "url": "http://127.0.0.1:\(port)/test.dmg",
            "sha256": "\(sha256)",
            "size": \(payload.count)
          }
        }
        """
        let manifestData = Data(manifestText.utf8)

        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<3 {
                let clientFd = Darwin.accept(listenFd, nil, nil)
                guard clientFd >= 0 else { break }
                var buf = [UInt8](repeating: 0, count: 2048)
                let n = Darwin.recv(clientFd, &buf, buf.count, 0)
                let reqText = n > 0 ? (String(bytes: buf[0..<n], encoding: .utf8) ?? "") : ""
                let body: Data
                let contentType: String
                if reqText.contains("GET /latest.json") {
                    body = manifestData
                    contentType = "application/json"
                } else {
                    body = payload
                    contentType = "application/octet-stream"
                }
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                _ = Data(header.utf8).withUnsafeBytes { raw in
                    Darwin.send(clientFd, raw.baseAddress, header.utf8.count, 0)
                }
                _ = body.withUnsafeBytes { raw in
                    Darwin.send(clientFd, raw.baseAddress, body.count, 0)
                }
                close(clientFd)
            }
            close(listenFd)
        }
        return port
    }
}
