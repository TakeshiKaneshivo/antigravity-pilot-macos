import Foundation

private struct CachedAggregateRow: Codable {
    let cascadeId: String
    let clientSource: UsageClientSource
    let dateKey: String
    let modelKey: String
    let isOver200k: Bool
    var inputTokens: Int
    var cacheReadTokens: Int
    var outputTokens: Int
    var requestCount: Int
}

private struct CachedTranscriptFile: Codable {
    let fileSize: Int64
    let mtimeSeconds: Double
    let rows: [CachedAggregateRow]
}

private struct TranscriptUsageCache: Codable {
    static let currentVersion = 4
    var version: Int = currentVersion
    var files: [String: CachedTranscriptFile] = [:]
}

private struct TranscriptLineDTO: Decodable {
    let stepIndex: FlexibleInt?
    let type: String?
    let status: String?
    let createdAt: String?
    let model: String?
    let inputTokens: FlexibleInt?
    let cacheReadTokens: FlexibleInt?
    let outputTokens: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case stepIndex = "step_index"
        case type
        case status
        case createdAt = "created_at"
        case model
        case inputTokens = "input_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case outputTokens = "output_tokens"
    }
}

enum TranscriptScanner {
    struct ArchiveRoot {
        let brainDir: URL
        let rootDir: URL
        let source: UsageClientSource
    }

