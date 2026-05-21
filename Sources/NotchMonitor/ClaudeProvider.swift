import Foundation

/// Claude Code agent provider. Wraps the existing JSONLParser with no
/// behavioral changes — all Claude sessions continue to work identically.
struct ClaudeProvider: AgentProvider {
    let kind: AgentKind = .claude
    let sessionBaseDir = ".claude/projects"
    let findDepth = (min: 2, max: 2)
    let needsCompanionJSON = false

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
        guard let (snap, inputs) = JSONLParser.parse(
            sessionId: sessionId,
            projectDir: projectDir,
            host: host,
            defaultModelHint: defaultModelHint,
            awaitingPermission: awaitingPermission,
            lines: lines,
            fileMTime: fileMTime,
            agent: .claude
        ) else { return nil }
        return (snap, inputs, nil)
    }

    func recomputeActivity(inputs: JSONLParser.ActivityInputs, awaitingPermission: Bool) -> SessionActivity {
        JSONLParser.recomputeActivity(inputs: inputs, awaitingPermission: awaitingPermission)
    }
}
