import CryptoKit
import Foundation

enum McpPluginStatus: Equatable {
    case notInstalled
    case installedCurrent(version: String)
    case updateAvailable(installedVersion: String, bundledVersion: String)
    case unavailable(reason: String)

    var isInstalled: Bool {
        switch self {
        case .installedCurrent, .updateAvailable:
            return true
        case .notInstalled, .unavailable:
            return false
        }
    }
}

struct McpPluginInstaller {
    let support: AppSupport
    let resourceBaseURL: URL?

    init(support: AppSupport = AppSupport(), resourceBaseURL: URL? = Bundle.main.resourceURL) {
        self.support = support
        self.resourceBaseURL = resourceBaseURL
    }

    var pluginDir: URL {
        support.mcpPluginDirectory
    }

    func status(bundledVersion: String) -> McpPluginStatus {
        guard let assets = try? resolveBundledAssets() else {
            return .unavailable(reason: L10n.t(
                "当前应用包未内置 MCP 插件产物，请通过 ./build.sh 重新构建。",
                "Bundled MCP plugin assets are missing in this app bundle. Rebuild via ./build.sh."
            ))
        }

        let fm = FileManager.default
        let pluginJson = pluginDir.appendingPathComponent("plugin.json")
        let mcpConfig = pluginDir.appendingPathComponent("mcp_config.json")
        let binDest = pluginDir.appendingPathComponent("bin/antigravity-pilot-mcp")
        let htmlDest = pluginDir.appendingPathComponent("assets/dashboard.html")

        guard fm.fileExists(atPath: pluginDir.path) else {
            return .notInstalled
        }

        guard fm.fileExists(atPath: pluginJson.path),
              fm.fileExists(atPath: mcpConfig.path),
              fm.fileExists(atPath: binDest.path),
              fm.fileExists(atPath: htmlDest.path) else {
            return .updateAvailable(
                installedVersion: L10n.t("不完整", "Incomplete"),
                bundledVersion: bundledVersion
            )
        }

        let installedVersion = readInstalledVersion(from: pluginJson) ?? L10n.t("未知", "Unknown")
        let binMatches = sha256File(assets.mcpBinary) == sha256File(binDest)
        let htmlMatches = sha256File(assets.dashboardHTML) == sha256File(htmlDest)
        let configMatches = (try? Data(contentsOf: mcpConfig)) == (try? expectedMCPConfigData(appVersion: bundledVersion))

        if binMatches && htmlMatches && configMatches && installedVersion == bundledVersion {
            return .installedCurrent(version: installedVersion)
        }
        return .updateAvailable(installedVersion: installedVersion, bundledVersion: bundledVersion)
    }

    func installOrUpdate(appVersion: String, language: AppLanguage = L10n.current) throws {
        let assets = try resolveBundledAssets()
        let fm = FileManager.default

        let tempDir = support.pluginsRoot.appendingPathComponent(".antigravity-pilot-staging-\(UUID().uuidString)", isDirectory: true)
        let backupDir = support.pluginsRoot.appendingPathComponent(".antigravity-pilot-backup-\(UUID().uuidString)", isDirectory: true)
        let binDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        let assetsDir = tempDir.appendingPathComponent("assets", isDirectory: true)

        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let binDest = binDir.appendingPathComponent("antigravity-pilot-mcp")
        try fm.copyItem(at: assets.mcpBinary, to: binDest)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: binDest.path)

        try fm.copyItem(at: assets.dashboardHTML, to: assetsDir.appendingPathComponent("dashboard.html"))
        if let logo = assets.logoPNG {
            try fm.copyItem(at: logo, to: assetsDir.appendingPathComponent("logo.png"))
        }

        let manifestData = try buildManifestData(appVersion: appVersion, language: language)
        try manifestData.write(to: tempDir.appendingPathComponent("plugin.json"), options: .atomic)

        let mcpData = try expectedMCPConfigData(appVersion: appVersion)
        try mcpData.write(to: tempDir.appendingPathComponent("mcp_config.json"), options: .atomic)

