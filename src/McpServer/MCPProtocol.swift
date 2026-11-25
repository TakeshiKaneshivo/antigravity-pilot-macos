import Foundation

enum MCPAppConstants {
    static let resourceURI = "ui://pilot/dashboard.html"
    static let mimeType = "text/html;profile=mcp-app"
    static let defaultProtocolVersion = "2025-03-26"
}

struct MCPToolResult {
    let text: String
    let structuredContent: [String: Any]
    let isError: Bool

    init(text: String, structuredContent: [String: Any] = [:], isError: Bool = false) {
        self.text = text
        self.structuredContent = structuredContent
        self.isError = isError
    }

    func toJSONObject() -> [String: Any] {
        var obj: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ],
            "isError": isError
        ]
        if !structuredContent.isEmpty {
            obj["structuredContent"] = structuredContent
        }
        return obj
    }
}

protocol MCPServiceHandling: Sendable {
    var serverVersion: String { get }
    func currentLanguage() -> AppLanguage
    func loadDashboardHTML() throws -> String
    func callTool(name: String, arguments: [String: Any]) async -> MCPToolResult
}

final class StdoutWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle = FileHandle.standardOutput

    func writeJSONLine(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            logStderr("Failed to serialize JSON-RPC response")
            return
        }
        var line = data
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        handle.write(line)
    }

    func logStderr(_ message: String) {
        let line = "[antigravity-pilot-mcp] \(message)\n"
        if let data = line.data(using: .utf8) {
            lock.lock()
            defer { lock.unlock() }
            FileHandle.standardError.write(data)
        }
    }
}

private actor ActiveTaskTracker {
    private var activeIds = Set<UUID>()

    func insert(_ id: UUID) {
        activeIds.insert(id)
    }

    func remove(_ id: UUID) {
        activeIds.remove(id)
    }

    var isEmpty: Bool {
        activeIds.isEmpty
    }
}

final class MCPStdioServer {
    private let handler: MCPServiceHandling
    private let writer = StdoutWriter()

    init(handler: MCPServiceHandling) {
        self.handler = handler
    }

