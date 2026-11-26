import Foundation

enum PricingSyncService {
    static let upstreamURL = URL(string: "https://raw.githubusercontent.com/yuhuan-dev/antigravity-usage-monitor/main/pricing-catalog.json")!
    static let cooldownSeconds: TimeInterval = 12 * 3600
    static let maxPayloadBytes = 1_048_576

    struct SyncState: Codable, Equatable {
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        var etag: String?
        var catalogVersion: String?
    }

    static func syncIfNeeded(
        config: ProxyConfig,
        support: AppSupport,
        overrideURL: URL? = nil,
        allowInsecureHTTPOverride: Bool = false,
        force: Bool = false
    ) async -> Bool {
        let targetURL = overrideURL ?? upstreamURL
        let scheme = targetURL.scheme?.lowercased() ?? ""
        guard scheme == "https" || (allowInsecureHTTPOverride && scheme == "http" && isLoopbackHost(targetURL.host)) else {
            return false
        }

        var state = loadState(from: support.pricingSyncStateURL)
        if !force, let lastAttempt = state.lastAttemptAt,
           Date().timeIntervalSince(lastAttempt) < cooldownSeconds {
            return false
        }

        state.lastAttemptAt = Date()
        let candidates = candidateSessions(for: targetURL, config: config)

        for session in candidates {
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: targetURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !force, let etag = state.etag, !etag.isEmpty {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }

                if http.statusCode == 304 {
                    saveState(state, to: support.pricingSyncStateURL)
                    return false
                }
                guard (200..<300).contains(http.statusCode) else { continue }
                guard data.count > 0 && data.count <= maxPayloadBytes else { continue }

                guard let catalog = try? JSONDecoder().decode(ExternalPricingCatalog.self, from: data),
                      catalog.isValid else {
                    saveState(state, to: support.pricingSyncStateURL)
                    return false
                }

                let existingData = try? Data(contentsOf: support.syncedPricingCatalogURL)
                let changed = existingData != data
                if changed {
                    try support.ensureRoot()
                    try data.write(to: support.syncedPricingCatalogURL, options: .atomic)
                }

                state.lastSuccessAt = Date()
                state.catalogVersion = catalog.catalogVersion
                if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                    state.etag = etag
                }
                saveState(state, to: support.pricingSyncStateURL)
                return changed
            } catch {
                continue
            }
        }

        saveState(state, to: support.pricingSyncStateURL)
        return false
    }

    private static func candidateSessions(for url: URL, config: ProxyConfig) -> [URLSession] {
        var sessions: [URLSession] = []
        let host = config.normalizedHost
        let targetIsLoopback = isLoopbackHost(url.host)

        if !targetIsLoopback && ProxyConfig.isValidNumericIP(host) {
            if config.envScheme.lowercased() == "http",
               (1...65535).contains(config.envPort),
               ProxyHealthService.testTCPConnect(host: host, port: config.envPort, timeoutMs: 250) {
                let proxyCfg = makeSessionConfig()
                proxyCfg.connectionProxyDictionary = [
                    "HTTPEnable": 1,
                    "HTTPProxy": host,
                    "HTTPPort": config.envPort,
                    "HTTPSEnable": 1,
                    "HTTPSProxy": host,
                    "HTTPSPort": config.envPort
                ]
                sessions.append(URLSession(configuration: proxyCfg))
            } else if (1...65535).contains(config.hookPort),
                      ProxyHealthService.testTCPConnect(host: host, port: config.hookPort, timeoutMs: 250) {
                let proxyCfg = makeSessionConfig()
                proxyCfg.connectionProxyDictionary = [
                    "SOCKSEnable": 1,
                    "SOCKSProxy": host,
                    "SOCKSPort": config.hookPort
                ]
                sessions.append(URLSession(configuration: proxyCfg))
            }
        }

        sessions.append(URLSession(configuration: makeSessionConfig()))
        return sessions
    }

    private static func makeSessionConfig() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return cfg
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        let h = (host ?? "").lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    private static func loadState(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState()
        }
        return state
    }

    private static func saveState(_ state: SyncState, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
