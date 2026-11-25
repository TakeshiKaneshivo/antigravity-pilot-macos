import Darwin
import Foundation

final class LoopbackSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           (host == "127.0.0.1" || host == "localhost"),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

final class LanguageServerClient {
    private let session: URLSession
    private let delegate = LoopbackSessionDelegate()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 6.0
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    static func discoverLiveHub(daemonDir: URL? = nil) -> DaemonHubInfo? {
        let env = ProcessInfo.processInfo.environment
        let envAddress = (env["ANTIGRAVITY_LS_ADDRESS"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let envToken = (env["ANTIGRAVITY_CSRF_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let dir = daemonDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        var liveHubs: [DaemonHubInfo] = []

        if let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let hubFiles = urls
                .filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
                .sorted { lhs, rhs in
                    let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lDate > rDate
                }

            for file in hubFiles {
                guard let data = try? Data(contentsOf: file),
                      let hub = try? JSONDecoder().decode(DaemonHubInfo.self, from: data),
                      !hub.csrfToken.isEmpty,
                      isPidAlive(hub.pid) else {
                    continue
                }
                liveHubs.append(hub)
            }
        }

        if !envToken.isEmpty {
            if let matched = liveHubs.first(where: { $0.csrfToken == envToken }) {
                return matched
            }
            if let port = parseLoopbackPort(from: envAddress) {
                let isHttps = envAddress.lowercased().hasPrefix("https://")
                return DaemonHubInfo(
                    pid: getppid(),
                    httpsPort: isHttps ? port : nil,
                    httpPort: isHttps ? nil : port,
                    lsVersion: nil,
                    csrfToken: envToken
                )
            }
        }

        return liveHubs.first
    }

    private static func parseLoopbackPort(from address: String) -> Int? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
           let port = url.port, (1...65535).contains(port) {
            return port
        }
        if let colonIdx = trimmed.lastIndex(of: ":"),
           let port = Int(trimmed[trimmed.index(after: colonIdx)...]),
           (1...65535).contains(port) {
            return port
        }
        return nil
    }

    static func isPidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    func fetchUserStatus(hub: DaemonHubInfo) async throws -> (UserProfileInfo?, [QuotaPoolGroup], [String: String]) {
        let resp: GetUserStatusResponse = try await callRPC("GetUserStatus", body: EmptyRequest(), hub: hub)
        let u = resp.userStatus
        let profile = u.map {
            UserProfileInfo(
                name: $0.name ?? "",
                email: $0.email ?? "",
                tierName: $0.userTier?.name ?? $0.planStatus?.planInfo?.planName ?? "Antigravity"
            )
        }

        var modelLabels: [String: String] = [:]
        var quotaItems: [ModelQuotaItem] = []

        if let configs = u?.cascadeModelConfigData?.clientModelConfigs {
            for cfg in configs {
                let modelId = cfg.modelOrAlias?.model ?? cfg.label ?? ""
                let label = cfg.label ?? modelId
                if !modelId.isEmpty && !label.isEmpty {
                    modelLabels[modelId] = label
                }
                let resetISO = cfg.quotaInfo?.resetTime
                let resetDate = resetISO.flatMap { Self.parseISO8601($0) }
                quotaItems.append(ModelQuotaItem(
                    id: "\(modelId)|\(label)",
                    label: label,
                    modelId: modelId,
                    remainingFraction: cfg.quotaInfo?.remainingFraction,
                    resetTime: resetDate,
                    resetTimeISO: resetISO,
                    tagTitle: cfg.tagTitle
                ))
            }
        }

        let groups = Self.groupQuotaPools(items: quotaItems)
        return (profile, groups, modelLabels)
    }

    func fetchSessions(hub: DaemonHubInfo) async throws -> [SessionSummary] {
        let resp: GetAllTrajectoriesResponse = try await callRPC("GetAllCascadeTrajectories", body: EmptyRequest(), hub: hub)
        let items = (resp.trajectorySummaries ?? [:]).map { (cid, summary) in
            SessionSummary(
                id: cid,
                title: (summary.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? summary.summary!
                    : String(cid.prefix(8)),
                stepCount: summary.stepCount?.value ?? 0,
                lastModifiedTime: summary.lastModifiedTime.flatMap { Self.parseISO8601($0) },
                status: summary.status ?? ""
            )
        }
        return items.sorted { ($0.lastModifiedTime ?? .distantPast) > ($1.lastModifiedTime ?? .distantPast) }
    }

    func fetchSessionContext(
        hub: DaemonHubInfo,
        session: SessionSummary,
        modelLabels: [String: String]
    ) async throws -> SessionContextSnapshot? {
        let req = GeneratorMetadataRequest(cascadeId: session.id, generatorMetadataOffset: 0, includeMessages: false)
        let resp: GeneratorMetadataResponse = try await callRPC("GetCascadeTrajectoryGeneratorMetadata", body: req, hub: hub)
        guard let list = resp.generatorMetadata else { return nil }

        guard let latest = list.reversed().first(where: { $0.chatModel?.usage != nil }) else {
            return nil
        }

        let chatModel = latest.chatModel!
        let usage = chatModel.usage!
        let modelId = chatModel.model ?? usage.model ?? ""
        let displayName = chatModel.modelDisplayName
            ?? modelLabels[modelId]
            ?? PricingCatalog.displayName(for: PricingCatalog.normalizeModelKey(modelId))

        let inputTokens = usage.inputTokens?.value ?? 0
        let cacheReadTokens = usage.cacheReadTokens?.value ?? 0
        let outputTokens = usage.outputTokens?.value ?? 0
        let thinkingOutput = usage.thinkingOutputTokens?.value ?? 0
        let responseOutput = usage.responseOutputTokens?.value ?? max(0, outputTokens - thinkingOutput)

        return SessionContextSnapshot(
            cascadeId: session.id,
            title: session.title,
            modelId: modelId,
            modelDisplayName: displayName,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            thinkingOutputTokens: thinkingOutput,
            responseOutputTokens: responseOutput,
            contextLimitTokens: PricingCatalog.contextLimit(for: "\(displayName) \(modelId)"),
            timeToFirstTokenSec: Self.parseDurationSeconds(chatModel.timeToFirstToken),
            streamingDurationSec: Self.parseDurationSeconds(chatModel.streamingDuration),
            updatedAt: Date()
        )
    }

    private func callRPC<Req: Encodable, Res: Decodable>(_ method: String, body: Req, hub: DaemonHubInfo) async throws -> Res {
        var origins: [String] = []
        if let httpPort = hub.httpPort, httpPort > 0 {
            origins.append("http://127.0.0.1:\(httpPort)")
        }
        if let httpsPort = hub.httpsPort, httpsPort > 0 {
            origins.append("https://127.0.0.1:\(httpsPort)")
        }

        let bodyData = try JSONEncoder().encode(body)
        var lastError: Error = URLError(.cannotConnectToHost)

        for origin in origins {
            guard let url = URL(string: "\(origin)/exa.language_server_pb.LanguageServerService/\(method)") else {
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue(hub.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")

            do {
                let (data, response) = try await session.data(for: request)
                if let httpResp = response as? HTTPURLResponse, !(200..<300).contains(httpResp.statusCode) {
                    lastError = NSError(
                        domain: "LanguageServerRPC",
                        code: httpResp.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "RPC \(method) HTTP \(httpResp.statusCode)"]
                    )
                    continue
                }
                return try JSONDecoder().decode(Res.self, from: data)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func groupQuotaPools(items: [ModelQuotaItem]) -> [QuotaPoolGroup] {
        var buckets: [String: [ModelQuotaItem]] = [:]
        var orderedKeys: [String] = []

        for item in items {
            guard let frac = item.remainingFraction else { continue }
            let bucketMilli = Int((frac * 1000).rounded())
            let resetKey = item.resetTimeISO ?? "none"
            let key = "\(bucketMilli)|\(resetKey)"
            if buckets[key] == nil {
                orderedKeys.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(item)
        }

        return orderedKeys.compactMap { key in
            guard let groupItems = buckets[key], let first = groupItems.first, let frac = first.remainingFraction else {
                return nil
            }
            let title = summarizeGroupTitle(groupItems)
            return QuotaPoolGroup(
                id: key,
                title: title,
                remainingFraction: frac,
                resetTime: first.resetTime,
                models: groupItems
            )
        }
    }

    private static func summarizeGroupTitle(_ items: [ModelQuotaItem]) -> String {
        var families: [String] = []
        for item in items {
            let label = item.label
            let base = label.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty && !families.contains(base) {
                families.append(base)
            }
        }
        if families.isEmpty { return L10n.t("模型配额池", "Model Quota Pool") }
        if families.count <= 2 {
            return families.joined(separator: " / ")
        }
        return L10n.t(
            zhHans: "\(families.prefix(2).joined(separator: " / ")) 等 \(families.count) 个模型",
            zhHant: "\(families.prefix(2).joined(separator: " / ")) 等 \(families.count) 個模型",
            en: "\(families.prefix(2).joined(separator: " / ")) +\(families.count - 2) more",
            ru: "\(families.prefix(2).joined(separator: " / ")) и ещё \(families.count - 2)"
        )
    }

    static func parseISO8601(_ str: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }

        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }

    static func parseDurationSeconds(_ str: String?) -> Double? {
        guard let raw = str?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasSuffix("ms") {
            return Double(raw.dropLast(2)).map { $0 / 1000.0 }
        }
        if raw.hasSuffix("s") {
            return Double(raw.dropLast(1))
        }
        return Double(raw)
    }

    func refreshMcpServer(hub: DaemonHubInfo, serverName: String) async {
        struct RefreshReq: Encodable {
            let serverName: String
        }
        struct EmptyResp: Decodable {}
        let _: EmptyResp? = try? await callRPC("RefreshMcpServers", body: RefreshReq(serverName: serverName), hub: hub)
    }
}

private struct EmptyRequest: Encodable {}

private struct GeneratorMetadataRequest: Encodable {
    let cascadeId: String
    let generatorMetadataOffset: Int
    let includeMessages: Bool
}

private struct GetUserStatusResponse: Decodable {
    let userStatus: UserStatusDTO?
}

private struct UserStatusDTO: Decodable {
    let name: String?
    let email: String?
    let userTier: UserTierDTO?
    let planStatus: PlanStatusDTO?
    let cascadeModelConfigData: CascadeModelConfigDataDTO?
}

private struct UserTierDTO: Decodable {
    let name: String?
}

private struct PlanStatusDTO: Decodable {
    let planInfo: PlanInfoDTO?
}

private struct PlanInfoDTO: Decodable {
    let planName: String?
}

private struct CascadeModelConfigDataDTO: Decodable {
    let clientModelConfigs: [ClientModelConfigDTO]?
}

private struct ClientModelConfigDTO: Decodable {
    let label: String?
    let modelOrAlias: ModelOrAliasDTO?
    let quotaInfo: QuotaInfoDTO?
    let tagTitle: String?
}

private struct ModelOrAliasDTO: Decodable {
    let model: String?
}

private struct QuotaInfoDTO: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

private struct GetAllTrajectoriesResponse: Decodable {
    let trajectorySummaries: [String: TrajectorySummaryDTO]?
}

private struct TrajectorySummaryDTO: Decodable {
    let summary: String?
    let stepCount: FlexibleInt?
    let lastModifiedTime: String?
    let status: String?
}

private struct GeneratorMetadataResponse: Decodable {
    let generatorMetadata: [GeneratorMetadataEntryDTO]?
}

private struct GeneratorMetadataEntryDTO: Decodable {
    let chatModel: ChatModelDTO?
}

private struct ChatModelDTO: Decodable {
    let model: String?
    let modelDisplayName: String?
    let usage: TokenUsageDTO?
    let timeToFirstToken: String?
    let streamingDuration: String?
}

private struct TokenUsageDTO: Decodable {
    let model: String?
    let inputTokens: FlexibleInt?
    let outputTokens: FlexibleInt?
    let thinkingOutputTokens: FlexibleInt?
    let responseOutputTokens: FlexibleInt?
    let cacheReadTokens: FlexibleInt?
}
