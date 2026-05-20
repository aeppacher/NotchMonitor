import Foundation

/// How far back to look for "active" sessions. Sessions whose most recent
/// message is older than this drop out of the HUD entirely.
enum ActivityWindow: Int, CaseIterable {
    case oneHour = 1
    case threeHours = 3
    case eightHours = 8

    var label: String {
        switch self {
        case .oneHour:    return "Last 1 hour"
        case .threeHours: return "Last 3 hours"
        case .eightHours: return "Last 8 hours"
        }
    }

    var seconds: TimeInterval { TimeInterval(rawValue * 3600) }
    var minutes: Int { rawValue * 60 }
}

/// Where the HUD should appear.
enum DisplayPlacement: String, CaseIterable {
    /// Whichever screen is currently the user's "main" — the one with the
    /// menu bar / active focus. Follows the system as it changes.
    case mainDisplay
    /// The notched MacBook Pro built-in display, regardless of where the
    /// user's focus is. Falls back to main if no notched display exists.
    case notchedDisplay
    /// Render a HUD on every connected display.
    case allDisplays

    var label: String {
        switch self {
        case .mainDisplay:    return "Notch on Main Display"
        case .notchedDisplay: return "Notch on Laptop Display"
        case .allDisplays:    return "Notch on All Displays"
        }
    }
}

/// App-wide settings backed by UserDefaults. Posts a notification on change
/// so the notch controller / poller can react.
final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("NotchMonitor.AppSettings.didChange")

    private let displayKey = "displayPlacement"
    private let hostsKey = "enabledRemoteHosts"
    private let activityWindowKey = "activityWindowHours"

    var activityWindow: ActivityWindow {
        get {
            let raw = UserDefaults.standard.integer(forKey: activityWindowKey)
            return ActivityWindow(rawValue: raw) ?? .threeHours
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: activityWindowKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    var displayPlacement: DisplayPlacement {
        get {
            guard let raw = UserDefaults.standard.string(forKey: displayKey),
                  let val = DisplayPlacement(rawValue: raw)
            else { return .notchedDisplay }
            return val
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: displayKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Set of SSH host aliases the user has opted into monitoring. Empty by
    /// default — opt-in: no remote hosts are polled until the user picks them.
    var enabledRemoteHosts: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: hostsKey) ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: hostsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    func setHostEnabled(_ alias: String, enabled: Bool) {
        var current = enabledRemoteHosts
        if enabled { current.insert(alias) } else { current.remove(alias) }
        enabledRemoteHosts = current
    }
}

/// User-defined display names for project groups. Keyed by group key
/// (`"<host>::<project>"`), persisted via UserDefaults.
final class ProjectNameStore: ObservableObject {
    static let shared = ProjectNameStore()

    private let key = "projectCustomNames"

    @Published private(set) var names: [String: String] = [:]

    private init() {
        names = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    func displayName(for groupKey: String, default fallback: String) -> String {
        names[groupKey] ?? fallback
    }

    func setName(_ name: String?, for groupKey: String) {
        if let n = name, !n.isEmpty {
            names[groupKey] = n
        } else {
            names.removeValue(forKey: groupKey)
        }
        UserDefaults.standard.set(names, forKey: key)
    }
}
