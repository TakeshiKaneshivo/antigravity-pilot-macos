import Foundation

enum PilotHookEventKind: String, Codable, Equatable, Sendable {
    case taskCompleted = "task_completed"
    case taskErrored = "task_errored"
    case approvalNeeded = "approval_needed"
}

struct PilotHookEvent: Codable, Equatable, Sendable {
    let eventId: String
    let kind: PilotHookEventKind
    let conversationId: String
    let workspaceName: String?
    let summary: String?
    let terminationReason: String?
    let errorDetail: String?
    let timestampEpoch: Double
}

enum PilotHookMode: String, Sendable {
    case stop
    case preTool = "pre-tool"
}

enum PilotHookProcessor {
    static let darwinHookEventName = "com.takeshikaneshivo.antigravity-pilot.hook-event"

    static func parseHookStdin(
        _ data: Data,
        mode: PilotHookMode,
        now: Date = Date()
    ) -> (event: PilotHookEvent?, stdoutJSON: String) {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return (nil, "{}")
        }

        let conversationId = (json["conversationId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workspaceName: String? = {
            if let paths = json["workspacePaths"] as? [String],
               let first = paths.first?.trimmingCharacters(in: .whitespacesAndNewlines),
               !first.isEmpty {
                let name = URL(fileURLWithPath: first).lastPathComponent
                return name.isEmpty ? first : name
            }
            if let cwd = (json["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                let name = URL(fileURLWithPath: cwd).lastPathComponent
                return name.isEmpty ? cwd : name
            }
            return nil
        }()
        let lastInput = (json["lastUserInput"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryText = lastInput.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }

        switch mode {
        case .stop:
            let reason = (json["terminationReason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            let continuationActive = (json["continuationActive"] as? Bool) ?? false
            let fullyIdle = (json["fullyIdle"] as? Bool) ?? true

            if reason == "USER_CANCELED" || continuationActive || !fullyIdle {
                return (nil, "{}")
            }

            let errorStr = (json["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isError = !((errorStr ?? "").isEmpty)
                || reason == "ERROR"
                || reason == "MAX_INVOCATIONS"
                || reason == "MAX_FORCED_INVOCATIONS"
                || reason == "MAX_TOKEN_BUDGET_EXCEEDED"

            let event = PilotHookEvent(
                eventId: UUID().uuidString,
                kind: isError ? .taskErrored : .taskCompleted,
                conversationId: conversationId,
                workspaceName: workspaceName,
                summary: summaryText,
                terminationReason: reason.isEmpty ? nil : reason,
                errorDetail: (errorStr?.isEmpty == false) ? String(errorStr!.prefix(200)) : nil,
                timestampEpoch: now.timeIntervalSince1970
            )
            return (event, "{}")

        case .preTool:
            guard let toolCall = json["toolCall"] as? [String: Any],
                  let toolName = (toolCall["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() else {
                return (nil, "{}")
            }

            // Safety rule: ONLY match ask_question (interactive prompt tool); never return "allow" for privileged tools.
            guard toolName == "ask_question" else {
                return (nil, "{}")
            }

            let promptPreview: String? = {
                if let args = toolCall["args"] as? [String: Any],
                   let questions = args["questions"] as? [[String: Any]],
                   let firstQ = questions.first?["question"] as? String {
                    let trimmed = firstQ.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return String(trimmed.prefix(120))
                    }
                }
                return summaryText
            }()

            let event = PilotHookEvent(
                eventId: UUID().uuidString,
                kind: .approvalNeeded,
                conversationId: conversationId,
                workspaceName: workspaceName,
                summary: promptPreview,
                terminationReason: nil,
                errorDetail: nil,
                timestampEpoch: now.timeIntervalSince1970
            )
            return (event, "{\"decision\":\"allow\"}")
        }
    }

    static func appendEvent(_ event: PilotHookEvent, to url: URL, maxEntries: Int = 50) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        let lineData = try encoder.encode(event)
        guard let lineStr = String(data: lineData, encoding: .utf8) else { return }

        var lines: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            lines = existing
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
        lines.append(lineStr)
        if lines.count > maxEntries {
            lines = Array(lines.suffix(maxEntries))
        }
        let payload = (lines.joined(separator: "\n") + "\n")
        try Data(payload.utf8).write(to: url, options: .atomic)
    }

    static func drainUnconsumedEvents(
        from url: URL,
        sinceEpoch: Double
    ) -> (events: [PilotHookEvent], latestEpoch: Double) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ([], sinceEpoch)
        }
        let decoder = JSONDecoder()
        var events: [PilotHookEvent] = []
        var maxEpoch = sinceEpoch

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = rawLine.data(using: .utf8),
                  let ev = try? decoder.decode(PilotHookEvent.self, from: data) else {
                continue
            }
            if ev.timestampEpoch > sinceEpoch {
                events.append(ev)
                if ev.timestampEpoch > maxEpoch {
                    maxEpoch = ev.timestampEpoch
                }
            }
        }
        return (events, maxEpoch)
    }
}
