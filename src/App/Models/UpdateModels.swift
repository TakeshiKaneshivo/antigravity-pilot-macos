import Foundation

struct AppVersion: Comparable, Equatable, Hashable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let preRelease: [String]
    let rawNormalized: String

    init?(_ raw: String) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty else { return nil }

        if let plusIdx = cleaned.firstIndex(of: "+") {
            cleaned = String(cleaned[..<plusIdx])
        }

        let coreString: String
        let preList: [String]
        if let dashIdx = cleaned.firstIndex(of: "-") {
            coreString = String(cleaned[..<dashIdx])
            let preRaw = String(cleaned[cleaned.index(after: dashIdx)...])
            guard !preRaw.isEmpty else { return nil }
            preList = preRaw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if preList.contains(where: { $0.isEmpty }) {
                return nil
            }
        } else {
            coreString = cleaned
            preList = []
        }

        let parts = coreString.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        var numbers: [Int] = []
        for part in parts {
            guard let val = Int(part), val >= 0 else { return nil }
            numbers.append(val)
        }

        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
        self.preRelease = preList
        if preList.isEmpty {
            self.rawNormalized = "\(self.major).\(self.minor).\(self.patch)"
        } else {
            self.rawNormalized = "\(self.major).\(self.minor).\(self.patch)-\(preList.joined(separator: "."))"
        }
    }

    var description: String {
        rawNormalized
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.preRelease.isEmpty && rhs.preRelease.isEmpty { return false }
        if lhs.preRelease.isEmpty { return false }
        if rhs.preRelease.isEmpty { return true }

        let count = max(lhs.preRelease.count, rhs.preRelease.count)
        for idx in 0..<count {
            if idx >= lhs.preRelease.count { return true }
            if idx >= rhs.preRelease.count { return false }

            let l = lhs.preRelease[idx]
            let r = rhs.preRelease[idx]
            if l == r { continue }

            let lInt = Int(l)
            let rInt = Int(r)
            switch (lInt, rInt) {
            case let (li?, ri?):
                return li < ri
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return l < r
            }
        }
        return false
    }

    static func currentOSMeets(minMacOS: String?) -> Bool {
        guard let minMacOS = minMacOS?.trimmingCharacters(in: .whitespacesAndNewlines),
              !minMacOS.isEmpty,
              let required = AppVersion(minMacOS) else {
            return true
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = OperatingSystemTuple(
            major: os.majorVersion,
            minor: os.minorVersion,
            patch: os.patchVersion
        )
        let target = OperatingSystemTuple(
            major: required.major,
            minor: required.minor,
            patch: required.patch
        )
        return current >= target
    }

    private struct OperatingSystemTuple: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: OperatingSystemTuple, rhs: OperatingSystemTuple) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }
}

struct UpdateManifest: Codable, Equatable, Sendable {
    struct DMGAsset: Codable, Equatable, Sendable {
        let fileName: String
        let url: String
        let sha256: String
        let size: Int64?
    }

    struct LocalizedNotes: Codable, Equatable, Sendable {
        let translations: [String: String]

