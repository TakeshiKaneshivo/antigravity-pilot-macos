import Foundation

struct AppSupport {
    let sourceApp = URL(fileURLWithPath: "/Applications/Antigravity.app")
    private let customPluginsRoot: URL?

    init(pluginsRoot: URL? = nil) {
        self.customPluginsRoot = pluginsRoot
    }

    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Antigravity Pilot", isDirectory: true)
    }

    var legacyRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Antigravity Proxy", isDirectory: true)
    }

    var runtimeRoot: URL {
        root.appendingPathComponent("Runtime", isDirectory: true)
    }

    var runtimeApp: URL {
        runtimeRoot.appendingPathComponent("Antigravity-Pilot.app", isDirectory: true)
    }

    var legacyRuntimeApp: URL {
        legacyRoot
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("Antigravity-Proxy.app", isDirectory: true)
    }

    var configURL: URL {
        root.appendingPathComponent("config.json")
    }

    var legacyConfigURL: URL {
        legacyRoot.appendingPathComponent("config.json")
    }

    var externalProxyEnvURL: URL {
        root.appendingPathComponent("proxy.env")
    }

    var usageCacheURL: URL {
        root.appendingPathComponent("usage_cache.json")
    }

    var customPricingURL: URL {
        root.appendingPathComponent("custom_pricing.json")
    }

    var updatesDirectory: URL {
        root.appendingPathComponent("Updates", isDirectory: true)
    }

    var pluginsRoot: URL {
        customPluginsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/plugins", isDirectory: true)
    }

    var mcpPluginDirectory: URL {
        pluginsRoot.appendingPathComponent("antigravity-pilot", isDirectory: true)
    }

    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func loadConfig() throws -> ProxyConfig {
        if let data = try? Data(contentsOf: configURL) {
            return try JSONDecoder().decode(ProxyConfig.self, from: data)
        }
        let legacyData = try Data(contentsOf: legacyConfigURL)
        let migrated = try JSONDecoder().decode(ProxyConfig.self, from: legacyData)
        try? saveConfig(migrated)
        return migrated
    }

    func saveConfig(_ config: ProxyConfig) throws {
        try ensureRoot()
        let data = try JSONEncoder().encode(config)
        try data.write(to: configURL, options: .atomic)
    }
}
