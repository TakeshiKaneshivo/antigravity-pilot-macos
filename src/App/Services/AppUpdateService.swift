import CryptoKit
import Foundation

enum AppUpdateService {
    static let defaultFeedURL = URL(string: "https://github.com/TakeshiKaneshivo/antigravity-pilot-macos/releases/latest/download/latest.json")!
    static let defaultReleasesPageURL = URL(string: "https://github.com/TakeshiKaneshivo/antigravity-pilot-macos/releases")!
    static let expectedBundleIdentifier = "com.takeshikaneshivo.antigravity-pilot.macos"

    static func resolvedFeedURL() -> (url: URL, allowInsecureHTTP: Bool) {
        if let raw = ProcessInfo.processInfo.environment["AG_PILOT_UPDATE_FEED_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw),
           let scheme = url.scheme?.lowercased() {
            let allowHTTP = (scheme == "http" && isLoopbackHost(url.host))
            if scheme == "https" || allowHTTP {
                return (url, allowHTTP)
            }
        }
        return (defaultFeedURL, false)
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let raw = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return false
        }
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return cleaned == "localhost" || cleaned == "127.0.0.1" || cleaned == "::1"
    }

    private static func makeSessionConfig(timeoutRequest: TimeInterval, timeoutResource: TimeInterval) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = timeoutRequest
        cfg.timeoutIntervalForResource = timeoutResource
        return cfg
    }

    static func candidateSessions(
        for url: URL,
        config: ProxyConfig,
        timeoutResource: TimeInterval
    ) -> [(session: URLSession, route: UpdateRoute)] {
        var result: [(URLSession, UpdateRoute)] = []
        let host = config.normalizedHost

        if !isLoopbackHost(url.host), ProxyConfig.isValidNumericIP(host) {
            if config.envScheme == "http",
               (1...65535).contains(config.envPort),
               ProxyHealthService.testTCPConnect(host: host, port: config.envPort, timeoutMs: 250) {
                let proxyCfg = makeSessionConfig(timeoutRequest: 15, timeoutResource: timeoutResource)
                proxyCfg.connectionProxyDictionary = [
                    "HTTPEnable": 1,
                    "HTTPProxy": host,
                    "HTTPPort": config.envPort,
                    "HTTPSEnable": 1,
                    "HTTPSProxy": host,
                    "HTTPSPort": config.envPort
                ]
                result.append((URLSession(configuration: proxyCfg), .localProxy("\(host):\(config.envPort)")))
            } else if (1...65535).contains(config.hookPort),
                      ProxyHealthService.testTCPConnect(host: host, port: config.hookPort, timeoutMs: 250) {
                let proxyCfg = makeSessionConfig(timeoutRequest: 15, timeoutResource: timeoutResource)
                proxyCfg.connectionProxyDictionary = [
                    "SOCKSEnable": 1,
                    "SOCKSProxy": host,
                    "SOCKSPort": config.hookPort
                ]
                result.append((URLSession(configuration: proxyCfg), .localProxy("socks5://\(host):\(config.hookPort)")))
            }
        }

        let directCfg = makeSessionConfig(timeoutRequest: 15, timeoutResource: timeoutResource)
        result.append((URLSession(configuration: directCfg), .direct))
        return result
    }

    static func fetchManifest(
        config: ProxyConfig,
        currentVersion: String,
        feedOverride: URL? = nil,
        allowInsecureHTTPOverride: Bool? = nil
    ) async throws -> (manifest: UpdateManifest, route: UpdateRoute) {
        let resolved = resolvedFeedURL()
        let feedURL = feedOverride ?? resolved.url
        let allowHTTP = allowInsecureHTTPOverride ?? (feedOverride != nil ? (feedURL.scheme?.lowercased() == "http" && isLoopbackHost(feedURL.host)) : resolved.allowInsecureHTTP)

        let candidates = candidateSessions(for: feedURL, config: config, timeoutResource: 25)
        var lastError: Error?

        for (session, route) in candidates {
            defer { session.finishTasksAndInvalidate() }
            try Task.checkCancellation()

            var request = URLRequest(url: feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Antigravity-Pilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw UpdateError.networkError(L10n.t("无效的网络响应。", "Invalid network response.", config.appLanguage))
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw UpdateError.networkError(L10n.t(
                        zhHans: "检查更新失败（HTTP \(http.statusCode)）。",
                        zhHant: "檢查更新失敗（HTTP \(http.statusCode)）。",
                        en: "Update check failed (HTTP \(http.statusCode)).",
                        ru: "Ошибка проверки обновлений (HTTP \(http.statusCode)).",
                        config.appLanguage
                    ))
                }
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                try manifest.validate(allowInsecureHTTP: allowHTTP)
                return (manifest, route)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        if let error = lastError {
            throw error
        }
        throw UpdateError.networkError(L10n.t("无法连接到更新服务器。", "Unable to reach update server.", config.appLanguage))
    }

    static func downloadAndVerifyDMG(
        manifest: UpdateManifest,
        config: ProxyConfig,
        updatesDir: URL,
        allowInsecureHTTP: Bool,
        onProgress: @Sendable @escaping (Int64, Int64, UpdateRoute) -> Void
    ) async throws -> (dmgURL: URL, route: UpdateRoute) {
        try manifest.validate(allowInsecureHTTP: allowInsecureHTTP)
        guard let downloadURL = URL(string: manifest.dmg.url) else {
            throw UpdateError.invalidManifest(L10n.t("无效的下载地址。", "Invalid download URL.", config.appLanguage))
        }

        let fm = FileManager.default
        let versionDir = updatesDir.appendingPathComponent("v\(manifest.version)", isDirectory: true)
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let finalURL = versionDir.appendingPathComponent(manifest.dmg.fileName)
        let partURL = versionDir.appendingPathComponent("\(manifest.dmg.fileName).part")

        if fm.fileExists(atPath: finalURL.path),
           let cachedSize = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
           (manifest.dmg.size == nil || manifest.dmg.size == cachedSize),
           let cachedSHA = sha256File(finalURL),
           cachedSHA.caseInsensitiveCompare(manifest.dmg.sha256) == .orderedSame {
            return (finalURL, .direct)
        }

        let candidates = candidateSessions(for: downloadURL, config: config, timeoutResource: 600)
        var lastError: Error?

        for (session, route) in candidates {
            defer { session.finishTasksAndInvalidate() }
            try Task.checkCancellation()
            try? fm.removeItem(at: partURL)

            var request = URLRequest(url: downloadURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Antigravity-Pilot/\(manifest.version)", forHTTPHeaderField: "User-Agent")

            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw UpdateError.networkError(L10n.t("下载响应无效。", "Invalid download response.", config.appLanguage))
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw UpdateError.networkError(L10n.t(
                        zhHans: "下载安装包失败（HTTP \(http.statusCode)）。",
                        zhHant: "下載安裝套件失敗（HTTP \(http.statusCode)）。",
                        en: "Download failed (HTTP \(http.statusCode)).",
                        ru: "Ошибка загрузки установщика (HTTP \(http.statusCode)).",
                        config.appLanguage
                    ))
                }

                let expectedTotal = http.expectedContentLength > 0
                    ? http.expectedContentLength
                    : (manifest.dmg.size ?? 0)

                fm.createFile(atPath: partURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: partURL)
                var hasher = SHA256()
                var downloaded: Int64 = 0
                var buffer: [UInt8] = []
                buffer.reserveCapacity(65536)
                var lastReportNs = DispatchTime.now().uptimeNanoseconds

                do {
                    onProgress(0, expectedTotal, route)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count >= 65536 {
                            let chunk = Data(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            try handle.write(contentsOf: chunk)
                            hasher.update(data: chunk)
                            downloaded += Int64(chunk.count)

                            let now = DispatchTime.now().uptimeNanoseconds
                            if now - lastReportNs >= 80_000_000 {
                                lastReportNs = now
                                onProgress(downloaded, expectedTotal, route)
                            }
                        }
                    }

                    if !buffer.isEmpty {
                        let chunk = Data(buffer)
                        try handle.write(contentsOf: chunk)
                        hasher.update(data: chunk)
                        downloaded += Int64(chunk.count)
                    }
                    try handle.close()
                    onProgress(downloaded, max(expectedTotal, downloaded), route)
                } catch {
                    try? handle.close()
                    try? fm.removeItem(at: partURL)
                    throw error
                }

                if let expectedSize = manifest.dmg.size, expectedSize > 0, downloaded != expectedSize {
                    try? fm.removeItem(at: partURL)
                    throw UpdateError.sizeMismatch(expected: expectedSize, actual: downloaded)
                }

                let actualSHA = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard actualSHA.caseInsensitiveCompare(manifest.dmg.sha256) == .orderedSame else {
                    try? fm.removeItem(at: partURL)
                    throw UpdateError.checksumMismatch(expected: manifest.dmg.sha256, actual: actualSHA)
                }

                try? fm.removeItem(at: finalURL)
                try fm.moveItem(at: partURL, to: finalURL)
                return (finalURL, route)
            } catch is CancellationError {
                try? fm.removeItem(at: partURL)
                throw CancellationError()
            } catch {
                try? fm.removeItem(at: partURL)
                lastError = error
            }
        }

        if let error = lastError {
            throw error
        }
        throw UpdateError.networkError(L10n.t("下载失败。", "Download failed.", config.appLanguage))
    }

    static func checkInstallEligibility(
        bundleURL: URL = Bundle.main.bundleURL,
        lang: AppLanguage = L10n.current
    ) -> InstallEligibility {
        let standardized = bundleURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "app" else {
            return .manualFallbackRequired(reason: L10n.t(
                "当前以开发二进制方式运行，请下载安装包后手动覆盖 /Applications 中的应用。",
                "Running outside an .app bundle; download the DMG and install manually.",
                lang
            ))
        }

        if standardized.path.contains("/AppTranslocation/") {
            return .manualFallbackRequired(reason: L10n.t(
                "当前应用运行在 macOS 安全隔离路径（App Translocation）下，请打开下载的 DMG 并拖入 /Applications。",
                "App is running under macOS App Translocation; open the downloaded DMG and drag to /Applications.",
                lang
            ))
        }

        let values = try? standardized.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true {
            return .manualFallbackRequired(reason: L10n.t(
                "当前应用正从只读磁盘映像中运行，请打开下载的 DMG 并拖入 /Applications。",
                "App is running from a read-only volume; open the downloaded DMG and drag to /Applications.",
                lang
            ))
        }

        let fm = FileManager.default
        let parentDir = standardized.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parentDir.path),
              fm.isWritableFile(atPath: standardized.path) else {
            return .manualFallbackRequired(reason: L10n.t(
                "当前账户对应用所在目录没有写权限，请打开下载的 DMG 并手动拖入 /Applications。",
                "Current user lacks write permission for the app directory; open the DMG and install manually.",
                lang
            ))
        }

        return .inPlaceSupported(targetApp: standardized)
    }

    static func prepareAndLaunchInPlaceUpdate(
        dmgURL: URL,
        manifest: UpdateManifest,
        targetAppURL: URL,
        updatesDir: URL,
        lang: AppLanguage,
        onStage: @Sendable @escaping (String) -> Void
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: updatesDir, withIntermediateDirectories: true)

        onStage(L10n.t("正在挂载安装包...", "Mounting installer image...", lang))
        let mountPoint = try attachDMG(at: dmgURL, lang: lang)
        defer { detachDMG(at: mountPoint) }

        let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true)
        guard let sourceApp = findPilotApp(in: mountURL) else {
            throw UpdateError.mountFailed(L10n.t(
                "安装包内未找到 Antigravity Pilot.app。",
                "Antigravity Pilot.app not found inside installer DMG.",
                lang
            ))
        }

        let stagingRoot = updatesDir.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagedApp = stagingRoot.appendingPathComponent("Antigravity Pilot.app", isDirectory: true)

        onStage(L10n.t("正在提取新版应用...", "Extracting new app bundle...", lang))
        try runProcess("/usr/bin/ditto", [sourceApp.path, stagedApp.path])

        onStage(L10n.t("正在校验应用签名与版本...", "Verifying app signature & version...", lang))
        let plistURL = stagedApp.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            try? fm.removeItem(at: stagingRoot)
            throw UpdateError.verificationFailed(L10n.t("无法读取新版 Info.plist。", "Unable to read Info.plist of new app.", lang))
        }

        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? ""
        guard bundleID == expectedBundleIdentifier else {
            try? fm.removeItem(at: stagingRoot)
            throw UpdateError.verificationFailed(L10n.t(
                zhHans: "新版应用 Bundle ID 不匹配（\(bundleID)）。",
                zhHant: "新版應用 Bundle ID 不符（\(bundleID)）。",
                en: "Unexpected Bundle ID in update (\(bundleID)).",
                ru: "Неожиданный Bundle ID в обновлении (\(bundleID)).",
                lang
            ))
        }

        let extractedVersion = ((plist["CFBundleShortVersionString"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let vExtracted = AppVersion(extractedVersion),
           let vExpected = AppVersion(manifest.version),
           vExtracted != vExpected {
            try? fm.removeItem(at: stagingRoot)
            throw UpdateError.verificationFailed(L10n.t(
                zhHans: "新版版本号不匹配（预期 \(manifest.version)，实际 \(extractedVersion)）。",
                zhHant: "新版版本號不符（預期 \(manifest.version)，實際 \(extractedVersion)）。",
                en: "Version mismatch in extracted app (expected \(manifest.version), got \(extractedVersion)).",
                ru: "Несовпадение версии в образе (ожидалось \(manifest.version), получено \(extractedVersion)).",
                lang
            ))
        }

        _ = try? runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path], allowFailure: true)

        do {
            try runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
        } catch {
            try? fm.removeItem(at: stagingRoot)
            throw UpdateError.verificationFailed(L10n.t(
                "新版应用代码签名校验失败，已取消替换。",
                "New app code signature verification failed; update aborted.",
                lang
            ))
        }

        onStage(L10n.t("正在替换并重启应用...", "Replacing app and relaunching...", lang))

        let scriptURL = stagingRoot.appendingPathComponent("apply-update.sh")
        let logURL = updatesDir.appendingPathComponent("last-update.log")
        let scriptBody = """
        #!/usr/bin/env bash
        set -uo pipefail
        OLD_PID="$1"
        TARGET_APP="$2"
        STAGED_APP="$3"
        STAGING_ROOT="$4"
        LOG_FILE="$5"

        exec >"$LOG_FILE" 2>&1
        echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting update for pid=$OLD_PID target=$TARGET_APP"

        for _ in $(seq 1 150); do
          if ! /bin/kill -0 "$OLD_PID" 2>/dev/null; then
            break
          fi
          /bin/sleep 0.1
        done
        /bin/sleep 0.3

        PARENT_DIR="$(/usr/bin/dirname "$TARGET_APP")"
        BACKUP_APP="$PARENT_DIR/.Antigravity-Pilot.app.backup-$$"
        OLD_ICON_SHA=""
        NEW_ICON_SHA="$(/usr/bin/shasum -a 256 "$STAGED_APP/Contents/Resources/antigravity-pilot.icns" 2>/dev/null | /usr/bin/awk '{print $1}' || true)"

        if [[ -e "$TARGET_APP" ]]; then
          OLD_ICON_SHA="$(/usr/bin/shasum -a 256 "$TARGET_APP/Contents/Resources/antigravity-pilot.icns" 2>/dev/null | /usr/bin/awk '{print $1}' || true)"
          if ! /bin/mv "$TARGET_APP" "$BACKUP_APP"; then
            echo "Failed to move target app to backup"
            /usr/bin/open "$TARGET_APP" || true
            exit 1
          fi
        fi

        if ! /bin/mv "$STAGED_APP" "$TARGET_APP"; then
          echo "Failed to move staged app into target; rolling back"
          if [[ -e "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
            /bin/mv "$BACKUP_APP" "$TARGET_APP" || true
          fi
          /usr/bin/open "$TARGET_APP" || true
          exit 1
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
        /usr/bin/touch "$TARGET_APP" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true
        LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if [[ -x "$LSREGISTER" ]]; then
          "$LSREGISTER" -f "$TARGET_APP" 2>/dev/null || true
          if [[ -n "$OLD_ICON_SHA" && -n "$NEW_ICON_SHA" && "$OLD_ICON_SHA" != "$NEW_ICON_SHA" ]]; then
            "$LSREGISTER" -f -R "$TARGET_APP" 2>/dev/null || true
          fi
        fi

        if [[ -e "$BACKUP_APP" ]]; then
          /bin/rm -rf "$BACKUP_APP" || true
        fi
        /bin/rm -rf "$STAGING_ROOT" || true

        echo "Update complete; relaunching $TARGET_APP"
        /usr/bin/open "$TARGET_APP"
        """
        try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: scriptURL.path)

        let pidText = String(ProcessInfo.processInfo.processIdentifier)
        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        launchProcess.arguments = [
            "-c",
            "nohup /bin/bash \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" </dev/null >/dev/null 2>&1 &",
            "spawn-updater",
            scriptURL.path,
            pidText,
            targetAppURL.path,
            stagedApp.path,
            stagingRoot.path,
            logURL.path
        ]
        launchProcess.standardInput = FileHandle.nullDevice
        launchProcess.standardOutput = FileHandle.nullDevice
        launchProcess.standardError = FileHandle.nullDevice
        try launchProcess.run()
        launchProcess.waitUntilExit()

        guard launchProcess.terminationStatus == 0 else {
            throw UpdateError.installFailed(L10n.t("无法启动更新替换进程。", "Failed to launch update helper.", lang))
        }
    }

    static func refreshBundleIconCacheIfChanged(
        bundleURL: URL = Bundle.main.bundleURL,
        support: AppSupport = AppSupport(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        let standardized = bundleURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "app" else { return false }

        let icnsURL = standardized.appendingPathComponent("Contents/Resources/antigravity-pilot.icns")
        guard let currentHash = sha256File(icnsURL) else { return false }

        let key = "pilot.lastBundledIconSHA256"
        let previousHash = defaults.string(forKey: key)
        if previousHash == currentHash {
            return false
        }
        defaults.set(currentHash, forKey: key)

        let isExistingUserUpgrade = (previousHash != nil) || FileManager.default.fileExists(atPath: support.configURL.path)
        guard isExistingUserUpgrade else { return false }

        _ = try? runProcess(
            "/usr/bin/touch",
            [standardized.path, standardized.appendingPathComponent("Contents/Info.plist").path],
            allowFailure: true
        )

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister) {
            _ = try? runProcess(lsregister, ["-f", standardized.path], allowFailure: true)
        }

        if isAppPinnedInDock(bundleURL: standardized) {
            _ = try? runProcess("/usr/bin/killall", ["Dock"], allowFailure: true)
        }
        return true
    }

    private static func isAppPinnedInDock(bundleURL: URL) -> Bool {
        guard let persistentApps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return false
        }
        let plainName = bundleURL.lastPathComponent
        let encodedName = plainName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? plainName
        for item in persistentApps {
            guard let tileData = item["tile-data"] as? [String: Any] else { continue }
            if let bundleID = tileData["bundle-identifier"] as? String, bundleID == expectedBundleIdentifier {
                return true
            }
            if let fileData = tileData["file-data"] as? [String: Any],
               let urlString = fileData["_CFURLString"] as? String,
               urlString.contains(plainName) || urlString.contains(encodedName) {
                return true
            }
        }
        return false
    }

    static func cleanupStaleUpdateFiles(in updatesDir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: updatesDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for item in items {
            let name = item.lastPathComponent
            if name == "last-update.log" { continue }
            if name.hasPrefix("staging-") || name.hasSuffix(".part") {
                try? fm.removeItem(at: item)
                continue
            }
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey])
            if let mtime = values?.contentModificationDate, mtime < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    private static func attachDMG(at dmgURL: URL, lang: AppLanguage) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmgURL.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: outData, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw UpdateError.mountFailed(L10n.t(
                zhHans: "挂载 DMG 失败：\(errText)",
                zhHant: "掛載 DMG 失敗：\(errText)",
                en: "Failed to mount DMG: \(errText)",
                ru: "Ошибка монтирования DMG: \(errText)",
                lang
            ))
        }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
        }
        throw UpdateError.mountFailed(L10n.t("未找到 DMG 挂载点。", "DMG mount point not found.", lang))
    }

    private static func detachDMG(at mountPoint: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["detach", mountPoint, "-quiet"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let force = Process()
            force.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            force.arguments = ["detach", mountPoint, "-force", "-quiet"]
            force.standardOutput = FileHandle.nullDevice
            force.standardError = FileHandle.nullDevice
            try? force.run()
            force.waitUntilExit()
        }
    }

    private static func findPilotApp(in mountURL: URL) -> URL? {
        let fm = FileManager.default
        let preferred = mountURL.appendingPathComponent("Antigravity Pilot.app", isDirectory: true)
        if fm.fileExists(atPath: preferred.path) {
            return preferred
        }
        guard let children = try? fm.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        for child in children where child.pathExtension.lowercased() == "app" {
            let plistURL = child.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               (plist["CFBundleIdentifier"] as? String) == expectedBundleIdentifier {
                return child
            }
        }
        return nil
    }

    @discardableResult
    private static func runProcess(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 && !allowFailure {
            throw UpdateError.installFailed("\(executable) \(arguments.joined(separator: " "))\n\(output)")
        }
        return output
    }

    private static func sha256File(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 65536)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
