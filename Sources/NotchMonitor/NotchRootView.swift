import SwiftUI

/// PreferenceKey that bubbles the expanded content's intrinsic size up to
/// the root, where it drives the body's animated frame.
private struct ExpandedSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width),
                       height: max(value.height, next.height))
    }
}

/// Rounded rect with independently animatable top + bottom corner radii.
struct AdaptiveCornerRect: Shape {
    var topLeft: CGFloat = 0
    var topRight: CGFloat = 0
    var bottomLeft: CGFloat = 0
    var bottomRight: CGFloat = 0

    init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topLeft = topRadius
        self.topRight = topRadius
        self.bottomLeft = bottomRadius
        self.bottomRight = bottomRadius
    }

    init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(topLeft, topRight), AnimatablePair(bottomLeft, bottomRight)) }
        set {
            topLeft = newValue.first.first
            topRight = newValue.first.second
            bottomLeft = newValue.second.first
            bottomRight = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cap = min(rect.width, rect.height) / 2
        let tl = max(0, min(topLeft, cap))
        let tr = max(0, min(topRight, cap))
        let bl = max(0, min(bottomLeft, cap))
        let br = max(0, min(bottomRight, cap))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tr),
                           control: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bl),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.minX + tl, y: rect.minY),
                           control: CGPoint(x: rect.minX, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: ExpandedState
    let metrics: NotchMetrics
    let collapsedHeight: CGFloat
    let expandedSize: CGSize

    init(store: SessionStore,
         metrics: NotchMetrics,
         collapsedHeight: CGFloat,
         expandedSize: CGSize,
         state: ExpandedState) {
        self.store = store
        self.metrics = metrics
        self.collapsedHeight = collapsedHeight
        self.expandedSize = expandedSize
        self.state = state
    }

    @State private var measuredExpandedSize: CGSize = .zero
    private static let minExpandedWidth: CGFloat = 320
    private static let minExpandedHeight: CGFloat = 60
    /// Width of the trailing wing — fits the combined status+count badge,
    /// with a few extra pts of clearance for the badge's pulse-scale animation
    /// so it doesn't slide under the notch when expanded.
    private static let collapsedWingWidth: CGFloat = 36

    var body: some View {
        let expanded = state.isExpanded
        let resolvedW: CGFloat = {
            guard measuredExpandedSize.width > 0 else { return expandedSize.width }
            return min(max(measuredExpandedSize.width, Self.minExpandedWidth), expandedSize.width)
        }()
        let resolvedH: CGFloat = {
            guard measuredExpandedSize.height > 0 else { return expandedSize.height }
            return min(max(measuredExpandedSize.height, Self.minExpandedHeight), expandedSize.height)
        }()
        // Collapsed: a wide pill that sits in the menu-bar row, with the
        // hardware notch carved through its middle. Wings extend past both
        // sides of the notch so the status dot and count badge are visible.
        // Expanded: pill drops below the bridge and grows to fit content,
        // identical to the original notch UI.
        // Collapsed body matches the full notch width on the left (so it
        // grows out cleanly as the panel expands) and extends right past
        // the notch by `collapsedWingWidth` to host the status badge.
        let collapsedBodyWidth = metrics.notchWidth + Self.collapsedWingWidth
        let bodyWidth = expanded ? resolvedW : collapsedBodyWidth
        let bodyHeight = expanded ? resolvedH : metrics.notchHeight
        // Collapsed: square top (flush with screen edge / menu-bar row),
        // rounded bottom-right (pill-shaped trailing edge), rounded
        // bottom-left so it tucks into the notch's bottom-left curve
        // instead of sticking out as a square corner.
        // Expanded: square top, rounded bottom-left + bottom-right.
        let cornerTL: CGFloat = 0
        let cornerTR: CGFloat = 0
        let cornerBL: CGFloat = expanded ? 14 : metrics.notchHeight / 2
        let cornerBR: CGFloat = expanded ? 14 : metrics.notchHeight / 2

        ZStack(alignment: .top) {
            // Off-screen probe — measured size includes the top inset so the
            // panel grows tall enough to push all content below the bridge.
            ExpandedView(store: store)
                .padding(.horizontal, 14)
                .padding(.top, metrics.notchHeight + 12)
                .padding(.bottom, 12)
                .fixedSize()
                .frame(maxWidth: expandedSize.width)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ExpandedSizeKey.self, value: geo.size)
                    }
                )
                .opacity(0)
                .allowsHitTesting(false)

            // Body — sits in the menu-bar row when collapsed (matching the
            // bridge), and grows downward + outward when expanded.
            // Drawn *before* the bridge so the bridge paints over the body's
            // square left corner, hiding it against the notch's rounded curve.
            AdaptiveCornerRect(
                topLeft: cornerTL,
                topRight: cornerTR,
                bottomLeft: cornerBL,
                bottomRight: cornerBR
            )
                .fill(Color.black)
                .frame(width: bodyWidth, height: bodyHeight)
                .overlay(
                    content
                        .frame(width: bodyWidth, height: bodyHeight)
                        .clipped()
                )
                // Hover + click hit-testing live on the visible shape so we
                // don't pick up hover events from the giant transparent panel
                // area surrounding the pill. Otherwise SwiftUI thinks the
                // mouse is "still inside" the panel even after leaving the
                // pill, and never re-fires onHover.
                .contentShape(
                    AdaptiveCornerRect(
                        topLeft: cornerTL,
                        topRight: cornerTR,
                        bottomLeft: cornerBL,
                        bottomRight: cornerBR
                    )
                )
                .onHover { isInside in
                    bodyHovered = isInside
                    handleHoverChange()
                }
                // Shadow only when expanded — when collapsed, the soft blur
                // around the body's left edge would leak past the notch's
                // rounded curve into the menu bar area below the bridge.
                .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 8, y: 2)
                // Expanded sits flush with the top of the screen (y=0) and
                // grows downward; collapsed sits in the menu-bar row.
                // Horizontal: collapsed body covers the full notch + a right
                // wing. Center it over the notch by offsetting just the wing
                // halfway right (so the notch portion stays aligned with the
                // hardware cutout).
                .offset(
                    x: expanded ? 0 : Self.collapsedWingWidth / 2,
                    y: 0
                )

            // Expanded header — sits in the menu-bar row so the title+totals
            // fill the wings on either side of the notch. The hardware notch
            // is a physical screen cutout, so we don't need to paint anything
            // over it; the header just renders edge-to-edge and the notch
            // naturally hides its middle.
            // Asymmetric timing: on insertion (expand), wait for the panel to
            // finish growing before fading text in. On removal (collapse),
            // fade out IMMEDIATELY so the text disappears before the panel
            // shrinks — otherwise text floats over the menu bar mid-collapse.
            if expanded {
                ExpandedHeader(store: store)
                    .padding(.horizontal, 14)
                    .frame(width: resolvedW, height: metrics.notchHeight)
                    .onHover { isInside in
                        headerHovered = isInside
                        handleHoverChange()
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeInOut(duration: 0.18).delay(0.12)),
                        removal: .opacity.animation(.easeInOut(duration: 0.08))
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ExpandedSizeKey.self) { size in
            measuredExpandedSize = size
        }
        .animation(.easeOut(duration: 0.22), value: expanded)
        .animation(.easeOut(duration: 0.22), value: resolvedW)
        .animation(.easeOut(duration: 0.22), value: resolvedH)
    }

    @State private var hoverExpandWorkItem: DispatchWorkItem?
    @State private var hoverCollapseWorkItem: DispatchWorkItem?
    /// Hover state is split across the body shape and the header overlay
    /// (a sibling in the ZStack). When the cursor moves between them,
    /// the leaving region fires `false` *before* the entering one fires
    /// `true`, so we debounce collapse and require both to be out.
    @State private var bodyHovered: Bool = false
    @State private var headerHovered: Bool = false

    private func handleHoverChange() {
        let anyHovered = bodyHovered || headerHovered
        if anyHovered {
            hoverCollapseWorkItem?.cancel()
            hoverCollapseWorkItem = nil
            guard !state.isExpanded else { return }
            let work = DispatchWorkItem {
                if !state.isExpanded {
                    state.isExpanded = true
                }
            }
            hoverExpandWorkItem?.cancel()
            hoverExpandWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else {
            hoverExpandWorkItem?.cancel()
            hoverExpandWorkItem = nil
            guard state.isExpanded else { return }
            let work = DispatchWorkItem {
                if bodyHovered || headerHovered { return }
                if state.isExpanded {
                    state.isExpanded = false
                }
            }
            hoverCollapseWorkItem?.cancel()
            hoverCollapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.isExpanded {
            // If the intrinsic content height exceeds the panel's cap, wrap
            // in a ScrollView so the user can reach overflow rows. Below the
            // cap, render as before — no scroll bar / extra chrome.
            let overflows = measuredExpandedSize.height > expandedSize.height
            ExpandedContent(
                store: store,
                topInset: metrics.notchHeight + 12,
                overflows: overflows
            )
            .transition(.asymmetric(
                insertion: .opacity.animation(.easeInOut(duration: 0.18).delay(0.12)),
                removal: .opacity.animation(.easeInOut(duration: 0.08))
            ))
        } else {
            CollapsedView(store: store)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .transition(.opacity.animation(.easeInOut(duration: 0.12)))
        }
    }
}

/// Wrapper that switches between a plain VStack and a ScrollView depending
/// on whether the content overflows the panel's height cap.
private struct ExpandedContent: View {
    @ObservedObject var store: SessionStore
    let topInset: CGFloat
    let overflows: Bool

    var body: some View {
        if overflows {
            ScrollView(.vertical, showsIndicators: true) {
                ExpandedView(store: store)
                    .padding(.horizontal, 14)
                    .padding(.top, topInset)
                    .padding(.bottom, 12)
            }
        } else {
            ExpandedView(store: store)
                .padding(.horizontal, 14)
                .padding(.top, topInset)
                .padding(.bottom, 12)
        }
    }
}

private struct CollapsedView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        // Single combined badge on the trailing wing: status dot + session
        // count when more than one session is active. The leading wing stays
        // empty so the bar visually frames the notch.
        HStack {
            Spacer()
            StatusBadge(
                activity: store.aggregateActivity,
                sessionCount: store.aggregateMatchCount
            )
        }
    }
}

