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

    nonisolated static var isRunningInAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var onOpenMainWindow: (() -> Void)?
    private var darwinNotifyToken: Int32 = NOTIFY_TOKEN_INVALID

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

    func configure(onOpenMainWindow: @escaping () -> Void) {
        self.onOpenMainWindow = onOpenMainWindow
        if Self.isRunningInAppBundle {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func startDarwinListener(onRuntimeUpdateNeeded: @escaping @MainActor () -> Void) {
        stopDarwinListener()
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

    func stopDarwinListener() {
        if darwinNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(darwinNotifyToken)
            darwinNotifyToken = NOTIFY_TOKEN_INVALID
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

    func postRuntimeUpdateNeeded(language: AppLanguage, completion: (@Sendable (Bool) -> Void)? = nil) {
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
        Task { @MainActor in
            self.onOpenMainWindow?()
            completionHandler()
        }
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

        var isNotDetermined = false
        let settingsSem = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            isNotDetermined = (settings.authorizationStatus == .notDetermined)
            settingsSem.signal()
        }
        _ = settingsSem.wait(timeout: .now() + 1.0)

        var finished = false
        let deadline = Date().addingTimeInterval(isNotDetermined ? 20.0 : 4.0)

        service.postRuntimeUpdateNeeded(language: resolvedLang) { delivered in
            let flushDelay: TimeInterval = delivered ? 0.35 : 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay) {
                finished = true
            }
        }

        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        exit(0)
    }
}