        try fm.createDirectory(at: support.pluginsRoot, withIntermediateDirectories: true)
        var movedToBackup = false
        if fm.fileExists(atPath: pluginDir.path) {
            try fm.moveItem(at: pluginDir, to: backupDir)
            movedToBackup = true
        }
        do {
            try fm.moveItem(at: tempDir, to: pluginDir)
        } catch {
            if movedToBackup && !fm.fileExists(atPath: pluginDir.path) {
                try? fm.moveItem(at: backupDir, to: pluginDir)
            }
            throw error
        }
        if movedToBackup {
            try? fm.removeItem(at: backupDir)
        }

        triggerLiveMcpRefresh()
    }

    func syncLanguageIfInstalled(appVersion: String, language: AppLanguage) {
        let manifestURL = pluginDir.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let manifestData = try? buildManifestData(appVersion: appVersion, language: language) else {
            return
        }
        try? manifestData.write(to: manifestURL, options: .atomic)
        triggerLiveMcpRefresh()
    }

    func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: pluginDir.path) {
            try fm.removeItem(at: pluginDir)
        }
        triggerLiveMcpRefresh()
    }

    private func buildManifestData(appVersion: String, language: AppLanguage) throws -> Data {
        let pluginManifest: [String: Any] = [
            "name": "antigravity-pilot",
            "displayName": "Antigravity Pilot",
            "description": L10n.t(
                "Antigravity 应用内代理健康探测、实时会话上下文、模型共享配额池与全年用量账单看板。",
                "In-app proxy health diagnostics, live session context, shared model quota pools, and 1-year usage & billing dashboard.",
                language
            ),
            "version": appVersion,
            "logo": "assets/logo.png",
            "suggestedPrompts": [
                L10n.t(
                    "打开 Pilot 实时监控面板查看当前会话上下文与配额",
                    "Open Pilot Live Monitor to inspect active session context & model quotas",
                    language
                ),
                L10n.t(
                    "打开 Pilot 用量与账单看板统计近期 Token 与估算费用",
                    "Open Pilot Usage & Billing dashboard to review token usage & estimated cost",
                    language
                ),
                L10n.t(
                    "检查当前本地代理三阶健康状态",
                    "Check local proxy 3-stage health status",
                    language
                )
            ]
        ]
        var data = try JSONSerialization.data(
            withJSONObject: pluginManifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private func triggerLiveMcpRefresh() {
        Task.detached(priority: .utility) {
            guard let hub = LanguageServerClient.discoverLiveHub() else { return }
            let client = LanguageServerClient()
            await client.refreshMcpServer(hub: hub, serverName: "antigravity-pilot_pilot")
            client.invalidate()
        }
    }

    private func expectedMCPConfigData(appVersion: String) throws -> Data {
        let binPath = pluginDir.appendingPathComponent("bin/antigravity-pilot-mcp").path
        let htmlPath = pluginDir.appendingPathComponent("assets/dashboard.html").path
        let payload: [String: Any] = [
            "mcpServers": [
                "pilot": [
                    "command": binPath,
                    "args": ["--html", htmlPath, "--version", appVersion],
                    "env": [
                        "DYLD_INSERT_LIBRARIES": ""
                    ]
                ]
            ]
        ]
        var data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private func resolveBundledAssets() throws -> (mcpBinary: URL, dashboardHTML: URL, logoPNG: URL?) {
        guard let base = resourceBaseURL else {
            throw BuilderError.missingResource("Bundle.main.resourceURL")
        }
        let fm = FileManager.default
        let mcpBinary = base.appendingPathComponent("antigravity-pilot-mcp")
        let dashboardHTML = base.appendingPathComponent("pilot-mcp-dashboard.html")
        let logoPNG = base.appendingPathComponent("icon.png")

        guard fm.fileExists(atPath: mcpBinary.path) else {
            throw BuilderError.missingResource("antigravity-pilot-mcp")
        }
        guard fm.fileExists(atPath: dashboardHTML.path) else {
            throw BuilderError.missingResource("pilot-mcp-dashboard.html")
        }
        return (
            mcpBinary: mcpBinary,
            dashboardHTML: dashboardHTML,
            logoPNG: fm.fileExists(atPath: logoPNG.path) ? logoPNG : nil
        )
    }

    private func readInstalledVersion(from manifestURL: URL) -> String? {
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["version"] as? String
    }

    private func sha256File(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
