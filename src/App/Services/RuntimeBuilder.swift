import AppKit
import CryptoKit
import Foundation
import ServiceManagement

struct RunningInstanceInfo: Identifiable, Equatable {
    enum Kind: String {
        case original = "原版 Antigravity"
        case runtime = "Antigravity Pilot"

        func localizedName(_ lang: AppLanguage) -> String {
            switch self {
            case .original: return L10n.t("原版 Antigravity", "Original Antigravity", lang)
            case .runtime: return "Antigravity Pilot"
            }
        }
    }

    let id: pid_t
    let kind: Kind
    let bundleURL: URL?
    let app: NSRunningApplication

    static func == (lhs: RunningInstanceInfo, rhs: RunningInstanceInfo) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }
}

enum RunningInstanceManager {
    static func detectRunningInstances(support: AppSupport = AppSupport()) -> [RunningInstanceInfo] {
        let runtimePath = support.runtimeApp.standardizedFileURL.path
        let legacyRuntimePath = support.legacyRuntimeApp.standardizedFileURL.path
        let sourcePath = support.sourceApp.standardizedFileURL.path
        var results: [RunningInstanceInfo] = []

        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated else { continue }
            let bundleId = app.bundleIdentifier ?? ""
            let bundlePath = app.bundleURL?.standardizedFileURL.path ?? ""

            if bundleId == "com.google.antigravity.pilot.runtime" ||
                bundleId == "com.google.antigravity.proxy.runtime" ||
                bundlePath == runtimePath ||
                bundlePath == legacyRuntimePath {
                results.append(RunningInstanceInfo(
                    id: app.processIdentifier,
                    kind: .runtime,
                    bundleURL: app.bundleURL,
                    app: app
                ))
            } else if bundleId == "com.google.antigravity" || bundlePath == sourcePath {
                results.append(RunningInstanceInfo(
                    id: app.processIdentifier,
                    kind: .original,
                    bundleURL: app.bundleURL,
                    app: app
                ))
            }
        }
        return results
    }

    static func terminateGracefully(
        _ instances: [RunningInstanceInfo],
        timeoutSeconds: TimeInterval = 5.0
    ) async -> Bool {
        guard !instances.isEmpty else { return true }
        await MainActor.run {
            for item in instances where !item.app.isTerminated {
                item.app.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let allExited = await MainActor.run {
                instances.allSatisfy { $0.app.isTerminated }
            }
            if allExited { return true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return await MainActor.run {
            instances.allSatisfy { $0.app.isTerminated }
        }
    }

    static func forceTerminate(_ instances: [RunningInstanceInfo]) async -> Bool {
        await MainActor.run {
            for item in instances where !item.app.isTerminated {
                item.app.forceTerminate()
            }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        return await MainActor.run {
            instances.allSatisfy { $0.app.isTerminated }
        }
    }
}

enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        statusDescription(for: L10n.current)
    }

    static func statusDescription(for lang: AppLanguage) -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return L10n.t("已开启登录时启动", "Launch at login enabled", lang)
        case .requiresApproval:
            return L10n.t("需在系统设置 → 登录项中允许", "Approval needed in System Settings → Login Items", lang)
        case .notRegistered:
            return L10n.t("未开启", "Disabled", lang)
        case .notFound:
            return L10n.t("请先将应用移至 /Applications", "Move app to /Applications first", lang)
        @unknown default:
            return L10n.t("未知状态", "Unknown", lang)
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

struct BuilderResources {
    let dylib: URL
    let launcher: URL
    let iconPNG: URL
}

struct RuntimeIcon {
    let name: String
    let icns: URL
}

final class RuntimeBuilder {
    private let config: ProxyConfig
    private let support: AppSupport
    private let progress: (String) -> Void
    private let fileManager = FileManager.default

    init(config: ProxyConfig, support: AppSupport, progress: @escaping (String) -> Void) {
        self.config = config
        self.support = support
        self.progress = progress
    }

    static func canFastHotUpdate(config: ProxyConfig, support: AppSupport = AppSupport()) -> Bool {
        let runtime = support.runtimeApp
        let source = support.sourceApp
        let fm = FileManager.default

        guard fm.fileExists(atPath: source.path),
              fm.fileExists(atPath: runtime.path),
              let resourcePath = Bundle.main.resourcePath else {
            return false
        }

        let builderBase = URL(fileURLWithPath: resourcePath, isDirectory: true)
        let builderLauncher = builderBase.appendingPathComponent("AntigravityProxyLauncher")
        let builderDylib = builderBase.appendingPathComponent("libantigravity_proxy.dylib")
        let runtimeLauncher = runtime.appendingPathComponent("Contents/MacOS/AntigravityProxyLauncher")
        let runtimeDylib = runtime.appendingPathComponent("Contents/Resources/libantigravity_proxy.dylib")

        guard fm.fileExists(atPath: runtimeLauncher.path),
              fm.fileExists(atPath: runtimeDylib.path),
              sha256File(builderLauncher) == sha256File(runtimeLauncher),
              sha256File(builderDylib) == sha256File(runtimeDylib) else {
            return false
        }

        let sourceVersion = readBundleShortVersion(at: source.appendingPathComponent("Contents/Info.plist"))
        let builtVersion = readEnvValue(key: "AG_SOURCE_VERSION", from: runtime.appendingPathComponent("Contents/Resources/proxy.env"))
        if !sourceVersion.isEmpty && sourceVersion != builtVersion {
            return false
        }

        let runtimeUsesOriginal = isRuntimeUsingOriginalIcon(app: runtime)
        if runtimeUsesOriginal != config.useOriginalIcon {
            return false
        }

        return verifySignatureQuick(app: runtime)
    }

    func applyAndLaunch(forceRebuild: Bool = false) throws -> BuildApplyOutcome {
        guard fileManager.fileExists(atPath: support.sourceApp.path) else {
            throw BuilderError.missingSourceApp(support.sourceApp.path)
        }

        try support.ensureRoot()
        let sourceVersion = Self.readBundleShortVersion(at: support.sourceApp.appendingPathComponent("Contents/Info.plist"))

        progress(L10n.t("写入外置代理配置...", "Writing external proxy config...", config.appLanguage))
        try Self.writeProxyEnv(config: config, to: support.externalProxyEnvURL, sourceVersion: nil)

        if !forceRebuild && Self.canFastHotUpdate(config: config, support: support) {
            progress(L10n.t("极速热更新配置（免重建）...", "Fast hot-updating config...", config.appLanguage))
            try launchRuntimeApp()
            return .fastHotUpdated
        }

        try rebuildRuntime(sourceVersion: sourceVersion)
        try launchRuntimeApp()
        return .fullRebuilt
    }

    private func rebuildRuntime(sourceVersion: String) throws {
        let resources = try builderResources()
        let app = support.runtimeApp
        let stagingApp = support.runtimeRoot.appendingPathComponent(
            ".Antigravity-Pilot-staging-\(UUID().uuidString).app",
            isDirectory: true
        )
        let backupApp = support.runtimeRoot.appendingPathComponent(
            ".Antigravity-Pilot-backup-\(UUID().uuidString).app",
            isDirectory: true
        )
        let contents = stagingApp.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let appResources = contents.appendingPathComponent("Resources", isDirectory: true)
        let launcherDest = macOS.appendingPathComponent("AntigravityProxyLauncher")
        let dylibDest = appResources.appendingPathComponent("libantigravity_proxy.dylib")
        let hadExistingRuntime = fileManager.fileExists(atPath: app.path)
        let previousIconFingerprint = hadExistingRuntime ? iconFingerprint(for: app) : nil
        let lang = config.appLanguage

        try fileManager.createDirectory(at: support.runtimeRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingApp) }

        progress(L10n.t("复制原版 Antigravity...", "Copying original Antigravity...", lang))
        try run("/usr/bin/ditto", [support.sourceApp.path, stagingApp.path])

        progress(L10n.t("写入代理组件...", "Installing proxy components...", lang))
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appResources, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: launcherDest)
        try fileManager.copyItem(at: resources.launcher, to: launcherDest)
        try? fileManager.removeItem(at: dylibDest)
        try fileManager.copyItem(at: resources.dylib, to: dylibDest)
        try Self.writeProxyEnv(config: config, to: appResources.appendingPathComponent("proxy.env"), sourceVersion: sourceVersion)
        try run("/bin/chmod", ["+x", launcherDest.path])

        if config.useOriginalIcon {
            progress(L10n.t("修改 bundle 信息（保留原版图标）...", "Updating bundle info (original icon)...", lang))
            try configureRuntimeApp(app: stagingApp, icon: nil)
        } else {
            progress(L10n.t("生成图标...", "Generating app icon...", lang))
            let icon = try prepareIcon(resources: resources, appResources: appResources)

            progress(L10n.t("修改 bundle 信息...", "Updating bundle info...", lang))
            try configureRuntimeApp(app: stagingApp, icon: icon)

            progress(L10n.t("Patch Electron 图标...", "Patching Electron icon...", lang))
            let asar = appResources.appendingPathComponent("app.asar")
            if fileManager.fileExists(atPath: asar.path) {
                let asarHash = try AsarIconPatcher.patch(asarURL: asar, iconURL: resources.iconPNG)
                try updateAsarIntegrity(infoPlistURL: contents.appendingPathComponent("Info.plist"), asarHash: asarHash)
            }
        }

        let newIconFingerprint = iconFingerprint(for: stagingApp)
        let iconChanged = hadExistingRuntime && (previousIconFingerprint != newIconFingerprint)

        progress(L10n.t("提取原版 Entitlements 并重签名...", "Extracting entitlements & re-signing...", lang))
        let entitlements = try prepareMergedEntitlements()
        try sign(app: stagingApp, entitlements: entitlements)

        progress(L10n.t("原子替换 runtime...", "Swapping runtime bundle...", lang))
        var movedToBackup = false
        if fileManager.fileExists(atPath: app.path) {
            try fileManager.moveItem(at: app, to: backupApp)
            movedToBackup = true
        }
        do {
            try fileManager.moveItem(at: stagingApp, to: app)
        } catch {
            if movedToBackup && !fileManager.fileExists(atPath: app.path) {
                try? fileManager.moveItem(at: backupApp, to: app)
            }
            throw error
        }
        if movedToBackup {
            try? fileManager.removeItem(at: backupApp)
        }

        refreshIconCaches(app: app, restartDock: iconChanged)
    }

    private func launchRuntimeApp() throws {
        progress(L10n.t("启动 Antigravity Pilot...", "Launching Antigravity Pilot...", config.appLanguage))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let sem = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: support.runtimeApp, configuration: configuration) { _, error in
            launchError = error
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        if let launchError {
            throw launchError
        }
    }

    private func builderResources() throws -> BuilderResources {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw BuilderError.missingResource("Resources")
        }
        let base = URL(fileURLWithPath: resourcePath, isDirectory: true)
        let resources = BuilderResources(
            dylib: base.appendingPathComponent("libantigravity_proxy.dylib"),
            launcher: base.appendingPathComponent("AntigravityProxyLauncher"),
            iconPNG: base.appendingPathComponent("icon.png")
        )
        for url in [resources.dylib, resources.launcher, resources.iconPNG] {
            guard fileManager.fileExists(atPath: url.path) else {
                throw BuilderError.missingResource(url.lastPathComponent)
            }
        }
        return resources
    }

    static func readBundleShortVersion(at plistURL: URL) -> String {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else {
            return ""
        }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readEnvValue(key: String, from envURL: URL) -> String? {
        guard let text = try? String(contentsOf: envURL, encoding: .utf8) else {
            return nil
        }
        let prefix = "\(key)="
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(prefix) {
                let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func isRuntimeUsingOriginalIcon(app: URL) -> Bool {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let iconFile = plist["CFBundleIconFile"] as? String else {
            return true
        }
        return iconFile != "antigravity-pilot.icns" && iconFile != "antigravity-proxy.icns"
    }

    private static func sha256File(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verifySignatureQuick(app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func writeExternalProxyEnv(config: ProxyConfig, support: AppSupport) throws {
        try support.ensureRoot()
        try writeProxyEnv(config: config, to: support.externalProxyEnvURL, sourceVersion: nil)
    }

    static func writeProxyEnv(config: ProxyConfig, to url: URL, sourceVersion: String?) throws {
        let noProxy = config.effectiveNoProxy
        var lines = [
            "AG_PROXY=\(config.hookProxyURL)",
            "AG_PROXY_LOG=0",
            "AG_PROXY_TIMEOUT_MS=15000",
            "AG_APP_LANG=\(config.appLanguage.resolved.rawValue)",
            "HTTP_PROXY=\(config.envProxyURL)",
            "HTTPS_PROXY=\(config.envProxyURL)",
            "ALL_PROXY=\(config.envProxyURL)",
            "http_proxy=\(config.envProxyURL)",
            "https_proxy=\(config.envProxyURL)",
            "all_proxy=\(config.envProxyURL)",
            "NO_PROXY=\(noProxy)",
            "no_proxy=\(noProxy)",
            "NODE_USE_ENV_PROXY=1"
        ]
        if let sourceVersion, !sourceVersion.isEmpty {
            lines.append("AG_SOURCE_VERSION=\(sourceVersion)")
        }
        let contents = lines.joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func prepareIcon(resources: BuilderResources, appResources: URL) throws -> RuntimeIcon {
        let iconName = "antigravity-pilot.icns"
        let iconURL = appResources.appendingPathComponent(iconName)
        try? fileManager.removeItem(at: iconURL)
        try generateICNS(from: resources.iconPNG, to: iconURL)
        return RuntimeIcon(name: iconName, icns: iconURL)
    }

    private func generateICNS(from png: URL, to icns: URL) throws {
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("antigravity-pilot-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = temp.appendingPathComponent("icon.iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }

        let sizes: [(Int, String)] = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png")
        ]

        for (size, name) in sizes {
            try run("/usr/bin/sips", [
                "-z", "\(size)", "\(size)",
                png.path,
                "--out",
                iconset.appendingPathComponent(name).path
            ])
        }
        try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    }

    private func iconFingerprint(for app: URL) -> String {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return ""
        }
        let iconFile = (plist["CFBundleIconFile"] as? String) ?? ""
        let iconName = (plist["CFBundleIconName"] as? String) ?? ""
        var icnsHash = ""
        if !iconFile.isEmpty {
            let resourcesDir = app.appendingPathComponent("Contents/Resources", isDirectory: true)
            let candidate = resourcesDir.appendingPathComponent(iconFile)
            let resolved: URL
            if fileManager.fileExists(atPath: candidate.path) {
                resolved = candidate
            } else if !iconFile.lowercased().hasSuffix(".icns") {
                resolved = resourcesDir.appendingPathComponent("\(iconFile).icns")
            } else {
                resolved = candidate
            }
            if let icnsData = try? Data(contentsOf: resolved) {
                icnsHash = SHA256.hash(data: icnsData).map { String(format: "%02x", $0) }.joined()
            }
        }
        return "\(iconFile)|\(iconName)|\(icnsHash)"
    }

    private func configureRuntimeApp(app: URL, icon: RuntimeIcon?) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        try plistSetOrAdd(info, "CFBundleExecutable", "AntigravityProxyLauncher")
        try plistSetOrAdd(info, "CFBundleIdentifier", "com.google.antigravity.pilot.runtime")
        try plistSetOrAdd(info, "CFBundleDisplayName", "Antigravity Pilot")
        plistDeleteIfExists(info, "CFBundleIconName")
        if let icon {
            try plistSetOrAdd(info, "CFBundleIconFile", icon.name)
        }

        try setHelper(app, "Antigravity Helper.app", "com.google.antigravity.pilot.runtime.helper", icon: icon)
        try setHelper(app, "Antigravity Helper (GPU).app", "com.google.antigravity.pilot.runtime.helper.GPU", icon: icon)
        try setHelper(app, "Antigravity Helper (Plugin).app", "com.google.antigravity.pilot.runtime.helper.Plugin", icon: icon)
        try setHelper(app, "Antigravity Helper (Renderer).app", "com.google.antigravity.pilot.runtime.helper.Renderer", icon: icon)
    }

    private func setHelper(_ app: URL, _ helperName: String, _ helperID: String, icon: RuntimeIcon?) throws {
        let helper = app.appendingPathComponent("Contents/Frameworks/\(helperName)", isDirectory: true)
        let plist = helper.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: plist.path) else { return }

        try plistSetOrAdd(plist, "CFBundleIdentifier", helperID)
        if let icon {
            let resources = helper.appendingPathComponent("Contents/Resources", isDirectory: true)
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: resources.appendingPathComponent(icon.name))
            try fileManager.copyItem(at: icon.icns, to: resources.appendingPathComponent(icon.name))
            try plistSetOrAdd(plist, "CFBundleIconFile", icon.name)
            plistDeleteIfExists(plist, "CFBundleIconName")
        }
    }

    static func buildMergedEntitlementsData(fromSourceApp sourceApp: URL) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", sourceApp.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var dict: [String: Any] = [:]
        if (try? process.run()) != nil {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            let combined = String(data: outData, encoding: .utf8) ?? ""
            let combinedErr = String(data: errData, encoding: .utf8) ?? ""
            let rawText = combined.contains("<plist") ? combined : combinedErr

            if let xmlStart = rawText.range(of: "<?xml") ?? rawText.range(of: "<plist"),
               let xmlEnd = rawText.range(of: "</plist>", options: .backwards) {
                let xmlSlice = String(rawText[xmlStart.lowerBound..<xmlEnd.upperBound])
                if let xmlData = xmlSlice.data(using: .utf8),
                   let parsed = try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil) as? [String: Any] {
                    dict = parsed
                }
            }
        }

        if dict.isEmpty {
            dict = [
                "com.apple.security.automation.apple-events": true,
                "com.apple.security.device.audio-input": true,
                "com.apple.security.device.camera": true
            ]
        }

        dict["com.apple.security.cs.allow-dyld-environment-variables"] = true
        dict["com.apple.security.cs.disable-library-validation"] = true
        dict["com.apple.security.cs.allow-jit"] = true

        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            return data
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>com.apple.security.automation.apple-events</key>
          <true/>
          <key>com.apple.security.cs.allow-dyld-environment-variables</key>
          <true/>
          <key>com.apple.security.cs.allow-jit</key>
          <true/>
          <key>com.apple.security.cs.disable-library-validation</key>
          <true/>
          <key>com.apple.security.device.audio-input</key>
          <true/>
          <key>com.apple.security.device.camera</key>
          <true/>
        </dict>
        </plist>
        """.data(using: .utf8)!
    }

    private func prepareMergedEntitlements() throws -> URL {
        try support.ensureRoot()
        let url = support.root.appendingPathComponent("antigravity-pilot.entitlements.plist")
        let data = Self.buildMergedEntitlementsData(fromSourceApp: support.sourceApp)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func sign(app: URL, entitlements: URL) throws {
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], allowFailure: true)

        let script = """
        set -euo pipefail
        app="$1"
        entitlements="$2"

        ag_bin="$app/Contents/MacOS/Antigravity"
        if [[ -f "$ag_bin" ]]; then
          tmp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ag-sign.XXXXXX")"
          trap 'rm -rf "$tmp_dir"' EXIT
          /bin/mv "$ag_bin" "$tmp_dir/Antigravity"
          /usr/bin/codesign --force --sign - --options runtime --entitlements "$entitlements" "$tmp_dir/Antigravity"
          /bin/mv "$tmp_dir/Antigravity" "$ag_bin"
          /bin/chmod +x "$ag_bin"
        fi

        while IFS= read -r -d '' item; do
          if /usr/bin/file "$item" | /usr/bin/grep -q 'Mach-O'; then
            /usr/bin/codesign --force --sign - --options runtime --entitlements "$entitlements" "$item" >/dev/null 2>&1 || true
          fi
        done < <(/usr/bin/find "$app/Contents/Frameworks" "$app/Contents/Resources" -type f \\( -perm -111 -o -name '*.dylib' -o -name '*.so' -o -name '*.node' \\) -print0 2>/dev/null)

        for fw in "$app/Contents/Frameworks"/*.framework; do
          if [[ -e "$fw" ]]; then
            /usr/bin/codesign --force --sign - "$fw"
          fi
        done

        for helper in "$app/Contents/Frameworks"/Antigravity\\ Helper*.app; do
          if [[ -e "$helper" ]]; then
            /usr/bin/codesign --force --sign - --options runtime --entitlements "$entitlements" "$helper"
          fi
        done

        /usr/bin/codesign --force --sign - --options runtime --entitlements "$entitlements" "$app"
        /usr/bin/codesign --verify --deep --strict "$app"
        """

        try run("/bin/bash", ["-c", script, "sign-runtime", app.path, entitlements.path])
    }

    private func refreshIconCaches(app: URL, restartDock: Bool) {
        var touchTargets = [
            app.path,
            app.appendingPathComponent("Contents/Info.plist").path
        ]
        let helperNames = [
            "Antigravity Helper.app",
            "Antigravity Helper (GPU).app",
            "Antigravity Helper (Plugin).app",
            "Antigravity Helper (Renderer).app"
        ]
        for helperName in helperNames {
            let helper = app.appendingPathComponent("Contents/Frameworks/\(helperName)", isDirectory: true)
            if fileManager.fileExists(atPath: helper.path) {
                touchTargets.append(helper.path)
                touchTargets.append(helper.appendingPathComponent("Contents/Info.plist").path)
            }
        }
        _ = try? run("/usr/bin/touch", touchTargets, allowFailure: true)

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if fileManager.isExecutableFile(atPath: lsregister) {
            _ = try? run(lsregister, ["-f", "-R", app.path], allowFailure: true)
        }

        NSWorkspace.shared.noteFileSystemChanged(app.path)

        if restartDock {
            _ = try? run("/usr/bin/killall", ["Dock"], allowFailure: true)
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private func plistSet(_ plist: URL, _ key: String, _ value: String) throws {
        try run("/usr/libexec/PlistBuddy", ["-c", "Set :\(key) \(value)", plist.path])
    }

    private func plistSetOrAdd(_ plist: URL, _ key: String, _ value: String) throws {
        do {
            try plistSet(plist, key, value)
        } catch {
            try run("/usr/libexec/PlistBuddy", ["-c", "Add :\(key) string \(value)", plist.path])
        }
    }

    private func plistDeleteIfExists(_ plist: URL, _ key: String) {
        _ = try? run("/usr/libexec/PlistBuddy", ["-c", "Delete :\(key)", plist.path], allowFailure: true)
    }

    private func updateAsarIntegrity(infoPlistURL: URL, asarHash: String) throws {
        guard fileManager.fileExists(atPath: infoPlistURL.path) else { return }
        let data = try Data(contentsOf: infoPlistURL)
        var format: PropertyListSerialization.PropertyListFormat = .xml
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        ) as? [String: Any],
              var integrity = plist["ElectronAsarIntegrity"] as? [String: Any],
              var appAsar = integrity["Resources/app.asar"] as? [String: Any] else {
            return
        }
        appAsar["algorithm"] = "SHA256"
        appAsar["hash"] = asarHash
        integrity["Resources/app.asar"] = appAsar
        plist["ElectronAsarIntegrity"] = integrity

        let outputFormat: PropertyListSerialization.PropertyListFormat = format == .binary ? .binary : .xml
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: outputFormat, options: 0)
        try updated.write(to: infoPlistURL, options: .atomic)
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            if allowFailure { return error.localizedDescription }
            throw BuilderError.commandFailed("\(executable) \(arguments.joined(separator: " "))\n\(error.localizedDescription)")
        }

        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && !allowFailure {
            throw BuilderError.commandFailed("\(executable) \(arguments.joined(separator: " "))\n\(output)")
        }

        return output
    }
}

enum AsarIconPatcher {
    @discardableResult
    static func patch(asarURL: URL, iconURL: URL) throws -> String {
        let original = try Data(contentsOf: asarURL)
        guard original.count >= 16 else {
            throw BuilderError.asarFormat(L10n.t("文件过小", "File too small"))
        }

        let headerPickleSize = Int(readUInt32(original, offset: 4))
        let jsonSize = Int(readUInt32(original, offset: 12))
        let headerStart = 16
        let headerEnd = headerStart + jsonSize
        let dataStart = 8 + headerPickleSize
        guard headerPickleSize >= 8, headerEnd <= dataStart, dataStart <= original.count else {
            throw BuilderError.asarFormat(L10n.t("header size 越界", "Header size out of bounds"))
        }

        let headerData = original.subdata(in: headerStart..<headerEnd)
        guard var header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              var files = header["files"] as? [String: Any] else {
            throw BuilderError.asarFormat(L10n.t("无法解析 header", "Failed to parse ASAR header"))
        }

        let iconData = try Data(contentsOf: iconURL)
        var blobs: [Data] = []
        var offset = 0
        var foundIcon = false

        try processFiles(
            files: &files,
            prefix: "",
            original: original,
            dataStart: dataStart,
            iconData: iconData,
            blobs: &blobs,
            offset: &offset,
            foundIcon: &foundIcon
        )

        guard foundIcon else {
            throw BuilderError.asarFormat("icon.png not found")
        }

        header["files"] = files
        let newHeader = try JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes])
        let headerHash = sha256Hex(newHeader)
        let padding = (4 - (newHeader.count % 4)) % 4
        let alignedHeaderSize = newHeader.count + padding

        var output = Data()
        output.append(writeUInt32(4))
        output.append(writeUInt32(UInt32(alignedHeaderSize + 8)))
        output.append(writeUInt32(UInt32(alignedHeaderSize + 4)))
        output.append(writeUInt32(UInt32(newHeader.count)))
        output.append(newHeader)
        if padding > 0 {
            output.append(Data(repeating: 0x00, count: padding))
        }
        for blob in blobs {
            output.append(blob)
        }
        try output.write(to: asarURL, options: .atomic)
        return headerHash
    }

    private static func processFiles(
        files: inout [String: Any],
        prefix: String,
        original: Data,
        dataStart: Int,
        iconData: Data,
        blobs: inout [Data],
        offset: inout Int,
        foundIcon: inout Bool
    ) throws {
        for name in Array(files.keys).sorted() {
            guard var entry = files[name] as? [String: Any] else { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"

            if var nested = entry["files"] as? [String: Any] {
                try processFiles(
                    files: &nested,
                    prefix: path,
                    original: original,
                    dataStart: dataStart,
                    iconData: iconData,
                    blobs: &blobs,
                    offset: &offset,
                    foundIcon: &foundIcon
                )
                entry["files"] = nested
                files[name] = entry
                continue
            }

            if (entry["unpacked"] as? Bool) == true || entry["link"] != nil {
                files[name] = entry
                continue
            }

            let blob: Data
            if path == "icon.png" {
                blob = iconData
                foundIcon = true
                entry["size"] = blob.count
                let blockSize = ((entry["integrity"] as? [String: Any])?["blockSize"] as? Int) ?? 4 * 1024 * 1024
                entry["integrity"] = integrity(for: blob, blockSize: blockSize)
            } else {
                guard let size = intValue(entry["size"]),
                      let oldOffset = intValue(entry["offset"]) else {
                    throw BuilderError.asarFormat(L10n.t(
                        zhHans: "缺少 size 或 offset：\(path)",
                        zhHant: "缺少 size 或 offset：\(path)",
                        en: "Missing size or offset: \(path)",
                        ru: "Отсутствует size или offset: \(path)"
                    ))
                }
                let start = dataStart + oldOffset
                let end = start + size
                guard start >= 0, end <= original.count else {
                    throw BuilderError.asarFormat(L10n.t(
                        zhHans: "文件数据越界：\(path)",
                        zhHant: "檔案資料越界：\(path)",
                        en: "File data out of bounds: \(path)",
                        ru: "Данные файла вне границ: \(path)"
                    ))
                }
                blob = original.subdata(in: start..<end)
            }

            entry["offset"] = String(offset)
            blobs.append(blob)
            offset += blob.count
            files[name] = entry
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func integrity(for data: Data, blockSize: Int) -> [String: Any] {
        var blocks: [String] = []
        var index = 0
        while index < data.count {
            let end = min(index + blockSize, data.count)
            blocks.append(sha256Hex(data.subdata(in: index..<end)))
            index = end
        }
        if blocks.isEmpty {
            blocks = [sha256Hex(Data())]
        }
        return [
            "algorithm": "SHA256",
            "hash": sha256Hex(data),
            "blockSize": blockSize,
            "blocks": blocks
        ]
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let bytes = data[offset..<(offset + 4)]
        return bytes.enumerated().reduce(UInt32(0)) { result, item in
            result | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }

    private static func writeUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var config: ProxyConfig = .defaultConfig
    @Published var status: String = L10n.t("准备就绪", "Ready")
    @Published var runtimeSummary: String = L10n.t("正在检查本机 Antigravity 状态...", "Checking Antigravity installation...")
    @Published var runtimeStatusKind: RuntimeStatusKind = .notBuilt
    @Published var healthReport: ProxyHealthReport = .checking
    @Published var runningInstances: [RunningInstanceInfo] = []
    @Published var canHotUpdate: Bool = false
    @Published var loginItemEnabled: Bool = LoginItemManager.isEnabled
    @Published var loginItemStatus: String = LoginItemManager.statusDescription
    @Published var mcpPluginStatus: McpPluginStatus = .notInstalled
    @Published var isUpdatingMcpPlugin = false
    @Published var errorMessage: String?
    @Published var bannerSuccessMessage: String?
    @Published var isWorking = false

    let support = AppSupport()
    private var probeGeneration = 0
    private var mcpStatusGeneration = 0
    private var runtimeStatusGeneration = 0
    private var debounceHealthTask: Task<Void, Never>?
    private var debounceNoProxyTask: Task<Void, Never>?

    private lazy var cachedOriginalIcon: NSImage = {
        let icnsURL = support.sourceApp.appendingPathComponent("Contents/Resources/icon.icns")
        if let image = NSImage(contentsOf: icnsURL) {
            return image
        }
        if FileManager.default.fileExists(atPath: support.sourceApp.path) {
            return NSWorkspace.shared.icon(forFile: support.sourceApp.path)
        }
        return NSApplication.shared.applicationIconImage
    }()

    var pilotAppIcon: NSImage {
        NSApplication.shared.applicationIconImage
    }

    var originalAppIcon: NSImage {
        cachedOriginalIcon
    }

    var previewIcon: NSImage {
        config.useOriginalIcon ? cachedOriginalIcon : NSApplication.shared.applicationIconImage
    }

    var appVersionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    func load() {
        if let loaded = try? support.loadConfig() {
            config = loaded
        } else {
            config = .defaultConfig
        }
        L10n.current = config.appLanguage
        status = L10n.t("准备就绪", "Ready", config.appLanguage)
        refreshRuntimeStatus()
        refreshRunningInstances()
        refreshLoginItemState()
        refreshMcpPluginStatus()
        checkProxyHealth()
    }

    func applyLanguageChange() {
        L10n.current = config.appLanguage
        savePreferencesOnly()
        refreshLoginItemState()
        refreshMcpPluginStatus()
        if mcpPluginStatus.isInstalled {
            let version = appVersionText
            let currentSupport = support
            let lang = config.appLanguage
            Task.detached(priority: .utility) {
                McpPluginInstaller(support: currentSupport).syncLanguageIfInstalled(
                    appVersion: version,
                    language: lang
                )
            }
        }
        if !isWorking {
            status = L10n.t("准备就绪", "Ready", config.appLanguage)
        }
        errorMessage = nil
        bannerSuccessMessage = nil
        checkProxyHealth()
    }

    func refreshRuntimeStatus() {
        runtimeStatusGeneration += 1
        let gen = runtimeStatusGeneration
        let lang = config.appLanguage
        let sourcePlist = support.sourceApp.appendingPathComponent("Contents/Info.plist")
        let sourceVersion = RuntimeBuilder.readBundleShortVersion(at: sourcePlist)
        let runtimeExists = FileManager.default.fileExists(atPath: support.runtimeApp.path)
        let builtVersion = RuntimeBuilder.readEnvValue(
            key: "AG_SOURCE_VERSION",
            from: support.runtimeApp.appendingPathComponent("Contents/Resources/proxy.env")
        )

        guard !sourceVersion.isEmpty else {
            runtimeSummary = L10n.t(
                "未检测到原版 /Applications/Antigravity.app",
                "Original /Applications/Antigravity.app not found",
                lang
            )
            runtimeStatusKind = .missingSource
            canHotUpdate = false
            return
        }

        if !runtimeExists {
            runtimeSummary = L10n.t(
                zhHans: "原版 \(sourceVersion) · 尚未生成代理副本",
                zhHant: "原版 \(sourceVersion) · 尚未產生代理副本",
                en: "Source \(sourceVersion) · Runtime copy not built yet",
                ru: "Оригинал \(sourceVersion) · Копия ещё не собрана",
                lang
            )
            runtimeStatusKind = .notBuilt
            canHotUpdate = false
        } else if let builtVersion, !builtVersion.isEmpty {
            if builtVersion == sourceVersion {
                runtimeSummary = L10n.t(
                    zhHans: "原版 \(sourceVersion) · 代理副本已就绪 (\(builtVersion))",
                    zhHant: "原版 \(sourceVersion) · 代理副本已就緒 (\(builtVersion))",
                    en: "Source \(sourceVersion) · Runtime ready (\(builtVersion))",
                    ru: "Оригинал \(sourceVersion) · Копия готова (\(builtVersion))",
                    lang
                )
                runtimeStatusKind = .ready
            } else {
                runtimeSummary = L10n.t(
                    zhHans: "原版 \(sourceVersion) · 检测到更新（副本 \(builtVersion)），建议重建",
                    zhHant: "原版 \(sourceVersion) · 偵測到更新（副本 \(builtVersion)），建議重建",
                    en: "Source \(sourceVersion) · Update detected (copy \(builtVersion)), rebuild recommended",
                    ru: "Оригинал \(sourceVersion) · Есть обновление (копия \(builtVersion)), нужна пересборка",
                    lang
                )
                runtimeStatusKind = .updateNeeded
            }
        } else {
            runtimeSummary = L10n.t(
                zhHans: "原版 \(sourceVersion) · 代理副本已就绪",
                zhHant: "原版 \(sourceVersion) · 代理副本已就緒",
                en: "Source \(sourceVersion) · Runtime ready",
                ru: "Оригинал \(sourceVersion) · Копия готова",
                lang
            )
            runtimeStatusKind = .ready
        }

        let currentCfg = config
        let currentSupport = support
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fast = RuntimeBuilder.canFastHotUpdate(config: currentCfg, support: currentSupport)
            DispatchQueue.main.async {
                guard let self, self.runtimeStatusGeneration == gen else { return }
                self.canHotUpdate = fast
            }
        }
    }

    func refreshRunningInstances() {
        runningInstances = RunningInstanceManager.detectRunningInstances(support: support)
    }

    func refreshLoginItemState() {
        loginItemEnabled = LoginItemManager.isEnabled
        loginItemStatus = LoginItemManager.statusDescription(for: config.appLanguage)
    }

    func refreshMcpPluginStatus() {
        mcpStatusGeneration += 1
        let gen = mcpStatusGeneration
        let currentSupport = support
        let bundledVersion = appVersionText
        Task { [weak self] in
            let nextStatus = await Task.detached(priority: .utility) {
                McpPluginInstaller(support: currentSupport).status(bundledVersion: bundledVersion)
            }.value
            guard let self, self.mcpStatusGeneration == gen else { return }
            self.mcpPluginStatus = nextStatus
        }
    }

    func installOrUpdateMcpPlugin() {
        guard !isUpdatingMcpPlugin else { return }
        isUpdatingMcpPlugin = true
        errorMessage = nil
        bannerSuccessMessage = nil

        let version = appVersionText
        let currentSupport = support
        let lang = config.appLanguage
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try McpPluginInstaller(support: currentSupport).installOrUpdate(appVersion: version, language: lang)
                }.value
                refreshMcpPluginStatus()
                bannerSuccessMessage = L10n.t(
                    zhHans: "已安装 Antigravity 应用内看板插件（v\(version)），可在左侧边栏或对话右上角 + 菜单打开。",
                    zhHant: "已安裝 Antigravity 應用內看板外掛（v\(version)），可在左側邊欄或對話右上角 + 選單開啟。",
                    en: "Installed Antigravity in-app dashboard plugin (v\(version)). Open from the left sidebar or chat + menu.",
                    ru: "Плагин панели установлен (v\(version)). Откройте из боковой панели или меню + в чате.",
                    lang
                )
            } catch {
                errorMessage = L10n.t(
                    zhHans: "安装应用内插件失败：\(error.localizedDescription)",
                    zhHant: "安裝應用內外掛失敗：\(error.localizedDescription)",
                    en: "Failed to install in-app plugin: \(error.localizedDescription)",
                    ru: "Ошибка установки плагина: \(error.localizedDescription)",
                    lang
                )
            }
            isUpdatingMcpPlugin = false
        }
    }

    func uninstallMcpPlugin() {
        guard !isUpdatingMcpPlugin else { return }
        isUpdatingMcpPlugin = true
        errorMessage = nil
        bannerSuccessMessage = nil

        let currentSupport = support
        let lang = config.appLanguage
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try McpPluginInstaller(support: currentSupport).uninstall()
                }.value
                refreshMcpPluginStatus()
                bannerSuccessMessage = L10n.t(
                    "已卸载 Antigravity 应用内看板插件。",
                    "Uninstalled Antigravity in-app dashboard plugin.",
                    lang
                )
            } catch {
                errorMessage = L10n.t(
                    zhHans: "卸载应用内插件失败：\(error.localizedDescription)",
                    zhHant: "解除安裝應用內外掛失敗：\(error.localizedDescription)",
                    en: "Failed to uninstall in-app plugin: \(error.localizedDescription)",
                    ru: "Ошибка удаления плагина: \(error.localizedDescription)",
                    lang
                )
            }
            isUpdatingMcpPlugin = false
        }
    }

    func setLoginItem(_ enabled: Bool) {
        let lang = config.appLanguage
        do {
            try LoginItemManager.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = L10n.t(
                zhHans: "设置登录时启动失败：\(error.localizedDescription)",
                zhHant: "設定登入時啟動失敗：\(error.localizedDescription)",
                en: "Failed to update login item: \(error.localizedDescription)",
                ru: "Ошибка настройки автозапуска: \(error.localizedDescription)",
                lang
            )
        }
        refreshLoginItemState()
    }

    func savePreferencesOnly() {
        do {
            try support.saveConfig(config)
            if (try? validate(config)) != nil,
               FileManager.default.fileExists(atPath: support.externalProxyEnvURL.path) {
                try? RuntimeBuilder.writeExternalProxyEnv(config: config, support: support)
            }
            refreshRuntimeStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleSaveNoProxy() {
        debounceNoProxyTask?.cancel()
        debounceNoProxyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.savePreferencesOnly()
        }
    }

    func saveNoProxyNow() {
        debounceNoProxyTask?.cancel()
        savePreferencesOnly()
    }

    func scheduleProxyHealthCheck() {
        debounceHealthTask?.cancel()
        debounceHealthTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.checkProxyHealth()
        }
    }

    func checkProxyHealth() {
        debounceHealthTask?.cancel()
        probeGeneration += 1
        let generation = probeGeneration
        let cfg = config
        healthReport = .checking(lang: cfg.appLanguage)

        Task { [weak self] in
            let report = await ProxyHealthService.probe(config: cfg, includeInternetCheck: true)
            await MainActor.run {
                guard let self, self.probeGeneration == generation else { return }
                self.healthReport = report
            }
        }
    }

    func saveAndStart(forceRebuild: Bool = false, terminateRunningFirst: Bool = false, onLaunchComplete: (() -> Void)? = nil) {
        guard !isWorking else { return }
        Task {
            await start(forceRebuild: forceRebuild, terminateRunningFirst: terminateRunningFirst, onLaunchComplete: onLaunchComplete)
        }
    }

    func start(forceRebuild: Bool, terminateRunningFirst: Bool, onLaunchComplete: (() -> Void)?) async {
        let lang = config.appLanguage
        isWorking = true
        errorMessage = nil
        bannerSuccessMessage = nil
        status = L10n.t("检查代理端口...", "Checking proxy ports...", lang)

        do {
            try validate(config)
            let currentConfig = config
            let currentSupport = support

            let report = await ProxyHealthService.probe(config: currentConfig, includeInternetCheck: true)
            healthReport = report
            guard report.tcpReachable && report.socks5HandshakeOK else {
                throw BuilderError.invalidPort(report.detailMessage)
            }

            let instances = RunningInstanceManager.detectRunningInstances(support: currentSupport)
            runningInstances = instances
            if !instances.isEmpty {
                if terminateRunningFirst {
                    status = L10n.t(
                        "正在优雅退出运行中的 Antigravity...",
                        "Gracefully quitting running Antigravity...",
                        lang
                    )
                    let exited = await RunningInstanceManager.terminateGracefully(instances, timeoutSeconds: 5.0)
                    refreshRunningInstances()
                    if !exited {
                        throw BuilderError.commandFailed(L10n.t(
                            "旧版 Antigravity 未能在 5 秒内退出，请手动 Cmd + Q 退出后重试。",
                            "Antigravity did not exit within 5s. Quit with Cmd + Q and try again.",
                            lang
                        ))
                    }
                } else {
                    let sep = (lang.resolved == .zhHans || lang.resolved == .zhHant) ? "、" : ", "
                    let names = instances.map { "\($0.kind.localizedName(lang)) (PID \($0.id))" }.joined(separator: sep)
                    throw BuilderError.commandFailed(L10n.t(
                        zhHans: "检测到正在运行的实例：\(names)。请先退出或点击“优雅退出并启动”。",
                        zhHant: "偵測到正在執行的執行個體：\(names)。請先結束或點擊「優雅結束並啟動」。",
                        en: "Running instances detected: \(names). Quit them first or click 'Quit & Launch'.",
                        ru: "Обнаружены запущенные процессы: \(names). Закройте их или нажмите «Закрыть и запуск».",
                        lang
                    ))
                }
            }

            try currentSupport.saveConfig(currentConfig)

            let outcome: BuildApplyOutcome = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let builder = RuntimeBuilder(config: currentConfig, support: currentSupport) { [weak self] message in
                            DispatchQueue.main.async {
                                self?.status = message
                            }
                        }
                        let result = try builder.applyAndLaunch(forceRebuild: forceRebuild)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            status = outcome == .fastHotUpdated
                ? L10n.t("已热更新配置并启动", "Hot-updated config & launched", lang)
                : L10n.t("已重建副本并启动", "Rebuilt runtime & launched", lang)
            bannerSuccessMessage = status
            if case .updateAvailable = mcpPluginStatus {
                let ver = appVersionText
                try? await Task.detached(priority: .utility) {
                    try McpPluginInstaller(support: currentSupport).installOrUpdate(appVersion: ver, language: lang)
                }.value
                refreshMcpPluginStatus()
            }
            isWorking = false
            refreshRuntimeStatus()
            refreshRunningInstances()

            if currentConfig.enableMenuBarMonitor {
                onLaunchComplete?()
            }
        } catch {
            errorMessage = error.localizedDescription
            status = L10n.t("准备就绪", "Ready", lang)
            isWorking = false
            refreshRunningInstances()
        }
    }

    func launchExistingRuntimeOnly() {
        let lang = config.appLanguage
        let runtime = support.runtimeApp
        guard FileManager.default.fileExists(atPath: runtime.path) else {
            errorMessage = L10n.t(
                "尚未生成代理副本，请先在「代理概览」中保存并启动。",
                "Runtime copy not built yet. Save & launch from Proxy Overview first.",
                lang
            )
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: runtime, configuration: configuration) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.errorMessage = L10n.t(
                        zhHans: "启动失败：\(error.localizedDescription)",
                        zhHant: "啟動失敗：\(error.localizedDescription)",
                        en: "Launch failed: \(error.localizedDescription)",
                        ru: "Ошибка запуска: \(error.localizedDescription)",
                        lang
                    )
                }
            }
        }
    }

    private func validate(_ config: ProxyConfig) throws {
        let lang = config.appLanguage
        let normalizedHost = config.normalizedHost
        guard !normalizedHost.isEmpty else {
            throw BuilderError.invalidPort(L10n.t("代理 host 不能为空。", "Proxy host cannot be empty.", lang))
        }
        guard ProxyConfig.isValidNumericIP(normalizedHost) else {
            throw BuilderError.invalidPort(L10n.t(
                "代理 Host 需为数字 IP（如 127.0.0.1 或 ::1）或 localhost。",
                "Proxy host must be a numeric IP (e.g. 127.0.0.1 or ::1) or localhost.",
                lang
            ))
        }
        guard (1...65535).contains(config.hookPort) else {
            throw BuilderError.invalidPort(L10n.t("SOCKS5 端口必须在 1 到 65535 之间。", "SOCKS5 port must be between 1 and 65535.", lang))
        }
        guard (1...65535).contains(config.envPort) else {
            throw BuilderError.invalidPort(L10n.t("环境变量代理端口必须在 1 到 65535 之间。", "ENV proxy port must be between 1 and 65535.", lang))
        }
        guard ["http", "socks5"].contains(config.envScheme) else {
            throw BuilderError.invalidPort(L10n.t("环境变量代理协议只能是 http 或 socks5。", "ENV proxy scheme must be http or socks5.", lang))
        }
    }
}