        init(translations: [String: String]) {
            self.translations = translations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let dict = try? container.decode([String: String].self) {
                self.translations = dict
            } else if let plain = try? container.decode(String.self) {
                self.translations = ["en": plain]
            } else {
                self.translations = [:]
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(translations)
        }

        func text(for lang: AppLanguage) -> String? {
            let resolvedKey = lang.resolved.rawValue
            let candidates = [resolvedKey, "en", "zh-Hans", "zh-Hant", "ru"]
            for key in candidates {
                if let value = translations[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            for value in translations.values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }
    }

    let version: String
    let tag: String
    let publishedAt: String?
    let minMacOS: String?
    let dmg: DMGAsset
    let releasePageUrl: String?
    let notes: LocalizedNotes?

    func validate(allowInsecureHTTP: Bool) throws {
        guard AppVersion(version) != nil else {
            throw UpdateError.invalidManifest(L10n.t(
                "更新清单中的版本号无效。",
                "Invalid version in update manifest."
            ))
        }

        let trimmedFile = dmg.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFile.isEmpty,
              !trimmedFile.contains("/"),
              !trimmedFile.contains("..") else {
            throw UpdateError.invalidManifest(L10n.t(
                "更新清单中的安装包文件名无效。",
                "Invalid installer file name in update manifest."
            ))
        }

        let hex = dmg.sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValidSHA = hex.count == 64 && hex.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
        }
        guard isValidSHA else {
            throw UpdateError.invalidManifest(L10n.t(
                "更新清单中的 SHA-256 校验值格式无效。",
                "Invalid SHA-256 checksum in update manifest."
            ))
        }

        guard let dmgURL = URL(string: dmg.url),
              let scheme = dmgURL.scheme?.lowercased(),
              scheme == "https" || (allowInsecureHTTP && scheme == "http") else {
            throw UpdateError.invalidManifest(L10n.t(
                "更新包下载地址必须使用 HTTPS。",
                "Installer download URL must use HTTPS."
            ))
        }

        if let releasePageUrl, !releasePageUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let pageURL = URL(string: releasePageUrl),
                  let pageScheme = pageURL.scheme?.lowercased(),
                  pageScheme == "https" || (allowInsecureHTTP && pageScheme == "http") else {
                throw UpdateError.invalidManifest(L10n.t(
                    "Release 页面地址必须使用 HTTPS。",
                    "Release page URL must use HTTPS."
                ))
            }
        }
    }
}

enum UpdateRoute: Equatable, Sendable {
    case direct
    case localProxy(String)

    func localizedLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .direct:
            return L10n.t("系统网络直连", "Direct Connection", lang)
        case .localProxy(let endpoint):
            return L10n.t(
                zhHans: "本地代理 (\(endpoint))",
                zhHant: "本機代理 (\(endpoint))",
                en: "Local Proxy (\(endpoint))",
                ru: "Локальный прокси (\(endpoint))",
                lang
            )
        }
    }
}

enum InstallEligibility: Equatable, Sendable {
    case inPlaceSupported(targetApp: URL)
    case manualFallbackRequired(reason: String)
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date, route: UpdateRoute)
    case available(manifest: UpdateManifest, route: UpdateRoute, osSupported: Bool, eligibility: InstallEligibility)
    case downloading(manifest: UpdateManifest, downloadedBytes: Int64, totalBytes: Int64, route: UpdateRoute)
    case verifying(manifest: UpdateManifest, stage: String)
    case readyForManualInstall(manifest: UpdateManifest, dmgURL: URL, reason: String)
    case installing(manifest: UpdateManifest)
    case failed(message: String, canRetry: Bool)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing:
            return true
        case .idle, .upToDate, .available, .readyForManualInstall, .failed:
            return false
        }
    }

    var activeManifest: UpdateManifest? {
        switch self {
        case .available(let m, _, _, _),
             .downloading(let m, _, _, _),
             .verifying(let m, _),
             .readyForManualInstall(let m, _, _),
             .installing(let m):
            return m
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }
}

enum UpdateError: LocalizedError {
    case invalidManifest(String)
    case networkError(String)
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case mountFailed(String)
    case verificationFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let msg),
             .networkError(let msg),
             .mountFailed(let msg),
             .verificationFailed(let msg),
             .installFailed(let msg):
            return msg
        case .checksumMismatch(let expected, let actual):
            return L10n.t(
                zhHans: "安装包 SHA-256 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…），已自动删除损坏文件。",
                zhHant: "安裝套件 SHA-256 驗證失敗（預期 \(expected.prefix(12))…，實際 \(actual.prefix(12))…），已自動刪除損壞檔案。",
                en: "Installer SHA-256 mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…). Corrupted file deleted.",
                ru: "Несовпадение SHA-256 установщика (ожидалось \(expected.prefix(12))…, получено \(actual.prefix(12))…). Повреждённый файл удалён."
            )
        case .sizeMismatch(let expected, let actual):
            return L10n.t(
                zhHans: "安装包大小校验失败（期望 \(expected) 字节，实际 \(actual) 字节）。",
                zhHant: "安裝套件大小驗證失敗（預期 \(expected) 位元組，實際 \(actual) 位元組）。",
                en: "Installer size mismatch (expected \(expected) bytes, got \(actual) bytes).",
                ru: "Несовпадение размера установщика (ожидалось \(expected) байт, получено \(actual) байт)."
            )
        }
    }
}
