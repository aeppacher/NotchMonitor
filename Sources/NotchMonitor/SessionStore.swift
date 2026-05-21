import Foundation
import Combine
import SwiftUI

enum AgentKind: String, CaseIterable, Equatable {
    case claude
    case kiro

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .kiro:   return "Kiro"
        }
    }

    var tintColor: Color {
        switch self {
        case .claude: return .orange
        case .kiro:   return .purple
        }
    }
}

enum SessionActivity: Equatable {
    case thinking                  // assistant streaming text/thinking mid-turn
    case running(tool: String)     // tool dispatched, awaiting result
    case processing                // tool returned, assistant about to react (autonomous)
    case awaitingUser              // AskUserQuestion / ExitPlanMode actively pending — your input required
    case idle                      // nothing happening / turn ended

    var label: String {
        switch self {
        case .thinking: return "Thinking…"
        case .running(let t): return "Running \(t)"
        case .processing: return "Processing…"
        case .awaitingUser: return "Awaiting input"
        case .idle: return "Idle"
        }
    }

    /// Higher = more attention-grabbing. Used to pick the aggregate state
    /// across multiple sessions.
    var priority: Int {
        switch self {
        case .awaitingUser: return 5
        case .running: return 4
        case .thinking: return 3
        case .processing: return 2
        case .idle: return 1
        }
    }

    /// Category used for grouping sessions in the aggregate badge — collapses
    /// `running(Bash)` and `running(Edit)` into a single "running" bucket so
    /// the count reflects the visible status color.
    var category: Int {
        switch self {
        case .awaitingUser: return 5
        case .running:      return 4
        case .thinking:     return 3
        case .processing:   return 2
        case .idle:         return 1
        }
    }
}

struct SessionSnapshot: Identifiable, Equatable {
    let id: String          // session uuid (jsonl filename without extension)
    let host: String        // "local" or ssh alias
    let isLocal: Bool
    let agent: AgentKind
    let project: String     // human-readable project name (cwd basename)
    let activity: SessionActivity
    let lastMessageAt: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let credits: Double?            // Kiro uses credits instead of tokens
    let turnCount: Int?             // Kiro: number of completed turns
    let totalDurationSecs: Int?     // Kiro: cumulative turn duration
    let toolUseCount: Int?          // Kiro: total tool invocations
    let lastAssistantPreview: String?

    // Latest-turn metadata (most recent assistant message wins)
    let model: String?              // raw id, e.g. "claude-opus-4-7"
    let gitBranch: String?
    let cwd: String?                // working directory (for local git status)
    let contextTokens: Int          // size of latest prompt sent to Claude
    let modelContextLimit: Int      // model's window in tokens

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    var contextFraction: Double {
        guard modelContextLimit > 0 else { return 0 }
        return min(1.0, Double(contextTokens) / Double(modelContextLimit))
    }

    /// Pretty model name from raw IDs like "claude-opus-4-7", "claude-opus-4.7-1m",
    /// "minimax-m2.5", "deepseek-3.2", "qwen3-coder-480b", "auto", etc.
    var modelPretty: String {
        guard let m = model else { return "—" }
        // Strip "-1m" suffix (context window indicator, not useful for display)
        let cleaned = m.replacingOccurrences(of: "-1m", with: "")
            .replacingOccurrences(of: "-1M", with: "")
        let lower = cleaned.lowercased()

        // Special case: "auto" mode
        if lower == "auto" { return "Auto" }

        // Claude models: extract family + version
        if lower.contains("opus") || lower.contains("sonnet") || lower.contains("haiku") {
            let family: String =
                lower.contains("opus") ? "Opus" :
                lower.contains("sonnet") ? "Sonnet" : "Haiku"
            let parts = lower.split(separator: "-")
            if let idx = parts.firstIndex(where: { $0.first?.isNumber == true }) {
                let version = parts[idx...].joined(separator: ".")
                return version.isEmpty ? family : "\(family) \(version)"
            }
            return family
        }

        // Generic models: capitalize each segment, treat first numeric as version.
        // "minimax-m2.5" → "Minimax M2.5", "deepseek-3.2" → "Deepseek 3.2"
        // "qwen3-coder-480b" → "Qwen3 Coder 480b", "glm-5" → "GLM 5"
        let parts = cleaned.split(separator: "-")
        let formatted = parts.map { segment -> String in
            let s = String(segment)
            // All-letter segments ≤4 chars that look like acronyms: uppercase
            if s.count <= 4 && s.allSatisfy(\.isLetter) && s == s.lowercased() {
                // Common acronyms
                let acronyms: Set<String> = ["glm", "agi"]
                if acronyms.contains(s) { return s.uppercased() }
            }
            // Capitalize first letter
            return s.prefix(1).uppercased() + s.dropFirst()
        }
        return formatted.joined(separator: " ")
    }
}

enum HostState: Equatable {
    case connecting   // SSH not yet established / first probe in flight
    case settingUp    // first poll succeeded, hooks being installed
    case active       // hooks installed, polling normally
    case offline      // recent failure
    case localOk      // local always-on bucket

    var label: String {
        switch self {
        case .connecting: return "connecting"
        case .settingUp:  return "setup"
        case .active:     return "active"
        case .offline:    return "offline"
        case .localOk:    return "active"
        }
    }
}

struct HostStatus: Identifiable, Equatable {
    let id: String        // alias
    let isLocal: Bool
    let state: HostState
}

