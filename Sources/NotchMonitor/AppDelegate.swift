import AppKit
import SwiftUI

@main
struct NotchMonitorApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var menuBar: MenuBarController?
    private let store = SessionStore()
    private var poller: Poller?
    private let updateChecker = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchController = NotchWindowController(store: store)
        notchController?.show()

        menuBar = MenuBarController(updateChecker: updateChecker)

        let bridge = SSHBridge()
        let poller = Poller(interval: 1.0, bridge: bridge, store: store)
        self.poller = poller
        store.onReloadAll = { [weak poller] in poller?.reloadNow() }
        poller.start()

        updateChecker.start()
    }
}
