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
           (host == "127.0.0.1" || host == "localhost" || host == "::1"),
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

    static func effectiveRemainingFraction(
        fraction: Double?,
        resetTimeISO: String?,
        hasQuotaInfo: Bool,
        disabled: Bool = false
    ) -> Double? {
        if disabled {
            return 0.0
        }
        if let fraction, fraction.isFinite {
            return min(1.0, max(0.0, fraction))
        }
        if hasQuotaInfo,
           let resetTimeISO,
           !resetTimeISO.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 0.0
        }
        return nil
    }

    func fetchUserStatus(
        hub: DaemonHubInfo,
        lang: AppLanguage = L10n.current
    ) async throws -> (UserProfileInfo?, [QuotaPoolGroup], [String: String], [String: ModelCatalogEntry]) {
        async let userStatusTask: GetUserStatusResponse = callRPC("GetUserStatus", body: EmptyRequest(), hub: hub)
        async let quotaSummaryTask: RetrieveUserQuotaSummaryResponse? = try? await callRPC("RetrieveUserQuotaSummary", body: EmptyRequest(), hub: hub)
        async let availableModelsTask: GetAvailableModelsResponse? = try? await callRPC("GetAvailableModels", body: EmptyRequest(), hub: hub)

        let resp = try await userStatusTask
        let quotaResp = await quotaSummaryTask
        let availResp = await availableModelsTask

        let modelCatalog = Self.parseAvailableModels(from: availResp)
        let u = resp.userStatus
        let profile = u.map {
            let tierId = $0.userTier?.id ?? ""
            let tierName = $0.userTier?.name ?? $0.planStatus?.planInfo?.planName ?? "Antigravity"
            let planName = $0.planStatus?.planInfo?.planName ?? ""
            let kind = SubscriptionTierKind.infer(tierId: tierId, tierName: tierName, planName: planName)
            return UserProfileInfo(
                name: $0.name ?? "",
                email: $0.email ?? "",
                tierName: tierName,
                tierId: tierId,
                tierKind: kind
            )
        }

        var modelLabels: [String: String] = [:]
        for entry in modelCatalog.values {
            if !entry.modelSlug.isEmpty && !entry.displayName.isEmpty {
                modelLabels[entry.modelSlug] = entry.displayName
            }
            if !entry.placeholderId.isEmpty && !entry.displayName.isEmpty {
                modelLabels[entry.placeholderId] = entry.displayName
            }
        }

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
                let effectiveFrac = Self.effectiveRemainingFraction(
                    fraction: cfg.quotaInfo?.remainingFraction,
                    resetTimeISO: resetISO,
                    hasQuotaInfo: cfg.quotaInfo != nil
                )
                quotaItems.append(ModelQuotaItem(
                    id: "\(modelId)|\(label)",
                    label: label,
                    modelId: modelId,
                    remainingFraction: effectiveFrac,
                    resetTime: resetDate,
                    resetTimeISO: resetISO,
                    tagTitle: cfg.tagTitle
                ))
            }
        }

        let officialGroups = Self.parseOfficialQuotaPools(
            from: quotaResp,
            quotaItems: quotaItems,
            lang: lang
        )
        let groups = !officialGroups.isEmpty ? officialGroups : Self.groupQuotaPools(items: quotaItems, lang: lang)
        return (profile, groups, modelLabels, modelCatalog)
    }

    static func parseAvailableModels(data: Data) -> [String: ModelCatalogEntry] {
        guard let resp = try? JSONDecoder().decode(GetAvailableModelsResponse.self, from: data) else {
            return [:]
        }
        return parseAvailableModels(from: resp)
    }

    private static func parseAvailableModels(from resp: GetAvailableModelsResponse?) -> [String: ModelCatalogEntry] {
        guard let rawModels = resp?.resolvedModels else { return [:] }
        var map: [String: ModelCatalogEntry] = [:]
        for (slug, dto) in rawModels {
            let maxTokens = dto.maxTokens?.value ?? 0
            let placeholder = (dto.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (dto.displayName ?? slug).trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = ModelCatalogEntry(
                modelSlug: slug,
                placeholderId: placeholder,
                displayName: display.isEmpty ? slug : display,
                maxTokens: maxTokens,
                maxOutputTokens: dto.maxOutputTokens?.value,
                tagTitle: dto.tagTitle
            )
            map[slug.lowercased()] = entry
            if !placeholder.isEmpty {
                map[placeholder.uppercased()] = entry
                map[placeholder] = entry
            }
        }
        return map
    }

    static func parseOfficialQuotaPools(
        data: Data,
        quotaItems: [ModelQuotaItem] = [],
        lang: AppLanguage = L10n.current,
        now: Date = Date()
    ) -> [QuotaPoolGroup] {
        guard let resp = try? JSONDecoder().decode(RetrieveUserQuotaSummaryResponse.self, from: data) else {
            return []
        }
        return parseOfficialQuotaPools(from: resp, quotaItems: quotaItems, lang: lang, now: now)
    }

    private static func parseOfficialQuotaPools(
        from resp: RetrieveUserQuotaSummaryResponse?,
        quotaItems: [ModelQuotaItem] = [],
        lang: AppLanguage = L10n.current,
        now: Date = Date()
    ) -> [QuotaPoolGroup] {
        guard let rawGroups = resp?.resolvedGroups, !rawGroups.isEmpty else {
            return []
        }

        var result: [QuotaPoolGroup] = []
        for (idx, g) in rawGroups.enumerated() {
            let groupTitle = (g.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? g.displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
                : L10n.t("模型配额池", "Model Quota Pool", lang)

            var mainBuckets: [QuotaWindowBucket] = []
            var argonBuckets: [QuotaWindowBucket] = []
            var carbonBuckets: [QuotaWindowBucket] = []

            for (bIdx, b) in (g.buckets ?? []).enumerated() {
                let resetISO = b.resetTime
                let resetDate = resetISO.flatMap { parseISO8601($0) }
                if b.remainingFraction == nil && !(b.disabled ?? false) {
                    guard let resetDate, resetDate > now else {
                        continue
                    }
                }
                guard let frac = effectiveRemainingFraction(
                    fraction: b.remainingFraction,
                    resetTimeISO: resetISO,
                    hasQuotaInfo: true,
                    disabled: b.disabled ?? false
                ) else {
                    continue
                }
                let kind = classifyWindowKind(bucket: b, resetDate: resetDate, now: now)
                let bid = b.bucketId ?? "bucket_\(idx)_\(bIdx)"
                let bName = (b.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? b.displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : kind.shortLabel(lang)
                let bucket = QuotaWindowBucket(
                    id: bid,
                    windowKind: kind,
                    displayName: bName,
                    remainingFraction: frac,
                    resetTime: resetDate,
                    resetTimeISO: resetISO,
                    description: b.description
                )

                let idLower = bid.lowercased()
                let groupLower = groupTitle.lowercased()
                if idLower.contains("argon") && !groupLower.contains("argon") {
                    argonBuckets.append(bucket)
                } else if idLower.contains("carbon") && !groupLower.contains("carbon") {
                    carbonBuckets.append(bucket)
                } else {
                    mainBuckets.append(bucket)
                }
            }

            let matchingModels = matchQuotaModels(groupTitle: groupTitle, description: g.description, from: quotaItems)
            if !mainBuckets.isEmpty {
                let sortedMain = sortBuckets(mainBuckets)
                result.append(QuotaPoolGroup(
                    id: "official|\(idx)|\(groupTitle)",
                    title: groupTitle,
                    remainingFraction: sortedMain.first?.remainingFraction ?? 1.0,
                    resetTime: sortedMain.first?.resetTime,
                    models: matchingModels,
                    buckets: sortedMain,
                    poolDescription: g.description
                ))
            }
            if !argonBuckets.isEmpty {
                let sorted = sortBuckets(argonBuckets)
                let argonModels = quotaItems.filter { $0.label.lowercased().contains("argon") || $0.modelId.lowercased().contains("argon") }
                result.append(QuotaPoolGroup(
                    id: "official|\(idx)|argon",
                    title: "Gemini 4 Argon",
                    remainingFraction: sorted.first?.remainingFraction ?? 1.0,
                    resetTime: sorted.first?.resetTime,
                    models: argonModels,
                    buckets: sorted,
                    poolDescription: nil
                ))
            }
            if !carbonBuckets.isEmpty {
                let sorted = sortBuckets(carbonBuckets)
                let carbonModels = quotaItems.filter { $0.label.lowercased().contains("carbon") || $0.modelId.lowercased().contains("carbon") }
                result.append(QuotaPoolGroup(
                    id: "official|\(idx)|carbon",
                    title: "Gemini 4 Carbon",
                    remainingFraction: sorted.first?.remainingFraction ?? 1.0,
                    resetTime: sorted.first?.resetTime,
                    models: carbonModels,
                    buckets: sorted,
                    poolDescription: nil
                ))
            }
        }
        return result
    }

    private static func sortBuckets(_ buckets: [QuotaWindowBucket]) -> [QuotaWindowBucket] {
        buckets.sorted { lhs, rhs in
            func rank(_ k: QuotaWindowKind) -> Int {
                switch k {
                case .fiveHour: return 0
                case .weekly: return 1
                case .unknown: return 2
                }
            }
            return rank(lhs.windowKind) < rank(rhs.windowKind)
        }
    }

    private static func classifyWindowKind(bucket: OfficialQuotaBucketDTO, resetDate: Date?, now: Date) -> QuotaWindowKind {
        let w = (bucket.window ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let idAndName = "\(bucket.bucketId ?? "") \(bucket.displayName ?? "")".lowercased()
        if w == "5h" || idAndName.contains("5h") || idAndName.contains("five hour") || idAndName.contains("five-hour") {
            return .fiveHour
        }
        if w == "weekly" || w == "7d" || w.contains("week") || idAndName.contains("week") {
            return .weekly
        }
        if let resetDate {
            let delta = resetDate.timeIntervalSince(now)
            if delta > 0 && delta <= 8 * 3600 {
                return .fiveHour
            }
            if delta > 8 * 3600 {
                return .weekly
            }
        }
        return .unknown
    }

    private static func matchQuotaModels(
        groupTitle: String,
        description: String?,
        from items: [ModelQuotaItem]
    ) -> [ModelQuotaItem] {
        guard !items.isEmpty else { return [] }
        let gLow = groupTitle.lowercased()
        let descLow = (description ?? "").lowercased()
        let isThirdParty = gLow.contains("claude") || gLow.contains("gpt") || gLow.contains("3p")
        let isArgonOnly = gLow.contains("argon") && !gLow.contains("gemini models")
        let isCarbonOnly = gLow.contains("carbon") && !gLow.contains("gemini models")

        let filtered = items.filter { item in
            let lbl = item.label.lowercased()
            let mid = item.modelId.lowercased()
            if isThirdParty {
                return lbl.contains("claude") || lbl.contains("gpt") || mid.contains("claude") || mid.contains("gpt")
            }
            if isArgonOnly {
                return lbl.contains("argon") || mid.contains("argon")
            }
            if isCarbonOnly {
                return lbl.contains("carbon") || mid.contains("carbon")
            }
            if gLow.contains("gemini") {
                return !(lbl.contains("claude") || lbl.contains("gpt") || mid.contains("claude") || mid.contains("gpt"))
            }
            if !descLow.isEmpty {
                let base = lbl.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return !base.isEmpty && descLow.contains(base)
            }
            return false
        }
        return filtered
    }

    func fetchSessions(hub: DaemonHubInfo) async throws -> [SessionSummary] {
        let resp: GetAllTrajectoriesResponse = try await callRPC("GetAllCascadeTrajectories", body: EmptyRequest(), hub: hub)
        let rawMap = resp.trajectorySummaries ?? [:]

        var parsed: [SessionSummary] = rawMap.map { (cid, summary) in
            let workspaces = summary.workspaces ?? summary.trajectoryMetadata?.workspaces ?? []
            let firstWs = workspaces.first
            let repoName = firstWs?.repository?.computedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let wsUri = firstWs?.workspaceFolderAbsoluteUri
                ?? summary.trajectoryMetadata?.workspaceUris?.first
            let wsPath = wsUri.flatMap { Self.cleanWorkspacePath(from: $0) }
            let wsName = Self.cleanWorkspaceName(repoName: repoName, uri: wsUri)
            let branch = firstWs?.branchName?.trimmingCharacters(in: .whitespacesAndNewlines)

            let parentRaw = summary.trajectoryMetadata?.parentConversationId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parentId = (parentRaw?.isEmpty == false && parentRaw != cid) ? parentRaw : nil
            let rootRaw = summary.trajectoryMetadata?.rootConversationId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootId = (rootRaw?.isEmpty == false) ? rootRaw : parentId
            let roleRaw = summary.trajectoryMetadata?.subagentSpec?.role
                ?? summary.trajectoryMetadata?.subagentSpec?.typeName
                ?? summary.trajectoryMetadata?.subagentSpec?.name
            let agentRole = (roleRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? roleRaw?.trimmingCharacters(in: .whitespacesAndNewlines) : nil

            return SessionSummary(
                id: cid,
                title: (summary.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? summary.summary!
                    : String(cid.prefix(8)),
                stepCount: summary.stepCount?.value ?? 0,
                lastModifiedTime: summary.lastModifiedTime.flatMap { Self.parseISO8601($0) },
                status: summary.status ?? "",
                workspaceName: wsName,
                workspacePath: wsPath,
                branchName: (branch?.isEmpty == false) ? branch : nil,
                parentConversationId: parentId,
                rootConversationId: rootId,
                nestingDepth: parentId != nil ? 1 : 0,
                agentRole: agentRole
            )
        }

        // Order root sessions by lastModifiedTime descending, placing nested subagents below their root/parent
        parsed.sort { ($0.lastModifiedTime ?? .distantPast) > ($1.lastModifiedTime ?? .distantPast) }
        var byRoot: [String: [SessionSummary]] = [:]
        var roots: [SessionSummary] = []
        let idSet = Set(parsed.map(\.id))
        for item in parsed {
            let anchorId = [item.rootConversationId, item.parentConversationId]
                .compactMap { $0 }
                .first { !$0.isEmpty && $0 != item.id && idSet.contains($0) }
            if let anchorId {
                byRoot[anchorId, default: []].append(item)
            } else {
                roots.append(item)
            }
        }

        var ordered: [SessionSummary] = []
        ordered.reserveCapacity(parsed.count)
        for root in roots {
            ordered.append(root)
            if let children = byRoot[root.id] {
                ordered.append(contentsOf: children)
            }
        }
        return ordered
    }

    func fetchSessionContext(
        hub: DaemonHubInfo,
        session: SessionSummary,
        modelLabels: [String: String],
        modelCatalog: [String: ModelCatalogEntry] = [:],
        pricingSource: PricingCatalog.ResolvedPricingSource = .load()
    ) async throws -> SessionContextSnapshot? {
        let req = GeneratorMetadataRequest(cascadeId: session.id, generatorMetadataOffset: 0, includeMessages: false)
        let resp: GeneratorMetadataResponse = try await callRPC("GetCascadeTrajectoryGeneratorMetadata", body: req, hub: hub)
        guard let list = resp.generatorMetadata else { return nil }
        return Self.buildSessionContextSnapshot(
            from: list,
            session: session,
            modelLabels: modelLabels,
            modelCatalog: modelCatalog,
            pricingSource: pricingSource
        )
    }

    static func parseGeneratorMetadataResponse(
        data: Data,
        session: SessionSummary,
        modelLabels: [String: String] = [:],
        modelCatalog: [String: ModelCatalogEntry] = [:],
        pricingSource: PricingCatalog.ResolvedPricingSource = .empty
    ) -> SessionContextSnapshot? {
        guard let resp = try? JSONDecoder().decode(GeneratorMetadataResponse.self, from: data),
              let list = resp.generatorMetadata else {
            return nil
        }
        return buildSessionContextSnapshot(
            from: list,
            session: session,
            modelLabels: modelLabels,
            modelCatalog: modelCatalog,
            pricingSource: pricingSource
        )
    }

    private static func buildSessionContextSnapshot(
        from list: [GeneratorMetadataEntryDTO],
        session: SessionSummary,
        modelLabels: [String: String],
        modelCatalog: [String: ModelCatalogEntry],
        pricingSource: PricingCatalog.ResolvedPricingSource
    ) -> SessionContextSnapshot? {
        let chatModels: [(idx: Int, chat: ChatModelDTO)] = list.enumerated().compactMap { idx, entry in
            guard let cm = entry.chatModel, cm.usage != nil else { return nil }
            return (idx, cm)
        }
        guard !chatModels.isEmpty else { return nil }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let todayKey = dayFormatter.string(from: Date())

        var rawSteps: [SessionStepItem] = []
        rawSteps.reserveCapacity(chatModels.count)

        var lastKnownModelId: String = ""
        for (stepPos, (_, cm)) in chatModels.enumerated() {
            let usage = cm.usage!
            let rawModelId = (cm.model ?? usage.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isCompaction = detectCompactionStep(chatModel: cm, rawModelId: rawModelId)
            let resolvedRawId: String
            if !rawModelId.isEmpty {
                resolvedRawId = rawModelId
                if !isCompaction {
                    lastKnownModelId = rawModelId
                }
            } else if !lastKnownModelId.isEmpty {
                resolvedRawId = lastKnownModelId
            } else {
                resolvedRawId = ""
            }

            let resolvedDisplayName = resolveDisplayName(
                rawModelId: resolvedRawId,
                explicitDisplayName: cm.modelDisplayName,
                modelLabels: modelLabels,
                pricingSource: pricingSource
            )

            let inp = max(0, usage.inputTokens?.value ?? 0)
            let cacheRead = max(0, usage.cacheReadTokens?.value ?? 0)
            let out = max(0, usage.outputTokens?.value ?? 0)
            let thinking = max(0, usage.thinkingOutputTokens?.value ?? 0)
            let response = max(0, usage.responseOutputTokens?.value ?? max(0, out - thinking))

            let ttft = parseDurationSeconds(cm.timeToFirstToken)
            let streamDur = parseDurationSeconds(cm.streamingDuration)
            let tps: Double? = (streamDur ?? 0) > 0.05 && out > 0 ? Double(out) / streamDur! : nil

            let (cost, _) = PricingCatalog.estimateCostAndSavingsUSD(
                model: resolvedRawId.isEmpty ? "gemini-3.8-flash" : resolvedRawId,
                inputTokens: inp,
                cacheReadTokens: cacheRead,
                outputTokens: out,
                dateKey: todayKey,
                source: pricingSource
            )

            let retries = cm.retryInfos ?? []
            let anomaly = classifyAnomaly(retryInfos: retries)
            let errorRetryCount = countErrorRetries(retries)

            rawSteps.append(SessionStepItem(
                id: stepPos + 1,
                stepNumber: stepPos + 1,
                modelId: resolvedRawId,
                modelDisplayName: resolvedDisplayName,
                inputTokens: inp,
                cacheReadTokens: cacheRead,
                outputTokens: out,
                thinkingOutputTokens: thinking,
                responseOutputTokens: response,
                timeToFirstTokenSec: ttft,
                streamingDurationSec: streamDur,
                tokensPerSecond: tps,
                estimatedCostUSD: cost,
                isCompactionStep: isCompaction,
                retryCount: errorRetryCount,
                anomalyKind: anomaly?.kind,
                anomalyExcerpt: anomaly?.excerpt
            ))
        }

        // Backward donor inference if the very first step was a compaction without model
        if let firstNonEmpty = rawSteps.first(where: { !$0.modelId.isEmpty }) {
            for i in rawSteps.indices where rawSteps[i].modelId.isEmpty {
                let s = rawSteps[i]
                let (recomputedCost, _) = PricingCatalog.estimateCostAndSavingsUSD(
                    model: firstNonEmpty.modelId,
                    inputTokens: s.inputTokens,
                    cacheReadTokens: s.cacheReadTokens,
                    outputTokens: s.outputTokens,
                    dateKey: todayKey,
                    source: pricingSource
                )
                rawSteps[i] = SessionStepItem(
                    id: s.id,
                    stepNumber: s.stepNumber,
                    modelId: firstNonEmpty.modelId,
                    modelDisplayName: firstNonEmpty.modelDisplayName,
                    inputTokens: s.inputTokens,
                    cacheReadTokens: s.cacheReadTokens,
                    outputTokens: s.outputTokens,
                    thinkingOutputTokens: s.thinkingOutputTokens,
                    responseOutputTokens: s.responseOutputTokens,
                    timeToFirstTokenSec: s.timeToFirstTokenSec,
                    streamingDurationSec: s.streamingDurationSec,
                    tokensPerSecond: s.tokensPerSecond,
                    estimatedCostUSD: recomputedCost,
                    isCompactionStep: s.isCompactionStep,
                    retryCount: s.retryCount,
                    anomalyKind: s.anomalyKind,
                    anomalyExcerpt: s.anomalyExcerpt
                )
            }
        }

        // Session aggregates (harmonic speed & mean TTFT exclude compaction steps)
        var speedOutputSum = 0
        var speedDurationSum = 0.0
        var ttftSum = 0.0
        var ttftCount = 0
        var totalCost = 0.0
        var anomalyCount = 0

        for step in rawSteps {
            totalCost += step.estimatedCostUSD
            if step.anomalyKind != nil {
                anomalyCount += 1
            }
            if !step.isCompactionStep {
                if let dur = step.streamingDurationSec, dur > 0.05, step.outputTokens > 0 {
                    speedOutputSum += step.outputTokens
                    speedDurationSum += dur
                }
                if let t = step.timeToFirstTokenSec, t > 0 {
                    ttftSum += t
                    ttftCount += 1
                }
            }
        }

        let avgTPS = speedDurationSum > 0.05 ? Double(speedOutputSum) / speedDurationSum : nil
        let avgTTFT = ttftCount > 0 ? ttftSum / Double(ttftCount) : nil

        let latestStep = rawSteps.last!
        let breakdown = chatModels.reversed().lazy
            .map { extractContextBreakdown(from: $0.chat) }
            .first { !$0.isEmpty } ?? []

        let contextLimit = PricingCatalog.contextLimit(
            for: latestStep.modelId.isEmpty ? latestStep.modelDisplayName : latestStep.modelId,
            modelCatalog: modelCatalog
        )

        let recentSteps = Array(rawSteps.suffix(60).reversed())

        return SessionContextSnapshot(
            cascadeId: session.id,
            title: session.title,
            modelId: latestStep.modelId,
            modelDisplayName: latestStep.modelDisplayName,
            inputTokens: latestStep.inputTokens,
            cacheReadTokens: latestStep.cacheReadTokens,
            outputTokens: latestStep.outputTokens,
            thinkingOutputTokens: latestStep.thinkingOutputTokens,
            responseOutputTokens: latestStep.responseOutputTokens,
            contextLimitTokens: contextLimit,
            timeToFirstTokenSec: latestStep.timeToFirstTokenSec,
            streamingDurationSec: latestStep.streamingDurationSec,
            updatedAt: Date(),
            contextBreakdown: breakdown,
            sessionStepCount: rawSteps.count,
            sessionAvgTokensPerSecond: avgTPS,
            sessionAvgTTFTSec: avgTTFT,
            sessionTotalCostUSD: totalCost,
            anomalyStepCount: anomalyCount,
            recentSteps: recentSteps
        )
    }

    private static func resolveDisplayName(
        rawModelId: String,
        explicitDisplayName: String?,
        modelLabels: [String: String],
        pricingSource: PricingCatalog.ResolvedPricingSource
    ) -> String {
        if let explicit = explicitDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let lbl = modelLabels[rawModelId] ?? modelLabels[rawModelId.uppercased()], !lbl.isEmpty {
            return lbl
        }
        if let ph = PricingCatalog.resolvePlaceholder(rawModelId, source: pricingSource), let lbl = ph.label, !lbl.isEmpty {
            return lbl
        }
        let norm = PricingCatalog.normalizeModelKey(rawModelId, source: pricingSource)
        return PricingCatalog.displayName(for: norm, source: pricingSource)
    }

    private static func detectCompactionStep(chatModel: ChatModelDTO, rawModelId: String) -> Bool {
        let low = rawModelId.lowercased()
        if low.contains("checkpoint") || low.contains("compact") {
            return true
        }
        if let sections = chatModel.promptSections {
            for sec in sections {
                let s = "\(sec.name ?? "") \(sec.title ?? "")".lowercased()
                if s.contains("compaction") || s.contains("checkpoint") || s.contains("conversation summary") {
                    return true
                }
            }
        }
        return false
    }

    private static func countErrorRetries(_ retryInfos: [RetryInfoDTO]) -> Int {
        guard !retryInfos.isEmpty else { return 0 }
        let explicitErrors = retryInfos.filter { info in
            let hasMsg = [info.errorMessage, info.error, info.status, info.detail]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains { !$0.isEmpty }
            let code = info.errorCode?.value ?? info.statusCode?.value ?? 0
            let reason = info.reasonCode?.value ?? 0
            return hasMsg || code != 0 || reason != 0
        }.count
        if explicitErrors > 0 {
            return explicitErrors
        }
        return retryInfos.count > 1 ? retryInfos.count - 1 : 0
    }

    static func classifyAnomaly(retryInfos: [RetryInfoDTO]) -> (kind: StepAnomalyKind, excerpt: String?)? {
        guard !retryInfos.isEmpty else { return nil }
        for info in retryInfos.reversed() {
            let msg = [info.errorMessage, info.error, info.status, info.detail]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let code = info.errorCode?.value ?? info.statusCode?.value ?? 0
            let reason = info.reasonCode?.value ?? 0
            if msg.isEmpty && code == 0 && reason == 0 {
                continue
            }
            let kind = classifyAnomalyError(msg, errorCode: code, reasonCode: reason)
            let cleaned = msg
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = cleaned.isEmpty ? nil : String(cleaned.prefix(140))
            return (kind, excerpt)
        }
        return nil
    }

    static func classifyAnomalyError(_ raw: String, errorCode: Int = 0, reasonCode: Int = 0) -> StepAnomalyKind {
        let low = raw.lowercased()
        if low.contains("context canceled") || low.contains("canceled by user") {
            return .canceled
        }
        if reasonCode == 2 || low.contains("model output error") || low.contains("invalid tool call") {
            return .modelOutput
        }
        if errorCode == 429 || low.contains("429") || low.contains("resource_exhausted") || low.contains("quota reached") || low.contains("rate limit") || low.contains("rate_limit") {
            return .rateLimit
        }
        if low.contains("timeout") || low.contains("deadline exceeded") {
            return .timeout
        }
        if errorCode == 503 || low.contains("503") || low.contains("unavailable") || low.contains("no capacity") || low.contains("overloaded") || low.contains("high demand") {
            return .capacity
        }
        if low.contains("eof") || low.contains("connection reset") || low.contains("broken pipe") || low.contains("econnreset") || low.contains("wsarecv") || low.contains("dial tcp") || low.contains("tls:") || low.contains("interrupted") {
            return .disconnect
        }
        if low.contains("safety filter") || low.contains("content safety") {
            return .safety
        }
        if errorCode == 500 || errorCode == 502 || errorCode == 504 || low.contains("500") || low.contains("502") || low.contains("504") || low.contains("internal") || low.contains("bad_gateway") {
            return .upstream
        }
        return .other
    }

    static func extractContextBreakdown(from chat: ChatModelDTO) -> [ContextBreakdownItem] {
        guard let groups = chat.chatStartMetadata?.contextWindowMetadata?.tokenBreakdown?.groups,
              !groups.isEmpty else {
            return []
        }

        var totals: [ContextBreakdownCategory: Int] = [:]
        func add(_ cat: ContextBreakdownCategory, _ tokens: Int) {
            guard tokens > 0 else { return }
            totals[cat, default: 0] += tokens
        }

        for g in groups {
            let gType = (g.type ?? "").uppercased()
            let gName = (g.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let gTokens = max(0, g.numTokens?.value ?? 0)
            let children = g.children ?? []

            if gType == "TOKEN_TYPE_SYSTEM_PROMPT" || gName == "system prompt" {
                if !children.isEmpty {
                    var childSum = 0
                    for c in children {
                        let tok = max(0, c.numTokens?.value ?? 0)
                        childSum += tok
                        add(classifyPromptChild(name: c.name ?? c.title ?? "", type: c.type ?? ""), tok)
                    }
                    if gTokens > childSum {
                        add(.systemPrompt, gTokens - childSum)
                    }
                } else {
                    add(.systemPrompt, gTokens)
                }
            } else if gType == "TOKEN_TYPE_SKILLS" || gName == "skills" || gName == "skill" {
                add(.skills, gTokens)
            } else if gType == "TOKEN_TYPE_RULES" || gType == "TOKEN_TYPE_USER_RULES" || gName == "rules" || gName == "user rules" || gName == "user_rules" {
                add(.userRules, gTokens)
            } else if gType == "TOKEN_TYPE_MCP_TOOLS" || gName.contains("mcp") {
                add(.mcpTools, gTokens)
            } else if gType == "TOKEN_TYPE_TOOLS" || gName == "tools" || gName == "system tools" {
                if !children.isEmpty {
                    var childSum = 0
                    for c in children {
                        let tok = max(0, c.numTokens?.value ?? 0)
                        childSum += tok
                        let cName = (c.name ?? c.title ?? "").lowercased()
                        let cType = (c.type ?? "").uppercased()
                        if cType.contains("MCP") || cName.contains("mcp") {
                            add(.mcpTools, tok)
                        } else {
                            add(.systemTools, tok)
                        }
                    }
                    if gTokens > childSum {
                        add(.systemTools, gTokens - childSum)
                    }
                } else {
                    add(.systemTools, gTokens)
                }
            } else if gType == "TOKEN_TYPE_SUBAGENTS" || gName == "subagents" {
                add(.subagents, gTokens)
            } else if gType == "TOKEN_TYPE_PLUGINS" || gName == "plugins" || gName == "featured plugins" || gName == "featured_plugins" {
                add(.systemPrompt, gTokens)
            } else if gType == "TOKEN_TYPE_CHAT_MESSAGES" || gName == "chat messages" || gName == "messages" {
                if !children.isEmpty {
                    var childSum = 0
                    for c in children {
                        let tok = max(0, c.numTokens?.value ?? 0)
                        childSum += tok
                        add(classifyMessageChild(name: c.name ?? c.title ?? "", type: c.type ?? ""), tok)
                    }
                    if gTokens > childSum {
                        add(.assistantResponses, gTokens - childSum)
                    }
                } else {
                    add(.userMessages, gTokens)
                }
            } else if gType.contains("COMPACT") || gName.contains("compact") || gName.contains("checkpoint") {
                add(.compaction, gTokens)
            } else {
                add(.systemPrompt, gTokens)
            }
        }

        let sumAll = max(1, totals.values.reduce(0, +))
        return totals
            .filter { $0.value > 0 }
            .map { ContextBreakdownItem(category: $0.key, tokens: $0.value, fraction: Double($0.value) / Double(sumAll)) }
            .sorted { $0.tokens > $1.tokens }
    }

    private static func classifyPromptChild(name: String, type: String) -> ContextBreakdownCategory {
        let low = "\(name) \(type)".lowercased()
        if low.contains("skill") { return .skills }
        if low.contains("rule") { return .userRules }
        if low.contains("mcp") { return .mcpTools }
        return .systemPrompt
    }

    private static func classifyMessageChild(name: String, type: String) -> ContextBreakdownCategory {
        let raw = (!name.isEmpty ? name : type).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let stepType = raw.replacingOccurrences(of: #"^\d+:\s*"#, with: "", options: .regularExpression)
        if stepType.contains("CHECKPOINT") || stepType.contains("SUMMARY") || stepType.contains("COMPACT") {
            return .compaction
        }
        if stepType.contains("PLANNER_RESPONSE") || stepType.contains("ASSISTANT") || stepType.contains("MODEL") {
            return .assistantResponses
        }
        if stepType.contains("SYSTEM_MESSAGE") || stepType.contains("SUBAGENT") || stepType.contains("SWARM") {
            return .subagents
        }
        if stepType.contains("USER_INPUT") || stepType == "USER" || stepType.contains("HUMAN") {
            return .userMessages
        }
        // GENERIC, VIEW_FILE, RUN_COMMAND, CODE_ACTION, etc. represent tool call payloads/results
        return .toolResults
    }

    static func cleanWorkspaceName(repoName: String?, uri: String?) -> String? {
        if let repo = repoName?.trimmingCharacters(in: .whitespacesAndNewlines), !repo.isEmpty {
            if let last = repo.split(separator: "/").last {
                return String(last)
            }
            return repo
        }
        if let path = cleanWorkspacePath(from: uri) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? nil : name
        }
        return nil
    }

    static func cleanWorkspacePath(from uri: String?) -> String? {
        guard let raw = uri?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let url = URL(string: raw), url.isFileURL {
            return url.path
        }
        if raw.hasPrefix("file://") {
            let stripped = String(raw.dropFirst("file://".count))
            return stripped.removingPercentEncoding ?? stripped
        }
        return raw
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

    static func groupQuotaPools(items: [ModelQuotaItem], lang: AppLanguage = L10n.current) -> [QuotaPoolGroup] {
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
            let title = summarizeGroupTitle(groupItems, lang: lang)
            return QuotaPoolGroup(
                id: key,
                title: title,
                remainingFraction: frac,
                resetTime: first.resetTime,
                models: groupItems,
                buckets: []
            )
        }
    }

    private static func summarizeGroupTitle(_ items: [ModelQuotaItem], lang: AppLanguage) -> String {
        var families: [String] = []
        for item in items {
            let label = item.label
            let base = label.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty && !families.contains(base) {
                families.append(base)
            }
        }
        if families.isEmpty { return L10n.t("模型配额池", "Model Quota Pool", lang) }
        if families.count <= 2 {
            return families.joined(separator: " / ")
        }
        return L10n.t(
            zhHans: "\(families.prefix(2).joined(separator: " / ")) 等 \(families.count) 个模型",
            zhHant: "\(families.prefix(2).joined(separator: " / ")) 等 \(families.count) 個模型",
            en: "\(families.prefix(2).joined(separator: " / ")) +\(families.count - 2) more",
            ru: "\(families.prefix(2).joined(separator: " / ")) и ещё \(families.count - 2)",
            lang
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
    let id: String?
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

private struct RetrieveUserQuotaSummaryResponse: Decodable {
    let response: OfficialQuotaSummaryInnerDTO?
    let groups: [OfficialQuotaGroupDTO]?

    var resolvedGroups: [OfficialQuotaGroupDTO]? {
        response?.groups ?? groups
    }
}

private struct OfficialQuotaSummaryInnerDTO: Decodable {
    let groups: [OfficialQuotaGroupDTO]?
}

private struct OfficialQuotaGroupDTO: Decodable {
    let displayName: String?
    let description: String?
    let buckets: [OfficialQuotaBucketDTO]?
}

private struct OfficialQuotaBucketDTO: Decodable {
    let bucketId: String?
    let displayName: String?
    let description: String?
    let window: String?
    let remainingFraction: Double?
    let resetTime: String?
    let disabled: Bool?
}

private struct GetAvailableModelsResponse: Decodable {
    let response: AvailableModelsInnerDTO?
    let models: [String: AvailableModelDTO]?

    var resolvedModels: [String: AvailableModelDTO]? {
        response?.models ?? models
    }
}

private struct AvailableModelsInnerDTO: Decodable {
    let models: [String: AvailableModelDTO]?
}

private struct AvailableModelDTO: Decodable {
    let displayName: String?
    let maxTokens: FlexibleInt?
    let maxOutputTokens: FlexibleInt?
    let model: String?
    let tagTitle: String?
}

private struct GetAllTrajectoriesResponse: Decodable {
    let trajectorySummaries: [String: TrajectorySummaryDTO]?
}

private struct TrajectorySummaryDTO: Decodable {
    let summary: String?
    let stepCount: FlexibleInt?
    let lastModifiedTime: String?
    let status: String?
    let workspaces: [WorkspaceInfoDTO]?
    let trajectoryMetadata: TrajectoryMetadataDTO?
}

private struct WorkspaceInfoDTO: Decodable {
    let workspaceFolderAbsoluteUri: String?
    let repository: WorkspaceRepositoryDTO?
    let branchName: String?
}

private struct WorkspaceRepositoryDTO: Decodable {
    let computedName: String?
}

private struct TrajectoryMetadataDTO: Decodable {
    let workspaces: [WorkspaceInfoDTO]?
    let workspaceUris: [String]?
    let parentConversationId: String?
    let rootConversationId: String?
    let subagentSpec: SubagentSpecDTO?
}

private struct SubagentSpecDTO: Decodable {
    let role: String?
    let typeName: String?
    let name: String?
}

private struct GeneratorMetadataResponse: Decodable {
    let generatorMetadata: [GeneratorMetadataEntryDTO]?
}

private struct GeneratorMetadataEntryDTO: Decodable {
    let chatModel: ChatModelDTO?
}

struct ChatModelDTO: Decodable {
    let model: String?
    let modelDisplayName: String?
    let usage: TokenUsageDTO?
    let timeToFirstToken: String?
    let streamingDuration: String?
    let chatStartMetadata: ChatStartMetadataDTO?
    let promptSections: [PromptSectionDTO]?
    let retryInfos: [RetryInfoDTO]?
}

struct ChatStartMetadataDTO: Decodable {
    let contextWindowMetadata: ContextWindowMetadataDTO?
}

struct ContextWindowMetadataDTO: Decodable {
    let estimatedTokensUsed: FlexibleInt?
    let tokenBreakdown: TokenBreakdownDTO?
}

struct TokenBreakdownDTO: Decodable {
    let groups: [TokenBreakdownNodeDTO]?
}

struct TokenBreakdownNodeDTO: Decodable {
    let name: String?
    let title: String?
    let type: String?
    let source: String?
    let numTokens: FlexibleInt?
    let children: [TokenBreakdownNodeDTO]?
}

struct PromptSectionDTO: Decodable {
    let name: String?
    let title: String?
}

struct RetryInfoDTO: Decodable {
    let error: String?
    let errorMessage: String?
    let status: String?
    let detail: String?
    let errorCode: FlexibleInt?
    let statusCode: FlexibleInt?
    let reasonCode: FlexibleInt?
}

struct TokenUsageDTO: Decodable {
    let model: String?
    let inputTokens: FlexibleInt?
    let outputTokens: FlexibleInt?
    let thinkingOutputTokens: FlexibleInt?
    let responseOutputTokens: FlexibleInt?
    let cacheReadTokens: FlexibleInt?
}