    static func defaultBrainDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
    }

    static func defaultArchiveRoots() -> [ArchiveRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktopRoot = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let cliRoot = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        return [
            ArchiveRoot(
                brainDir: desktopRoot.appendingPathComponent("brain", isDirectory: true),
                rootDir: desktopRoot,
                source: .desktop
            ),
            ArchiveRoot(
                brainDir: cliRoot.appendingPathComponent("brain", isDirectory: true),
                rootDir: cliRoot,
                source: .cli
            )
        ]
    }

    static func scan(
        brainDir: URL = defaultBrainDirectory(),
        cacheURL: URL = AppSupport().usageCacheURL,
        customPricingURL: URL? = AppSupport().customPricingURL
    ) -> UsageHistorySnapshot {
        let rootDir = brainDir.deletingLastPathComponent()
        let pricingSource = PricingCatalog.ResolvedPricingSource.load(
            customPricingURL: customPricingURL,
            syncedCatalogURL: AppSupport().syncedPricingCatalogURL,
            bundledCatalogURL: PricingCatalog.defaultBundledCatalogURL(),
            modelCatalog: [:]
        )
        return scanMultiSource(
            roots: [ArchiveRoot(brainDir: brainDir, rootDir: rootDir, source: .desktop)],
            cacheURL: cacheURL,
            pricingSource: pricingSource,
            liveSessions: []
        )
    }

    static func scanMultiSource(
        roots: [ArchiveRoot] = defaultArchiveRoots(),
        cacheURL: URL = AppSupport().usageCacheURL,
        support: AppSupport = AppSupport(),
        modelCatalog: [String: ModelCatalogEntry] = [:],
        liveSessions: [SessionSummary] = []
    ) -> UsageHistorySnapshot {
        let pricingSource = PricingCatalog.ResolvedPricingSource.load(
            customPricingURL: support.customPricingURL,
            syncedCatalogURL: support.syncedPricingCatalogURL,
            bundledCatalogURL: PricingCatalog.defaultBundledCatalogURL(),
            modelCatalog: modelCatalog
        )
        return scanMultiSource(
            roots: roots,
            cacheURL: cacheURL,
            pricingSource: pricingSource,
            liveSessions: liveSessions
        )
    }

    static func scanMultiSource(
        roots: [ArchiveRoot],
        cacheURL: URL,
        pricingSource: PricingCatalog.ResolvedPricingSource,
        liveSessions: [SessionSummary]
    ) -> UsageHistorySnapshot {
        let fm = FileManager.default
        var cache = loadCache(from: cacheURL)
        var cacheDirty = false

        var discoveredFiles: [String: (url: URL, cascadeId: String, source: UsageClientSource)] = [:]
        var desktopFilesCount = 0
        var cliFilesCount = 0

        for root in roots {
            guard let sessionDirs = try? fm.contentsOfDirectory(
                at: root.brainDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for dir in sessionDirs {
                let cid = dir.lastPathComponent.lowercased()
                let candidate1 = dir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                let candidate2 = dir.appendingPathComponent("transcript.jsonl")
                let targetURL: URL?
                let relSub: String
                if fm.fileExists(atPath: candidate1.path) {
                    targetURL = candidate1
                    relSub = ".system_generated/logs/transcript.jsonl"
                } else if fm.fileExists(atPath: candidate2.path) {
                    targetURL = candidate2
                    relSub = "transcript.jsonl"
                } else {
                    targetURL = nil
                    relSub = ""
                }
                guard let url = targetURL else { continue }
                let cacheKey = "\(root.source.rawValue)/\(dir.lastPathComponent)/\(relSub)"
                discoveredFiles[cacheKey] = (url, cid, root.source)
                switch root.source {
                case .desktop: desktopFilesCount += 1
                case .cli: cliFilesCount += 1
                }
            }
        }

        for existingKey in Array(cache.files.keys) where discoveredFiles[existingKey] == nil {
            cache.files.removeValue(forKey: existingKey)
            cacheDirty = true
        }

        let localDayFormatter = makeLocalDayFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        for (cacheKey, info) in discoveredFiles {
            guard let attrs = try? fm.attributesOfItem(atPath: info.url.path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

            if let cached = cache.files[cacheKey],
               cached.fileSize == size,
               abs(cached.mtimeSeconds - mtime) < 0.001 {
                continue
            }

            let rows = parseTranscriptFile(
                url: info.url,
                cascadeId: info.cascadeId,
                clientSource: info.source,
                localDayFormatter: localDayFormatter,
                isoFractional: isoFractional,
                isoBasic: isoBasic
            )
            cache.files[cacheKey] = CachedTranscriptFile(
                fileSize: size,
                mtimeSeconds: mtime,
                rows: rows
            )
            cacheDirty = true
        }

        if cacheDirty {
            saveCache(cache, to: cacheURL)
        }

        let indexMeta = LocalSessionIndexReader.loadMetadata(
            roots: roots.map { ($0.rootDir, $0.source) }
        )

        return aggregate(
            cache: cache,
            scannedFilesCount: discoveredFiles.count,
            desktopArchiveCount: desktopFilesCount,
            cliArchiveCount: cliFilesCount,
            pricingSource: pricingSource,
            indexMeta: indexMeta,
            liveSessions: liveSessions
        )
    }

    private static let plannerMarker = Data("PLANNER_RESPONSE".utf8)

    private static func parseTranscriptFile(
        url: URL,
        cascadeId: String,
        clientSource: UsageClientSource,
        localDayFormatter: DateFormatter,
        isoFractional: ISO8601DateFormatter,
        isoBasic: ISO8601DateFormatter
    ) -> [CachedAggregateRow] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return []
        }

        let decoder = JSONDecoder()
        var seenKeys = Set<String>()
        var grouped: [String: CachedAggregateRow] = [:]

        for var rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            while let last = rawLine.last, last == 0x0D || last == 0x20 || last == 0x09 {
                rawLine = rawLine.dropLast()
            }
            while let first = rawLine.first, first == 0x20 || first == 0x09 {
                rawLine = rawLine.dropFirst()
            }
            guard !rawLine.isEmpty,
                  rawLine.range(of: plannerMarker) != nil else {
                continue
            }

            let lineData = Data(rawLine)
            let decodedEntry: TranscriptLineDTO?
            if let direct = try? decoder.decode(TranscriptLineDTO.self, from: lineData) {
                decodedEntry = direct
            } else {
                let sanitized = String(decoding: lineData, as: UTF8.self)
                decodedEntry = sanitized.data(using: .utf8).flatMap { try? decoder.decode(TranscriptLineDTO.self, from: $0) }
            }
            guard let entry = decodedEntry, entry.type == "PLANNER_RESPONSE" else {
                continue
            }

            let inp = max(0, entry.inputTokens?.value ?? 0)
            let cacheRead = max(0, entry.cacheReadTokens?.value ?? 0)
            let out = max(0, entry.outputTokens?.value ?? 0)
            if inp == 0 && cacheRead == 0 && out == 0 {
                continue
            }

            let stepPart = entry.stepIndex?.value ?? -1
            let createdStr = entry.createdAt ?? ""
            let dedupKey = "\(stepPart)|\(createdStr)|\(inp)|\(cacheRead)|\(out)"
            if seenKeys.contains(dedupKey) {
                continue
            }
            seenKeys.insert(dedupKey)

            let dateKey: String
            if let dt = isoFractional.date(from: createdStr) ?? isoBasic.date(from: createdStr) {
                dateKey = localDayFormatter.string(from: dt)
            } else if createdStr.count >= 10 {
                dateKey = String(createdStr.prefix(10))
            } else {
                dateKey = localDayFormatter.string(from: Date())
            }

            let rawModel = (entry.model ?? "gemini-3.8-flash").trimmingCharacters(in: .whitespacesAndNewlines)
            let modelToken = rawModel.isEmpty ? "gemini-3.8-flash" : rawModel
            let isOver200k = (inp + cacheRead) > 200_000
            let aggKey = "\(dateKey)|\(modelToken)|\(isOver200k ? 1 : 0)"
            if var existing = grouped[aggKey] {
                existing.inputTokens += inp
                existing.cacheReadTokens += cacheRead
                existing.outputTokens += out
                existing.requestCount += 1
                grouped[aggKey] = existing
            } else {
                grouped[aggKey] = CachedAggregateRow(
                    cascadeId: cascadeId,
                    clientSource: clientSource,
                    dateKey: dateKey,
                    modelKey: modelToken,
                    isOver200k: isOver200k,
                    inputTokens: inp,
                    cacheReadTokens: cacheRead,
                    outputTokens: out,
                    requestCount: 1
                )
            }
        }

        return Array(grouped.values)
    }

    private static func aggregate(
        cache: TranscriptUsageCache,
        scannedFilesCount: Int,
        desktopArchiveCount: Int,
        cliArchiveCount: Int,
        pricingSource: PricingCatalog.ResolvedPricingSource,
        indexMeta: [String: LocalSessionMetadata],
        liveSessions: [SessionSummary]
    ) -> UsageHistorySnapshot {
        let dayFormatter = makeLocalDayFormatter()
        let cal = Calendar.current
        let today = Date()
        let todayKey = dayFormatter.string(from: today)
        let cutoff7Key = dayFormatter.string(from: cal.date(byAdding: .day, value: -6, to: today) ?? today)
        let cutoff30Key = dayFormatter.string(from: cal.date(byAdding: .day, value: -29, to: today) ?? today)

        var liveMap: [String: SessionSummary] = [:]
        for s in liveSessions {
            liveMap[s.id.lowercased()] = s
        }

        var dailyMap: [String: DailyUsageBucket] = [:]
        var periodModelMaps: [UsagePeriod: [String: ModelUsageSummary]] = [
            .today: [:], .days7: [:], .days30: [:], .all: [:]
        ]
        var periodProjectMaps: [UsagePeriod: [String: (summary: ProjectUsageSummary, sessionIds: Set<String>)]] = [
            .today: [:], .days7: [:], .days30: [:], .all: [:]
        ]
        var periodSessionMaps: [UsagePeriod: [String: SessionUsageSummary]] = [
            .today: [:], .days7: [:], .days30: [:], .all: [:]
        ]
        var periodTotals: [UsagePeriod: DailyUsageBucket] = [
            .today: DailyUsageBucket(dateKey: todayKey, inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0, cacheSavingsUSD: 0),
            .days7: DailyUsageBucket(dateKey: cutoff7Key, inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0, cacheSavingsUSD: 0),
            .days30: DailyUsageBucket(dateKey: cutoff30Key, inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0, cacheSavingsUSD: 0),
            .all: DailyUsageBucket(dateKey: "all", inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0, cacheSavingsUSD: 0)
        ]

        for cached in cache.files.values {
            for row in cached.rows {
                let perReqPrompt = (row.inputTokens + row.cacheReadTokens) / max(1, row.requestCount)
                let (rowCost, rowSavings) = PricingCatalog.estimateCostAndSavingsUSD(
                    model: row.modelKey,
                    inputTokens: row.inputTokens,
                    cacheReadTokens: row.cacheReadTokens,
                    outputTokens: row.outputTokens,
                    dateKey: row.dateKey,
                    source: pricingSource,
                    promptTokensForTier: perReqPrompt
                )

                let normModelKey = PricingCatalog.normalizeModelKey(row.modelKey, source: pricingSource)
                let modelDisplay = PricingCatalog.displayName(for: normModelKey, source: pricingSource)

                if var day = dailyMap[row.dateKey] {
                    day.inputTokens += row.inputTokens
                    day.cacheReadTokens += row.cacheReadTokens
                    day.outputTokens += row.outputTokens
                    day.requestCount += row.requestCount
                    day.estimatedCostUSD += rowCost
                    day.cacheSavingsUSD += rowSavings
                    dailyMap[row.dateKey] = day
                } else {
                    dailyMap[row.dateKey] = DailyUsageBucket(
                        dateKey: row.dateKey,
                        inputTokens: row.inputTokens,
                        cacheReadTokens: row.cacheReadTokens,
                        outputTokens: row.outputTokens,
                        requestCount: row.requestCount,
                        estimatedCostUSD: rowCost,
                        cacheSavingsUSD: rowSavings
                    )
                }

                let cidLower = row.cascadeId.lowercased()
                let scopedMeta = indexMeta[LocalSessionIndexReader.metadataKey(cid: cidLower, source: row.clientSource)] ?? indexMeta[cidLower]
                let liveMeta = liveMap[cidLower]

                let sessionTitle: String = {
                    if let t = scopedMeta?.title, !t.isEmpty { return t }
                    if let t = liveMeta?.title, !t.isEmpty { return t }
                    return String(cidLower.prefix(8))
                }()
                let projectName: String? = {
                    if let w = scopedMeta?.workspaceName, !w.isEmpty { return w }
                    if let w = liveMeta?.workspaceName, !w.isEmpty { return w }
                    return nil
                }()
                let projectKey = projectName ?? "__unassigned__"
                let projectDisplay = projectName ?? L10n.t(
                    zhHans: "未绑定工作区",
                    zhHant: "未綁定工作區",
                    en: "Unassigned Workspace",
                    ru: "Без проекта",
                    L10n.current
                )
                let sessionMapKey = "\(row.clientSource.rawValue)|\(cidLower)"

                for period in UsagePeriod.allCases {
                    let matches: Bool
                    switch period {
                    case .today: matches = row.dateKey == todayKey
                    case .days7: matches = row.dateKey >= cutoff7Key
                    case .days30: matches = row.dateKey >= cutoff30Key
                    case .all: matches = true
                    }
                    guard matches else { continue }

                    if var tot = periodTotals[period] {
                        tot.inputTokens += row.inputTokens
                        tot.cacheReadTokens += row.cacheReadTokens
                        tot.outputTokens += row.outputTokens
                        tot.requestCount += row.requestCount
                        tot.estimatedCostUSD += rowCost
                        tot.cacheSavingsUSD += rowSavings
                        periodTotals[period] = tot
                    }

                    // Model breakdown
                    var modelMap = periodModelMaps[period] ?? [:]
                    if let existing = modelMap[normModelKey] {
                        modelMap[normModelKey] = ModelUsageSummary(
                            modelKey: normModelKey,
                            displayName: modelDisplay,
                            inputTokens: existing.inputTokens + row.inputTokens,
                            cacheReadTokens: existing.cacheReadTokens + row.cacheReadTokens,
                            outputTokens: existing.outputTokens + row.outputTokens,
                            requestCount: existing.requestCount + row.requestCount,
                            estimatedCostUSD: existing.estimatedCostUSD + rowCost,
                            cacheSavingsUSD: existing.cacheSavingsUSD + rowSavings
                        )
                    } else {
                        modelMap[normModelKey] = ModelUsageSummary(
                            modelKey: normModelKey,
                            displayName: modelDisplay,
                            inputTokens: row.inputTokens,
                            cacheReadTokens: row.cacheReadTokens,
                            outputTokens: row.outputTokens,
                            requestCount: row.requestCount,
                            estimatedCostUSD: rowCost,
                            cacheSavingsUSD: rowSavings
                        )
                    }
                    periodModelMaps[period] = modelMap

                    // Project breakdown
                    var projMap = periodProjectMaps[period] ?? [:]
                    if var existingProj = projMap[projectKey] {
                        existingProj.sessionIds.insert(sessionMapKey)
                        let s = existingProj.summary
                        existingProj.summary = ProjectUsageSummary(
                            projectKey: projectKey,
                            displayName: projectDisplay,
                            inputTokens: s.inputTokens + row.inputTokens,
                            cacheReadTokens: s.cacheReadTokens + row.cacheReadTokens,
                            outputTokens: s.outputTokens + row.outputTokens,
                            requestCount: s.requestCount + row.requestCount,
                            sessionCount: existingProj.sessionIds.count,
                            estimatedCostUSD: s.estimatedCostUSD + rowCost,
                            cacheSavingsUSD: s.cacheSavingsUSD + rowSavings
                        )
                        projMap[projectKey] = existingProj
                    } else {
                        projMap[projectKey] = (
                            ProjectUsageSummary(
                                projectKey: projectKey,
                                displayName: projectDisplay,
                                inputTokens: row.inputTokens,
                                cacheReadTokens: row.cacheReadTokens,
                                outputTokens: row.outputTokens,
                                requestCount: row.requestCount,
                                sessionCount: 1,
                                estimatedCostUSD: rowCost,
                                cacheSavingsUSD: rowSavings
                            ),
                            Set([sessionMapKey])
                        )
                    }
                    periodProjectMaps[period] = projMap

                    // Session breakdown
                    var sessMap = periodSessionMaps[period] ?? [:]
                    if let existingSess = sessMap[sessionMapKey] {
                        sessMap[sessionMapKey] = SessionUsageSummary(
                            cascadeId: cidLower,
                            title: sessionTitle,
                            projectName: projectName,
                            clientSource: row.clientSource,
                            inputTokens: existingSess.inputTokens + row.inputTokens,
                            cacheReadTokens: existingSess.cacheReadTokens + row.cacheReadTokens,
                            outputTokens: existingSess.outputTokens + row.outputTokens,
                            requestCount: existingSess.requestCount + row.requestCount,
                            estimatedCostUSD: existingSess.estimatedCostUSD + rowCost,
                            cacheSavingsUSD: existingSess.cacheSavingsUSD + rowSavings,
                            lastDateKey: max(existingSess.lastDateKey, row.dateKey)
                        )
                    } else {
                        sessMap[sessionMapKey] = SessionUsageSummary(
                            cascadeId: cidLower,
                            title: sessionTitle,
                            projectName: projectName,
                            clientSource: row.clientSource,
                            inputTokens: row.inputTokens,
                            cacheReadTokens: row.cacheReadTokens,
                            outputTokens: row.outputTokens,
                            requestCount: row.requestCount,
                            estimatedCostUSD: rowCost,
                            cacheSavingsUSD: rowSavings,
                            lastDateKey: row.dateKey
                        )
                    }
                    periodSessionMaps[period] = sessMap
                }
            }
        }

        let sortedDays = dailyMap.values.sorted { $0.dateKey < $1.dateKey }
        var sortedModelsByPeriod: [UsagePeriod: [ModelUsageSummary]] = [:]
        var sortedProjectsByPeriod: [UsagePeriod: [ProjectUsageSummary]] = [:]
        var sortedSessionsByPeriod: [UsagePeriod: [SessionUsageSummary]] = [:]

        for period in UsagePeriod.allCases {
            let modelVals = periodModelMaps[period].map { Array($0.values) } ?? []
            sortedModelsByPeriod[period] = modelVals.sorted { $0.totalTokens > $1.totalTokens }

            let projVals = periodProjectMaps[period].map { $0.values.map(\.summary) } ?? []
            sortedProjectsByPeriod[period] = Array(projVals.sorted { $0.totalTokens > $1.totalTokens }.prefix(25))

            let sessVals = periodSessionMaps[period].map { Array($0.values) } ?? []
            sortedSessionsByPeriod[period] = Array(sessVals.sorted { $0.totalTokens > $1.totalTokens }.prefix(30))
        }

        return UsageHistorySnapshot(
            dailyBuckets: sortedDays,
            modelSummariesByPeriod: sortedModelsByPeriod,
            projectSummariesByPeriod: sortedProjectsByPeriod,
            sessionSummariesByPeriod: sortedSessionsByPeriod,
            totalsByPeriod: periodTotals,
            scannedFilesCount: scannedFilesCount,
            desktopArchiveCount: desktopArchiveCount,
            cliArchiveCount: cliArchiveCount,
            scannedAt: Date()
        )
    }

    private static func makeLocalDayFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df
    }

    private static func loadCache(from url: URL) -> TranscriptUsageCache {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TranscriptUsageCache.self, from: data),
              decoded.version == TranscriptUsageCache.currentVersion else {
            return TranscriptUsageCache()
        }
        return decoded
    }

    private static func saveCache(_ cache: TranscriptUsageCache, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
