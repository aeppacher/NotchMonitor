import Foundation

/// Kiro CLI agent provider. Parses Kiro's JSONL format and reads metadata
/// from the companion .json file (cwd, model, context usage).
struct KiroProvider: AgentProvider {
    let kind: AgentKind = .kiro
    let sessionBaseDir = ".kiro/sessions/cli"
    let findDepth = (min: 1, max: 1)
    let needsCompanionJSON = true

    func parse(
        sessionId: String,
        projectDir: String,
        host: DetectedHost,
        defaultModelHint: String?,
        awaitingPermission: Bool,
        lines: [String],
        fileMTime: Date,
        companionJSON: String?
    ) -> (SessionSnapshot, JSONLParser.ActivityInputs, PermissionRequest?)? {
        KiroParser.parse(
            sessionId: sessionId,
            host: host,
            awaitingPermission: awaitingPermission,
            lines: lines,
            fileMTime: fileMTime,
            companionJSON: companionJSON
        )
    }

    func recomputeActivity(inputs: JSONLParser.ActivityInputs, awaitingPermission: Bool) -> SessionActivity {
        if awaitingPermission { return .awaitingUser }
        // Without fresh companion JSON we can't know isMidTurn, so we
        // conservatively check only the awaiting-approval case. The full
        // state is recomputed when the file changes (triggering a re-parse
        // with fresh companion data).
        return KiroParser.inferActivity(inputs: inputs, isMidTurn: false)
    }
}

/// Parses Kiro CLI session JSONL files.
///
/// Kiro format differences from Claude Code:
/// - Top-level `kind` field: "Prompt", "AssistantMessage", "ToolResults", "Clear"
/// - Content blocks use `kind`: "text", "toolUse", "toolResult", "thinking"
/// - Timestamps only on Prompt entries (unix epoch in `data.meta.timestamp`)
/// - No token usage in JSONL — comes from companion JSON
/// - No cwd/model in JSONL — comes from companion JSON
enum KiroParser {

    /// Tools that Kiro auto-approves (never prompt the user).
    /// Kiro prompts for most filesystem tools including read — only MCP
    /// tools in trusted_tools and internal agent tools skip the prompt.
    private static let autoApprovedTools: Set<String> = [
        "summary", "subagent",
    ]

    /// Kiro only gives us two meaningful states from its JSONL:
    ///   1. Awaiting approval (toolUse pending for a non-auto-approved tool)
    ///   2. Working (anything else mid-turn)
    ///
    /// We use `isMidTurn` (from companion JSON turn count) as the primary
    /// signal for whether the session is active, and fall back to the last
    /// event only to detect the awaiting-approval case.
    static func inferActivity(inputs: JSONLParser.ActivityInputs, isMidTurn: Bool) -> SessionActivity {
        let age = Date().timeIntervalSince(inputs.lastEventAt)

        // Check for awaiting approval: last event is toolUse for a
        // non-auto-approved tool and no ToolResults has followed.
        if case .assistantToolUse(let name, _) = inputs.lastEvent {
            if !autoApprovedTools.contains(name) && age > 3 {
                return .awaitingUser
            }
        }

        // If the companion JSON says we're mid-turn, show as thinking.
        if isMidTurn {
            return .thinking
        }

        return .idle
    }

    static func parse(
        sessionId: String,
        host: DetectedHost,
        awaitingPermission: Bool,
        lines: [String],
        fileMTime: Date,
        companionJSON: String?
    ) -> (SessionSnapshot, JSONLParser.ActivityInputs, PermissionRequest?)? {
        var lastEvent: JSONLParser.LastEvent = .none
        var lastEventAt: Date = fileMTime
        var lastAssistantPreview: String?
        var promptCount: Int = 0
        var lastToolInput: [String: Any] = [:]

        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let kind = obj["kind"] as? String ?? ""
            let payload = obj["data"] as? [String: Any]

            switch kind {
            case "Prompt":
                promptCount += 1
                if let meta = payload?["meta"] as? [String: Any],
                   let ts = meta["timestamp"] as? TimeInterval {
                    lastEventAt = Date(timeIntervalSince1970: ts)
                }
                lastEvent = .userPrompt

            case "AssistantMessage":
                guard let content = payload?["content"] as? [[String: Any]],
                      !content.isEmpty
                else { continue }

                // Kiro emits all blocks in one message: [thinking, text, toolUse].
                // Priority: toolUse > thinking > text (most "active" state wins).
                var hasThinking = false
                var hasToolUse: String?
                var textPreview: String?

                for block in content {
                    guard let blockKind = block["kind"] as? String else { continue }
                    switch blockKind {
                    case "thinking":
                        hasThinking = true
                    case "toolUse":
                        let toolData = block["data"] as? [String: Any]
                        hasToolUse = (toolData?["name"] as? String) ?? "tool"
                        lastToolInput = (toolData?["input"] as? [String: Any]) ?? [:]
                    case "text":
                        if let t = block["data"] as? String, !t.isEmpty {
                            textPreview = String(t.prefix(200))
                        } else if let td = block["data"] as? [String: Any],
                                  let t = td["text"] as? String, !t.isEmpty {
                            textPreview = String(t.prefix(200))
                        }
                    default:
                        break
                    }
                }

                if let tool = hasToolUse {
                    lastEvent = .assistantToolUse(name: tool, stop: nil)
                } else if hasThinking && textPreview == nil {
                    // Still thinking (no text output yet)
                    lastEvent = .assistantThinking(stop: nil)
                } else {
                    // Text with no pending tool call = turn finished
                    lastEvent = .assistantText(stop: "end_turn")
                }
                if let preview = textPreview {
                    lastAssistantPreview = preview
                }

            case "ToolResults":
                lastEvent = .userToolResult

            case "Clear":
                lastEvent = .none
                lastAssistantPreview = nil

            default:
                break
            }
        }

