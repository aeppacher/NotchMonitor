import Foundation

enum HostSource {
    case local
    case vscodeRemote(String)   // ssh host alias
    case sshConfig(String)
}

struct DetectedHost: Hashable {
    let alias: String           // "local" or ssh alias
    let isLocal: Bool
}

enum HostDiscovery {
    /// Returns local plus any remote hosts the user has explicitly enabled
    /// via Settings (`AppSettings.enabledRemoteHosts`). Defaults to local-only
    /// — remote SSH polling is opt-in.
    static func discover() -> [DetectedHost] {
        var hosts: [DetectedHost] = [DetectedHost(alias: "local", isLocal: true)]
        let enabled = AppSettings.shared.enabledRemoteHosts
        let candidates = candidateAliases()
        var seen: Set<String> = ["local"]
        for alias in candidates where enabled.contains(alias) {
            if seen.insert(alias).inserted {
                hosts.append(DetectedHost(alias: alias, isLocal: false))
            }
        }
        // Also allow enabled hosts that aren't (yet) in our discovered list,
        // so a user can pre-enable an alias before its `Host` entry shows up
        // in ssh config. Won't affect anything unless the alias is real.
        for alias in enabled where !seen.contains(alias) {
            hosts.append(DetectedHost(alias: alias, isLocal: false))
            seen.insert(alias)
        }
        return hosts
    }

    /// Every alias we can find from ssh-config + VSCode Remote storage.
    /// De-duplicated, used to populate the "Monitor Hosts" menu.
    static func candidateAliases() -> [String] {
        var aliases: [String] = []
        var seen = Set<String>()
        for alias in sshConfigHosts() where seen.insert(alias).inserted {
            aliases.append(alias)
        }
        for alias in vscodeRemoteHosts() where seen.insert(alias).inserted {
            aliases.append(alias)
        }
        return aliases.sorted()
    }

    // MARK: - VSCode Remote

    private static func vscodeRemoteHosts() -> [String] {
        let candidates = [
            "Library/Application Support/Code/User/globalStorage/storage.json",
            "Library/Application Support/Code/storage.json",
            "Library/Application Support/Code - Insiders/User/globalStorage/storage.json",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        var aliases: [String] = []
        for rel in candidates {
            let url = home.appendingPathComponent(rel)
            guard let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8) else { continue }
            aliases.append(contentsOf: extractRemoteAliases(from: s))
        }
        // Also scan workspace storage entries which often carry the URI.
        let workspaces = home.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: workspaces, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let meta = dir.appendingPathComponent("workspace.json")
                if let data = try? Data(contentsOf: meta),
                   let s = String(data: data, encoding: .utf8) {
                    aliases.append(contentsOf: extractRemoteAliases(from: s))
                }
            }
        }
        // De-dup, preserve order.
        var seen = Set<String>()
        return aliases.filter { seen.insert($0).inserted }
    }

    /// Pulls out the host alias from `vscode-remote://ssh-remote+<alias>/...` substrings.
    static func extractRemoteAliases(from text: String) -> [String] {
        var out: [String] = []
        let needle = "ssh-remote+"
        var idx = text.startIndex
        while let range = text.range(of: needle, range: idx..<text.endIndex) {
            let tail = text[range.upperBound...]
            // Alias ends at `/`, `"`, or whitespace.
            let stoppers: Set<Character> = ["/", "\"", " ", "\n", "\\"]
            var end = tail.startIndex
            while end < tail.endIndex, !stoppers.contains(tail[end]) {
                end = tail.index(after: end)
            }
            let alias = String(tail[tail.startIndex..<end])
                .removingPercentEncoding ?? String(tail[tail.startIndex..<end])
            if !alias.isEmpty { out.append(alias) }
            idx = end < tail.endIndex ? tail.index(after: end) : tail.endIndex
        }
        return out
    }

    // MARK: - ~/.ssh/config

    private static func sshConfigHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = []
        for raw in s.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("host ") {
                let names = line.dropFirst(5).split(separator: " ")
                for n in names where !n.contains("*") && !n.contains("?") {
                    out.append(String(n))
                }
            }
        }
        return out
    }
}