private struct StatusBadge: View {
    let activity: SessionActivity
    let sessionCount: Int

    var body: some View {
        if sessionCount > 1 {
            ZStack {
                ActivityDot(activity: activity, size: 16)
                Text("\(sessionCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.85))
            }
        } else {
            ActivityDot(activity: activity)
        }
    }
}

/// Sits in the menu-bar row, with the bridge covering its middle. Title +
/// status dot live in the leading wing, today's totals in the trailing wing.
struct ExpandedHeader: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 8) {
            ActivityDot(activity: store.aggregateActivity)
            Text("NotchMonitor")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(store.sessions.count) active session\(store.sessions.count == 1 ? "" : "s")")
                    .help("Sessions with activity in the last \(AppSettings.shared.activityWindow.rawValue) hour\(AppSettings.shared.activityWindow.rawValue == 1 ? "" : "s"), across all hosts")
                Text("v\(UpdateChecker.currentVersion)")
                    .foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            Button {
                store.reset()
                store.onReloadAll?()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Reset all sessions to idle and clear stale state")
        }
    }
}

private struct ExpandedView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.sessions.isEmpty {
                Text(store.hasPolled ? "No active sessions" : "Connecting…")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 28)
            } else {
                VStack(spacing: 8) {
                    ForEach(groupedSessions(store.sessions), id: \.key) { group in
                        ProjectCard(group: group, onDismiss: { sid in
                            store.dismissSession(id: sid)
                        }, store: store)
                    }
                }
            }

            if let err = store.lastError {
                Text(err)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(2)
            }

            if !store.hosts.isEmpty {
                HostStatusFooter(hosts: store.hosts)
            }
        }
    }
}

