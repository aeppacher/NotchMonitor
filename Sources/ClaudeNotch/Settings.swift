import Foundation

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
/// so the notch controller can rebuild its panels.
final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("ClaudeNotch.AppSettings.didChange")

    private let key = "displayPlacement"

    var displayPlacement: DisplayPlacement {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let val = DisplayPlacement(rawValue: raw)
            else { return .notchedDisplay }
            return val
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
