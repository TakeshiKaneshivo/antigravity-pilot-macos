import AppKit
import Combine
import CryptoKit
import Darwin
import SQLite3
import SwiftUI

@main
enum AppEntry {
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTestRunner.runAndExit()
        } else if CommandLine.arguments.contains("--notify-runtime-update") {
            SystemNotificationService.runHeadlessRuntimeUpdateNotificationAndExit(arguments: CommandLine.arguments)
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
                antigravityUpdateStore: appDelegate.antigravityUpdateStore,
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
    let antigravityUpdateStore = AntigravityUpdateStore()
    private let notificationService = SystemNotificationService.shared
    private var statusBarController: StatusBarController?
    private weak var mainWindow: NSWindow?
    private var mainWindowMouseDownMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.load()
        monitorStore.start()
        let appSupport = appModel.support
        notificationService.configure { [weak self] in
            self?.showMainWindow()
        }
        SystemNotificationService.writePIDFile(at: appSupport.pilotPIDURL)
        notificationService.startDarwinListener { [weak self] in
            guard let self else { return }
            self.appModel.refreshRuntimeStatus()
            self.notificationService.postRuntimeUpdateNeeded(language: self.appModel.config.appLanguage)
        }
        if FileManager.default.fileExists(atPath: appSupport.runtimeApp.path) {
            notificationService.requestAuthorizationIfNeeded()
        }
        if FileManager.default.fileExists(atPath: appSupport.externalProxyEnvURL.path),
           let currentPilotPath = RuntimeBuilder.currentPilotAppPath(),
           RuntimeBuilder.readEnvValue(key: "AG_PILOT_APP_PATH", from: appSupport.externalProxyEnvURL) != currentPilotPath {
            try? RuntimeBuilder.writeExternalProxyEnv(config: appModel.config, support: appSupport)
        }
        let bundleURL = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            if AppUpdateService.refreshBundleIconCacheIfChanged(bundleURL: bundleURL, support: appSupport) {
                await MainActor.run {
                    NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
                }
            }
        }
        updateStore.startAutoCheckSchedule { [weak self] in
            self?.appModel.config ?? .defaultConfig
        }
        antigravityUpdateStore.startAutoCheckSchedule { [weak self] in
            self?.appModel.config ?? .defaultConfig
        }
        let initialConfig = appModel.config
        let monitorRef = monitorStore
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let updated = await PricingSyncService.syncIfNeeded(config: initialConfig, support: appSupport)
            if updated {
                await MainActor.run {
                    monitorRef.refreshHistory()
                }
            }
        }

        statusBarController = StatusBarController(
            appModel: appModel,
            monitorStore: monitorStore,
            updateStore: updateStore,
            antigravityUpdateStore: antigravityUpdateStore,
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

    func applicationWillTerminate(_ notification: Notification) {
        notificationService.stopDarwinListener()
        SystemNotificationService.removePIDFileIfOwned(at: appModel.support.pilotPIDURL)
        if let monitor = mainWindowMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mainWindowMouseDownMonitor = nil
        }
    }

    private func findAndConfigureMainWindow() -> NSWindow? {
        if let existing = mainWindow {
            installMainWindowFocusDismissMonitorIfNeeded()
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
            installMainWindowFocusDismissMonitorIfNeeded()
            return window
        }
        return nil
    }

    private func installMainWindowFocusDismissMonitorIfNeeded() {
        guard mainWindowMouseDownMonitor == nil else { return }
        mainWindowMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window, window === self.mainWindow else {
                return event
            }

            let activeControl: NSView?
            if let textView = window.firstResponder as? NSTextView {
                activeControl = (textView.delegate as? NSView) ?? textView
            } else if let textField = window.firstResponder as? NSTextField {
                activeControl = textField
            } else {
                activeControl = nil
            }

            guard let activeControl else {
                return event
            }

            let localPoint = activeControl.convert(event.locationInWindow, from: nil)
            if activeControl.bounds.contains(localPoint) {
                return event
            }

            let hitView = window.contentView?.superview?.hitTest(event.locationInWindow)
                ?? window.contentView?.hitTest(event.locationInWindow)
            var cursor = hitView
            while let current = cursor {
                if let targetField = current as? NSTextField, targetField.isEditable, targetField.isEnabled {
                    return event
                }
                if let targetTextView = current as? NSTextView, targetTextView.isEditable {
                    return event
                }
                cursor = current.superview
            }

            window.makeFirstResponder(nil)
            return event
        }
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

        if let window = findAndConfigureMainWindow() ?? NSApplication.shared.windows.first(where: { !($0 is NSPanel) && !$0.className.contains("NSStatusBar") }) {
            mainWindow = window
            window.delegate = self
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    nonisolated private static let spinnerFrameCount = 16
    private static let spinnerFrameInterval: TimeInterval = 1.0 / 12.0
    nonisolated private static let spinnerImageSize = NSSize(width: 32, height: 18)
    private static var cachedBaseIcon: NSImage?
    private static var cachedSpinnerFrames: [NSImage]?

    private let appModel: AppModel
    private let monitorStore: MonitorStore
    private let updateStore: UpdateStore
    private let onOpenMainWindow: () -> Void
    private let onOpenUpdatePopover: () -> Void
    private let onQuit: () -> Void

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var contextMenu: NSMenu?
    nonisolated(unsafe) private var spinnerTimer: Timer?
    private var spinnerFrameIndex: Int = 0
    private var isShowingSpinner: Bool = false
    nonisolated(unsafe) private var pendingSingleClickWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var globalPopoverMonitor: Any?
    nonisolated(unsafe) private var localPopoverMonitor: Any?

    var isPopoverShown: Bool {
        popover.isShown
    }

    private var hasVisibleMainWindow: Bool {
        NSApplication.shared.windows.contains {
            !($0 is NSPanel) && !$0.className.contains("NSStatusBar") && $0.isVisible && !$0.isMiniaturized
        }
    }

    deinit {
        spinnerTimer?.invalidate()
        pendingSingleClickWorkItem?.cancel()
        if let global = globalPopoverMonitor {
            NSEvent.removeMonitor(global)
        }
        if let local = localPopoverMonitor {
            NSEvent.removeMonitor(local)
        }
    }

    init(
        appModel: AppModel,
        monitorStore: MonitorStore,
        updateStore: UpdateStore,
        antigravityUpdateStore: AntigravityUpdateStore,
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

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: MenuBarPopoverView(
                appModel: appModel,
                monitorStore: monitorStore,
                updateStore: updateStore,
                antigravityUpdateStore: antigravityUpdateStore,
                onOpenMainWindow: onOpenMainWindow,
                onOpenUpdatePopover: onOpenUpdatePopover,
                onClosePopover: { [weak self] in self?.closePopover() },
                onQuit: onQuit
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
    }

    func updateVisibilityAndTitle() {
        if !appModel.config.enableMenuBarMonitor {
            stopSpinnerTimer()
            isShowingSpinner = false
            cancelPendingSingleClick()
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
                button.image = Self.makeStatusBarImage()
                button.imagePosition = .imageLeading
                button.target = self
                button.action = #selector(handleStatusButtonClick(_:))
                button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            }
            statusItem = item
        }

        guard let button = statusItem?.button else { return }
        let config = appModel.config
        let isLive = monitorStore.liveHub != nil
        let runningCount = (isLive && config.showMenuBarRunningStatus) ? monitorStore.activeRunningSessionCount : 0
        let metricsText = isLive
            ? monitorStore.compactMetricsText(
                includeContext: config.showMenuBarContextUsage,
                includeQuota: config.showMenuBarQuotaPercent
            )
            : nil
        let shouldShowSpinner = runningCount > 0
        let targetTitle = isLive
            ? MonitorStore.formatMenuBarTitle(runningCount: runningCount, metricsText: metricsText)
            : ""

        if button.title != targetTitle {
            button.title = targetTitle
        }
        if !targetTitle.isEmpty {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        let targetTooltip = monitorStore.menuBarTooltip(lang: config.appLanguage)
        if button.toolTip != targetTooltip {
            button.toolTip = targetTooltip
        }

        if shouldShowSpinner {
            if !isShowingSpinner {
                isShowingSpinner = true
                spinnerFrameIndex = 0
                button.image = Self.spinnerStatusBarImage(frameIndex: 0)
            }
            startSpinnerTimerIfNeeded()
        } else {
            stopSpinnerTimer()
            if isShowingSpinner || button.image == nil {
                isShowingSpinner = false
                button.image = Self.makeStatusBarImage()
            }
        }
    }

    private static func makeStatusBarImage() -> NSImage? {
        if let cached = cachedBaseIcon {
            return cached
        }
        let image: NSImage?
        if let bundleImage = Bundle.main.image(forResource: NSImage.Name("menubar-icon")) {
            bundleImage.size = NSSize(width: 18, height: 18)
            bundleImage.isTemplate = true
            bundleImage.accessibilityDescription = "Antigravity Pilot"
            image = bundleImage
        } else {
            image = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: "Antigravity Pilot")
        }
        cachedBaseIcon = image
        return image
    }

    private static func spinnerStatusBarImage(frameIndex: Int) -> NSImage {
        if let frames = cachedSpinnerFrames, !frames.isEmpty {
            let normalized = ((frameIndex % frames.count) + frames.count) % frames.count
            return frames[normalized]
        }
        let base = makeStatusBarImage()
        let frames = (0..<spinnerFrameCount).map { idx in
            renderSpinnerStatusBarImage(baseImage: base, frameIndex: idx)
        }
        cachedSpinnerFrames = frames
        let normalized = ((frameIndex % frames.count) + frames.count) % frames.count
        return frames[normalized]
    }

    nonisolated static func renderSpinnerStatusBarImage(baseImage: NSImage?, frameIndex: Int) -> NSImage {
        let size = spinnerImageSize
        let out = NSImage(size: size)
        let normalized = ((frameIndex % spinnerFrameCount) + spinnerFrameCount) % spinnerFrameCount
        let startAngle = CGFloat.pi / 2 - CGFloat(normalized) * (2 * CGFloat.pi / CGFloat(spinnerFrameCount))
        let sweep = CGFloat(240.0 * .pi / 180.0)
        let center = CGPoint(x: 27.0, y: 9.0)
        let radius: CGFloat = 3.85

        for scale in [2, 3] {
            let pxW = Int(size.width) * scale
            let pxH = Int(size.height) * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pxW,
                pixelsHigh: pxH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
                continue
            }
            rep.size = size

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let cg = ctx.cgContext
            cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

            if let baseImage {
                baseImage.draw(
                    in: NSRect(x: 0, y: 0, width: 18, height: 18),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
            }

            cg.setLineWidth(1.15)
            cg.setStrokeColor(NSColor.black.withAlphaComponent(0.20).cgColor)
            cg.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * CGFloat.pi, clockwise: false)
            cg.strokePath()

            cg.setLineWidth(1.3)
            cg.setLineCap(.round)
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: startAngle - sweep,
                clockwise: true
            )
            cg.strokePath()

            NSGraphicsContext.restoreGraphicsState()
            out.addRepresentation(rep)
        }

        out.isTemplate = true
        out.accessibilityDescription = "Antigravity Pilot"
        return out
    }

    private func startSpinnerTimerIfNeeded() {
        guard spinnerTimer == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: Self.spinnerFrameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isShowingSpinner, let button = self.statusItem?.button else { return }
                self.spinnerFrameIndex = (self.spinnerFrameIndex + 1) % Self.spinnerFrameCount
                button.image = Self.spinnerStatusBarImage(frameIndex: self.spinnerFrameIndex)
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        spinnerTimer = timer
    }

    private func stopSpinnerTimer() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    private func cancelPendingSingleClick() {
        pendingSingleClickWorkItem?.cancel()
        pendingSingleClickWorkItem = nil
    }

    private func installPopoverDismissMonitors() {
        removePopoverDismissMonitors()

        globalPopoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }

        localPopoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }

            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.closePopover()
                    return nil
                }
                return event
            }

            if let popWin = self.popover.contentViewController?.view.window, event.window === popWin {
                return event
            }
            if let btnWin = self.statusItem?.button?.window, event.window === btnWin {
                return event
            }

            self.closePopover()
            return event
        }
    }

    private func removePopoverDismissMonitors() {
        if let global = globalPopoverMonitor {
            NSEvent.removeMonitor(global)
            globalPopoverMonitor = nil
        }
        if let local = localPopoverMonitor {
            NSEvent.removeMonitor(local)
            localPopoverMonitor = nil
        }
    }

    func closePopover() {
        cancelPendingSingleClick()
        removePopoverDismissMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }

        if event.type == .rightMouseUp
            || event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            cancelPendingSingleClick()
            closePopover()
            showContextMenu(from: sender)
            return
        }

        if event.clickCount >= 2 {
            cancelPendingSingleClick()
            closePopover()
            onOpenMainWindow()
            return
        }

        cancelPendingSingleClick()
        let delay = min(NSEvent.doubleClickInterval, 0.25)
        let workItem = DispatchWorkItem { [weak self, weak sender] in
            guard let self, let sender else { return }
            self.pendingSingleClickWorkItem = nil
            self.togglePopover(sender)
        }
        pendingSingleClickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            appModel.refreshRuntimeStatus()
            appModel.refreshRunningInstances()
            monitorStore.setInteractiveVisible(true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.orderFrontRegardless()
            if !hasVisibleMainWindow {
                NSApp.activate(ignoringOtherApps: true)
            }
            installPopoverDismissMonitors()
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
        monitorStore.refreshAll(forceHistory: true, forceLive: true)
    }

    @objc private func menuCheckForUpdates() {
        onOpenUpdatePopover()
    }

    @objc private func menuQuit() {
        onQuit()
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverDismissMonitors()
        if !hasVisibleMainWindow {
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
                    let (profile, pools, labels, catalog) = try await client.fetchUserStatus(hub: hub)
                    let sessions = try await client.fetchSessions(hub: hub)
                    check(!pools.isEmpty, "LanguageServerClient decoded \(pools.count) quota pools (tier=\(profile?.tierName ?? "?"))")
                    if let first = sessions.first {
                        let ctx = try await client.fetchSessionContext(hub: hub, session: first, modelLabels: labels, modelCatalog: catalog)
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
                let logoURL = tempSupport.mcpPluginDirectory.appendingPathComponent("assets/logo.png")
                try Data("stale-logo".utf8).write(to: logoURL)
                check(
                    installer.status(bundledVersion: "0.1.0") == .updateAvailable(installedVersion: "0.1.0", bundledVersion: "0.1.0"),
                    "McpPluginInstaller detects changed logo.png as updateAvailable"
                )
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

        // 17. AntigravityUpdateService YAML parser, arch filtering, validation & app-update.yml feed resolution
        let validSHA512 = Data(repeating: 0xAB, count: 64).base64EncodedString()
        let armYAML = """
        version: 2.36.0
        files:
          - url: https://storage.googleapis.com/antigravity-public/antigravity-hub/2.36.0/darwin-arm/Antigravity.zip
            sha512: \(validSHA512)
            size: 216133032
        path: Antigravity.zip
        sha512: \(validSHA512)
        """
        let relYAML = """
        version: '2.36.1'
        files:
          - url: darwin-x64/Antigravity.zip
            sha512: '\(validSHA512)'
            size: 224099686
        """
        let badSHAYAML = """
        version: 2.36.0
        files:
          - url: https://example.com/Antigravity.zip
            sha512: invalid-sha512
        """
        let httpYAML = """
        version: 2.36.0
        files:
          - url: http://example.com/Antigravity.zip
            sha512: \(validSHA512)
        """
        let feedBase = URL(string: "https://example.com/manifest/")!
        let parsedArm = try? AntigravityUpdateService.parseElectronUpdaterYAML(armYAML, baseURL: feedBase, isArm64: true)
        let parsedRel = try? AntigravityUpdateService.parseElectronUpdaterYAML(relYAML, baseURL: feedBase, isArm64: false)
        var rejectedBadSHA = false
        do {
            _ = try AntigravityUpdateService.parseElectronUpdaterYAML(badSHAYAML, baseURL: feedBase, isArm64: true)
        } catch {
            rejectedBadSHA = true
        }
        var rejectedHTTPYAML = false
        do {
            _ = try AntigravityUpdateService.parseElectronUpdaterYAML(httpYAML, baseURL: feedBase, isArm64: true, allowInsecureHTTP: false)
        } catch {
            rejectedHTTPYAML = true
        }
        let tempFeedApp = tempUpdatesRoot.appendingPathComponent("FeedSource.app", isDirectory: true)
        let tempFeedRes = tempFeedApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempFeedRes, withIntermediateDirectories: true)
        try? "provider: generic\nurl: https://custom.example.com/manifest\n".write(
            to: tempFeedRes.appendingPathComponent("app-update.yml"),
            atomically: true,
            encoding: .utf8
        )
        let resolvedCustomFeed = AntigravityUpdateService.readFeedBaseURL(from: tempFeedApp)
        let fallbackFeed = AntigravityUpdateService.readFeedBaseURL(from: tempUpdatesRoot.appendingPathComponent("Missing.app"))

        let minimalUpToDateYAML = "version: 2.35.2\n"
        let checkUpToDate = try? AntigravityUpdateService.parseFeedCheckYAML(
            minimalUpToDateYAML,
            installedVersion: "2.35.2",
            baseURL: feedBase,
            isArm64: true
        )
        var rejectedMinimalUpgrade = false
        do {
            _ = try AntigravityUpdateService.parseFeedCheckYAML(
                minimalUpToDateYAML,
                installedVersion: "2.35.1",
                baseURL: feedBase,
                isArm64: true
            )
        } catch {
            rejectedMinimalUpgrade = true
        }
        let checkFullUpgrade = try? AntigravityUpdateService.parseFeedCheckYAML(
            armYAML,
            installedVersion: "2.35.2",
            baseURL: feedBase,
            isArm64: true
        )
        var fullUpgradeOK = false
        if case .updateAvailable(let m) = checkFullUpgrade, m.version == "2.36.0" {
            fullUpgradeOK = true
        }

        check(
            parsedArm?.version == "2.36.0"
                && parsedArm?.size == 216133032
                && parsedRel?.downloadURL == "https://example.com/manifest/darwin-x64/Antigravity.zip"
                && rejectedBadSHA
                && rejectedHTTPYAML
                && resolvedCustomFeed.absoluteString == "https://custom.example.com/manifest/"
                && fallbackFeed == AntigravityUpdateService.defaultFeedBaseURL
                && checkUpToDate == .upToDate(remoteVersion: "2.35.2")
                && rejectedMinimalUpgrade
                && fullUpgradeOK,
            "AntigravityUpdateService parses YAML, handles minimal up-to-date feed, validates SHA-512/HTTPS, and resolves app-update.yml"
        )

        // 18. AntigravityUpdateService loopback E2E manifest fetch, streaming SHA-512 zip download, cache hit & tamper rejection
        let agZipPayload = Data("Mock-Antigravity-Archive-Payload-2.36.0".utf8)
        let agSHA512 = Data(SHA512.hash(data: agZipPayload)).base64EncodedString()
        let agUpdatesDir = tempUpdatesRoot.appendingPathComponent("ag-updates", isDirectory: true)
        if let agPort = spawnMockAntigravityServer(payload: agZipPayload, sha512Base64: agSHA512) {
            let agFeedURL = URL(string: "http://127.0.0.1:\(agPort)/latest-arm64-mac.yml")!
            let agSem = DispatchSemaphore(value: 0)
            Task {
                do {
                    let (feedResult, route) = try await AntigravityUpdateService.fetchManifest(
                        sourceApp: tempFeedApp,
                        installedVersion: "2.35.2",
                        config: ProxyConfig.defaultConfig,
                        feedOverride: agFeedURL,
                        allowInsecureHTTPOverride: true,
                        isArm64: true
                    )
                    guard case .updateAvailable(let manifest) = feedResult else {
                        check(false, "AntigravityUpdateService expected updateAvailable over loopback HTTP")
                        agSem.signal()
                        return
                    }
                    check(manifest.version == "2.36.0" && route == .direct, "AntigravityUpdateService fetches & parses YAML over loopback HTTP")

                    let (zip1, _) = try await AntigravityUpdateService.downloadAndVerifyZip(
                        manifest: manifest,
                        config: ProxyConfig.defaultConfig,
                        updatesDir: agUpdatesDir,
                        sharedPendingZipURL: nil,
                        allowInsecureHTTP: true
                    ) { _, _, _ in }
                    let (zip2, _) = try await AntigravityUpdateService.downloadAndVerifyZip(
                        manifest: manifest,
                        config: ProxyConfig.defaultConfig,
                        updatesDir: agUpdatesDir,
                        sharedPendingZipURL: nil,
                        allowInsecureHTTP: true
                    ) { _, _, _ in }
                    let z1Data = try? Data(contentsOf: zip1)
                    check(zip1 == zip2 && z1Data == agZipPayload, "AntigravityUpdateService verifies SHA-512 zip download and reuses verified cache")

                    let badManifest = AntigravityUpdateManifest(
                        version: "2.36.1",
                        downloadURL: "http://127.0.0.1:\(agPort)/Antigravity.zip",
                        fileName: "Antigravity.zip",
                        sha512Base64: Data(repeating: 0x00, count: 64).base64EncodedString(),
                        size: Int64(agZipPayload.count),
                        releaseDate: nil
                    )
                    var rejectedTampered = false
                    do {
                        _ = try await AntigravityUpdateService.downloadAndVerifyZip(
                            manifest: badManifest,
                            config: ProxyConfig.defaultConfig,
                            updatesDir: agUpdatesDir,
                            sharedPendingZipURL: nil,
                            allowInsecureHTTP: true
                        ) { _, _, _ in }
                    } catch AntigravityUpdateError.checksumMismatch {
                        rejectedTampered = true
                    } catch {
                        rejectedTampered = false
                    }
                    let badPart = agUpdatesDir.appendingPathComponent("v2.36.1/Antigravity.zip.part").path
                    check(rejectedTampered && !FileManager.default.fileExists(atPath: badPart), "AntigravityUpdateService rejects tampered SHA-512 and deletes .part file")
                } catch {
                    check(false, "AntigravityUpdateService loopback E2E failed: \(error.localizedDescription)")
                }
                agSem.signal()
            }
            agSem.wait()
        } else {
            check(false, "Spawn loopback Antigravity mock server")
        }

        // 19. AntigravityUpdateService ditto extraction, Info.plist check & atomic replacement
        let mockZipRoot = tempUpdatesRoot.appendingPathComponent("mock-zip-src", isDirectory: true)
        let mockAppBundle = mockZipRoot.appendingPathComponent("Antigravity.app", isDirectory: true)
        let mockAppContents = mockAppBundle.appendingPathComponent("Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: mockAppContents, withIntermediateDirectories: true)
        let newPlist: [String: Any] = [
            "CFBundleIdentifier": "com.google.antigravity",
            "CFBundleShortVersionString": "2.99.0",
            "CFBundleVersion": "2.99.0"
        ]
        if let newPlistData = try? PropertyListSerialization.data(fromPropertyList: newPlist, format: .xml, options: 0) {
            try? newPlistData.write(to: mockAppContents.appendingPathComponent("Info.plist"))
        }
        let mockArchiveURL = tempUpdatesRoot.appendingPathComponent("Antigravity-mock.zip")
        let dittoProc = Process()
        dittoProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProc.arguments = ["-ck", "--keepParent", mockAppBundle.path, mockArchiveURL.path]
        try? dittoProc.run()
        dittoProc.waitUntilExit()

        let mockZipData = (try? Data(contentsOf: mockArchiveURL)) ?? Data()
        let mockManifest = AntigravityUpdateManifest(
            version: "2.99.0",
            downloadURL: "https://example.com/Antigravity.zip",
            fileName: "Antigravity.zip",
            sha512Base64: Data(SHA512.hash(data: mockZipData)).base64EncodedString(),
            size: Int64(mockZipData.count),
            releaseDate: nil
        )
        let extractStaging = tempUpdatesRoot.appendingPathComponent("extract-staging", isDirectory: true)
        let targetAppDir = tempUpdatesRoot.appendingPathComponent("Applications", isDirectory: true)
        let targetMockApp = targetAppDir.appendingPathComponent("Antigravity.app", isDirectory: true)
        let targetMockContents = targetMockApp.appendingPathComponent("Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetMockContents, withIntermediateDirectories: true)
        let oldPlist: [String: Any] = [
            "CFBundleIdentifier": "com.google.antigravity",
            "CFBundleShortVersionString": "2.35.0",
            "CFBundleVersion": "2.35.0"
        ]
        if let oldPlistData = try? PropertyListSerialization.data(fromPropertyList: oldPlist, format: .xml, options: 0) {
            try? oldPlistData.write(to: targetMockContents.appendingPathComponent("Info.plist"))
        }
        do {
            let stagedApp = try AntigravityUpdateService.extractAndVerifyApp(
                zipURL: mockArchiveURL,
                manifest: mockManifest,
                stagingRoot: extractStaging,
                requireOfficialSignature: false,
                lang: .en
            )
            try AntigravityUpdateService.atomicallyReplaceSourceApp(stagedApp: stagedApp, targetApp: targetMockApp, lang: .en)
            let replacedVer = RuntimeBuilder.readBundleShortVersion(at: targetMockApp.appendingPathComponent("Contents/Info.plist"))
            check(replacedVer == "2.99.0", "AntigravityUpdateService extracts zip with ditto and atomically replaces target app")
        } catch {
            check(false, "AntigravityUpdateService extract & atomic replace failed: \(error.localizedDescription)")
        }

        // 20. canFastHotUpdate rejects runtime copy with app-update.yml + real /Applications/Antigravity.app Google signature check
        let isolatedRoot = tempUpdatesRoot.appendingPathComponent("pilot-support", isDirectory: true)
        let isolatedSupport = AppSupport(sourceApp: targetMockApp, rootOverride: isolatedRoot)
        let mockRuntime = isolatedSupport.runtimeApp
        let mockRuntimeMacOS = mockRuntime.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let mockRuntimeRes = mockRuntime.appendingPathComponent("Contents/Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: mockRuntimeMacOS, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: mockRuntimeRes, withIntermediateDirectories: true)
        if let resPath = Bundle.main.resourcePath {
            let resBase = URL(fileURLWithPath: resPath, isDirectory: true)
            try? FileManager.default.copyItem(
                at: resBase.appendingPathComponent("AntigravityProxyLauncher"),
                to: mockRuntimeMacOS.appendingPathComponent("AntigravityProxyLauncher")
            )
            try? FileManager.default.copyItem(
                at: resBase.appendingPathComponent("libantigravity_proxy.dylib"),
                to: mockRuntimeRes.appendingPathComponent("libantigravity_proxy.dylib")
            )
        }
        try? "AG_SOURCE_VERSION=2.99.0\nAG_SOURCE_BUILD=2.99.0\n".write(
            to: mockRuntimeRes.appendingPathComponent("proxy.env"),
            atomically: true,
            encoding: .utf8
        )
        try? "provider: generic\n".write(
            to: mockRuntimeRes.appendingPathComponent("app-update.yml"),
            atomically: true,
            encoding: .utf8
        )
        let blockedByYML = !RuntimeBuilder.canFastHotUpdate(config: ProxyConfig.defaultConfig, support: isolatedSupport)
        let evalYML = RuntimeBuilder.evaluateHotUpdate(config: ProxyConfig.defaultConfig, support: isolatedSupport)
        let missingEval = RuntimeBuilder.evaluateHotUpdate(
            config: ProxyConfig.defaultConfig,
            support: AppSupport(
                sourceApp: tempUpdatesRoot.appendingPathComponent("MissingSource.app"),
                rootOverride: isolatedRoot
            )
        )
        let unbuiltEval = RuntimeBuilder.evaluateHotUpdate(
            config: ProxyConfig.defaultConfig,
            support: AppSupport(
                sourceApp: targetMockApp,
                rootOverride: tempUpdatesRoot.appendingPathComponent("empty-support", isDirectory: true)
            )
        )
        let allResults: [HotUpdateCheckResult] = [
            .hotUpdateReady, .missingSourceApp, .runtimeNotBuilt, .runtimeIncomplete,
            .proxyBinaryUpdated, .legacyUpdaterPresent, .sourceVersionChanged, .iconStyleChanged, .pilotIconUpdated, .signatureInvalid
        ]
        let allStringsValid = allResults.allSatisfy { item in
            AppLanguage.allCases.filter { $0 != .system }.allSatisfy { lang in
                !item.pillTitle(lang).isEmpty && !item.detailReason(lang).isEmpty
            }
        }
        var googleSigOK = true
        if FileManager.default.fileExists(atPath: sourceApp.path) {
            let verifyProc = Process()
            verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verifyProc.arguments = [
                "--verify",
                "--deep",
                "--strict",
                "-R=\(AntigravityUpdateService.expectedCodeSignRequirement)",
                sourceApp.path
            ]
            verifyProc.standardOutput = FileHandle.nullDevice
            verifyProc.standardError = FileHandle.nullDevice
            try? verifyProc.run()
            verifyProc.waitUntilExit()
            googleSigOK = (verifyProc.terminationStatus == 0)
        }
        check(blockedByYML && evalYML == .legacyUpdaterPresent && googleSigOK, "canFastHotUpdate & evaluateHotUpdate flag app-update.yml & real Antigravity passes Google codesign -R")
        check(
            missingEval == .missingSourceApp && unbuiltEval == .runtimeNotBuilt && allStringsValid,
            "HotUpdateCheckResult distinguishes missingSourceApp/runtimeNotBuilt and provides 4-language descriptions"
        )

        if let resPath = Bundle.main.resourcePath,
           FileManager.default.fileExists(atPath: URL(fileURLWithPath: resPath).appendingPathComponent("antigravity-pilot.icns").path) {
            try? FileManager.default.removeItem(at: mockRuntimeRes.appendingPathComponent("app-update.yml"))
            let mockRuntimePlist: [String: Any] = [
                "CFBundleIdentifier": "com.google.antigravity.pilot.runtime",
                "CFBundleIconFile": "antigravity-pilot.icns"
            ]
            if let plistData = try? PropertyListSerialization.data(fromPropertyList: mockRuntimePlist, format: .xml, options: 0) {
                try? plistData.write(to: mockRuntime.appendingPathComponent("Contents/Info.plist"))
            }
            try? Data("stale-icns-bytes".utf8).write(to: mockRuntimeRes.appendingPathComponent("antigravity-pilot.icns"))
            let legacyDefaultEval = RuntimeBuilder.evaluateHotUpdate(config: ProxyConfig.defaultConfig, support: isolatedSupport)
            check(
                legacyDefaultEval == .pilotIconUpdated,
                "RuntimeBuilder.evaluateHotUpdate flags legacy runtime without AG_ICON_STYLE as pilotIconUpdated"
            )

            try? "AG_SOURCE_VERSION=2.99.0\nAG_SOURCE_BUILD=2.99.0\nAG_ICON_STYLE=originalWithBadge\nAG_ICON_SOURCE_SHA256=deadbeef\n".write(
                to: mockRuntimeRes.appendingPathComponent("proxy.env"),
                atomically: true,
                encoding: .utf8
            )
            let staleShaEval = RuntimeBuilder.evaluateHotUpdate(config: ProxyConfig.defaultConfig, support: isolatedSupport)
            check(
                staleShaEval == .pilotIconUpdated,
                "RuntimeBuilder.evaluateHotUpdate detects changed icon.png SHA-256 as pilotIconUpdated"
            )

            var pilotCatCfg = ProxyConfig.defaultConfig
            pilotCatCfg.runtimeIconStyle = .pilotCat
            let styleSwitchEval = RuntimeBuilder.evaluateHotUpdate(config: pilotCatCfg, support: isolatedSupport)
            check(
                styleSwitchEval == .iconStyleChanged,
                "RuntimeBuilder.evaluateHotUpdate detects switching runtimeIconStyle as iconStyleChanged"
            )

            let iconPNGURL = URL(fileURLWithPath: resPath).appendingPathComponent("icon.png")
            if let iconData = try? Data(contentsOf: iconPNGURL) {
                let iconSHA = SHA256.hash(data: iconData).map { String(format: "%02x", $0) }.joined()
                try? "AG_SOURCE_VERSION=2.99.0\nAG_SOURCE_BUILD=2.99.0\nAG_ICON_STYLE=originalWithBadge\nAG_ICON_SOURCE_SHA256=\(iconSHA)\n".write(
                    to: mockRuntimeRes.appendingPathComponent("proxy.env"),
                    atomically: true,
                    encoding: .utf8
                )
                let matchingShaEval = RuntimeBuilder.evaluateHotUpdate(config: ProxyConfig.defaultConfig, support: isolatedSupport)
                check(
                    matchingShaEval != .pilotIconUpdated && matchingShaEval != .iconStyleChanged,
                    "RuntimeBuilder.evaluateHotUpdate does not false-trigger icon rebuild when style & icon SHA match"
                )
            }

            if FileManager.default.fileExists(atPath: sourceApp.path) {
                let composedCG = RuntimeIconComposer.composeOriginalWithBadgeCGImage(
                    sourceApp: sourceApp,
                    pilotIconPNG: iconPNGURL
                )
                check(
                    composedCG?.width == 1024 && composedCG?.height == 1024,
                    "RuntimeIconComposer composes 1024x1024 original+cat badge icon"
                )

                if let badgedImg = RuntimeIconComposer.composeOriginalWithBadgeNSImage(sourceApp: sourceApp, pilotIconPNG: iconPNGURL),
                   let catImg = NSImage(contentsOf: iconPNGURL),
                   let origImg = NSImage(contentsOf: sourceApp.appendingPathComponent("Contents/Resources/icon.icns")) {
                    let bakedBadged = PilotIconCache.baked(badgedImg, key: "smoke-preview-badged", side: 44, cornerRadius: 10, shadowBlur: 6, shadowYOffset: 2, shadowAlpha: 0.14)
                    let bakedCat = PilotIconCache.baked(catImg, key: "smoke-preview-cat", side: 44, cornerRadius: 10, shadowBlur: 6, shadowYOffset: 2, shadowAlpha: 0.14)
                    let bakedOrig = PilotIconCache.baked(origImg, key: "smoke-preview-orig", side: 44, cornerRadius: 10, shadowBlur: 6, shadowYOffset: 2, shadowAlpha: 0.14)
                    let dBadged = (bakedBadged.representations.first as? NSBitmapImageRep)?.representation(using: .png, properties: [:])
                    let dCat = (bakedCat.representations.first as? NSBitmapImageRep)?.representation(using: .png, properties: [:])
                    let dOrig = (bakedOrig.representations.first as? NSBitmapImageRep)?.representation(using: .png, properties: [:])
                    check(
                        dBadged != nil && dCat != nil && dOrig != nil && dBadged != dCat && dCat != dOrig && dBadged != dOrig,
                        "PilotIconCache produces 3 distinct preview bitmaps for RuntimeIconStyle variants"
                    )
                }
            }
        }

        // 21. ProxyConfig legacy useOriginalIcon & runtimeIconStyle compatibility
        let legacyFalseJSON = Data(#"{"host":"127.0.0.1","hookPort":7890,"envScheme":"http","envPort":7890,"useOriginalIcon":false}"#.utf8)
        let legacyTrueJSON = Data(#"{"host":"127.0.0.1","hookPort":7890,"envScheme":"http","envPort":7890,"useOriginalIcon":true}"#.utf8)
        let decodedLegacyFalse = try? JSONDecoder().decode(ProxyConfig.self, from: legacyFalseJSON)
        let decodedLegacyTrue = try? JSONDecoder().decode(ProxyConfig.self, from: legacyTrueJSON)
        var encodedCatCfg = ProxyConfig.defaultConfig
        encodedCatCfg.runtimeIconStyle = .pilotCat
        let encodedCatData = try? JSONEncoder().encode(encodedCatCfg)
        let roundTripCat = encodedCatData.flatMap { try? JSONDecoder().decode(ProxyConfig.self, from: $0) }
        check(
            decodedLegacyFalse?.runtimeIconStyle == .originalWithBadge
                && decodedLegacyFalse?.useOriginalIcon == false
                && decodedLegacyTrue?.runtimeIconStyle == .original
                && decodedLegacyTrue?.useOriginalIcon == true
                && roundTripCat?.runtimeIconStyle == .pilotCat,
            "ProxyConfig migrates legacy useOriginalIcon and round-trips runtimeIconStyle"
        )

        // 22. Official dual-window quota pools, Proto3 zero-value omission & Pro argon-weekly split
        let nowDate = Date()
        let futureISO = ISO8601DateFormatter().string(from: nowDate.addingTimeInterval(3600 * 4))
        let futureWeekISO = ISO8601DateFormatter().string(from: nowDate.addingTimeInterval(3600 * 72))
        let pastISO = ISO8601DateFormatter().string(from: nowDate.addingTimeInterval(-60))
        let quotaSummaryJSON = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  { "bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.05, "resetTime": "\(futureWeekISO)" },
                  { "bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.86, "resetTime": "\(futureISO)" },
                  { "bucketId": "argon-weekly", "window": "weekly", "resetTime": "\(futureWeekISO)" },
                  { "bucketId": "stale-zero", "window": "5h", "resetTime": "\(pastISO)" }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!
        let parsedPools = LanguageServerClient.parseOfficialQuotaPools(data: quotaSummaryJSON, lang: .en, now: nowDate)
        let mainGeminiPool = parsedPools.first(where: { $0.title == "Gemini Models" })
        let argonSplitPool = parsedPools.first(where: { $0.title == "Gemini 4 Argon" })
        check(
            parsedPools.count == 2
                && mainGeminiPool?.buckets.count == 2
                && mainGeminiPool?.buckets.first?.windowKind == .fiveHour
                && mainGeminiPool?.remainingPercent == 5
                && argonSplitPool?.remainingPercent == 0,
            "LanguageServerClient parses 5h+weekly quota pools, Proto3 0% omission, and Pro argon-weekly split"
        )

        // 23. Dynamic GetAvailableModels maxTokens & placeholder resolution
        let modelsJSON = """
        {
          "response": {
            "models": {
              "claude-opus-5-5-high": {
                "displayName": "Claude Opus 5.5 (High)",
                "maxTokens": 1000000,
                "model": "MODEL_PLACEHOLDER_M402"
              }
            }
          }
        }
        """.data(using: .utf8)!
        let catalog = LanguageServerClient.parseAvailableModels(data: modelsJSON)
        let opusLimit = PricingCatalog.contextLimit(for: "MODEL_PLACEHOLDER_M402", modelCatalog: catalog)
        let pricingSrcWithCat = PricingCatalog.ResolvedPricingSource(
            customRules: [:],
            syncedEntries: [:],
            bundledEntries: [:],
            syncedPlaceholders: [:],
            bundledPlaceholders: [:],
            modelCatalog: catalog
        )
        let resolvedNorm = PricingCatalog.normalizeModelKey("MODEL_PLACEHOLDER_M402", source: pricingSrcWithCat)
        check(
            opusLimit == 1_000_000 && resolvedNorm == "claude-opus-5.5",
            "GetAvailableModels resolves 1M maxTokens for Claude Opus 5.5 and MODEL_PLACEHOLDER_M402"
        )

        // 24. 10-category tokenBreakdown & full step aggregation (harmonic TPS, compaction & anomaly)
        let gmJSON = """
        {
          "generatorMetadata": [
            {
              "chatModel": {
                "model": "MODEL_PLACEHOLDER_M402",
                "usage": { "inputTokens": "1000", "cacheReadTokens": "9000", "outputTokens": "200", "thinkingOutputTokens": "50" },
                "timeToFirstToken": "1.0s",
                "streamingDuration": "2.0s",
                "retryInfos": [{ "errorCode": 429, "errorMessage": "RESOURCE_EXHAUSTED: rate limit" }]
              }
            },
            {
              "chatModel": {
                "model": "",
                "promptSections": [{ "name": "Compaction Summary" }],
                "usage": { "inputTokens": "500", "cacheReadTokens": "0", "outputTokens": "100" },
                "timeToFirstToken": "9.0s",
                "streamingDuration": "10.0s"
              }
            },
            {
              "chatModel": {
                "model": "MODEL_PLACEHOLDER_M402",
                "usage": { "inputTokens": "2000", "cacheReadTokens": "18000", "outputTokens": "400" },
                "timeToFirstToken": "2.0s",
                "streamingDuration": "4.0s",
                "retryInfos": [{ "traceId": "ok-first-attempt" }],
                "chatStartMetadata": {
                  "contextWindowMetadata": {
                    "tokenBreakdown": {
                      "groups": [
                        { "name": "System Prompt", "type": "TOKEN_TYPE_SYSTEM_PROMPT", "numTokens": 5000, "children": [
                          { "name": "skills", "numTokens": 1200 },
                          { "name": "user_rules", "numTokens": 800 }
                        ]},
                        { "name": "Mcp Tools", "type": "TOKEN_TYPE_MCP_TOOLS", "numTokens": 500 },
                        { "name": "Tools", "type": "TOKEN_TYPE_TOOLS", "numTokens": 3000 },
                        { "name": "Chat Messages", "type": "TOKEN_TYPE_CHAT_MESSAGES", "numTokens": 8000, "children": [
                          { "name": "0: USER_INPUT", "numTokens": 1000 },
                          { "name": "1: PLANNER_RESPONSE", "numTokens": 1500 },
                          { "name": "2: GENERIC", "numTokens": 4500 },
                          { "name": "3: SYSTEM_MESSAGE", "numTokens": 600 },
                          { "name": "4: CHECKPOINT", "numTokens": 400 }
                        ]}
                      ]
                    }
                  }
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let dummySess = SessionSummary(id: "sess-1", title: "Test Session", stepCount: 3, lastModifiedTime: nowDate, status: "CASCADE_RUN_STATUS_IDLE", workspaceName: "antigravity-pilot-macos")
        let ctxSnap = LanguageServerClient.parseGeneratorMetadataResponse(
            data: gmJSON,
            session: dummySess,
            modelLabels: [:],
            modelCatalog: catalog,
            pricingSource: pricingSrcWithCat
        )
        let bdMap = Dictionary(uniqueKeysWithValues: (ctxSnap?.contextBreakdown ?? []).map { ($0.category, $0.tokens) })
        let harmonicTPSOK = abs((ctxSnap?.sessionAvgTokensPerSecond ?? 0) - 100.0) < 0.01 // (200+400)/(2+4) = 100, excluding compaction
        let avgTTFTOK = abs((ctxSnap?.sessionAvgTTFTSec ?? 0) - 1.5) < 0.01
        check(
            ctxSnap?.sessionStepCount == 3
                && ctxSnap?.anomalyStepCount == 1
                && ctxSnap?.recentSteps.first?.stepNumber == 3
                && ctxSnap?.recentSteps.first?.retryCount == 0
                && ctxSnap?.recentSteps.last?.anomalyKind == .rateLimit
                && ctxSnap?.recentSteps.last?.retryCount == 1
                && ctxSnap?.recentSteps[1].isCompactionStep == true
                && harmonicTPSOK && avgTTFTOK
                && bdMap[.skills] == 1200 && bdMap[.userRules] == 800 && bdMap[.systemPrompt] == 3000
                && bdMap[.mcpTools] == 500 && bdMap[.systemTools] == 3000
                && bdMap[.userMessages] == 1000 && bdMap[.assistantResponses] == 1500
                && bdMap[.toolResults] == 4500 && bdMap[.subagents] == 600 && bdMap[.compaction] == 400,
            "GeneratorMetadata parses 10-category breakdown, harmonic TPS, compaction & 429 anomalies"
        )

        // 25. Read-only SQLite LocalSessionIndexReader + .pbtxt fallback + Multi-source TranscriptScanner (Desktop + CLI)
        let tempUsageRoot = tempUpdatesRoot.appendingPathComponent("multi-usage", isDirectory: true)
        let desktopRoot = tempUsageRoot.appendingPathComponent("desktop", isDirectory: true)
        let cliRoot = tempUsageRoot.appendingPathComponent("cli", isDirectory: true)
        let desktopBrain = desktopRoot.appendingPathComponent("brain/11111111-1111-1111-1111-111111111111/.system_generated/logs", isDirectory: true)
        let cliBrain = cliRoot.appendingPathComponent("brain/22222222-2222-2222-2222-222222222222/.system_generated/logs", isDirectory: true)
        let cliAnn = cliRoot.appendingPathComponent("annotations", isDirectory: true)
        try? FileManager.default.createDirectory(at: desktopBrain, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cliBrain, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cliAnn, withIntermediateDirectories: true)

        let dbURL = desktopRoot.appendingPathComponent("conversation_summaries.db")
        var testDb: OpaquePointer?
        if sqlite3_open(dbURL.path, &testDb) == SQLITE_OK, let testDb {
            sqlite3_exec(testDb, "CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY, title text, workspace_uris text, parent_conversation_id text, nesting_depth integer, agent_name text);", nil, nil, nil)
            sqlite3_exec(testDb, "INSERT INTO conversation_summaries VALUES ('11111111-1111-1111-1111-111111111111', 'Pilot Refactor', '[\"file:///Users/dev/my-repo\"]', '', 0, '');", nil, nil, nil)
            sqlite3_close(testDb)
        }
        try? "title:\"CLI Task Title\"\n".write(to: cliAnn.appendingPathComponent("22222222-2222-2222-2222-222222222222.pbtxt"), atomically: true, encoding: .utf8)

        let todayStr = ISO8601DateFormatter().string(from: nowDate)
        let trLineDesktop = #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"\#(todayStr)","model":"gemini-4-neon","input_tokens":100000,"cache_read_tokens":900000,"output_tokens":10000}"# + "\n"
        let trLineCLI = #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"\#(todayStr)","model":"claude-opus-5-5-high","input_tokens":50000,"cache_read_tokens":50000,"output_tokens":5000}"# + "\n"
        try? trLineDesktop.write(to: desktopBrain.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        try? trLineCLI.write(to: cliBrain.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        // Also place a corrupt non-SQLite file in cliRoot to verify header check rejects safely
        try? Data("not-a-sqlite-file".utf8).write(to: cliRoot.appendingPathComponent("conversation_summaries.db"))

        let multiSnap = TranscriptScanner.scanMultiSource(
            roots: [
                TranscriptScanner.ArchiveRoot(brainDir: desktopRoot.appendingPathComponent("brain"), rootDir: desktopRoot, source: .desktop),
                TranscriptScanner.ArchiveRoot(brainDir: cliRoot.appendingPathComponent("brain"), rootDir: cliRoot, source: .cli)
            ],
            cacheURL: tempUsageRoot.appendingPathComponent("usage_cache_v4.json"),
            pricingSource: pricingSrcWithCat,
            liveSessions: []
        )
        let todayTot = multiSnap.totalsByPeriod[.today]
        let topProject = multiSnap.projectSummariesByPeriod[.today]?.first
        let cliSession = multiSnap.sessionSummariesByPeriod[.today]?.first(where: { $0.clientSource == .cli })
        check(
            multiSnap.desktopArchiveCount == 1
                && multiSnap.cliArchiveCount == 1
                && (todayTot?.cacheSavingsUSD ?? 0) > 2.5
                && topProject?.displayName == "my-repo"
                && cliSession?.title == "CLI Task Title",
            "LocalSessionIndexReader & TranscriptScanner merge Desktop+CLI archives, projects, sessions & cache savings"
        )

        // 26. PricingCatalog priority (custom > synced > bundled) & >200K tier preservation
        let pricingTestRoot = tempUpdatesRoot.appendingPathComponent("pricing-prio", isDirectory: true)
        let prioSupport = AppSupport(rootOverride: pricingTestRoot)
        try? prioSupport.ensureRoot()
        let syncedNoTiersJSON = """
        {
          "schemaVersion": 1,
          "catalogVersion": "2026.11.26.test",
          "pricing": {
            "gemini-3.1-pro": { "input": 2.00, "cache": 0.20, "output": 12.00 },
            "gpt-oss-120b": { "input": 0.80, "cache": 0.10, "output": 2.40 }
          }
        }
        """.data(using: .utf8)!
        try? syncedNoTiersJSON.write(to: prioSupport.syncedPricingCatalogURL)
        let customOverrideJSON = #"{"gpt-oss-120b":[{"inputPerMillion":9.0,"outputPerMillion":9.0,"cacheReadPerMillion":0.9}]}"#.data(using: .utf8)!
        try? customOverrideJSON.write(to: prioSupport.customPricingURL)

        let prioSrc = PricingCatalog.ResolvedPricingSource.load(
            customPricingURL: prioSupport.customPricingURL,
            syncedCatalogURL: prioSupport.syncedPricingCatalogURL,
            bundledCatalogURL: nil,
            modelCatalog: [:]
        )
        let customPrioCost = PricingCatalog.estimateCostAndSavingsUSD(
            model: "gpt-oss-120b",
            inputTokens: 1_000_000,
            cacheReadTokens: 0,
            outputTokens: 0,
            dateKey: "2026-11-26",
            source: prioSrc
        ).costUSD
        let over200kCost = PricingCatalog.estimateCostAndSavingsUSD(
            model: "gemini-3.1-pro",
            inputTokens: 250_000,
            cacheReadTokens: 0,
            outputTokens: 0,
            dateKey: "2026-11-26",
            source: prioSrc
        ).costUSD // Should preserve >200K tier ($4/M -> $1.00) rather than flat $2/M ($0.50)
        check(
            abs(customPrioCost - 9.0) < 0.001 && abs(over200kCost - 1.0) < 0.001,
            "PricingCatalog enforces custom > synced > built-in priority and preserves >200K tier rules"
        )

        // 27. PricingSyncService loopback HTTP sync & invalid JSON rejection
        if let pricingPort = spawnMockJSONServer(payload: syncedNoTiersJSON) {
            let syncRoot = tempUpdatesRoot.appendingPathComponent("pricing-sync-ok", isDirectory: true)
            let syncSupport = AppSupport(rootOverride: syncRoot)
            let syncSem = DispatchSemaphore(value: 0)
            Task.detached {
                let changed = await PricingSyncService.syncIfNeeded(
                    config: .defaultConfig,
                    support: syncSupport,
                    overrideURL: URL(string: "http://127.0.0.1:\(pricingPort)/pricing-catalog.json")!,
                    allowInsecureHTTPOverride: true,
                    force: true
                )
                let loaded = PricingCatalog.loadExternalCatalog(from: syncSupport.syncedPricingCatalogURL)
                let syncOK = changed && loaded?.catalogVersion == "2026.11.26.test"
                check(syncOK, "PricingSyncService fetches and validates pricing-catalog.json over loopback HTTP")
                syncSem.signal()
            }
            _ = syncSem.wait(timeout: .now() + 5)
        }
        if let badPort = spawnMockJSONServer(payload: Data(#"{"pricing":{"bad":{"input":-5,"cache":0,"output":1}}}"#.utf8)) {
            let badRoot = tempUpdatesRoot.appendingPathComponent("pricing-sync-bad", isDirectory: true)
            let badSupport = AppSupport(rootOverride: badRoot)
            let badSem = DispatchSemaphore(value: 0)
            Task.detached {
                let changed = await PricingSyncService.syncIfNeeded(
                    config: .defaultConfig,
                    support: badSupport,
                    overrideURL: URL(string: "http://127.0.0.1:\(badPort)/pricing-catalog.json")!,
                    allowInsecureHTTPOverride: true,
                    force: true
                )
                let rejectedBad = !changed && !FileManager.default.fileExists(atPath: badSupport.syncedPricingCatalogURL.path)
                check(rejectedBad, "PricingSyncService rejects negative/invalid pricing payloads safely")
                badSem.signal()
            }
            _ = badSem.wait(timeout: .now() + 5)
        }

        // 28. StoredSubscriptionTier inference & persistence
        let freeProfile = UserProfileInfo(name: "A", email: "a@example.com", tierName: "Google AI Free", tierId: "g1-free-tier")
        let ultraProfile = UserProfileInfo(name: "B", email: "b@example.com", tierName: "Google AI Ultra", tierId: "g1-ultra-tier")
        let tierURL = tempUpdatesRoot.appendingPathComponent("last_known_tier.json")
        if let st = ultraProfile.toStoredTier() {
            StoredSubscriptionTier.save(st, to: tierURL)
        }
        let loadedTier = StoredSubscriptionTier.load(from: tierURL)
        check(
            freeProfile.tierKind == .free && freeProfile.monthlyReferenceUSD == nil
                && ultraProfile.tierKind == .ultra && abs((loadedTier?.monthlyReferenceUSD ?? 0) - 249.99) < 0.01,
            "SubscriptionTierKind distinguishes Free vs Pro vs Ultra and persists StoredSubscriptionTier"
        )

        // 29. Dual-source quota reconciliation (GetUserStatus fresher fraction vs RetrieveUserQuotaSummary)
        let recNow = Date()
        let rec5hReset = recNow.addingTimeInterval(3600 * 3)
        let rec5hISO = ISO8601DateFormatter().string(from: rec5hReset)
        let rec5hNearDate = rec5hReset.addingTimeInterval(45) // within +-120s tolerance
        let rec5hNewWindowReset = recNow.addingTimeInterval(3600 * 5)
        let rec5hNewWindowISO = ISO8601DateFormatter().string(from: rec5hNewWindowReset)
        let recWeekReset = recNow.addingTimeInterval(3600 * 96)
        let recWeekISO = ISO8601DateFormatter().string(from: recWeekReset)

        let recSummarySameWindowJSON = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  { "bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.07, "resetTime": "\(rec5hISO)" },
                  { "bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.60, "resetTime": "\(recWeekISO)" }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!
        let recFresherModels = [
            ModelQuotaItem(
                id: "gemini-4-neon|Gemini 4 Neon",
                label: "Gemini 4 Neon",
                modelId: "gemini-4-neon",
                remainingFraction: 0.04,
                resetTime: rec5hNearDate,
                resetTimeISO: nil,
                tagTitle: nil
            )
        ]
        let recPoolsLower = LanguageServerClient.parseOfficialQuotaPools(
            data: recSummarySameWindowJSON,
            quotaItems: recFresherModels,
            lang: .en,
            now: recNow
        )
        let recLower5h = recPoolsLower.first?.buckets.first(where: { $0.windowKind == .fiveHour })
        let recLowerWk = recPoolsLower.first?.buckets.first(where: { $0.windowKind == .weekly })

        let recSummaryNewWindowJSON = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  { "bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1.0, "resetTime": "\(rec5hNewWindowISO)" }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!
        let recPoolsReset = LanguageServerClient.parseOfficialQuotaPools(
            data: recSummaryNewWindowJSON,
            quotaItems: recFresherModels,
            lang: .en,
            now: recNow
        )

        let recHigherModels = [
            ModelQuotaItem(
                id: "gemini-4-neon|Gemini 4 Neon",
                label: "Gemini 4 Neon",
                modelId: "gemini-4-neon",
                remainingFraction: 0.12,
                resetTime: rec5hNearDate,
                resetTimeISO: nil,
                tagTitle: nil
            )
        ]
        let recPoolsHigher = LanguageServerClient.parseOfficialQuotaPools(
            data: recSummarySameWindowJSON,
            quotaItems: recHigherModels,
            lang: .en,
            now: recNow
        )
        let recHigher5h = recPoolsHigher.first?.buckets.first(where: { $0.windowKind == .fiveHour })

        check(
            recLower5h?.remainingPercent == 4
                && recLowerWk?.remainingPercent == 60
                && recPoolsReset.first?.remainingPercent == 100
                && recHigher5h?.remainingPercent == 7,
            "LanguageServerClient reconciles fresher lower GetUserStatus 5h quota without touching weekly or post-reset windows"
        )

        // 30. 3-tier adaptive polling intervals & multi-hub activity selection
        let pollVisibleIdle = MonitorStore.pollingInterval(isInteractiveVisible: true, activeRunningSessionCount: 0)
        let pollHiddenRunning = MonitorStore.pollingInterval(isInteractiveVisible: false, activeRunningSessionCount: 1)
        let pollHiddenIdle = MonitorStore.pollingInterval(isInteractiveVisible: false, activeRunningSessionCount: 0)

        let hubOld = DaemonHubInfo(pid: 101, httpsPort: nil, httpPort: 5001, lsVersion: "1.0", csrfToken: "t1")
        let hubActive = DaemonHubInfo(pid: 102, httpsPort: nil, httpPort: 5002, lsVersion: "1.0", csrfToken: "t2")
        let hubPinned = DaemonHubInfo(pid: 103, httpsPort: nil, httpPort: 5003, lsVersion: "1.0", csrfToken: "t3")

        let candOld = LanguageServerClient.HubCandidateActivity(
            hub: hubOld,
            sessions: [SessionSummary(id: "s-old", title: "Old", stepCount: 1, lastModifiedTime: recNow.addingTimeInterval(-3600), status: "IDLE")]
        )
        let candActive = LanguageServerClient.HubCandidateActivity(
            hub: hubActive,
            sessions: [SessionSummary(id: "s-run", title: "Run", stepCount: 2, lastModifiedTime: recNow.addingTimeInterval(-10), status: "RUNNING")]
        )
        let candPinned = LanguageServerClient.HubCandidateActivity(
            hub: hubPinned,
            sessions: [SessionSummary(id: "s-pin", title: "Pin", stepCount: 3, lastModifiedTime: recNow.addingTimeInterval(-120), status: "IDLE")]
        )
        let bestActive = LanguageServerClient.selectBestHubCandidate([candOld, candActive, candPinned], preferredCascadeId: nil)
        let bestPinned = LanguageServerClient.selectBestHubCandidate([candOld, candActive, candPinned], preferredCascadeId: "s-pin")

        check(
            pollVisibleIdle == 5.0
                && pollHiddenRunning == 10.0
                && pollHiddenIdle == 30.0
                && bestActive?.hub.pid == 102
                && bestPinned?.hub.pid == 103,
            "MonitorStore adaptive polling (5s/10s/30s) & selectBestHubCandidate ranking behave as expected"
        )

        // 31. Menu bar metrics formatting & monochrome template arc spinner rendering
        check(
            MonitorStore.formatMenuBarTitle(runningCount: 0, metricsText: "18K · 47%") == " 18K · 47%"
                && MonitorStore.formatMenuBarTitle(runningCount: 1, metricsText: "18K · 47%") == " 18K · 47%"
                && MonitorStore.formatMenuBarTitle(runningCount: 2, metricsText: "117K · 46%") == "2 · 117K · 46%"
                && MonitorStore.formatMenuBarTitle(runningCount: 1, metricsText: nil) == ""
                && MonitorStore.formatMenuBarTitle(runningCount: 2, metricsText: nil) == "2"
                && MonitorStore.formatMenuBarTitle(runningCount: 0, metricsText: nil) == "",
            "MonitorStore.formatMenuBarTitle formats runningCount & metricsText across all states"
        )

        let spinFrame0 = StatusBarController.renderSpinnerStatusBarImage(baseImage: nil, frameIndex: 0)
        let spinFrame4 = StatusBarController.renderSpinnerStatusBarImage(baseImage: nil, frameIndex: 4)
        let reps0 = spinFrame0.representations.compactMap { $0 as? NSBitmapImageRep }
        let reps4 = spinFrame4.representations.compactMap { $0 as? NSBitmapImageRep }
        let has2xAnd3x0 = reps0.contains { $0.pixelsWide == 64 && $0.pixelsHigh == 36 }
            && reps0.contains { $0.pixelsWide == 96 && $0.pixelsHigh == 54 }
        let has2xAnd3x4 = reps4.contains { $0.pixelsWide == 64 && $0.pixelsHigh == 36 }
            && reps4.contains { $0.pixelsWide == 96 && $0.pixelsHigh == 54 }
        let tiff0 = reps0.first(where: { $0.pixelsWide == 64 })?.tiffRepresentation
        let tiff4 = reps4.first(where: { $0.pixelsWide == 64 })?.tiffRepresentation
        check(
            spinFrame0.isTemplate
                && spinFrame4.isTemplate
                && spinFrame0.size == NSSize(width: 32, height: 18)
                && spinFrame4.size == NSSize(width: 32, height: 18)
                && has2xAnd3x0
                && has2xAnd3x4
                && tiff0 != nil
                && tiff4 != nil
                && tiff0 != tiff4,
            "StatusBarController renders 2x/3x monochrome template arc spinner with rotating frames"
        )

        // 32. Granular menu bar display flags, legacy migration & filtered metrics formatting
        let defaultMenuCfg = ProxyConfig.defaultConfig
        check(
            defaultMenuCfg.showMenuBarRunningStatus
                && defaultMenuCfg.showMenuBarContextUsage
                && defaultMenuCfg.showMenuBarQuotaPercent
                && defaultMenuCfg.hasAnyMenuBarContent,
            "ProxyConfig defaults all 3 menu bar display options to enabled"
        )

        let legacyOffJSON = """
        {"host":"127.0.0.1","hookPort":7890,"envScheme":"http","envPort":7890,"showMenuBarMetrics":false}
        """
        let legacyDecoded = try? JSONDecoder().decode(ProxyConfig.self, from: Data(legacyOffJSON.utf8))
        check(
            legacyDecoded != nil
                && legacyDecoded?.showMenuBarRunningStatus == false
                && legacyDecoded?.showMenuBarContextUsage == false
                && legacyDecoded?.showMenuBarQuotaPercent == false
                && legacyDecoded?.hasAnyMenuBarContent == false,
            "ProxyConfig migrates legacy showMenuBarMetrics=false to all 3 granular flags"
        )

        var customMenuCfg = ProxyConfig.defaultConfig
        customMenuCfg.showMenuBarRunningStatus = false
        customMenuCfg.showMenuBarContextUsage = true
        customMenuCfg.showMenuBarQuotaPercent = false
        customMenuCfg.syncMenuBarMetricsMasterFlag()
        let encodedCustom = try? JSONEncoder().encode(customMenuCfg)
        let decodedCustom = encodedCustom.flatMap { try? JSONDecoder().decode(ProxyConfig.self, from: $0) }
        check(
            decodedCustom?.showMenuBarRunningStatus == false
                && decodedCustom?.showMenuBarContextUsage == true
                && decodedCustom?.showMenuBarQuotaPercent == false
                && decodedCustom?.showMenuBarMetrics == true,
            "ProxyConfig round-trips granular menu bar flags and syncs master flag"
        )

        check(
            MonitorStore.formatMetricsText(contextTokens: 18_400, quotaRemainingPercent: 47, includeContext: true, includeQuota: true) == "18K · 47%"
                && MonitorStore.formatMetricsText(contextTokens: 18_400, quotaRemainingPercent: 47, includeContext: true, includeQuota: false) == "18K"
                && MonitorStore.formatMetricsText(contextTokens: 18_400, quotaRemainingPercent: 47, includeContext: false, includeQuota: true) == "47%"
                && MonitorStore.formatMetricsText(contextTokens: 18_400, quotaRemainingPercent: 47, includeContext: false, includeQuota: false) == nil,
            "MonitorStore.formatMetricsText filters context and quota cleanly without stray separators"
        )

        // 33. Weekly 7d quota prefix & localized menu bar hover tooltip
        check(
            MonitorStore.formatMetricsText(contextTokens: 18_400, quotaRemainingPercent: 47, quotaWindowKind: .fiveHour, includeContext: true, includeQuota: true) == "18K · 47%"
                && MonitorStore.formatMetricsText(contextTokens: 18_400, quotaRemainingPercent: 47, quotaWindowKind: .weekly, includeContext: true, includeQuota: true) == "18K · 7d 47%"
                && MonitorStore.formatMetricsText(contextTokens: 18_400, quotaRemainingPercent: 47, quotaWindowKind: .weekly, includeContext: false, includeQuota: true) == "7d 47%",
            "MonitorStore.formatMetricsText prefixes 7d only when tightest window is weekly"
        )

        let tipWeeklyZh = MonitorStore.formatMenuBarTooltip(
            isLive: true,
            runningCount: 2,
            contextUsedText: "117.0K",
            contextLimitText: "1.00M",
            modelDisplayName: "Gemini 4",
            quotaTitle: "Gemini",
            quotaWindowKind: .weekly,
            quotaRemainingPercent: 46,
            quotaResetText: "3天 2小时后重置",
            lang: .zhHans
        )
        let tip5hEn = MonitorStore.formatMenuBarTooltip(
            isLive: true,
            runningCount: 1,
            contextUsedText: "18.4K",
            contextLimitText: "1.00M",
            modelDisplayName: "Claude",
            quotaTitle: "Claude",
            quotaWindowKind: .fiveHour,
            quotaRemainingPercent: 47,
            quotaResetText: "Resets in 2h 10m",
            lang: .en
        )
        let tipWaiting = MonitorStore.formatMenuBarTooltip(
            isLive: false,
            runningCount: 0,
            contextUsedText: nil,
            contextLimitText: nil,
            modelDisplayName: nil,
            quotaTitle: nil,
            quotaWindowKind: nil,
            quotaRemainingPercent: nil,
            quotaResetText: nil,
            lang: .zhHans
        )
        check(
            tipWeeklyZh.contains("每周 46%")
                && tipWeeklyZh.contains("运行中：2")
                && tip5hEn.contains("5h 47%")
                && tip5hEn.contains("Running: 1 active session")
                && tipWaiting.contains("等待 Antigravity 启动"),
            "MonitorStore.formatMenuBarTooltip formats localized 5h/weekly quota, running count, and waiting states"
        )

        // 34. Native runtime-update notification copy (3-line, no version numbers) & AG_PILOT_APP_PATH in proxy.env
        let concreteLangs: [AppLanguage] = [.zhHans, .zhHant, .en, .ru]
        let notifCopiesValid = concreteLangs.allSatisfy { lang in
            let copy = SystemNotificationService.runtimeUpdateCopy(for: lang)
            return copy.title == "Antigravity Pilot"
                && !copy.subtitle.isEmpty
                && !copy.body.isEmpty
                && !copy.subtitle.contains("→")
                && !copy.body.contains("→")
                && copy.subtitle.count <= 32
        }
        let tempEnvURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ag-pilot-env-test-\(UUID().uuidString).env")
        defer { try? FileManager.default.removeItem(at: tempEnvURL) }
        try? RuntimeBuilder.writeProxyEnv(
            config: ProxyConfig.defaultConfig,
            to: tempEnvURL,
            sourceVersion: "2.35.1",
            pilotAppPath: "/Applications/Antigravity Pilot.app"
        )
        let readPilotPath = RuntimeBuilder.readEnvValue(key: "AG_PILOT_APP_PATH", from: tempEnvURL)
        check(
            notifCopiesValid && readPilotPath == "/Applications/Antigravity Pilot.app",
            "SystemNotificationService provides concise 3-line 4-language copy without versions & writeProxyEnv persists AG_PILOT_APP_PATH"
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

    private static func spawnMockAntigravityServer(payload: Data, sha512Base64: String) -> UInt16? {
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

        let yamlText = """
        version: 2.36.0
        files:
          - url: http://127.0.0.1:\(port)/Antigravity.zip
            sha512: \(sha512Base64)
            size: \(payload.count)
        path: Antigravity.zip
        sha512: \(sha512Base64)
        """
        let yamlData = Data(yamlText.utf8)

        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<3 {
                let clientFd = Darwin.accept(listenFd, nil, nil)
                guard clientFd >= 0 else { break }
                var buf = [UInt8](repeating: 0, count: 2048)
                let n = Darwin.recv(clientFd, &buf, buf.count, 0)
                let reqText = n > 0 ? (String(bytes: buf[0..<n], encoding: .utf8) ?? "") : ""
                let body: Data
                let contentType: String
                if reqText.contains("GET /latest-arm64-mac.yml") {
                    body = yamlData
                    contentType = "text/yaml"
                } else {
                    body = payload
                    contentType = "application/zip"
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

    private static func spawnMockJSONServer(payload: Data) -> UInt16? {
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
        guard bindOk == 0, Darwin.listen(listenFd, 2) == 0 else {
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
                var buf = [UInt8](repeating: 0, count: 1024)
                _ = Darwin.recv(clientFd, &buf, buf.count, 0)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                _ = Data(header.utf8).withUnsafeBytes { raw in
                    Darwin.send(clientFd, raw.baseAddress, header.utf8.count, 0)
                }
                _ = payload.withUnsafeBytes { raw in
                    Darwin.send(clientFd, raw.baseAddress, payload.count, 0)
                }
                close(clientFd)
            }
            close(listenFd)
        }
        return port
    }
}