/// Aggregated token totals computed from each host's
/// `~/.claude/stats-cache.json`. Same source `/usage` reads — covers every
/// session, not just the active 60-min window. We track all-time and last-
/// 24-hour separately.
struct DailyTotals: Equatable {
    let tokensAllTime: Int
    let tokensLast24h: Int
}

struct GitStatus: Equatable {
    let additions: Int
    let deletions: Int

    var isEmpty: Bool { additions == 0 && deletions == 0 }
}

struct PermissionRequest: Equatable {
    let sessionId: String
    let toolName: String
    let toolInput: [String: Any]

    var inputPreview: String {
        if let path = toolInput["file_path"] as? String {
            return path
        }
        if let path = toolInput["path"] as? String {
            return path
        }
        if let cmd = toolInput["command"] as? String {
            // Kiro uses "command" for operation type (e.g. "insert"),
            // Claude uses it for shell commands. Only show if it looks
            // like a real command (longer than a single word).
            if cmd.contains(" ") || cmd.contains("/") {
                return String(cmd.prefix(120))
            }
        }
        if let query = toolInput["query"] as? String {
            return String(query.prefix(120))
        }
        return ""
    }

    static func == (lhs: PermissionRequest, rhs: PermissionRequest) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.toolName == rhs.toolName && lhs.inputPreview == rhs.inputPreview
    }
}

final class SessionStore: ObservableObject {
    @Published var sessions: [SessionSnapshot] = []
    @Published var lastError: String?
    @Published var connected: Bool = false
    @Published var hasPolled: Bool = false
    @Published var hosts: [HostStatus] = []
    @Published var todayTotals: DailyTotals = DailyTotals(tokensAllTime: 0, tokensLast24h: 0)
    @Published var gitStatusByPath: [String: GitStatus] = [:]
    @Published var permissionRequests: [String: PermissionRequest] = [:]

    /// Force an immediate poll across every host. Wired to the Poller in
    /// AppDelegate so the UI doesn't need to know about it directly.
    var onReloadAll: (() -> Void)?

    /// Reset all sessions to idle and clear pending permission requests.
    func reset() {
        permissionRequests.removeAll()
        sessions = sessions.map { s in
            SessionSnapshot(
                id: s.id, host: s.host, isLocal: s.isLocal,
                agent: s.agent,
                project: s.project,
                activity: .idle,
                lastMessageAt: Date(),
                inputTokens: s.inputTokens,
                outputTokens: s.outputTokens,
                cacheReadTokens: s.cacheReadTokens,
                cacheCreationTokens: s.cacheCreationTokens,
                credits: s.credits,
                turnCount: s.turnCount,
                totalDurationSecs: s.totalDurationSecs,
                toolUseCount: s.toolUseCount,
                lastAssistantPreview: s.lastAssistantPreview,
                model: s.model, gitBranch: s.gitBranch,
                cwd: s.cwd,
                contextTokens: s.contextTokens,
                modelContextLimit: s.modelContextLimit
            )
        }
    }

    /// Sessions the user has explicitly dismissed, mapped to the
    /// `lastMessageAt` value at the time of dismissal. The session stays
    /// hidden until a poll observes a strictly newer `lastMessageAt`, at
    /// which point the entry is cleared and the row reappears.
    private var dismissedAt: [String: Date] = [:]

    /// Hide a session from the UI until it next receives an update.
    func dismissSession(id: String) {
        guard let snap = sessions.first(where: { $0.id == id }) else { return }
        dismissedAt[id] = snap.lastMessageAt
        sessions.removeAll { $0.id == id }
    }

    var aggregateActivity: SessionActivity {
        sessions.map { $0.activity }
            .max(by: { $0.priority < $1.priority }) ?? .idle
    }

    /// Number of sessions whose activity matches the aggregate's category.
    /// e.g. if aggregate is `running(Bash)`, this counts every session in any
    /// `running(*)` state, not just Bash. Used by the status-bar badge so it
    /// reads "3 idle" or "1 awaiting" depending on what's hottest.
    var aggregateMatchCount: Int {
        let target = aggregateActivity.category
        return sessions.filter { $0.activity.category == target }.count
    }

    func update(_ snapshots: [SessionSnapshot], connected: Bool, error: String?, hosts: [HostStatus], todayTotals: DailyTotals, gitStatus: [String: GitStatus] = [:], permissionRequests: [String: PermissionRequest] = [:]) {
        self.todayTotals = todayTotals
        // Filter out dismissed sessions whose lastMessageAt hasn't advanced
        // past the moment the user dismissed them. Once an update arrives,
        // drop the dismissal so the row is shown again.
        let visible = snapshots.filter { snap in
            guard let dismissedTime = dismissedAt[snap.id] else { return true }
            if snap.lastMessageAt > dismissedTime {
                dismissedAt.removeValue(forKey: snap.id)
                return true
            }
            return false
        }
        // Garbage-collect dismissals for sessions no longer present at all
        // (e.g. aged out of the 60-min window) so the dict doesn't grow.
        let presentIds = Set(snapshots.map(\.id))
        dismissedAt = dismissedAt.filter { presentIds.contains($0.key) }

        self.sessions = visible.sorted { $0.lastMessageAt > $1.lastMessageAt }
        self.connected = connected
        self.lastError = error
        self.hasPolled = true
        self.hosts = hosts
        self.gitStatusByPath = gitStatus
        self.permissionRequests = permissionRequests
    }
}

