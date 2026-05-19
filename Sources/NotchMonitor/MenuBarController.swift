import AppKit

/// Owns the NSStatusItem (menu-bar icon) and its dropdown menu.
/// macOS auto-positions the status item to the right of the notch on
/// notched displays, so we don't have to place it manually.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let updateChecker: UpdateChecker
    private let updater = Updater()

    /// Path to the per-user LaunchAgent plist that toggles "start at login".
    /// We write this directly rather than using SMAppService.mainApp because
    /// SMAppService requires either Developer ID signing or installation in
    /// /Applications — neither is true for an ad-hoc-signed dev build.
    private let launchAgentURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("com.eppacher.notchmonitor.plist")
    }()

    init(updateChecker: UpdateChecker) {
        self.updateChecker = updateChecker
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        buildMenu()
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUpdateAvailable(_:)),
            name: UpdateChecker.updateAvailable,
            object: nil
        )
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // SF Symbol that visually echoes the notch HUD.
        let img = NSImage(
            systemSymbolName: "rectangle.dashed",
            accessibilityDescription: "NotchMonitor"
        )
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageOnly
        button.toolTip = "NotchMonitor"
    }

    private func buildMenu() {
        menu.removeAllItems()

        // Disabled header showing the running version. Reads from
        // CFBundleShortVersionString in the .app's Info.plist; falls back to
        // "dev" for unbundled `swift run` launches.
        let versionLabel: String = {
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return "NotchMonitor \(v ?? "dev")"
        }()
        let versionItem = NSMenuItem(title: versionLabel, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Update row — only meaningful when an update is actually available.
        // We always insert it (so position stays stable) but disable + label
        // it differently when there's nothing to do.
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(handleUpdateClick(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.identifier = NSUserInterfaceItemIdentifier("update")
        if let pending = updateChecker.lastResult, pending.isNewer {
            updateItem.title = "Install Update \(pending.tag)…"
        }
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        // Display placement — radio group, exactly one checked at a time.
        let currentPlacement = AppSettings.shared.displayPlacement
        for placement in DisplayPlacement.allCases {
            let item = NSMenuItem(
                title: placement.label,
                action: #selector(setPlacement(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = placement.rawValue
            item.state = (placement == currentPlacement) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Activity window — how far back to look for "active" sessions.
        let activityHeader = NSMenuItem(title: "Track Sessions From", action: nil, keyEquivalent: "")
        activityHeader.isEnabled = false
        menu.addItem(activityHeader)
        let currentWindow = AppSettings.shared.activityWindow
        for win in ActivityWindow.allCases {
            let item = NSMenuItem(
                title: win.label,
                action: #selector(setActivityWindow(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = win.rawValue
            item.state = (win == currentWindow) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Monitor SSH Connections submenu — opt-in list of remote hosts to poll.
        let hostsItem = NSMenuItem(title: "Monitor SSH Connections", action: nil, keyEquivalent: "")
        let hostsSubmenu = NSMenu()
        hostsSubmenu.delegate = self
        hostsSubmenu.identifier = NSUserInterfaceItemIdentifier("hosts-submenu")
        rebuildHostsSubmenu(hostsSubmenu)
        hostsItem.submenu = hostsSubmenu
        menu.addItem(hostsItem)

        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = isLoginItemEnabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit NotchMonitor",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Hosts submenu: rebuild every time it opens so newly-added entries
        // in ~/.ssh/config show up without restarting the app.
        if menu.identifier == NSUserInterfaceItemIdentifier("hosts-submenu") {
            rebuildHostsSubmenu(menu)
            return
        }
        // Refresh the toggle state in case the plist was added/removed
        // outside the app (e.g. via System Settings or by hand).
        if let toggle = menu.items.first(where: { $0.action == #selector(toggleLoginItem(_:)) }) {
            toggle.state = isLoginItemEnabled ? .on : .off
        }
        // Refresh placement radio in case it was changed elsewhere.
        let currentPlacement = AppSettings.shared.displayPlacement
        for item in menu.items where item.action == #selector(setPlacement(_:)) {
            let placement = (item.representedObject as? String).flatMap(DisplayPlacement.init(rawValue:))
            item.state = (placement == currentPlacement) ? .on : .off
        }
        // Refresh activity-window radio.
        let currentWindow = AppSettings.shared.activityWindow
        for item in menu.items where item.action == #selector(setActivityWindow(_:)) {
            let win = (item.representedObject as? Int).flatMap(ActivityWindow.init(rawValue:))
            item.state = (win == currentWindow) ? .on : .off
        }
    }

    @objc private func setPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let placement = DisplayPlacement(rawValue: raw)
        else { return }
        AppSettings.shared.displayPlacement = placement
    }

    @objc private func setActivityWindow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let win = ActivityWindow(rawValue: raw)
        else { return }
        AppSettings.shared.activityWindow = win
    }

    // MARK: - Monitor Hosts submenu

    private func rebuildHostsSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        let candidates = HostDiscovery.candidateAliases()
        let enabled = AppSettings.shared.enabledRemoteHosts

        if candidates.isEmpty {
            let empty = NSMenuItem(title: "No SSH hosts found in ~/.ssh/config", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        for alias in candidates {
            let item = NSMenuItem(
                title: alias,
                action: #selector(toggleHost(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = alias
            item.state = enabled.contains(alias) ? .on : .off
            submenu.addItem(item)
        }

        // Trailing items: select-all / clear-all for convenience.
        submenu.addItem(NSMenuItem.separator())
        let enableAll = NSMenuItem(
            title: "Enable All",
            action: #selector(enableAllHosts(_:)),
            keyEquivalent: ""
        )
        enableAll.target = self
        submenu.addItem(enableAll)

        let disableAll = NSMenuItem(
            title: "Disable All",
            action: #selector(disableAllHosts(_:)),
            keyEquivalent: ""
        )
        disableAll.target = self
        submenu.addItem(disableAll)
    }

    @objc private func toggleHost(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        let isOn = sender.state == .on
        AppSettings.shared.setHostEnabled(alias, enabled: !isOn)
        sender.state = isOn ? .off : .on
    }

    @objc private func enableAllHosts(_ sender: NSMenuItem) {
        AppSettings.shared.enabledRemoteHosts = Set(HostDiscovery.candidateAliases())
    }

    @objc private func disableAllHosts(_ sender: NSMenuItem) {
        AppSettings.shared.enabledRemoteHosts = []
    }

    private var isLoginItemEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    /// Resolves the path the LaunchAgent should launch.
    /// - Bundled launch (`/path/NotchMonitor.app/Contents/MacOS/NotchMonitor`):
    ///   we want the `.app` path so launchd can `open` it.
    /// - Unbundled (`swift run`): `Bundle.main.bundleURL` returns the build
    ///   *directory*, not the binary; we have to use `executablePath`.
    private struct LaunchTarget {
        let path: String
        let useOpen: Bool   // /usr/bin/open -a <path>  vs  <path>
    }

    private func resolveLaunchTarget() -> LaunchTarget? {
        // 1. Walk up from the executable looking for `.app` ancestor.
        if let exe = Bundle.main.executablePath {
            var candidate = URL(fileURLWithPath: exe)
            while candidate.pathComponents.count > 1 {
                candidate = candidate.deletingLastPathComponent()
                if candidate.pathExtension == "app" {
                    return LaunchTarget(path: candidate.path, useOpen: true)
                }
            }
            // No .app ancestor — exec the binary directly.
            return LaunchTarget(path: exe, useOpen: false)
        }
        return nil
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let fm = FileManager.default
        do {
            if isLoginItemEnabled {
                try fm.removeItem(at: launchAgentURL)
                // Also unload from launchd so it stops at next logout / now.
                _ = runLaunchctl(["unload", launchAgentURL.path])
            } else {
                try fm.createDirectory(
                    at: launchAgentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let plist = try makeLaunchAgentPlist()
                try plist.write(to: launchAgentURL)
                _ = runLaunchctl(["load", launchAgentURL.path])
            }
        } catch {
            NSLog("[notch-monitor] login-item toggle failed: %@", "\(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change login-item setting"
            alert.informativeText = "\(error.localizedDescription)\n\nLaunchAgent path:\n\(launchAgentURL.path)"
            alert.runModal()
        }
    }

    enum LoginItemError: LocalizedError {
        case noLaunchTarget
        var errorDescription: String? {
            switch self {
            case .noLaunchTarget:
                return "Couldn't determine the path to the running app."
            }
        }
    }

    private func makeLaunchAgentPlist() throws -> Data {
        guard let target = resolveLaunchTarget() else {
            throw LoginItemError.noLaunchTarget
        }
        let args = target.useOpen
            ? ["/usr/bin/open", "-a", target.path]
            : [target.path]

        let dict: [String: Any] = [
            "Label": "com.eppacher.notchmonitor",
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - Update flow

    @objc private func onUpdateAvailable(_ note: Notification) {
        // Refresh menu and add a small dot to the menu-bar icon to nudge the
        // user without being intrusive.
        DispatchQueue.main.async { [weak self] in
            self?.refreshUpdateBadge()
            self?.buildMenu()
        }
    }

    private func refreshUpdateBadge() {
        guard let button = statusItem.button else { return }
        if updateChecker.lastResult?.isNewer == true {
            // Compose the base symbol with a small filled circle in the
            // bottom-right to indicate a pending update.
            let base = NSImage(systemSymbolName: "rectangle.dashed",
                               accessibilityDescription: "NotchMonitor")
            let badged = NSImage(systemSymbolName: "rectangle.dashed.badge.record",
                                 accessibilityDescription: "NotchMonitor — update available")
            let img = badged ?? base
            img?.isTemplate = true
            button.image = img
            button.toolTip = "NotchMonitor — update available"
        } else {
            let img = NSImage(systemSymbolName: "rectangle.dashed",
                              accessibilityDescription: "NotchMonitor")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "NotchMonitor"
        }
    }

    @objc private func handleUpdateClick(_ sender: NSMenuItem) {
        if let pending = updateChecker.lastResult, pending.isNewer {
            promptInstall(update: pending)
        } else {
            // Manual check; show a brief result alert.
            updateChecker.checkNow()
            // Give the network a moment, then report status.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                if let pending = self.updateChecker.lastResult, pending.isNewer {
                    self.promptInstall(update: pending)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "You're up to date"
                    alert.informativeText = "NotchMonitor \(UpdateChecker.currentVersion) is the latest version."
                    alert.runModal()
                }
            }
        }
    }

    private func promptInstall(update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "NotchMonitor \(update.tag) is available"
        alert.informativeText = "You're running \(UpdateChecker.currentVersion). Install and relaunch?"
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            installUpdate(update)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.releasePageURL)
        default:
            break
        }
    }

    private func installUpdate(_ update: AvailableUpdate) {
        // Sanity check: we can only auto-install when running from a real
        // .app bundle (not `swift run`).
        guard Updater.resolveAppBundle() != nil else {
            let alert = NSAlert()
            alert.messageText = "Auto-install isn't available in dev mode"
            alert.informativeText = "Run from the installed .app to use one-click update, or download manually."
            alert.addButton(withTitle: "View on GitHub")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(update.releasePageURL)
            }
            return
        }
        updater.installAndRelaunch(update: update) { result in
            if case .failure(let err) = result {
                let alert = NSAlert()
                alert.messageText = "Update failed"
                alert.informativeText = "\(err.localizedDescription)"
                alert.addButton(withTitle: "View on GitHub")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(update.releasePageURL)
                }
            }
            // On success, the trampoline took over and we're terminating —
            // nothing to do here.
        }
    }
}