private struct HostStatusFooter: View {
    let hosts: [HostStatus]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(hosts) { h in
                HStack(spacing: 4) {
                    Image(systemName: h.isLocal ? "laptopcomputer" : "cloud")
                        .font(.system(size: 9))
                    Text(displayName(h))
                        .lineLimit(1)
                    Circle()
                        .fill(stateColor(h.state))
                        .frame(width: 5, height: 5)
                    Text(h.state.label)
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    private func displayName(_ h: HostStatus) -> String {
        if h.isLocal { return "local" }
        // Trim long FQDNs to the first label for compactness.
        return h.id.split(separator: ".").first.map(String.init) ?? h.id
    }

    private func stateColor(_ s: HostState) -> Color {
        switch s {
        case .active, .localOk: return .green
        case .settingUp, .connecting: return .yellow
        case .offline: return .red
        }
    }
}

struct SessionGroup {
    let key: String           // "<host>::<project>"
    let host: String
    let isLocal: Bool
    let project: String
    let gitBranch: String?
    let cwd: String?
    let sessions: [SessionSnapshot]   // sorted: most recent first

    var aggregateActivity: SessionActivity {
        sessions.map(\.activity).max(by: { $0.priority < $1.priority }) ?? .idle
    }

    var agents: Set<AgentKind> {
        Set(sessions.map(\.agent))
    }
}

func groupedSessions(_ sessions: [SessionSnapshot]) -> [SessionGroup] {
    var byKey: [String: [SessionSnapshot]] = [:]
    for s in sessions {
        let key = "\(s.host)::\(s.project)"
        byKey[key, default: []].append(s)
    }
    let groups: [SessionGroup] = byKey.map { (key, members) in
        let sorted = members.sorted { $0.lastMessageAt > $1.lastMessageAt }
        let head = sorted[0]
        return SessionGroup(
            key: key,
            host: head.host,
            isLocal: head.isLocal,
            project: head.project,
            gitBranch: head.gitBranch,
            cwd: head.cwd,
            sessions: sorted
        )
    }
    // Most-recently-active group first.
    return groups.sorted {
        ($0.sessions.first?.lastMessageAt ?? .distantPast) >
        ($1.sessions.first?.lastMessageAt ?? .distantPast)
    }
}

private struct GitStatusBadge: View {
    let status: GitStatus

    var body: some View {
        HStack(spacing: 2) {
            Text("+\(status.additions)")
                .foregroundStyle(.green.opacity(0.9))
            Text("-\(status.deletions)")
                .foregroundStyle(.red.opacity(0.9))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}

private struct PermissionRequestView: View {
    let request: PermissionRequest

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.pink)
            Text(request.toolName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.pink)
            if !request.inputPreview.isEmpty {
                Text(request.inputPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.pink.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.pink.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
}

private struct ProjectCard: View {
    let group: SessionGroup
    let onDismiss: (_ sessionId: String) -> Void
    @ObservedObject var store: SessionStore
    @ObservedObject private var nameStore = ProjectNameStore.shared
    @State private var isEditing = false
    @State private var editText = ""

    private var displayName: String {
        nameStore.displayName(for: group.key, default: group.project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: host icon · project · edit · session count badge
            HStack(spacing: 8) {
                ActivityDot(activity: group.aggregateActivity)

                Image(systemName: group.isLocal ? "laptopcomputer" : "cloud")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .help(group.isLocal ? "Local" : group.host)

                if isEditing {
                    TextField("Project name", text: $editText, onCommit: {
                        commitRename()
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                    .onExitCommand { cancelRename() }
                } else {
                    Text(displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Button {
                        editText = displayName
                        isEditing = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Rename this project")
                }

                Spacer(minLength: 4)

                if let branch = group.gitBranch {
                    let gitStatus = AppSettings.shared.gitTrackingEnabled
                        ? group.cwd.flatMap { store.gitStatusByPath[$0] }
                        : nil
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch).lineLimit(1)
                        if let gs = gitStatus, !gs.isEmpty {
                            GitStatusBadge(status: gs)
                        }
                    }
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                }

                if group.sessions.count > 1 {
                    Text("\(group.sessions.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
            }

            // Per-session sub-rows.
            VStack(spacing: 6) {
                ForEach(group.sessions) { s in
                    SessionStatRow(session: s, onDismiss: onDismiss, store: store)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == group.project {
            nameStore.setName(nil, for: group.key)
        } else {
            nameStore.setName(trimmed, for: group.key)
        }
        isEditing = false
    }

    private func cancelRename() {
        isEditing = false
    }
}

private struct SessionStatRow: View {
    let session: SessionSnapshot
    let onDismiss: (_ sessionId: String) -> Void
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: model pill · message/token stats · trash
            HStack(spacing: 8) {
                Text("\(session.modelPretty) · \(session.agent.displayName)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(session.agent.tintColor.opacity(0.15)))

                if let turns = session.turnCount {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10))
                        Text("\(turns)")
                    }
                    .help("Completed turns")
                } else if session.totalTokens > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up").font(.system(size: 10))
                        Text(formatTokens(session.inputTokens))
                    }
                    .help("Input tokens")
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down").font(.system(size: 10))
                        Text(formatTokens(session.outputTokens))
                    }
                    .help("Output tokens")
                }

                if let dur = session.totalDurationSecs {
                    HStack(spacing: 3) {
                        Image(systemName: "brain").font(.system(size: 10))
                        Text(formatDuration(dur))
                    }
                    .help("Total thinking time")
                }

                if let tools = session.toolUseCount, tools > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "wrench").font(.system(size: 10))
                        Text("\(tools)")
                    }
                    .help("Tool invocations")
                }

                Spacer(minLength: 4)

                if let credits = session.credits {
                    Text(String(format: "%.2f cred", credits))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .help("Credits consumed this session")
                } else if session.totalTokens > 0 {
                    Text("\(formatTokens(session.totalTokens)) token")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .help("Total tokens (in + out + cache)")
                }

                Button {
                    onDismiss(session.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Hide this session until it next updates")
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.65))

            // Row 2: status · context bar
            HStack(spacing: 10) {
                if !activityLabel.isEmpty {
                    Text(activityLabel)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(activityColor(session.activity))
                        .lineLimit(1)
                }

                ContextBar(fraction: session.contextFraction)
                    .frame(height: 5)
                    .frame(maxWidth: .infinity)

                Text(contextLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }

            // Permission request panel
            if let req = permissionRequest {
                PermissionRequestView(request: req)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var activityLabel: String {
        if session.agent == .kiro {
            switch session.activity {
            case .awaitingUser: return "Blocked"
            default:            return "Ready"
            }
        }
        switch session.activity {
        case .idle: return "Ready"
        default:    return session.activity.label
        }
    }

    private var permissionRequest: PermissionRequest? {
        let rawId = session.id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? session.id
        return store.permissionRequests[rawId]
    }

    private var contextLabel: String {
        let pct = Int((session.contextFraction * 100).rounded())
        return "\(formatTokens(session.contextTokens))/\(formatTokens(session.modelContextLimit)) (\(pct)%)"
    }

    private func activityColor(_ a: SessionActivity) -> Color {
        switch a {
        case .thinking:     return .green
        case .running:      return .blue
        case .processing:   return .cyan
        case .awaitingUser: return .pink
        case .idle:         return .white.opacity(0.55)
        }
    }
}

private struct ContextBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
    }

    private var color: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.6 { return .orange }
        return .white.opacity(0.55)
    }
}

private struct ActivityDot: View {
    let activity: SessionActivity
    var size: CGFloat = 10
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(shouldPulse && pulse ? 1.3 : 1.0)
            .opacity(shouldPulse && pulse ? 0.65 : 1.0)
            .onAppear {
                guard shouldPulse else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }

    private var shouldPulse: Bool {
        switch activity {
        case .thinking, .running, .processing, .awaitingUser: return true
        default: return false
        }
    }

    private var color: Color {
        switch activity {
        case .thinking:     return .green
        case .running:      return .blue
        case .processing:   return .cyan
        case .awaitingUser: return .pink
        case .idle:         return .gray
        }
    }

    fileprivate var isAttentionGrabbing: Bool {
        if case .awaitingUser = activity { return true }
        return false
    }
}

private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

private func formatDuration(_ secs: Int) -> String {
    if secs >= 3600 {
        let m = (secs % 3600) / 60
        return "\(secs / 3600)h\(m > 0 ? "\(m)m" : "")"
    }
    if secs >= 60 { return "\(secs / 60)m\(secs % 60 > 0 ? "\(secs % 60)s" : "")" }
    return "\(secs)s"
}

