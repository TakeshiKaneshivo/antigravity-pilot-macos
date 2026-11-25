import AppKit
import Combine
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
    private var statusBarController: StatusBarController?
    private weak var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.load()
        monitorStore.start()

        statusBarController = StatusBarController(
            appModel: appModel,
            monitorStore: monitorStore,
            onOpenMainWindow: { [weak self] in self?.showMainWindow() },
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

    func registerMainWindowIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in NSApplication.shared.windows where !(window is NSPanel) {
                if window.className.contains("NSStatusBar") { continue }
                self.mainWindow = window
                window.delegate = self
                window.styleMask.insert(.fullSizeContentView)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
                window.isReleasedWhenClosed = false
                break
            }
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
        registerMainWindowIfNeeded()
        mainWindow?.orderOut(nil)
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
    private let onOpenMainWindow: () -> Void
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
        onOpenMainWindow: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.monitorStore = monitorStore
        self.onOpenMainWindow = onOpenMainWindow
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
                && ProxyConfig.isValidNumericIP(cfgLocal.host)
                && ProxyConfig.isValidNumericIP(cfgV6.host)
                && !ProxyConfig.isValidNumericIP("example.com"),
            "ProxyConfig normalizes localhost/[::1] and rejects non-IP hostnames"
        )

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
}
