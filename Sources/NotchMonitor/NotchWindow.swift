import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct NotchMetrics {
    /// Height of the hardware notch (or menu-bar fallback on non-notched displays).
    let notchHeight: CGFloat
    /// Width of the hardware notch — the bridge rectangle matches this exactly.
    let notchWidth: CGFloat
}

/// Owns one `NotchPanel` per active display. Rebuilt whenever screens
/// change or the user picks a different placement.
final class NotchWindowController {
    private let store: SessionStore
    private var outsideClickMonitor: Any?

    /// Per-screen panel + per-screen expansion state, keyed by display id.
    /// Each panel has its own `ExpandedState` so hovering or clicking one
    /// doesn't expand every other display's HUD.
    private struct PanelHost {
        let panel: NotchPanel
        let hosting: NSHostingView<NotchRootView>
        let state: ExpandedState
    }
    private var panels: [CGDirectDisplayID: PanelHost] = [:]

    private static let collapsedHeight: CGFloat = 32
    /// Generous max for the panel — actual visible body will be measured
    /// from content and is always smaller than this.
    private static let expandedContentSize = CGSize(width: 600, height: 720)

    init(store: SessionStore) {
        self.store = store

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.rebuild() }

        NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.rebuild() }

        // Collapse the panel whenever the user clicks anywhere outside our
        // own windows or presses any key.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] _ in
            self?.collapseIfNeeded()
        }
    }

    private func collapseIfNeeded() {
        // Collapse every per-panel state that's currently expanded.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for (_, host) in self.panels where host.state.isExpanded {
                host.state.isExpanded = false
                host.state.source = .click
            }
        }
    }

    func show() {
        rebuild()
    }

    /// Resolve the set of screens that should display a HUD given the
    /// current `DisplayPlacement` setting.
    private func targetScreens() -> [NSScreen] {
        switch AppSettings.shared.displayPlacement {
        case .allDisplays:
            return NSScreen.screens
        case .notchedDisplay:
            if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
                return [notched]
            }
            return [NSScreen.screens.first].compactMap { $0 }
        case .mainDisplay:
            // `NSScreen.main` is the screen with the focused window; for a
            // menu-bar app that's effectively wherever the cursor is, not the
            // primary display the user picked in System Settings. The primary
            // is always `NSScreen.screens.first`.
            return [NSScreen.screens.first].compactMap { $0 }
        }
    }

    private func currentMetrics(for screen: NSScreen) -> NotchMetrics {
        let inset = screen.safeAreaInsets.top
        if inset > 0 {
            // Notched screen: match the hardware cutout exactly.
            let left = screen.auxiliaryTopLeftArea?.maxX ?? 0
            let right = screen.auxiliaryTopRightArea?.minX ?? screen.frame.width
            let measured = right - left
            let width = measured > 40 ? measured : 200
            return NotchMetrics(notchHeight: inset, notchWidth: width)
        }
        // Non-notched screen: fake a notch sized like the actual menu-bar
        // row. Compute the menu-bar height from the screen's geometry —
        // `NSStatusBar.system.thickness` returns 22 but the real menu bar
        // is taller (28-32pt depending on the display).
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY,
                                NSStatusBar.system.thickness)
        let fakeNotchWidth: CGFloat = 60
        return NotchMetrics(notchHeight: menuBarHeight, notchWidth: fakeNotchWidth)
    }

    /// Display id for a screen, used as our panel key. Returns 0 if the
    /// device-description is missing the field (shouldn't happen in practice).
    private func displayId(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// Tear down panels on screens that aren't in the current target set,
    /// and create/refresh panels for screens that are.
    private func rebuild() {
        let targets = targetScreens()
        let targetIds = Set(targets.map { displayId(for: $0) })

        // Drop panels for screens no longer in the target set.
        for (id, host) in panels where !targetIds.contains(id) {
            host.panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }

        for screen in targets {
            let id = displayId(for: screen)
            let metrics = currentMetrics(for: screen)
            let panelSize = CGSize(
                width: Self.expandedContentSize.width,
                height: metrics.notchHeight + Self.expandedContentSize.height
            )
            let frame = screen.frame
            let originX = frame.midX - panelSize.width / 2
            let originY = frame.maxY - panelSize.height
            let target = NSRect(x: originX, y: originY, width: panelSize.width, height: panelSize.height)

            // Reuse this screen's existing expansion state, or make a fresh
            // one so each display tracks its own expanded/collapsed status.
            let state = panels[id]?.state ?? ExpandedState()

            let root = NotchRootView(
                store: store,
                metrics: metrics,
                collapsedHeight: Self.collapsedHeight,
                expandedSize: Self.expandedContentSize,
                state: state
            )

            if let host = panels[id] {
                host.panel.setFrame(target, display: true, animate: false)
                host.hosting.frame = NSRect(origin: .zero, size: panelSize)
                host.hosting.rootView = root
            } else {
                let panel = NotchPanel(
                    contentRect: NSRect(origin: .zero, size: panelSize),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.level = .statusBar
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                panel.isMovable = false
                panel.hidesOnDeactivate = false

                let hosting = NSHostingView(rootView: root)
                hosting.frame = NSRect(origin: .zero, size: panelSize)
                hosting.autoresizingMask = [.width, .height]
                panel.contentView = hosting
                panel.setFrame(target, display: true, animate: false)
                panel.orderFrontRegardless()
                panels[id] = PanelHost(panel: panel, hosting: hosting, state: state)
            }
        }
    }
}

/// Shared expansion state so SwiftUI owns the animation entirely.
enum ExpansionSource {
    case click   // user clicked — sticky, ignore mouse-out
    case hover   // user hovered — collapse on mouse-out
}

final class ExpandedState: ObservableObject {
    @Published var isExpanded: Bool = false
    /// How the current expansion was triggered. Only meaningful while
    /// `isExpanded` is true; reset to `.click` on collapse.
    @Published var source: ExpansionSource = .click
}
