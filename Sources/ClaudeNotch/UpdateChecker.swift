import Foundation

struct AvailableUpdate: Equatable {
    let tag: String              // e.g. "v0.6.0"
    let versionString: String    // e.g. "0.6.0" — strips leading 'v'
    let zipURL: URL              // direct download URL for ClaudeNotch.zip
    let releasePageURL: URL      // human-friendly GitHub releases page
    let publishedAt: Date?

    var isNewer: Bool {
        UpdateChecker.compare(versionString, to: UpdateChecker.currentVersion) == .orderedDescending
    }
}

/// Polls GitHub Releases on launch and once a day while the app is running.
/// Posts `Notification.Name.updateAvailable` whenever a newer version is found
/// than the running bundle.
final class UpdateChecker {
    static let updateAvailable = Notification.Name("ClaudeNotch.updateAvailable")

    private let owner = "aeppacher"
    private let repo = "NotchMonitor"
    private let checkInterval: TimeInterval = 24 * 3600

    private var timer: Timer?
    private(set) var lastResult: AvailableUpdate?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func start() {
        // First check happens shortly after launch (don't block app startup).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkNow()
        }
        // Recurring 24h check while the app is running.
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    /// Kick off a check now. Safe to call from any thread; runs network on
    /// a background queue, posts notifications on main.
    func checkNow() {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        // GitHub recommends a UA + Accept header for API calls.
        req.setValue("ClaudeNotch/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                NSLog("[claude-notch] update check failed: %@", "\(error)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else {
                NSLog("[claude-notch] update check: no tag in response")
                return
            }
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            // Find the .zip asset.
            let zipAsset = assets.first { (($0["name"] as? String) ?? "").hasSuffix(".zip") }
            guard let zipURLString = zipAsset?["browser_download_url"] as? String,
                  let zipURL = URL(string: zipURLString)
            else {
                NSLog("[claude-notch] update check: no zip asset on release \(tag)")
                return
            }
            let pageURL = (json["html_url"] as? String).flatMap { URL(string: $0) }
                ?? URL(string: "https://github.com/\(self.owner)/\(self.repo)/releases")!
            let isoFormatter = ISO8601DateFormatter()
            let publishedAt = (json["published_at"] as? String).flatMap { isoFormatter.date(from: $0) }

            let versionString = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let update = AvailableUpdate(
                tag: tag,
                versionString: versionString,
                zipURL: zipURL,
                releasePageURL: pageURL,
                publishedAt: publishedAt
            )

            DispatchQueue.main.async {
                self.lastResult = update
                if update.isNewer {
                    NotificationCenter.default.post(name: Self.updateAvailable, object: update)
                }
            }
        }.resume()
    }

    /// Numeric semver-ish comparison. Splits on `.` and compares each segment
    /// as an Int when possible (falls back to string compare for things like
    /// `0.6.0-beta.1`, which we don't currently produce).
    static func compare(_ a: String, to b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map(String.init)
        let pb = b.split(separator: ".").map(String.init)
        for i in 0..<max(pa.count, pb.count) {
            let ai = i < pa.count ? pa[i] : "0"
            let bi = i < pb.count ? pb[i] : "0"
            if let an = Int(ai), let bn = Int(bi) {
                if an != bn { return an < bn ? .orderedAscending : .orderedDescending }
            } else if ai != bi {
                return ai < bi ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}
