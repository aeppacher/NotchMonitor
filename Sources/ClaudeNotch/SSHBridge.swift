import Foundation

/// Runs commands locally or over SSH using a persistent ControlMaster socket.
final class SSHBridge {
    private let controlDir: URL

    init() {
        controlDir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-notch-ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
    }

    /// Run `sh -c <command>` on the host. Local hosts run directly; remote hosts use ssh.
    func run(host: DetectedHost, command: String, timeout: TimeInterval = 8) -> Result<String, BridgeError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")

        if host.isLocal {
            proc.arguments = ["-c", command]
        } else {
            // AF_UNIX socket paths max out at 104 chars on macOS, so hash the
            // alias instead of using it verbatim — long FQDNs blow the limit.
            let socket = controlDir
                .appendingPathComponent("\(host.alias.djb2Hash).sock")
                .path
            // -o BatchMode=yes so we never hang on a password prompt.
            // ControlMaster=auto reuses the socket if alive; first call opens it.
            // ConnectTimeout=10: cold connects to corp dev hosts can easily
            // take 2-3s; 4s was too tight under jitter.
            // ControlPersist=600: keep the master socket alive for 10 minutes
            // of idle so we rarely pay cold-connect cost again.
            // Force /bin/sh on the remote: the user's default shell may be
            // zsh, which has stricter glob behavior (NO_MATCH errors) that
            // breaks our portable POSIX script.
            let wrappedCommand = "/bin/sh -c " + shellQuote(command)
            let sshCmd = """
            ssh -o BatchMode=yes \
                -o ConnectTimeout=10 \
                -o ServerAliveInterval=15 \
                -o ServerAliveCountMax=3 \
                -o ControlMaster=auto \
                -o ControlPath='\(socket)' \
                -o ControlPersist=600 \
                \(shellQuote(host.alias)) \(shellQuote(wrappedCommand))
            """
            proc.arguments = ["-c", sshCmd]
        }

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Drain pipes concurrently. macOS pipe buffers are ~64KB; large
        // outputs (200 lines of a hot JSONL can be hundreds of KB) will block
        // the child if we wait for exit before reading.
        let outLock = NSLock()
        var outData = Data()
        var errData = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            outLock.lock(); outData.append(chunk); outLock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            outLock.lock(); errData.append(chunk); outLock.unlock()
        }

        do { try proc.run() } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if proc.isRunning {
            proc.terminate()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return .failure(.timedOut)
        }

        // Process exited — flush any final bytes still in the pipes.
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let tailOut = stdout.fileHandleForReading.availableData
        let tailErr = stderr.fileHandleForReading.availableData
        outLock.lock()
        if !tailOut.isEmpty { outData.append(tailOut) }
        if !tailErr.isEmpty { errData.append(tailErr) }
        let outSnapshot = outData
        let errSnapshot = errData
        outLock.unlock()
        let out = String(data: outSnapshot, encoding: .utf8) ?? ""
        let err = String(data: errSnapshot, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            return .failure(.nonZeroExit(code: Int(proc.terminationStatus), stderr: err))
        }
        return .success(out)
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    /// Stable, short hash for filesystem-safe socket names. Plain DJB2;
    /// collisions don't matter here because we only have a handful of hosts.
    var djb2Hash: String {
        var h: UInt64 = 5381
        for b in self.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 36)
    }
}

enum BridgeError: Error, CustomStringConvertible {
    case launchFailed(String)
    case timedOut
    case nonZeroExit(code: Int, stderr: String)

    var description: String {
        switch self {
        case .launchFailed(let s): return "launch failed: \(s)"
        case .timedOut: return "timed out"
        case .nonZeroExit(let c, let s): return "exit \(c): \(s.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
