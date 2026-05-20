import Foundation

/// Parses tail of a Claude Code session JSONL file into a SessionSnapshot.
/// Walks events in order so we can infer turn state from the *last meaningful*
/// line, not any line — e.g. a tool result coming back after a Bash run is
/// what flips state from "running tool" to "processing".
enum JSONLParser {
    enum LastEvent {
        case none
        case assistantThinking(stop: String?)
        case assistantText(stop: String?)
        case assistantToolUse(name: String, stop: String?)
        case userPrompt
        case userToolResult
    }

    /// Inputs to `inferActivity`, captured at parse time so the poller can
    /// re-derive the time-dependent activity later (e.g. for `.justFinished`
    /// to decay to `.idle` without re-tailing the file).
    struct ActivityInputs {
        let lastEvent: LastEvent
        let lastEventAt: Date
        let permissionMode: String
    }

    /// Re-runs the activity state machine using cached inputs and the
    /// authoritative awaiting-permission flag from the hook marker. Used by
    /// the poller for unchanged files so time-decay states like
    /// `.justFinished` settle to `.idle` without re-tailing.
    static func recomputeActivity(inputs: ActivityInputs, awaitingPermission: Bool) -> SessionActivity {
        if awaitingPermission { return .awaitingUser }
        return inferActivity(
            lastEvent: inputs.lastEvent,
            lastEventAt: inputs.lastEventAt,
            permissionMode: inputs.permissionMode,
            now: Date()
        )
    }

    static func parse(sessionId: String, projectDir: String, host: DetectedHost, defaultModelHint: String?, awaitingPermission: Bool, lines: [String], fileMTime: Date) -> (SessionSnapshot, ActivityInputs)? {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var lastAssistantPreview: String?
        var lastEntryAt: Date = fileMTime

        var lastEvent: LastEvent = .none
        var lastEventAt: Date = fileMTime

        // Latest-turn metadata.
        var lastModel: String?
        var lastBranch: String?
        var lastCwd: String?
        var lastContextTokens: Int = 0   // input + cache_read of most recent turn
        var lastPermissionMode: String = "default"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        let metaTypes: Set<String> = [
            "file-history-snapshot", "last-prompt", "permission-mode",
            "attachment", "system",
        ]

        // Dedup tokens by `message.id`. Claude Code splits one API response
        // into multiple JSONL lines (one per content block: thinking/text/
        // tool_use), but stamps every line with the *same* message id and the
        // *same* full-response usage. Counting each one inflates totals by
        // ~50-100%. `/usage` dedupes by id; we must too.
        var seenMessageIds: Set<String> = []

        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let entryType = obj["type"] as? String ?? ""

            var entryDate: Date?
            if let ts = obj["timestamp"] as? String {
                entryDate = iso.date(from: ts) ?? isoNoFrac.date(from: ts)
            }
            if let d = entryDate { lastEntryAt = d }

            if entryType == "assistant", let message = obj["message"] as? [String: Any] {
                let messageId = message["id"] as? String
                let firstSeen = messageId.map { seenMessageIds.insert($0).inserted } ?? true
                if firstSeen, let usage = message["usage"] as? [String: Any] {
                    let inp = (usage["input_tokens"] as? Int) ?? 0
                    let out = (usage["output_tokens"] as? Int) ?? 0
                    let cr  = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let cc  = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    inputTokens += inp
                    outputTokens += out
                    cacheReadTokens += cr
                    cacheCreationTokens += cc
                    // Context size = what was sent in this turn's prompt.
                    // input_tokens covers only the new tail; the bulk is in
                    // cache. cr + cc + inp ≈ total prompt size.
                    lastContextTokens = inp + cr + cc
                }
                if let m = message["model"] as? String { lastModel = m }
            }
            if let cwd = obj["cwd"] as? String { lastCwd = cwd }
            if let br = obj["gitBranch"] as? String, !br.isEmpty { lastBranch = br }
            // permissionMode is emitted on dedicated entries and also lives
            // on user-prompt entries; either source is fine.
            if entryType == "permission-mode", let m = obj["permissionMode"] as? String {
                lastPermissionMode = m
            } else if let m = obj["permissionMode"] as? String, !m.isEmpty {
                lastPermissionMode = m
            }

            if metaTypes.contains(entryType) { continue }

            if entryType == "assistant", let message = obj["message"] as? [String: Any] {
                let stop = message["stop_reason"] as? String
                let blocks = (message["content"] as? [[String: Any]]) ?? []
                // Last block in the message indicates what Claude is currently
                // doing/just did — Claude streams one block type at a time.
                if let last = blocks.last, let kind = last["type"] as? String {
                    switch kind {
                    case "thinking":
                        lastEvent = .assistantThinking(stop: stop)
                    case "tool_use":
                        let name = (last["name"] as? String) ?? "tool"
                        lastEvent = .assistantToolUse(name: name, stop: stop)
                    case "text":
                        lastEvent = .assistantText(stop: stop)
                        if let txt = last["text"] as? String, !txt.isEmpty {
                            lastAssistantPreview = String(txt.prefix(200))
                        }
                    default:
                        break
                    }
                    if let d = entryDate { lastEventAt = d }
                }
            } else if entryType == "user", let message = obj["message"] as? [String: Any] {
                let content = message["content"]
                let isToolResult: Bool = {
                    if let arr = content as? [[String: Any]] {
                        return arr.contains { ($0["type"] as? String) == "tool_result" }
                    }
                    return false
                }()
                lastEvent = isToolResult ? .userToolResult : .userPrompt
                if let d = entryDate { lastEventAt = d }
            }
        }