        // Extract metadata from companion JSON
        var cwd: String?
        var model: String?
        var contextWindow: Int = 200_000
        var contextPct: Double = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var credits: Double = 0
        var completedTurns: Int = 0
        var totalDuration: Int = 0
        var toolUses: Int = 0
        var updatedAt: Date?

        if let json = companionJSON, let jsonData = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            cwd = obj["cwd"] as? String
            model = obj["model"] as? String
            if let cw = obj["context_window"] as? Int, cw > 0 { contextWindow = cw }
            if let pct = obj["context_pct"] as? Double { contextPct = pct }
            if let inp = obj["input_tokens"] as? Int { inputTokens = inp }
            if let out = obj["output_tokens"] as? Int { outputTokens = out }
            if let cr = obj["credits"] as? Double { credits = cr }
            if let ct = obj["completed_turns"] as? Int { completedTurns = ct }
            if let td = obj["total_duration"] as? Int { totalDuration = td }
            if let tu = obj["tool_uses"] as? Int { toolUses = tu }
            if let ua = obj["updated_at"] as? String, !ua.isEmpty {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let isoNoFrac = ISO8601DateFormatter()
                isoNoFrac.formatOptions = [.withInternetDateTime]
                updatedAt = iso.date(from: ua) ?? isoNoFrac.date(from: ua)
            }
        }

        // If there are more prompts in the JSONL than completed turns in the
        // companion JSON, the session is mid-turn (actively thinking/running).
        let isMidTurn = promptCount > completedTurns

        let lastMessageAt: Date = {
            if lastEventAt != fileMTime { return lastEventAt }
            if let ua = updatedAt { return ua }
            return fileMTime
        }()

        let inputs = JSONLParser.ActivityInputs(
            lastEvent: lastEvent,
            lastEventAt: lastEventAt,
            permissionMode: "default"
        )
        let activity: SessionActivity = awaitingPermission
            ? .awaitingUser
            : KiroParser.inferActivity(inputs: inputs, isMidTurn: isMidTurn)

        let project: String = {
            if let c = cwd, let last = c.split(separator: "/").last { return String(last) }
            return sessionId
        }()

        let contextTokens = Int(contextPct / 100.0 * Double(contextWindow))

        let snap = SessionSnapshot(
            id: "\(host.alias)/kiro-\(sessionId)",
            host: host.alias,
            isLocal: host.isLocal,
            agent: .kiro,
            project: project,
            activity: activity,
            lastMessageAt: lastMessageAt,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            credits: credits > 0 ? credits : nil,
            turnCount: completedTurns > 0 ? completedTurns : nil,
            totalDurationSecs: totalDuration > 0 ? totalDuration : nil,
            toolUseCount: toolUses > 0 ? toolUses : nil,
            lastAssistantPreview: lastAssistantPreview,
            model: model,
            gitBranch: nil,
            cwd: cwd,
            contextTokens: contextTokens,
            modelContextLimit: contextWindow
        )

        // Build permission request if blocked on a tool approval
        let permRequest: PermissionRequest? = (activity == .awaitingUser)
            ? PermissionRequest(
                sessionId: sessionId,
                toolName: {
                    if case .assistantToolUse(let name, _) = lastEvent { return name }
                    return "tool"
                }(),
                toolInput: lastToolInput
            )
            : nil

        return (snap, inputs, permRequest)
    }
}
