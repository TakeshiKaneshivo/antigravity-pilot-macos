import AppKit
import Foundation
import notify
import UserNotifications

struct RuntimeUpdateNotificationCopy: Equatable, Sendable {
    let title: String
    let subtitle: String
    let body: String
}

@MainActor
final class SystemNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotificationService()

    nonisolated static let darwinRuntimeUpdateEventName = "com.takeshikaneshivo.antigravity-pilot.runtime-update-needed"
    nonisolated static let runtimeUpdateRequestID = "com.takeshikaneshivo.antigravity-pilot.runtime-update-needed"
    nonisolated static let darwinHookEventName = PilotHookProcessor.darwinHookEventName

    nonisolated static var isRunningInAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var onOpenMainWindow: (() -> Void)?
    private var onOpenMonitorTab: (() -> Void)?
    private var onWillFocusAntigravity: (() -> Void)?
    private var darwinNotifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var hookEventDarwinToken: Int32 = NOTIFY_TOKEN_INVALID
    private var recentNotificationDates: [String: Date] = [:]
    nonisolated private static let externalFocusLock = NSLock()
    nonisolated(unsafe) private static var suppressReopenUntilEpoch: Double = 0

    nonisolated static func resolveLanguage(rawCode: String?) -> AppLanguage {
        guard let raw = rawCode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return AppLanguage.system.resolved
        }
        if let exact = AppLanguage(rawValue: raw) {
            return exact.resolved
        }
        let lower = raw.lowercased()
        if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh_hant")
            || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh_tw")
            || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh_hk")
            || lower.hasPrefix("zh-mo") || lower.hasPrefix("zh_mo") {
            return .zhHant
        }
        if lower == "zh" || lower.hasPrefix("zh-") || lower.hasPrefix("zh_") {
            return .zhHans
        }
        if lower == "ru" || lower.hasPrefix("ru-") || lower.hasPrefix("ru_") {
            return .ru
        }
        if lower == "en" || lower.hasPrefix("en-") || lower.hasPrefix("en_") {
            return .en
        }
        return AppLanguage.system.resolved
    }

    nonisolated static func runtimeUpdateCopy(for lang: AppLanguage) -> RuntimeUpdateNotificationCopy {
        let resolved = lang.resolved
        switch resolved {
        case .zhHans:
            return RuntimeUpdateNotificationCopy(
                title: "Antigravity Pilot",
                subtitle: "原版 Antigravity 已更新",
                body: "点击打开 Antigravity Pilot 重建代理副本。"
            )
        case .zhHant:
            return RuntimeUpdateNotificationCopy(
                title: "Antigravity Pilot",
                subtitle: "原版 Antigravity 已更新",
                body: "點擊開啟 Antigravity Pilot 重建代理副本。"
            )
        case .ru:
            return RuntimeUpdateNotificationCopy(
                title: "Antigravity Pilot",
                subtitle: "Antigravity обновлён",
                body: "Нажмите, чтобы открыть Antigravity Pilot и пересобрать копию."
            )
        case .en, .system:
            return RuntimeUpdateNotificationCopy(
                title: "Antigravity Pilot",
                subtitle: "Original Antigravity updated",
                body: "Click to open Antigravity Pilot to rebuild the runtime copy."
            )
        }
    }

    nonisolated static func writePIDFile(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated static func removePIDFileIfOwned(at url: URL) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid == getpid() else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    func configure(
        onOpenMainWindow: @escaping () -> Void,
        onOpenMonitorTab: (() -> Void)? = nil,
        onWillFocusAntigravity: (() -> Void)? = nil
    ) {
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenMonitorTab = onOpenMonitorTab
        self.onWillFocusAntigravity = onWillFocusAntigravity
        if Self.isRunningInAppBundle {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    nonisolated static func markPendingExternalFocus(durationSeconds: TimeInterval = 1.5, now: Date = Date()) {
        externalFocusLock.lock()
        suppressReopenUntilEpoch = max(suppressReopenUntilEpoch, now.timeIntervalSince1970 + durationSeconds)
        externalFocusLock.unlock()
    }

    nonisolated static func isExternalFocusPending(now: Date = Date()) -> Bool {
        externalFocusLock.lock()
        let pending = now.timeIntervalSince1970 < suppressReopenUntilEpoch
        externalFocusLock.unlock()
        return pending
    }

    func startDarwinListener(onRuntimeUpdateNeeded: @escaping @MainActor () -> Void) {
        if darwinNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(darwinNotifyToken)
            darwinNotifyToken = NOTIFY_TOKEN_INVALID
        }
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(
            Self.darwinRuntimeUpdateEventName,
            &token,
            DispatchQueue.main
        ) { _ in
            Task { @MainActor in
                onRuntimeUpdateNeeded()
            }
        }
        if status == NOTIFY_STATUS_OK {
            darwinNotifyToken = token
        }
    }

    func startHookEventDarwinListener(onHookEvent: @escaping @MainActor () -> Void) {
        if hookEventDarwinToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(hookEventDarwinToken)
            hookEventDarwinToken = NOTIFY_TOKEN_INVALID
        }
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(
            Self.darwinHookEventName,
            &token,
            DispatchQueue.main
        ) { _ in
            Task { @MainActor in
                onHookEvent()
            }
        }
        if status == NOTIFY_STATUS_OK {
            hookEventDarwinToken = token
        }
    }

    func stopDarwinListener() {
        if darwinNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(darwinNotifyToken)
            darwinNotifyToken = NOTIFY_TOKEN_INVALID
        }
        if hookEventDarwinToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(hookEventDarwinToken)
            hookEventDarwinToken = NOTIFY_TOKEN_INVALID
        }
    }

    func requestAuthorizationIfNeeded() {
        guard Self.isRunningInAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func postRuntimeUpdateNeeded(
        language: AppLanguage,
        onAuthorizationPromptNeeded: (@Sendable () -> Void)? = nil,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard Self.isRunningInAppBundle else {
            completion?(false)
            return
        }

        let copy = Self.runtimeUpdateCopy(for: language)
        let center = UNUserNotificationCenter.current()

        let enqueueNotification: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.subtitle = copy.subtitle
            content.body = copy.body
            content.sound = .default
            content.userInfo = ["action": "openMainWindow"]

            let request = UNNotificationRequest(
                identifier: Self.runtimeUpdateRequestID,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                completion?(error == nil)
            }
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                enqueueNotification()
            case .notDetermined:
                onAuthorizationPromptNeeded?()
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        enqueueNotification()
                    } else {
                        completion?(false)
                    }
                }
            case .denied:
                completion?(false)
            @unknown default:
                completion?(false)
            }
        }
    }

    nonisolated static func isAntigravityMainBundle(bundleIdentifier: String?, bundlePath: String?) -> Bool {
        let bid = (bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = (bundlePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if bid == "com.takeshikaneshivo.antigravity-pilot.macos" || bid.contains(".helper") {
            return false
        }
        if path.contains("/Contents/Frameworks/") {
            return false
        }
        if bid == "com.google.antigravity.pilot.runtime"
            || bid == "com.google.antigravity.proxy.runtime"
            || bid == "com.google.antigravity" {
            return true
        }
        return path.hasSuffix("/Antigravity-Pilot.app")
            || path.hasSuffix("/Antigravity-Proxy.app")
            || path.hasSuffix("/Antigravity.app")
    }

    func isAntigravityFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        guard front.processIdentifier != selfPid else { return false }
        return Self.isAntigravityMainBundle(
            bundleIdentifier: front.bundleIdentifier,
            bundlePath: front.bundleURL?.standardizedFileURL.path
        )
    }

    private func focusAntigravityOrPilot() {
        Self.markPendingExternalFocus()
        onWillFocusAntigravity?()

        let selfPid = ProcessInfo.processInfo.processIdentifier
        let detected = RunningInstanceManager.detectRunningInstances().filter {
            !$0.app.isTerminated && $0.app.activationPolicy == .regular
        }
        let targetApp: NSRunningApplication? =
            detected.first(where: { $0.kind == .runtime })?.app
            ?? detected.first?.app
            ?? NSWorkspace.shared.runningApplications.first { app in
                guard app.processIdentifier != selfPid,
                      !app.isTerminated,
                      app.activationPolicy == .regular else {
                    return false
                }
                return Self.isAntigravityMainBundle(
                    bundleIdentifier: app.bundleIdentifier,
                    bundlePath: app.bundleURL?.standardizedFileURL.path
                )
            }

        guard let target = targetApp else {
            onOpenMainWindow?()
            return
        }

        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: target)
        }
        target.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        if let bundleURL = target.bundleURL {
            let openConfig = NSWorkspace.OpenConfiguration()
            openConfig.activates = true
            openConfig.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: openConfig) { _, _ in
                DispatchQueue.main.async {
                    target.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
            }
        }
    }

    private func shouldDeliver(dedupKey: String, cooldownSec: TimeInterval = 10.0, now: Date = Date()) -> Bool {
        recentNotificationDates = recentNotificationDates.filter { now.timeIntervalSince($0.value) < 300 }
        if let prev = recentNotificationDates[dedupKey], now.timeIntervalSince(prev) < cooldownSec {
            return false
        }
        recentNotificationDates[dedupKey] = now
        return true
    }

    private func postGenericNotification(
        identifier: String,
        title: String,
        subtitle: String?,
        body: String,
        action: String,
        requestPermissionIfNeeded: Bool = false,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard Self.isRunningInAppBundle else {
            completion?(false)
            return
        }
        let center = UNUserNotificationCenter.current()
        let enqueue: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle, !subtitle.isEmpty {
                content.subtitle = subtitle
            }
            content.body = body
            content.sound = .default
            content.userInfo = ["action": action]

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                completion?(error == nil)
            }
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                enqueue()
            case .notDetermined where requestPermissionIfNeeded:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        enqueue()
                    } else {
                        completion?(false)
                    }
                }
            default:
                completion?(false)
            }
        }
    }

    nonisolated static func taskFinishedDedupKey(conversationId: String, title: String?) -> String {
        let cidKey = conversationId.isEmpty ? (title ?? "default") : conversationId.lowercased()
        return "task_finished|\(cidKey)"
    }

    func postTaskFinished(
        conversationId: String,
        title: String?,
        workspaceName: String?,
        isError: Bool,
        errorDetail: String?,
        config: ProxyConfig
    ) {
        guard config.notifyOnTaskComplete else { return }
        if config.notifyOnlyWhenBackground && isAntigravityFrontmost() {
            return
        }
        let cidKey = conversationId.isEmpty ? (title ?? "default") : conversationId.lowercased()
        guard shouldDeliver(dedupKey: Self.taskFinishedDedupKey(conversationId: conversationId, title: title), cooldownSec: 10.0) else { return }

        let lang = config.appLanguage
        let notifTitle = isError
            ? L10n.t(zhHans: "任务异常中止", zhHant: "任務異常中止", en: "Task Stopped with Error", ru: "Задача прервана", lang)
            : L10n.t(zhHans: "任务已完成", zhHant: "任務已完成", en: "Task Completed", ru: "Задача завершена", lang)
        let wsPart = (workspaceName?.isEmpty == false) ? workspaceName! : nil
        let cleanTitle = (title?.isEmpty == false) ? title! : L10n.t(zhHans: "点击切回 Antigravity 查看结果", zhHant: "點擊切回 Antigravity 查看結果", en: "Click to focus Antigravity", ru: "Нажмите, чтобы вернуться в Antigravity", lang)
        let bodyText = (isError && errorDetail?.isEmpty == false) ? errorDetail! : cleanTitle

        postGenericNotification(
            identifier: "pilot.task.\(cidKey).\(Int(Date().timeIntervalSince1970))",
            title: notifTitle,
            subtitle: wsPart,
            body: bodyText,
            action: "focusAntigravity"
        )
    }

    func postApprovalNeeded(
        conversationId: String,
        title: String?,
        workspaceName: String?,
        detail: String?,
        config: ProxyConfig
    ) {
        guard config.notifyOnApprovalNeeded else { return }
        if config.notifyOnlyWhenBackground && isAntigravityFrontmost() {
            return
        }
        let cidKey = conversationId.isEmpty ? (title ?? "default") : conversationId.lowercased()
        guard shouldDeliver(dedupKey: "\(PilotHookEventKind.approvalNeeded.rawValue)|\(cidKey)", cooldownSec: 10.0) else { return }

        let lang = config.appLanguage
        let notifTitle = L10n.t(
            zhHans: "等待你的回复 / 审批",
            zhHant: "等待你的回覆 / 審批",
            en: "Input or Approval Needed",
            ru: "Требуется ответ или подтверждение",
            lang
        )
        let subtitle = (workspaceName?.isEmpty == false) ? workspaceName! : ((title?.isEmpty == false) ? title! : nil)
        let body = (detail?.isEmpty == false)
            ? detail!
            : L10n.t(
                zhHans: "Agent 正在等待确认或补充信息，点击切回 Antigravity。",
                zhHant: "Agent 正在等待確認或補充資訊，點擊切回 Antigravity。",
                en: "Agent is waiting for your input. Click to focus Antigravity.",
                ru: "Агент ожидает вашего ответа. Нажмите для перехода.",
                lang
            )

        postGenericNotification(
            identifier: "pilot.approval.\(cidKey).\(Int(Date().timeIntervalSince1970))",
            title: notifTitle,
            subtitle: subtitle,
            body: body,
            action: "focusAntigravity"
        )
    }

    func postQuotaRecovered(
        poolTitle: String,
        windowKind: QuotaWindowKind,
        remainingPercent: Int,
        config: ProxyConfig
    ) {
        guard config.notifyOnQuotaRecovered else { return }
        guard shouldDeliver(dedupKey: "quota|\(poolTitle)|\(windowKind.rawValue)", cooldownSec: 60.0) else { return }

        let lang = config.appLanguage
        let windowLabel = windowKind.shortLabel(lang)
        let title = L10n.t(
            zhHans: "模型配额已恢复",
            zhHant: "模型配額已恢復",
            en: "Model Quota Recovered",
            ru: "Квота моделей восстановлена",
            lang
        )
        let body = L10n.t(
            zhHans: "\(poolTitle)（\(windowLabel)）已恢复至 \(remainingPercent)%。",
            zhHant: "\(poolTitle)（\(windowLabel)）已恢復至 \(remainingPercent)%。",
            en: "\(poolTitle) (\(windowLabel)) is back to \(remainingPercent)%.",
            ru: "\(poolTitle) (\(windowLabel)) восстановлена до \(remainingPercent)%.",
            lang
        )

        postGenericNotification(
            identifier: "pilot.quota.\(poolTitle).\(windowKind.rawValue)",
            title: title,
            subtitle: nil,
            body: body,
            action: "openMonitor"
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.notification.request.content.userInfo["action"] as? String ?? "openMainWindow"
        if action == "focusAntigravity" {
            Self.markPendingExternalFocus()
        }
        Task { @MainActor in
            switch action {
            case "focusAntigravity":
                self.focusAntigravityOrPilot()
            case "openMonitor":
                if let onOpenMonitorTab = self.onOpenMonitorTab {
                    onOpenMonitorTab()
                } else {
                    self.onOpenMainWindow?()
                }
            default:
                self.onOpenMainWindow?()
            }
            completionHandler()
        }
    }

    @MainActor
    private final class HeadlessNotificationWaitState {
        var finished = false
        var deadline = Date().addingTimeInterval(4.0)
    }

    static func runHeadlessRuntimeUpdateNotificationAndExit(arguments: [String]) -> Never {
        var rawLang: String?
        var idx = 0
        while idx < arguments.count {
            let arg = arguments[idx]
            if arg == "--lang", idx + 1 < arguments.count {
                rawLang = arguments[idx + 1]
                break
            } else if arg.hasPrefix("--lang=") {
                rawLang = String(arg.dropFirst("--lang=".count))
                break
            }
            idx += 1
        }

        let resolvedLang: AppLanguage
        if let rawLang, !rawLang.isEmpty {
            resolvedLang = resolveLanguage(rawCode: rawLang)
        } else if let config = try? AppSupport().loadConfig() {
            resolvedLang = config.appLanguage.resolved
        } else {
            resolvedLang = AppLanguage.system.resolved
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        guard isRunningInAppBundle else {
            exit(1)
        }

        let service = SystemNotificationService.shared
        UNUserNotificationCenter.current().delegate = service

        let waitState = HeadlessNotificationWaitState()

        service.postRuntimeUpdateNeeded(
            language: resolvedLang,
            onAuthorizationPromptNeeded: {
                DispatchQueue.main.async {
                    waitState.deadline = max(waitState.deadline, Date().addingTimeInterval(20.0))
                }
            }
        ) { delivered in
            let flushDelay: TimeInterval = delivered ? 0.35 : 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay) {
                waitState.finished = true
            }
        }

        while !waitState.finished && Date() < waitState.deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        exit(0)
    }
}
