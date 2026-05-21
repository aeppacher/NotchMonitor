import Foundation

/// Abstracts agent-specific logic: where session files live, how to parse them,
/// and how to present the agent in the UI. Implement this protocol to add
/// support for a new AI coding agent (e.g. Codex).
protocol AgentProvider {
    var kind: AgentKind { get }

    /// Base directory relative to $HOME. e.g. ".claude/projects"
    var sessionBaseDir: String { get }

    /// `find` depth for session file discovery.
    /// Claude: (2, 2) for project-dir/session.jsonl
    /// Kiro: (1, 1) for flat session.jsonl
    var findDepth: (min: Int, max: Int) { get }

    /// Whether this provider needs a companion JSON file alongside the JSONL.
    var needsCompanionJSON: Bool { get }

    /// Parse JSONL lines (and optional companion JSON) into a snapshot.
    /// Returns the snapshot, activity inputs for caching, and an optional
    /// permission request if the session is currently blocked.
    func parse(
        sessionId: String,
        projectDir: String,
        host: DetectedHost,
        defaultModelHint: String?,
        awaitingPermission: Bool,
        lines: [String],
        fileMTime: Date,
        companionJSON: String?
    ) -> (SessionSnapshot, JSONLParser.ActivityInputs, PermissionRequest?)?

    /// Re-derive activity from cached inputs (for unchanged files).
    func recomputeActivity(inputs: JSONLParser.ActivityInputs, awaitingPermission: Bool) -> SessionActivity
}

/// Central registry of all supported agent providers.
enum AgentProviders {
    static let all: [AgentKind: AgentProvider] = [
        .claude: ClaudeProvider(),
        .kiro: KiroProvider(),
    ]

    static func provider(for kind: AgentKind) -> AgentProvider {
        all[kind]!
    }
}
