import Foundation

struct AntigravityUpdateManifest: Equatable, Sendable {
    let version: String
    let downloadURL: String
    let fileName: String
    let sha512Base64: String
    let size: Int64?
    let releaseDate: String?

    func validate(allowInsecureHTTP: Bool, lang: AppLanguage = L10n.current) throws {
        guard AppVersion(version) != nil else {
            throw AntigravityUpdateError.invalidManifest(L10n.t(
                "Antigravity 更新清单中的版本号无效。",
                "Invalid version in Antigravity update manifest.",
                lang
            ))
        }

        let trimmedFile = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFile.isEmpty,
              !trimmedFile.contains("/"),
              !trimmedFile.contains("..") else {
            throw AntigravityUpdateError.invalidManifest(L10n.t(
                "Antigravity 更新清单中的安装包文件名无效。",
                "Invalid installer file name in Antigravity update manifest.",
                lang
            ))
        }

        let trimmedSHA = sha512Base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: trimmedSHA), decoded.count == 64 else {
            throw AntigravityUpdateError.invalidManifest(L10n.t(
                "Antigravity 更新清单中的 SHA-512 校验值格式无效。",
                "Invalid SHA-512 checksum in Antigravity update manifest.",
                lang
            ))
        }

        guard let url = URL(string: downloadURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (allowInsecureHTTP && scheme == "http") else {
            throw AntigravityUpdateError.invalidManifest(L10n.t(
                "Antigravity 更新包下载地址必须使用 HTTPS。",
                "Antigravity download URL must use HTTPS.",
                lang
            ))
        }
    }
}

enum AntigravityInstallEligibility: Equatable, Sendable {
    case inPlaceSupported(targetApp: URL)
    case manualFallbackRequired(reason: String)
}

enum AntigravityUpdateState: Equatable {
    case idle
    case checking
    case upToDate(installedVersion: String, checkedAt: Date, route: UpdateRoute)
    case available(installedVersion: String, manifest: AntigravityUpdateManifest, route: UpdateRoute, eligibility: AntigravityInstallEligibility)
    case downloading(manifest: AntigravityUpdateManifest, downloadedBytes: Int64, totalBytes: Int64, route: UpdateRoute)
    case verifying(manifest: AntigravityUpdateManifest, stage: String)
    case replacingAndRebuilding(manifest: AntigravityUpdateManifest, stage: String)
    case readyForManualInstall(manifest: AntigravityUpdateManifest, zipURL: URL, reason: String)
    case failed(message: String, canRetry: Bool)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .replacingAndRebuilding:
            return true
        case .idle, .upToDate, .available, .readyForManualInstall, .failed:
            return false
        }
    }

    var activeManifest: AntigravityUpdateManifest? {
        switch self {
        case .available(_, let m, _, _),
             .downloading(let m, _, _, _),
             .verifying(let m, _),
             .replacingAndRebuilding(let m, _),
             .readyForManualInstall(let m, _, _):
            return m
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }
}

enum AntigravityUpdateError: LocalizedError {
    case missingSourceApp(String)
    case invalidManifest(String)
    case networkError(String)
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case extractionFailed(String)
    case verificationFailed(String)
    case runningInstancesNotExited(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSourceApp(let path):
            return L10n.t(
                zhHans: "未找到原版 Antigravity：\(path)",
                zhHant: "找不到原版 Antigravity：\(path)",
                en: "Original Antigravity not found: \(path)",
                ru: "Оригинальный Antigravity не найден: \(path)"
            )
        case .invalidManifest(let msg),
             .networkError(let msg),
             .extractionFailed(let msg),
             .verificationFailed(let msg),
             .runningInstancesNotExited(let msg),
             .installFailed(let msg):
            return msg
        case .checksumMismatch(let expected, let actual):
            return L10n.t(
                zhHans: "Antigravity 安装包 SHA-512 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…），已自动清理损坏文件。",
                zhHant: "Antigravity 安裝套件 SHA-512 驗證失敗（預期 \(expected.prefix(12))…，實際 \(actual.prefix(12))…），已自動清理損壞檔案。",
                en: "Antigravity package SHA-512 mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…). Corrupted file removed.",
                ru: "Несовпадение SHA-512 пакета Antigravity (ожидалось \(expected.prefix(12))…, получено \(actual.prefix(12))…). Файл удалён."
            )
        case .sizeMismatch(let expected, let actual):
            return L10n.t(
                zhHans: "Antigravity 安装包大小校验失败（期望 \(expected) 字节，实际 \(actual) 字节）。",
                zhHant: "Antigravity 安裝套件大小驗證失敗（預期 \(expected) 位元組，實際 \(actual) 位元組）。",
                en: "Antigravity package size mismatch (expected \(expected) bytes, got \(actual) bytes).",
                ru: "Несовпадение размера пакета Antigravity (ожидалось \(expected) байт, получено \(actual) байт)."
            )
        }
    }
}
