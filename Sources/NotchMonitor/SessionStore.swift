import Foundation
import Combine

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
    let project: String     // human-readable project name (cwd basename)
    let activity: SessionActivity
    let lastMessageAt: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
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

    /// Short pretty model name: "claude-opus-4-7" → "Opus 4.7"
    var modelPretty: String {
        guard let m = model else { return "—" }
        let lower = m.lowercased()
        let family: String =
            lower.contains("opus") ? "Opus" :
            lower.contains("sonnet") ? "Sonnet" :
            lower.contains("haiku") ? "Haiku" : m
        // Pull "x-y" from the trailing digits (e.g. "4-7" → "4.7").
        let digits = lower.split(separator: "-").suffix(2).joined(separator: ".")
        return digits.isEmpty ? family : "\(family) \(digits)"
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

final class SessionStore: ObservableObject {
    @Published var sessions: [SessionSnapshot] = []
    @Published var lastError: String?
    @Published var connected: Bool = false
    @Published var hasPolled: Bool = false
    @Published var hosts: [HostStatus] = []
    @Published var todayTotals: DailyTotals = DailyTotals(tokensAllTime: 0, tokensLast24h: 0)
    @Published var gitStatusByPath: [String: GitStatus] = [:]

    /// Force an immediate poll across every host. Wired to the Poller in
    /// AppDelegate so the UI doesn't need to know about it directly.
    var onReloadAll: (() -> Void)?
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

    func update(_ snapshots: [SessionSnapshot], connected: Bool, error: String?, hosts: [HostStatus], todayTotals: DailyTotals, gitStatus: [String: GitStatus] = [:]) {
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
    }
}