        // The hook-set marker is authoritative: if it's present, Claude is
        // blocked on a permission dialog right now.
        let activity: SessionActivity = awaitingPermission
            ? .awaitingUser
            : inferActivity(
                lastEvent: lastEvent,
                lastEventAt: lastEventAt,
                permissionMode: lastPermissionMode,
                now: Date()
            )
        let project: String = {
            if let cwd = lastCwd, let last = cwd.split(separator: "/").last { return String(last) }
            return prettifyProject(projectDir)
        }()

        let snap = SessionSnapshot(
            id: "\(host.alias)/\(sessionId)",
            host: host.alias,
            isLocal: host.isLocal,
            project: project,
            activity: activity,
            lastMessageAt: lastEntryAt,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            lastAssistantPreview: lastAssistantPreview,
            model: lastModel,
            gitBranch: lastBranch,
            contextTokens: lastContextTokens,
            modelContextLimit: contextLimit(
                jsonlModel: lastModel,
                hint: defaultModelHint,
                observedTokens: lastContextTokens
            )
        )
        let inputs = ActivityInputs(
            lastEvent: lastEvent,
            lastEventAt: lastEventAt,
            permissionMode: lastPermissionMode
        )
        return (snap, inputs)
    }

    /// Decide the context-window size for a session.
    ///
    /// Signals, in priority order:
    ///   1. `[1m]` suffix in the JSONL model id (rare — Bedrock often strips it).
    ///   2. `[1m]` suffix in settings.json `model` AND the session's model is
    ///      in the same Claude family. If the user has 1M-tier access for one
    ///      Opus model, they have it for any Opus model they run.
    ///   3. Observed prompt size > 200k → must be 1M, regardless of hints.
    ///   4. Default 200K.
    private static func contextLimit(jsonlModel: String?, hint: String?, observedTokens: Int) -> Int {
        let model = (jsonlModel ?? "").lowercased()
        let hintLower = (hint ?? "").lowercased()

        // 1. Direct `[1m]` on the running model.
        if model.contains("[1m]") || model.hasSuffix("-1m") { return 1_000_000 }

        // 2. Hint declares `[1m]` for this family.
        if hintLower.contains("[1m]") || hintLower.contains("-1m") {
            if family(of: model) != nil, family(of: model) == family(of: hintLower) {
                return 1_000_000
            }
            // Different family in the hint, but if hint mentions any 1M model
            // assume the user has 1M access for the whole tier — Anthropic's
            // 1M is a tier flag, not per-model.
            return 1_000_000
        }

        // 3. Observation overrides defaults: if we've already used >200k, the
        // window can't be 200k.
        if observedTokens > 200_000 { return 1_000_000 }

        return 200_000
    }

    private static func family(of modelString: String) -> String? {
        if modelString.contains("opus") { return "opus" }
        if modelString.contains("sonnet") { return "sonnet" }
        if modelString.contains("haiku") { return "haiku" }
        return nil
    }

    /// Tools whose semantic is "Claude is blocking on user input". When one
    /// of these is dispatched without a result yet, surface as `awaitingUser`
    /// rather than `running(tool:)` so it visually stands out.
    private static let blockingUserTools: Set<String> = [
        "AskUserQuestion", "ExitPlanMode",
    ]

    /// Whether a tool will run without prompting for user approval given the
    /// current permission mode.
    private static func isAutoApproved(tool: String, mode: String) -> Bool {
        switch mode {
        case "bypassPermissions", "auto", "dontAsk":
            return true
        case "acceptEdits":
            // acceptEdits auto-approves Edit/Write/MultiEdit/NotebookEdit but
            // still prompts for Bash and other side-effecting tools.
            let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
            return editTools.contains(tool)
        case "plan":
            // In plan mode nothing runs without approval.
            return false
        default:
            // "default" mode: most tools prompt. Read-only tools never do.
            let alwaysAllowed: Set<String> = ["Read", "Glob", "Grep", "TodoWrite"]
            return alwaysAllowed.contains(tool)
        }
    }

    /// State machine driven by the last meaningful event:
    /// - assistant `AskUserQuestion`/`ExitPlanMode` tool_use, no result yet → awaitingUser
    /// - assistant any other tool_use, no result yet                        → running(tool)
    /// - user tool_result                                                   → processing
    /// - assistant thinking/text mid-turn                                   → thinking
    /// - assistant + stop=end_turn                                          → idle (Claude finished, nothing pending)
    /// - user prompt with no assistant reply yet                            → thinking
    fileprivate static func inferActivity(
        lastEvent: LastEvent,
        lastEventAt: Date,
        permissionMode: String,
        now: Date
    ) -> SessionActivity {
        let age = now.timeIntervalSince(lastEventAt)
        switch lastEvent {
        case .none:
            return age > 60 ? .idle : .idle

        case .assistantThinking(let stop):
            if stop == "end_turn" { return .idle }
            return age > 5 ? .idle : .thinking

        case .assistantText(let stop):
            if stop == "end_turn" { return .idle }
            return age > 5 ? .idle : .thinking

        case .assistantToolUse(let name, _):
            if blockingUserTools.contains(name) {
                return age > 600 ? .idle : .awaitingUser
            }
            // Long-running tool (Bash etc.) — don't age out aggressively.
            // Permission-blocked state is detected separately via the hook
            // marker, so we don't need a time heuristic here.
            return age > 600 ? .idle : .running(tool: name)

        case .userToolResult:
            return age > 60 ? .idle : .processing

        case .userPrompt:
            return age > 60 ? .idle : .thinking
        }
    }

    private static func prettifyProject(_ encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = trimmed.split(separator: "-")
        return parts.last.map(String.init) ?? encoded
    }

}