    private static func stdinChunksStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.takeshikaneshivo.antigravity-pilot.mcp.stdin")
            queue.async {
                let stdinHandle = FileHandle.standardInput
                while true {
                    let chunk = stdinHandle.availableData
                    if chunk.isEmpty {
                        continuation.finish()
                        break
                    }
                    continuation.yield(chunk)
                }
            }
        }
    }

    func run() async {
        var buffer = Data()
        let tracker = ActiveTaskTracker()

        for await chunk in Self.stdinChunksStream() {
            buffer.append(chunk)

            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIdx)
                buffer.removeSubrange(buffer.startIndex...newlineIdx)
                let trimmed = trimLine(lineData)
                guard !trimmed.isEmpty else { continue }

                let taskId = UUID()
                await tracker.insert(taskId)

                Task.detached(priority: .userInitiated) { [handler, writer, tracker] in
                    await Self.processLine(trimmed, handler: handler, writer: writer)
                    await tracker.remove(taskId)
                }
            }
        }

        let remaining = trimLine(buffer)
        if !remaining.isEmpty {
            await Self.processLine(remaining, handler: handler, writer: writer)
        }

        // Wait briefly for any in-flight tool calls before exiting on EOF
        for _ in 0..<100 {
            if await tracker.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func trimLine(_ data: Data) -> Data {
        var slice = data
        while let last = slice.last, last == 0x0D || last == 0x20 || last == 0x09 {
            slice.removeLast()
        }
        while let first = slice.first, first == 0x20 || first == 0x09 {
            slice.removeFirst()
        }
        return slice
    }

    private static func processLine(_ data: Data, handler: MCPServiceHandling, writer: StdoutWriter) async {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            writer.writeJSONLine(errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
            return
        }

        let requestId = obj["id"]
        let isNotification = (requestId == nil || requestId is NSNull)
        guard let method = obj["method"] as? String else {
            if !isNotification, let id = requestId {
                writer.writeJSONLine(errorResponse(id: id, code: -32600, message: "Invalid Request"))
            }
            return
        }

        let params = obj["params"] as? [String: Any] ?? [:]

        // Notifications must not receive a response
        if isNotification {
            return
        }
        let id = requestId!

        switch method {
        case "initialize":
            let clientVersion = (params["protocolVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let negotiatedVersion = (clientVersion?.isEmpty == false) ? clientVersion! : MCPAppConstants.defaultProtocolVersion
            let result: [String: Any] = [
                "protocolVersion": negotiatedVersion,
                "capabilities": [
                    "tools": [
                        "listChanged": false
                    ],
                    "resources": [
                        "subscribe": false,
                        "listChanged": false
                    ]
                ],
                "serverInfo": [
                    "name": "antigravity-pilot-mcp",
                    "version": handler.serverVersion
                ]
            ]
            writer.writeJSONLine(successResponse(id: id, result: result))

        case "ping":
            writer.writeJSONLine(successResponse(id: id, result: [:]))

        case "tools/list":
            writer.writeJSONLine(successResponse(id: id, result: ["tools": toolDefinitions(lang: handler.currentLanguage())]))

        case "tools/call":
            guard let name = params["name"] as? String, !name.isEmpty else {
                writer.writeJSONLine(errorResponse(id: id, code: -32602, message: "Missing tool name"))
                return
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = await handler.callTool(name: name, arguments: args)
            writer.writeJSONLine(successResponse(id: id, result: result.toJSONObject()))

        case "resources/list":
            let resources: [[String: Any]] = [
                [
                    "uri": MCPAppConstants.resourceURI,
                    "name": "Antigravity Pilot Dashboard",
                    "description": "Interactive Antigravity Pilot proxy health, live context/quota, and 1-year (52-week) usage & billing dashboard.",
                    "mimeType": MCPAppConstants.mimeType,
                    "_meta": [
                        "ui": [
                            "prefersBorder": false
                        ]
                    ]
                ]
            ]
            writer.writeJSONLine(successResponse(id: id, result: ["resources": resources]))

        case "resources/templates/list":
            writer.writeJSONLine(successResponse(id: id, result: ["resourceTemplates": [] as [[String: Any]]]))

        case "resources/read":
            guard let uri = params["uri"] as? String, uri == MCPAppConstants.resourceURI else {
                writer.writeJSONLine(errorResponse(id: id, code: -32002, message: "Resource not found"))
                return
            }
            do {
                let html = try handler.loadDashboardHTML()
                let contents: [[String: Any]] = [
                    [
                        "uri": MCPAppConstants.resourceURI,
                        "mimeType": MCPAppConstants.mimeType,
                        "text": html,
                        "_meta": [
                            "ui": [
                                "prefersBorder": false
                            ]
                        ]
                    ]
                ]
                writer.writeJSONLine(successResponse(id: id, result: ["contents": contents]))
            } catch {
                writer.writeJSONLine(errorResponse(id: id, code: -32603, message: error.localizedDescription))
            }

        default:
            writer.writeJSONLine(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private static func successResponse(id: Any, result: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    private static func toolDefinitions(lang: AppLanguage) -> [[String: Any]] {
        let monitorTitle = L10n.t("Pilot 实时监控", "Pilot Live Monitor", lang)
        let usageTitle = L10n.t("Pilot 用量与账单", "Pilot Usage & Billing", lang)

        let openMonitorMeta: [String: Any] = [
            "ui": [
                "resourceUri": MCPAppConstants.resourceURI
            ],
            "ui/resourceUri": MCPAppConstants.resourceURI,
            "com.google.antigravity/ui": [
                "entrypoints": [
                    [
                        "type": "aux_pane",
                        "title": monitorTitle
                    ]
                ]
            ]
        ]

        let openUsageMeta: [String: Any] = [
            "ui": [
                "resourceUri": MCPAppConstants.resourceURI
            ],
            "ui/resourceUri": MCPAppConstants.resourceURI,
            "com.google.antigravity/ui": [
                "entrypoints": [
                    [
                        "type": "global",
                        "title": usageTitle
                    ]
                ]
            ]
        ]

        let appOnlyMeta: [String: Any] = [
            "ui": [
                "visibility": ["app"]
            ]
        ]

        return [
            [
                "name": "open_pilot_monitor",
                "title": monitorTitle,
                "description": "Open the Antigravity Pilot live monitor view (3-stage proxy health, active session context, shared model quota pools) inside Antigravity.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cascadeId": [
                            "type": "string",
                            "description": "Optional conversation/cascade ID to inspect."
                        ]
                    ],
                    "additionalProperties": false
                ],
                "_meta": openMonitorMeta
            ],
            [
                "name": "open_pilot_usage",
                "title": usageTitle,
                "description": "Open the Antigravity Pilot usage heatmap & estimated API billing dashboard (1-year (52-week) activity, 14-day trend, model cost breakdown).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "period": [
                            "type": "string",
                            "enum": ["today", "days7", "days30", "all"],
                            "description": "Initial summary period to display."
                        ]
                    ],
                    "additionalProperties": false
                ],
                "_meta": openUsageMeta
            ],
            [
                "name": "pilot_get_live_snapshot",
                "title": "Refresh Pilot Live Snapshot",
                "description": "Fetch live session context, model quota pools, and read-only proxy config/health status for the Pilot UI.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cascadeId": [
                            "type": "string",
                            "description": "Optional conversation/cascade ID."
                        ],
                        "includeInternetCheck": [
                            "type": "boolean",
                            "description": "Whether to perform Stage 3 generate_204 internet check through SOCKS5."
                        ]
                    ],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ],
            [
                "name": "pilot_probe_proxy",
                "title": "Run 3-Stage Proxy Health Probe",
                "description": "Run full 3-stage proxy health check (TCP, SOCKS5 handshake, generate_204 latency) for the Pilot UI.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ],
            [
                "name": "pilot_get_usage_history",
                "title": "Refresh Pilot Usage History",
                "description": "Scan local transcript archives incrementally and return 1-year (52-week) heatmap, 14-day trend, and estimated API billing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ]
        ]
    }
}
