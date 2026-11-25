import Foundation

private struct CachedAggregateRow: Codable {
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
    static let currentVersion = 3
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
    static func defaultBrainDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
    }

    static func scan(
        brainDir: URL = defaultBrainDirectory(),
        cacheURL: URL = AppSupport().usageCacheURL,
        customPricingURL: URL? = AppSupport().customPricingURL
    ) -> UsageHistorySnapshot {
        let fm = FileManager.default
        let customRules = PricingCatalog.loadCustomRules(from: customPricingURL)
        var cache = loadCache(from: cacheURL)
        var cacheDirty = false

        var discoveredFiles: [String: URL] = [:]
        if let sessionDirs = try? fm.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in sessionDirs {
                let candidate1 = dir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                let candidate2 = dir.appendingPathComponent("transcript.jsonl")
                if fm.fileExists(atPath: candidate1.path) {
                    discoveredFiles[dir.lastPathComponent + "/.system_generated/logs/transcript.jsonl"] = candidate1
                } else if fm.fileExists(atPath: candidate2.path) {
                    discoveredFiles[dir.lastPathComponent + "/transcript.jsonl"] = candidate2
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

        for (relKey, fileURL) in discoveredFiles {
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

            if let cached = cache.files[relKey],
               cached.fileSize == size,
               abs(cached.mtimeSeconds - mtime) < 0.001 {
                continue
            }

            let rows = parseTranscriptFile(
                url: fileURL,
                localDayFormatter: localDayFormatter,
                isoFractional: isoFractional,
                isoBasic: isoBasic
            )
            cache.files[relKey] = CachedTranscriptFile(
                fileSize: size,
                mtimeSeconds: mtime,
                rows: rows
            )
            cacheDirty = true
        }

        if cacheDirty {
            saveCache(cache, to: cacheURL)
        }

        return aggregate(cache: cache, scannedFilesCount: discoveredFiles.count, customRules: customRules)
    }

    private static let plannerMarker = Data("PLANNER_RESPONSE".utf8)

    private static func parseTranscriptFile(
        url: URL,
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

            let modelKey = PricingCatalog.normalizeModelKey(entry.model ?? "gemini-3.8-flash")
            let isOver200k = (inp + cacheRead) > 200_000
            let aggKey = "\(dateKey)|\(modelKey)|\(isOver200k ? 1 : 0)"
            if var existing = grouped[aggKey] {
                existing.inputTokens += inp
                existing.cacheReadTokens += cacheRead
                existing.outputTokens += out
                existing.requestCount += 1
                grouped[aggKey] = existing
            } else {
                grouped[aggKey] = CachedAggregateRow(
                    dateKey: dateKey,
                    modelKey: modelKey,
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
        customRules: [String: [PricingRule]]
    ) -> UsageHistorySnapshot {
        let dayFormatter = makeLocalDayFormatter()
        let cal = Calendar.current
        let today = Date()
        let todayKey = dayFormatter.string(from: today)
        let cutoff7Key = dayFormatter.string(from: cal.date(byAdding: .day, value: -6, to: today) ?? today)
        let cutoff30Key = dayFormatter.string(from: cal.date(byAdding: .day, value: -29, to: today) ?? today)

        var dailyMap: [String: DailyUsageBucket] = [:]
        var periodModelMaps: [UsagePeriod: [String: ModelUsageSummary]] = [
            .today: [:],
            .days7: [:],
            .days30: [:],
            .all: [:]
        ]
        var periodTotals: [UsagePeriod: DailyUsageBucket] = [
            .today: DailyUsageBucket(dateKey: todayKey, inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0),
            .days7: DailyUsageBucket(dateKey: cutoff7Key, inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0),
            .days30: DailyUsageBucket(dateKey: cutoff30Key, inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0),
            .all: DailyUsageBucket(dateKey: "all", inputTokens: 0, cacheReadTokens: 0, outputTokens: 0, requestCount: 0, estimatedCostUSD: 0)
        ]

        for cached in cache.files.values {
            for row in cached.rows {
                let perReqPrompt = (row.inputTokens + row.cacheReadTokens) / max(1, row.requestCount)
                let rowCost = PricingCatalog.estimateCostUSD(
                    model: row.modelKey,
                    inputTokens: row.inputTokens,
                    cacheReadTokens: row.cacheReadTokens,
                    outputTokens: row.outputTokens,
                    dateKey: row.dateKey,
                    customRules: customRules,
                    promptTokensForTier: perReqPrompt
                )

                if var day = dailyMap[row.dateKey] {
                    day.inputTokens += row.inputTokens
                    day.cacheReadTokens += row.cacheReadTokens
                    day.outputTokens += row.outputTokens
                    day.requestCount += row.requestCount
                    day.estimatedCostUSD += rowCost
                    dailyMap[row.dateKey] = day
                } else {
                    dailyMap[row.dateKey] = DailyUsageBucket(
                        dateKey: row.dateKey,
                        inputTokens: row.inputTokens,
                        cacheReadTokens: row.cacheReadTokens,
                        outputTokens: row.outputTokens,
                        requestCount: row.requestCount,
                        estimatedCostUSD: rowCost
                    )
                }

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
                        periodTotals[period] = tot
                    }

                    var modelMap = periodModelMaps[period] ?? [:]
                    if let existing = modelMap[row.modelKey] {
                        modelMap[row.modelKey] = ModelUsageSummary(
                            modelKey: row.modelKey,
                            displayName: PricingCatalog.displayName(for: row.modelKey),
                            inputTokens: existing.inputTokens + row.inputTokens,
                            cacheReadTokens: existing.cacheReadTokens + row.cacheReadTokens,
                            outputTokens: existing.outputTokens + row.outputTokens,
                            requestCount: existing.requestCount + row.requestCount,
                            estimatedCostUSD: existing.estimatedCostUSD + rowCost
                        )
                    } else {
                        modelMap[row.modelKey] = ModelUsageSummary(
                            modelKey: row.modelKey,
                            displayName: PricingCatalog.displayName(for: row.modelKey),
                            inputTokens: row.inputTokens,
                            cacheReadTokens: row.cacheReadTokens,
                            outputTokens: row.outputTokens,
                            requestCount: row.requestCount,
                            estimatedCostUSD: rowCost
                        )
                    }
                    periodModelMaps[period] = modelMap
                }
            }
        }

        let sortedDays = dailyMap.values.sorted { $0.dateKey < $1.dateKey }
        var sortedModelsByPeriod: [UsagePeriod: [ModelUsageSummary]] = [:]
        for period in UsagePeriod.allCases {
            let values = periodModelMaps[period].map { Array($0.values) } ?? []
            sortedModelsByPeriod[period] = values.sorted { $0.totalTokens > $1.totalTokens }
        }

        return UsageHistorySnapshot(
            dailyBuckets: sortedDays,
            modelSummariesByPeriod: sortedModelsByPeriod,
            totalsByPeriod: periodTotals,
            scannedFilesCount: scannedFilesCount,
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
