import AppKit
import Foundation

/// Downloads a release zip, unpacks it, then hands control to a small
/// trampoline shell script that waits for us to die before swapping the
/// bundle and relaunching. Necessary because macOS won't let you cleanly
/// overwrite the .app of a running process.
final class Updater {
    enum UpdaterError: LocalizedError {
        case noBundlePath
        case downloadFailed(String)
        case unzipFailed(Int32, String)
        case bundleNotFound

        var errorDescription: String? {
            switch self {
            case .noBundlePath:           return "Couldn't determine the running app's bundle path."
            case .downloadFailed(let s):  return "Download failed: \(s)"
            case .unzipFailed(let c, let s): return "Unzip exited \(c): \(s)"
            case .bundleNotFound:         return "Couldn't find ClaudeNotch.app in the downloaded zip."
            }
        }
    }

    /// Run the full install flow on a background queue. `completion` fires
    /// on the main queue. On success, the app is exiting and the trampoline
    /// is taking over.
    func installAndRelaunch(update: AvailableUpdate, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.runInstall(update: update)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func runInstall(update: AvailableUpdate) throws {
        // 1. Resolve the running app's .app bundle path. We'll overwrite it.
        guard let installedBundle = Self.resolveAppBundle() else {
            throw UpdaterError.noBundlePath
        }

        // 2. Set up a working directory.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-notch-update-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 3. Download the zip synchronously. It's small (~250KB).
        let zipURL = workDir.appendingPathComponent("ClaudeNotch.zip")
        try downloadFile(from: update.zipURL, to: zipURL)

        // 4. Unzip it.
        let unzipDir = workDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zipURL.path, "-d", unzipDir.path]
        let stderrPipe = Pipe()
        unzip.standardError = stderrPipe
        try unzip.run()
        unzip.waitUntilExit()
        if unzip.terminationStatus != 0 {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdaterError.unzipFailed(unzip.terminationStatus, err)
        }

        // 5. Locate ClaudeNotch.app inside the unzipped tree.
        guard let newBundle = Self.findApp(in: unzipDir) else {
            throw UpdaterError.bundleNotFound
        }

        // 6. Write the trampoline script and launch it. It waits for our
        // PID to die, swaps the bundle, then re-opens us.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -e
        # Wait for the running ClaudeNotch (PID \(pid)) to exit.
        for _ in $(seq 1 50); do
            if ! /bin/ps -p \(pid) > /dev/null; then break; fi
            /bin/sleep 0.1
        done

        INSTALLED='\(installedBundle.path)'
        NEWBUNDLE='\(newBundle.path)'

        # Atomically swap the bundle:
        #   1. Move the old one aside (so we can roll back if rsync fails).
        #   2. Copy the new bundle into place.
        #   3. Remove the old one.
        BACKUP="${INSTALLED}.update-bak-$$"
        /bin/mv "$INSTALLED" "$BACKUP" || true
        /usr/bin/ditto "$NEWBUNDLE" "$INSTALLED"
        /bin/rm -rf "$BACKUP"

        # Clear any quarantine bit applied by the download (not strictly
        # required for ad-hoc-signed apps but reduces Gatekeeper friction).
        /usr/bin/xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true

        # Relaunch.
        /usr/bin/open "$INSTALLED"

        # Clean up the work dir.
        /bin/rm -rf '\(workDir.path)'
        """
        let scriptURL = workDir.appendingPathComponent("trampoline.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 7. Detach the script so it survives our exit, then quit ourselves.
        let detached = Process()
        detached.executableURL = URL(fileURLWithPath: "/bin/bash")
        detached.arguments = ["-c", "nohup '\(scriptURL.path)' >/dev/null 2>&1 & disown"]
        try detached.run()

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private func downloadFile(from src: URL, to dst: URL) throws {
        // Use a sync download via dispatch group — we're already off the main
        // queue, so blocking here is fine.
        var req = URLRequest(url: src)
        req.setValue("ClaudeNotch/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        let group = DispatchGroup()
        var capturedError: Error?
        var capturedData: Data?
        group.enter()
        URLSession.shared.dataTask(with: req) { data, _, err in
            capturedData = data
            capturedError = err
            group.leave()
        }.resume()
        group.wait()
        if let err = capturedError { throw UpdaterError.downloadFailed("\(err)") }
        guard let data = capturedData else { throw UpdaterError.downloadFailed("empty response") }
        try data.write(to: dst)
    }

    /// Walks up from the running executable to find the enclosing .app bundle.
    /// Returns nil for unbundled `swift run` launches.
    static func resolveAppBundle() -> URL? {
        guard let exe = Bundle.main.executablePath else { return nil }
        var url = URL(fileURLWithPath: exe)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    /// Recursively look for a .app under the given directory.
    private static func findApp(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.pathExtension == "app" { return url }
        }
        return nil
    }
}
