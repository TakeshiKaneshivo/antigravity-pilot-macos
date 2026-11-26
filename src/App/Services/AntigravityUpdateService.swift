import CryptoKit
import Darwin
import Foundation

enum AntigravityUpdateService {
    static let defaultFeedBaseURL = URL(string: "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/")!
    static let expectedBundleIdentifier = "com.google.antigravity"
    static let expectedCodeSignRequirement = "identifier \"com.google.antigravity\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = EQHXZ8M8AV"

    static func detectIsArm64Mac() -> Bool {
        #if arch(arm64)
        return true
        #else
        var isArm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &isArm64, &size, nil, 0) == 0 && isArm64 == 1 {
            return true
        }
        var translated: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1 {
            return true
        }
        return false
        #endif
    }

    static func channelFileName(isArm64: Bool = detectIsArm64Mac()) -> String {
        isArm64 ? "latest-arm64-mac.yml" : "latest-x64-mac.yml"
    }

    static func readFeedBaseURL(from sourceApp: URL) -> URL {
        let ymlURL = sourceApp.appendingPathComponent("Contents/Resources/app-update.yml")
        guard let text = try? String(contentsOf: ymlURL, encoding: .utf8) else {
            return defaultFeedBaseURL
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = stripYAMLComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colonIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "url" else { continue }
            let rawVal = stripYAMLQuotes(String(trimmed[trimmed.index(after: colonIdx)...]))
            guard !rawVal.isEmpty, let parsed = URL(string: rawVal), parsed.scheme?.lowercased() == "https" else {
                continue
            }
            if rawVal.hasSuffix("/") {
                return parsed
            }
            return URL(string: rawVal + "/") ?? parsed
        }

        return defaultFeedBaseURL
    }

    static func resolvedFeedURL(
        from sourceApp: URL,
        isArm64: Bool = detectIsArm64Mac()
    ) -> (url: URL, allowInsecureHTTP: Bool) {
        if let raw = ProcessInfo.processInfo.environment["AG_PILOT_ANTIGRAVITY_FEED_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw),
           let scheme = url.scheme?.lowercased() {
            let allowHTTP = (scheme == "http" && AppUpdateService.isLoopbackHost(url.host))
            if scheme == "https" || allowHTTP {
                return (url, allowHTTP)
            }
        }

        let base = readFeedBaseURL(from: sourceApp)
        let channelURL = base.appendingPathComponent(channelFileName(isArm64: isArm64))
        return (channelURL, false)
    }

    private struct ParsedYAMLFile {
        var url: String = ""
        var sha512: String = ""
        var size: Int64?
    }

    static func parseElectronUpdaterYAML(
        _ yaml: String,
        baseURL: URL,
        isArm64: Bool,
        allowInsecureHTTP: Bool = false,
        lang: AppLanguage = L10n.current
    ) throws -> AntigravityUpdateManifest {
        var version = ""
        var topPath = ""
        var topSha512 = ""
        var releaseDate: String?
        var files: [ParsedYAMLFile] = []
        var inFilesBlock = false
        var currentFile: ParsedYAMLFile?

        func flushCurrentFile() {
            if let item = currentFile, (!item.url.isEmpty || !item.sha512.isEmpty || item.size != nil) {
                files.append(item)
            }
            currentFile = nil
        }

        for rawLine in yaml.components(separatedBy: .newlines) {
            let noComment = stripYAMLComment(rawLine)
            let trimmed = noComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let leadingSpaces = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            if leadingSpaces == 0 && !trimmed.hasPrefix("-") {
                flushCurrentFile()
                inFilesBlock = false

                guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
                let key = trimmed[..<colonIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                let val = stripYAMLQuotes(String(trimmed[trimmed.index(after: colonIdx)...]))

                switch key {
                case "version":
                    version = val
                case "path":
                    topPath = val
                case "sha512":
                    topSha512 = val
                case "releaseDate":
                    releaseDate = val.isEmpty ? nil : val
                case "files":
                    inFilesBlock = true
                default:
                    break
                }
                continue
            }

            if inFilesBlock {
                if trimmed.hasPrefix("-") {
                    flushCurrentFile()
                    var item = ParsedYAMLFile()
                    let afterDash = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if let colonIdx = afterDash.firstIndex(of: ":") {
                        let k = afterDash[..<colonIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                        let v = stripYAMLQuotes(String(afterDash[afterDash.index(after: colonIdx)...]))
                        assignFileField(&item, key: k, value: v)
                    }
                    currentFile = item
                } else if var item = currentFile, let colonIdx = trimmed.firstIndex(of: ":") {
                    let k = trimmed[..<colonIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                    let v = stripYAMLQuotes(String(trimmed[trimmed.index(after: colonIdx)...]))
                    assignFileField(&item, key: k, value: v)
                    currentFile = item
                }
            }
        }
        flushCurrentFile()

        let selectedFile: ParsedYAMLFile? = {
            let zipFiles = files.filter { isZipPath($0.url) }
            let pool = zipFiles.isEmpty ? files : zipFiles
            guard !pool.isEmpty else { return nil }

            let isArm64Entry: (ParsedYAMLFile) -> Bool = { item in
                item.url.lowercased().contains("arm64")
            }
            if isArm64, let armMatch = pool.first(where: isArm64Entry) {
                return armMatch
            }
            if !isArm64, let x64Match = pool.first(where: { !isArm64Entry($0) }) {
                return x64Match
            }
            return pool.first
        }()

        let rawURL = (selectedFile?.url.isEmpty == false ? selectedFile!.url : topPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sha512 = (selectedFile?.sha512.isEmpty == false ? selectedFile!.sha512 : topSha512)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawURL.isEmpty,
              let resolvedURL = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL else {
            throw AntigravityUpdateError.invalidManifest(L10n.t(
                "Antigravity 更新清单缺少下载地址。",
                "Antigravity update manifest is missing a download URL.",
                lang
            ))
        }

        let fileName: String = {
            let last = resolvedURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !last.isEmpty && last != "/" {
                return last
            }
            return "Antigravity.zip"
        }()

        let manifest = AntigravityUpdateManifest(
            version: version,
            downloadURL: resolvedURL.absoluteString,
            fileName: fileName,
            sha512Base64: sha512,
            size: selectedFile?.size,
            releaseDate: releaseDate
        )
        try manifest.validate(allowInsecureHTTP: allowInsecureHTTP, lang: lang)
        return manifest
    }

    static func fetchManifest(
        sourceApp: URL,
        installedVersion: String,
        config: ProxyConfig,
        feedOverride: URL? = nil,
        allowInsecureHTTPOverride: Bool? = nil,
        isArm64: Bool = detectIsArm64Mac()
    ) async throws -> (manifest: AntigravityUpdateManifest, route: UpdateRoute) {
        let resolved = resolvedFeedURL(from: sourceApp, isArm64: isArm64)
        let feedURL = feedOverride ?? resolved.url
        let allowHTTP = allowInsecureHTTPOverride ?? (
            feedOverride != nil
                ? (feedURL.scheme?.lowercased() == "http" && AppUpdateService.isLoopbackHost(feedURL.host))
                : resolved.allowInsecureHTTP
        )

        let pilotVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.1.0"
        let candidates = AppUpdateService.candidateSessions(for: feedURL, config: config, timeoutResource: 25)
        var lastError: Error?

        for (session, route) in candidates {
            defer { session.finishTasksAndInvalidate() }
            try Task.checkCancellation()

            var request = URLRequest(url: feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Antigravity-Pilot/\(pilotVersion)", forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if !installedVersion.isEmpty {
                request.setValue(installedVersion, forHTTPHeaderField: "x-app-version")
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AntigravityUpdateError.networkError(L10n.t(
                        "无效的网络响应。",
                        "Invalid network response.",
                        config.appLanguage
                    ))
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw AntigravityUpdateError.networkError(L10n.t(
                        zhHans: "检查 Antigravity 更新失败（HTTP \(http.statusCode)）。",
                        zhHant: "檢查 Antigravity 更新失敗（HTTP \(http.statusCode)）。",
                        en: "Antigravity update check failed (HTTP \(http.statusCode)).",
                        ru: "Ошибка проверки обновлений Antigravity (HTTP \(http.statusCode)).",
                        config.appLanguage
                    ))
                }
                guard let yamlText = String(data: data, encoding: .utf8) else {
                    throw AntigravityUpdateError.invalidManifest(L10n.t(
                        "无法解码 Antigravity 更新清单。",
                        "Unable to decode Antigravity update manifest.",
                        config.appLanguage
                    ))
                }

                let manifest = try parseElectronUpdaterYAML(
                    yamlText,
                    baseURL: feedURL.deletingLastPathComponent(),
                    isArm64: isArm64,
                    allowInsecureHTTP: allowHTTP,
                    lang: config.appLanguage
                )
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
        throw AntigravityUpdateError.networkError(L10n.t(
            "无法连接到 Antigravity 更新服务器。",
            "Unable to reach Antigravity update server.",
            config.appLanguage
        ))
    }

    static func downloadAndVerifyZip(
        manifest: AntigravityUpdateManifest,
        config: ProxyConfig,
        updatesDir: URL,
        sharedPendingZipURL: URL?,
        allowInsecureHTTP: Bool,
        onProgress: @Sendable @escaping (Int64, Int64, UpdateRoute) -> Void
    ) async throws -> (zipURL: URL, route: UpdateRoute) {
        try manifest.validate(allowInsecureHTTP: allowInsecureHTTP, lang: config.appLanguage)
        guard let downloadURL = URL(string: manifest.downloadURL) else {
            throw AntigravityUpdateError.invalidManifest(L10n.t(
                "无效的下载地址。",
                "Invalid download URL.",
                config.appLanguage
            ))
        }

        let fm = FileManager.default
        let versionDir = updatesDir.appendingPathComponent("v\(manifest.version)", isDirectory: true)
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let finalURL = versionDir.appendingPathComponent(manifest.fileName)
        let partURL = versionDir.appendingPathComponent("\(manifest.fileName).part")

        if matchesVerifiedZip(at: finalURL, manifest: manifest) {
            return (finalURL, .direct)
        }

        if let sharedPendingZipURL,
           sharedPendingZipURL.standardizedFileURL != finalURL.standardizedFileURL,
           matchesVerifiedZip(at: sharedPendingZipURL, manifest: manifest) {
            try? fm.removeItem(at: partURL)
            try fm.copyItem(at: sharedPendingZipURL, to: partURL)
            try? fm.removeItem(at: finalURL)
            try fm.moveItem(at: partURL, to: finalURL)
            return (finalURL, .direct)
        }

        let candidates = AppUpdateService.candidateSessions(for: downloadURL, config: config, timeoutResource: 900)
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
                    throw AntigravityUpdateError.networkError(L10n.t(
                        "下载响应无效。",
                        "Invalid download response.",
                        config.appLanguage
                    ))
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw AntigravityUpdateError.networkError(L10n.t(
                        zhHans: "下载 Antigravity 更新包失败（HTTP \(http.statusCode)）。",
                        zhHant: "下載 Antigravity 更新套件失敗（HTTP \(http.statusCode)）。",
                        en: "Antigravity download failed (HTTP \(http.statusCode)).",
                        ru: "Ошибка загрузки Antigravity (HTTP \(http.statusCode)).",
                        config.appLanguage
                    ))
                }

                let expectedTotal = http.expectedContentLength > 0
                    ? http.expectedContentLength
                    : (manifest.size ?? 0)

                fm.createFile(atPath: partURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: partURL)
                var hasher = SHA512()
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

                if let expectedSize = manifest.size, expectedSize > 0, downloaded != expectedSize {
                    try? fm.removeItem(at: partURL)
                    throw AntigravityUpdateError.sizeMismatch(expected: expectedSize, actual: downloaded)
                }

                let actualSHA = Data(hasher.finalize()).base64EncodedString()
                guard actualSHA == manifest.sha512Base64.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    try? fm.removeItem(at: partURL)
                    throw AntigravityUpdateError.checksumMismatch(
                        expected: manifest.sha512Base64,
                        actual: actualSHA
                    )
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
        throw AntigravityUpdateError.networkError(L10n.t("下载失败。", "Download failed.", config.appLanguage))
    }

    static func checkInstallEligibility(
        sourceApp: URL,
        lang: AppLanguage = L10n.current
    ) -> AntigravityInstallEligibility {
        let standardized = sourceApp.standardizedFileURL
        let parentDir = standardized.deletingLastPathComponent()
        let parentValues = try? parentDir.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if parentValues?.volumeIsReadOnly == true {
            return .manualFallbackRequired(reason: L10n.t(
                "目标目录所在卷为只读文件系统，请下载后手动拖入 /Applications。",
                "Target volume is read-only; install the downloaded package into /Applications manually.",
                lang
            ))
        }

        let fm = FileManager.default
        let targetWritable = !fm.fileExists(atPath: standardized.path) || fm.isWritableFile(atPath: standardized.path)
        guard fm.isWritableFile(atPath: parentDir.path), targetWritable else {
            return .manualFallbackRequired(reason: L10n.t(
                "当前账户对 /Applications/Antigravity.app 没有写权限，下载校验后请手动拖入 /Applications 并回 Pilot 重建。",
                "Current user lacks write permission for /Applications/Antigravity.app; move it to /Applications manually and rebuild in Pilot.",
                lang
            ))
        }

        return .inPlaceSupported(targetApp: standardized)
    }

    static func extractAndVerifyApp(
        zipURL: URL,
        manifest: AntigravityUpdateManifest,
        stagingRoot: URL,
        requireOfficialSignature: Bool = true,
        lang: AppLanguage = L10n.current
    ) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingRoot)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        do {
            try runProcess("/usr/bin/ditto", ["-xk", zipURL.path, stagingRoot.path])
        } catch {
            try? fm.removeItem(at: stagingRoot)
            throw AntigravityUpdateError.extractionFailed(L10n.t(
                zhHans: "解压 Antigravity 更新包失败：\(error.localizedDescription)",
                zhHant: "解壓 Antigravity 更新套件失敗：\(error.localizedDescription)",
                en: "Failed to extract Antigravity archive: \(error.localizedDescription)",
                ru: "Ошибка распаковки архива Antigravity: \(error.localizedDescription)",
                lang
            ))
        }

        guard let stagedApp = findAntigravityApp(in: stagingRoot) else {
            try? fm.removeItem(at: stagingRoot)
            throw AntigravityUpdateError.extractionFailed(L10n.t(
                "更新包内未找到 Antigravity.app。",
                "Antigravity.app not found inside extracted archive.",
                lang
            ))
        }

        _ = try? runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path], allowFailure: true)

        let plistURL = stagedApp.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            try? fm.removeItem(at: stagingRoot)
            throw AntigravityUpdateError.verificationFailed(L10n.t(
                "无法读取新版 Antigravity Info.plist。",
                "Unable to read Info.plist of new Antigravity bundle.",
                lang
            ))
        }

        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? ""
        guard bundleID == expectedBundleIdentifier else {
            try? fm.removeItem(at: stagingRoot)
            throw AntigravityUpdateError.verificationFailed(L10n.t(
                zhHans: "新版 Antigravity Bundle ID 不匹配（\(bundleID)）。",
                zhHant: "新版 Antigravity Bundle ID 不符（\(bundleID)）。",
                en: "Unexpected Bundle ID in Antigravity update (\(bundleID)).",
                ru: "Неожиданный Bundle ID в обновлении Antigravity (\(bundleID)).",
                lang
            ))
        }

        let extractedVersion = ((plist["CFBundleShortVersionString"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let vExtracted = AppVersion(extractedVersion),
           let vExpected = AppVersion(manifest.version),
           vExtracted != vExpected {
            try? fm.removeItem(at: stagingRoot)
            throw AntigravityUpdateError.verificationFailed(L10n.t(
                zhHans: "新版 Antigravity 版本号不匹配（预期 \(manifest.version)，实际 \(extractedVersion)）。",
                zhHant: "新版 Antigravity 版本號不符（預期 \(manifest.version)，實際 \(extractedVersion)）。",
                en: "Version mismatch in extracted Antigravity (expected \(manifest.version), got \(extractedVersion)).",
                ru: "Несовпадение версии Antigravity (ожидалось \(manifest.version), получено \(extractedVersion)).",
                lang
            ))
        }

        if requireOfficialSignature {
            do {
                try runProcess("/usr/bin/codesign", [
                    "--verify",
                    "--deep",
                    "--strict",
                    "-R=\(expectedCodeSignRequirement)",
                    stagedApp.path
                ])
            } catch {
                try? fm.removeItem(at: stagingRoot)
                throw AntigravityUpdateError.verificationFailed(L10n.t(
                    "新版 Antigravity 未通过 Google LLC 官方代码签名校验，已中止更新。",
                    "New Antigravity failed Google LLC official signature verification; update aborted.",
                    lang
                ))
            }
        }

        return stagedApp
    }

    static func atomicallyReplaceSourceApp(
        stagedApp: URL,
        targetApp: URL,
        lang: AppLanguage = L10n.current
    ) throws {
        let fm = FileManager.default
        let parentDir = targetApp.deletingLastPathComponent()
        let backupApp = parentDir.appendingPathComponent(".Antigravity.app.backup-\(UUID().uuidString)", isDirectory: true)
        var movedToBackup = false

        do {
            if fm.fileExists(atPath: targetApp.path) {
                try fm.moveItem(at: targetApp, to: backupApp)
                movedToBackup = true
            }
            try fm.moveItem(at: stagedApp, to: targetApp)
        } catch {
            if movedToBackup && !fm.fileExists(atPath: targetApp.path) {
                try? fm.moveItem(at: backupApp, to: targetApp)
            }
            throw AntigravityUpdateError.installFailed(L10n.t(
                zhHans: "替换原版 Antigravity 失败（已回滚）：\(error.localizedDescription)",
                zhHant: "替換原版 Antigravity 失敗（已回復）：\(error.localizedDescription)",
                en: "Failed to replace original Antigravity (rolled back): \(error.localizedDescription)",
                ru: "Не удалось заменить оригинальный Antigravity (откат выполнен): \(error.localizedDescription)",
                lang
            ))
        }

        if movedToBackup {
            try? fm.removeItem(at: backupApp)
        }
        _ = try? runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", targetApp.path], allowFailure: true)
        _ = try? runProcess("/usr/bin/touch", [targetApp.path, targetApp.appendingPathComponent("Contents/Info.plist").path], allowFailure: true)
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if fm.isExecutableFile(atPath: lsregister) {
            _ = try? runProcess(lsregister, ["-f", targetApp.path], allowFailure: true)
        }
    }

    static func cleanupStaleFiles(in updatesDir: URL) {
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

    private static func matchesVerifiedZip(at url: URL, manifest: AntigravityUpdateManifest) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        if let expectedSize = manifest.size, expectedSize > 0 {
            let actualSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if actualSize != expectedSize {
                return false
            }
        }
        guard let sha = sha512Base64File(url) else { return false }
        return sha == manifest.sha512Base64.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sha512Base64File(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA512()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 65536)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        return Data(hasher.finalize()).base64EncodedString()
    }

    private static func findAntigravityApp(in root: URL) -> URL? {
        let fm = FileManager.default
        let preferred = root.appendingPathComponent("Antigravity.app", isDirectory: true)
        if fm.fileExists(atPath: preferred.path) {
            return preferred
        }
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
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

    private static func assignFileField(_ item: inout ParsedYAMLFile, key: String, value: String) {
        switch key {
        case "url":
            item.url = value
        case "sha512":
            item.sha512 = value
        case "size":
            item.size = Int64(value)
        default:
            break
        }
    }

    private static func isZipPath(_ rawURL: String) -> Bool {
        let lower = rawURL.lowercased()
        let pathOnly = lower.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lower
        return pathOnly.hasSuffix(".zip")
    }

    private static func stripYAMLComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        for (idx, ch) in line.enumerated() {
            if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch == "#" && !inSingle && !inDouble {
                if idx == 0 { return "" }
                let prevIdx = line.index(line.startIndex, offsetBy: idx - 1)
                if line[prevIdx].isWhitespace {
                    return String(line[..<line.index(line.startIndex, offsetBy: idx)])
                }
            }
        }
        return line
    }

    private static func stripYAMLQuotes(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
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
            throw AntigravityUpdateError.installFailed("\(executable) \(arguments.joined(separator: " "))\n\(output)")
        }
        return output
    }
}
