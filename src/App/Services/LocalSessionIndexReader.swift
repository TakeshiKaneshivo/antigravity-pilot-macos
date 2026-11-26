import Foundation
import SQLite3

struct LocalSessionMetadata: Equatable {
    let cascadeId: String
    let title: String?
    let workspaceName: String?
    let workspacePath: String?
    let clientSource: UsageClientSource
    let parentConversationId: String?
    let nestingDepth: Int
    let agentRole: String?
}

enum LocalSessionIndexReader {
    private static let sqliteMagic = Data("SQLite format 3\0".utf8)
    private static let dbCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedDBMetaByPath: [String: [String: LocalSessionMetadata]] = [:]

    static func defaultRoots() -> [(rootDir: URL, source: UsageClientSource)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent(".gemini/antigravity", isDirectory: true), .desktop),
            (home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true), .cli)
        ]
    }

    static func isSQLiteHeaderReady(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 100), header.count >= 100 else {
            return false
        }
        return header.prefix(sqliteMagic.count) == sqliteMagic
    }

    static func loadMetadata(
        roots: [(rootDir: URL, source: UsageClientSource)] = defaultRoots()
    ) -> [String: LocalSessionMetadata] {
        var result: [String: LocalSessionMetadata] = [:]
        let fm = FileManager.default

        for (rootDir, source) in roots {
            guard fm.fileExists(atPath: rootDir.path) else { continue }

            let summaryDB = rootDir.appendingPathComponent("conversation_summaries.db")
            if fm.fileExists(atPath: summaryDB.path) && isSQLiteHeaderReady(at: summaryDB) {
                let dbMeta = readConversationSummariesDB(at: summaryDB, source: source)
                for (cid, meta) in dbMeta {
                    result[metadataKey(cid: cid, source: source)] = meta
                    if result[cid] == nil {
                        result[cid] = meta
                    }
                }
            }

            let annotationsDir = rootDir.appendingPathComponent("annotations", isDirectory: true)
            if fm.fileExists(atPath: annotationsDir.path) {
                let annTitles = readAnnotationsDirectory(at: annotationsDir)
                for (cid, title) in annTitles {
                    let scopedKey = metadataKey(cid: cid, source: source)
                    if let existing = result[scopedKey] {
                        if (existing.title?.isEmpty ?? true) && !title.isEmpty {
                            let updated = LocalSessionMetadata(
                                cascadeId: cid,
                                title: title,
                                workspaceName: existing.workspaceName,
                                workspacePath: existing.workspacePath,
                                clientSource: source,
                                parentConversationId: existing.parentConversationId,
                                nestingDepth: existing.nestingDepth,
                                agentRole: existing.agentRole
                            )
                            result[scopedKey] = updated
                            result[cid] = updated
                        }
                    } else if !title.isEmpty {
                        let meta = LocalSessionMetadata(
                            cascadeId: cid,
                            title: title,
                            workspaceName: nil,
                            workspacePath: nil,
                            clientSource: source,
                            parentConversationId: nil,
                            nestingDepth: 0,
                            agentRole: nil
                        )
                        result[scopedKey] = meta
                        if result[cid] == nil {
                            result[cid] = meta
                        }
                    }
                }
            }
        }

        return result
    }

    static func metadataKey(cid: String, source: UsageClientSource) -> String {
        "\(source.rawValue)|\(cid.lowercased())"
    }

    private static func readConversationSummariesDB(at dbURL: URL, source: UsageClientSource) -> [String: LocalSessionMetadata] {
        for attempt in 0..<2 {
            if let fresh = readConversationSummariesDBOnce(at: dbURL, source: source) {
                if !fresh.isEmpty {
                    dbCacheLock.lock()
                    cachedDBMetaByPath[dbURL.path] = fresh
                    dbCacheLock.unlock()
                }
                return fresh
            }
            if attempt == 0 {
                usleep(60_000)
            }
        }
        dbCacheLock.lock()
        let fallback = cachedDBMetaByPath[dbURL.path] ?? [:]
        dbCacheLock.unlock()
        return fallback
    }

    private static func readConversationSummariesDBOnce(at dbURL: URL, source: UsageClientSource) -> [String: LocalSessionMetadata]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 400)

        let sql = """
        SELECT conversation_id, title, workspace_uris, parent_conversation_id, nesting_depth, agent_name
        FROM conversation_summaries
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var out: [String: LocalSessionMetadata] = [:]
        var stepResult: Int32 = SQLITE_DONE
        while true {
            stepResult = sqlite3_step(stmt)
            guard stepResult == SQLITE_ROW else { break }
            let cid = columnString(stmt, index: 0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cid.isEmpty else { continue }
            let rawTitle = columnString(stmt, index: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawWorkspaces = columnString(stmt, index: 2)
            let rawParent = columnString(stmt, index: 3).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let depth = Int(sqlite3_column_int64(stmt, 4))
            let rawAgent = columnString(stmt, index: 5).trimmingCharacters(in: .whitespacesAndNewlines)

            let firstURI = extractFirstWorkspaceURI(from: rawWorkspaces)
            let wsPath = LanguageServerClient.cleanWorkspacePath(from: firstURI)
            let wsName = LanguageServerClient.cleanWorkspaceName(repoName: nil, uri: firstURI)
            let parentId = (!rawParent.isEmpty && rawParent != cid) ? rawParent : nil

            out[cid] = LocalSessionMetadata(
                cascadeId: cid,
                title: rawTitle.isEmpty ? nil : rawTitle,
                workspaceName: wsName,
                workspacePath: wsPath,
                clientSource: source,
                parentConversationId: parentId,
                nestingDepth: max(depth, parentId != nil ? 1 : 0),
                agentRole: rawAgent.isEmpty ? nil : rawAgent
            )
        }
        guard stepResult == SQLITE_DONE else {
            return nil
        }
        return out
    }

    private static func columnString(_ stmt: OpaquePointer, index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private static func extractFirstWorkspaceURI(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]" else { return nil }
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return arr.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        let parts = trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.first
    }

    private static func readAnnotationsDirectory(at dir: URL) -> [String: String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var map: [String: String] = [:]
        for file in urls where file.pathExtension == "pbtxt" {
            let cid = file.deletingPathExtension().lastPathComponent.lowercased()
            guard !cid.isEmpty,
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  let title = parsePbtxtTitle(text) else {
                continue
            }
            map[cid] = title
        }
        return map
    }

    static func parsePbtxtTitle(_ text: String) -> String? {
        guard let range = text.range(of: #"title:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) else {
            return nil
        }
        let matched = String(text[range])
        guard let firstQuote = matched.firstIndex(of: "\""),
              let lastQuote = matched.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            return nil
        }
        let inner = String(matched[matched.index(after: firstQuote)..<lastQuote])
        let unescaped = inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unescaped.isEmpty ? nil : unescaped
    }
}
