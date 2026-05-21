import Foundation

/// One shell snippet runs on each host and emits a stream like:
///   ===FILE=== <relative-path> <mtime-epoch>
///   <jsonl line>
///   <jsonl line>
///   ===FILE=== ...
///
/// Output stream:
///   ===SETTINGS===
///   {raw settings.json}
///   ===AWAITING=== <session-id>
///   ===AWAITING=== <session-id>
///   ===FILE=== <rel-path> <mtime-epoch>     ← when caller didn't supply a
///                                             cached mtime, OR file is newer
///   <jsonl tail>                            ← omitted for unchanged files
///   ===META=== <rel-path> <mtime-epoch>     ← for unchanged files (Swift
///                                             reuses its cached snapshot)
///   ...
///
/// Caller passes `KNOWN_MTIMES` env var: a `:` separated list of
/// `<rel>=<mtime>` pairs giving the latest mtime Swift has parsed for each
/// file. The remote re-tails any file whose mtime exceeds the supplied value
/// (or any file not in the list at all).
///
/// Also installs hooks idempotently on each poll so the marker dir gets
/// populated on `PermissionRequest` and cleared on tool completion / stop.
private let remoteScript = ##"""
set -e
DIR="$HOME/.claude/projects"
NOTCH_DIR="$HOME/.claude/notch"
SETTINGS="$HOME/.claude/settings.json"
HOOK_DIR="$NOTCH_DIR/hooks"

# --- One-time hook installation -----------------------------------------
# Gated by a sentinel so we don't redo this work on every poll. Bump the
# version suffix to force a re-run after script changes.
INSTALL_SENTINEL="$NOTCH_DIR/.installed.v6"
mkdir -p "$NOTCH_DIR"
# On force-refresh, purge all awaiting markers so stale permission state
# (e.g. from an Esc interrupt that didn't fire the clear hook) is wiped.
if [ "${CLEAR_MARKERS:-}" = "1" ]; then
  find "$NOTCH_DIR" -maxdepth 1 -type f -name '*.awaiting' -delete 2>/dev/null
fi
# Clean up older sentinels so their presence doesn't keep us from re-running
# the install when the script has changed.
rm -f "$NOTCH_DIR/.installed.v1" "$NOTCH_DIR/.installed.v2" "$NOTCH_DIR/.installed.v3" "$NOTCH_DIR/.installed.v4" "$NOTCH_DIR/.installed.v5" 2>/dev/null
if [ -f "$INSTALL_SENTINEL" ]; then
  printf '===STATE=== active\n'
else
  printf '===STATE=== setup\n'
fi
if [ ! -f "$INSTALL_SENTINEL" ]; then
mkdir -p "$HOOK_DIR"

# PermissionRequest hook: writes request JSON to marker so the notch app
# can display what's being requested. Non-blocking — display only.
cat > "$HOOK_DIR/permission-request.sh" <<'EOF'
#!/bin/sh
INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$SID" ] && printf '%s' "$INPUT" | tr -d '\n' > "$HOME/.claude/notch/$SID.awaiting" 2>/dev/null
exit 0
EOF
cat > "$HOOK_DIR/clear-awaiting.sh" <<'EOF'
#!/bin/sh
INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$SID" ] && rm -f "$HOME/.claude/notch/$SID.awaiting" 2>/dev/null
exit 0
EOF
chmod +x "$HOOK_DIR/permission-request.sh" "$HOOK_DIR/clear-awaiting.sh"

# Patch settings.json's hooks field. Always strip our previous entries first
# (matching by command path) and re-add — that way upgrades to this script
# automatically install new entries (e.g. a new event we want to hook).
if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" "$HOOK_DIR" <<'PYEOF' 2>/dev/null || true
import json, sys, os
path, hook_dir = sys.argv[1], sys.argv[2]
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    sys.exit(0)
hooks = cfg.setdefault("hooks", {})
perm_req = f"{hook_dir}/permission-request.sh"
clear = f"{hook_dir}/clear-awaiting.sh"
# Also remove legacy entries from earlier versions.
legacy = {f"{hook_dir}/mark-awaiting.sh", f"{hook_dir}/pre-tool.sh"}
ours = {perm_req, clear} | legacy

# Remove any existing entries that point at our scripts so we can re-add.
for event, arr in list(hooks.items()):
    new_arr = []
    for entry in arr:
        sub = entry.get("hooks", []) if isinstance(entry, dict) else []
        keep_sub = [h for h in sub if h.get("command") not in ours]
        if keep_sub:
            new_entry = dict(entry)
            new_entry["hooks"] = keep_sub
            new_arr.append(new_entry)
    if new_arr:
        hooks[event] = new_arr
    else:
        del hooks[event]

def add(event, cmd):
    arr = hooks.setdefault(event, [])
    arr.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
add("PermissionRequest", perm_req)
add("PreToolUse", clear)
add("PostToolUse", clear)
add("Stop", clear)
tmp = path + ".notch.tmp"
with open(tmp, "w") as f: json.dump(cfg, f, indent=2)
os.replace(tmp, path)
PYEOF
fi
touch "$INSTALL_SENTINEL"
fi

# --- Marker output ------------------------------------------------------
# Use `find` instead of a glob loop so we don't have to worry about
# nullglob/nomatch differences between bash and zsh on the remote.
find "$NOTCH_DIR" -maxdepth 1 -type f -name '*.awaiting' 2>/dev/null | while read -r marker; do
  bn=$(basename "$marker" .awaiting)
  mmt=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null)
  content=$(cat "$marker" 2>/dev/null)
  if [ -n "$content" ]; then
    printf '===AWAITING=== %s %s %s\n' "$bn" "$mmt" "$content"
  else
    printf '===AWAITING=== %s %s\n' "$bn" "$mmt"
  fi
done

# --- Live token totals (24h + all-time) --------------------------------
# Walk JSONLs and sum usage tokens directly. stats-cache.json only updates
# at session boundaries so it lags during active sessions; this is real-time.
# Dedup by message.id within each file because Claude Code splits one API
# response into multiple JSONL lines (one per content block) sharing a usage.
if [ -d "$DIR" ]; then
  python3 - "$DIR" <<'PYEOF' 2>/dev/null || true
import json, os, sys, time, glob
root = sys.argv[1]
cutoff_24h = time.time() - 24*3600
total_24h = 0
total_all = 0
for f in glob.glob(os.path.join(root, "*", "*.jsonl")):
    try:
        mt = os.path.getmtime(f)
    except OSError:
        continue
    include_24h = mt >= cutoff_24h
    try:
        fh = open(f, "r", errors="ignore")
    except OSError:
        continue
    seen = set()
    for line in fh:
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") != "assistant":
            continue
        msg = o.get("message") or {}
        mid = msg.get("id")
        if mid:
            if mid in seen: continue
            seen.add(mid)
        u = msg.get("usage") or {}
        if not isinstance(u, dict): continue
        t = (u.get("input_tokens") or 0) + (u.get("output_tokens") or 0) \
          + (u.get("cache_read_input_tokens") or 0) \
          + (u.get("cache_creation_input_tokens") or 0)
        total_all += t
        if include_24h:
            total_24h += t
    fh.close()
print(f"===DAILY24=== {total_24h}")
print(f"===DAILYALL=== {total_all}")
PYEOF
fi

# --- Settings + JSONL output -------------------------------------------
printf '===SETTINGS===\n'
if [ -f "$SETTINGS" ]; then cat "$SETTINGS"; fi
printf '\n'
[ -d "$DIR" ] || exit 0
# KNOWN_MTIMES is "<rel>=<mtime>:<rel>=<mtime>:..." — for each file we've
# already parsed, Swift sends the mtime it cached. We re-tail only files
# whose remote mtime advances past that. Unknown files always get tailed.
: "${KNOWN_MTIMES:=}"
: "${WINDOW_MIN:=60}"
find "$DIR" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mmin "-$WINDOW_MIN" 2>/dev/null | while read -r f; do
  mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  rel="${f#$DIR/}"
  # Look up cached mtime for this rel in KNOWN_MTIMES (if any).
  cached_mt=""
  case ":$KNOWN_MTIMES:" in
    *":$rel=$mt:"*) cached_mt="$mt" ;;
    *":$rel="*)
      # Some other mtime is cached; extract it.
      cached_mt=$(printf '%s' "$KNOWN_MTIMES" | tr ':' '\n' | grep -m1 "^$rel=" | cut -d= -f2)
      ;;
  esac
  if [ -z "$cached_mt" ] || [ "$mt" -gt "$cached_mt" ]; then
    printf '===FILE=== %s %s\n' "$rel" "$mt"
    cat "$f"
  else
    printf '===META=== %s %s\n' "$rel" "$mt"
  fi
done

# --- Git status per active session cwd ------------------------------------
if [ "${GIT_TRACKING:-}" = "1" ]; then
  find "$DIR" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mmin "-$WINDOW_MIN" 2>/dev/null | while read -r f; do
    cwd=$(grep -o '"cwd":"[^"]*"' "$f" 2>/dev/null | tail -1 | sed 's/"cwd":"//;s/"$//')
    [ -z "$cwd" ] && continue
    [ -d "$cwd" ] || continue
    [ -d "$cwd/.git" ] || git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    adds=0; dels=0
    stat=$(git -C "$cwd" diff --stat 2>/dev/null | tail -1)
    if [ -n "$stat" ]; then
      a=$(printf '%s' "$stat" | grep -o '[0-9]* insertion' | grep -o '[0-9]*')
      d=$(printf '%s' "$stat" | grep -o '[0-9]* deletion' | grep -o '[0-9]*')
      [ -n "$a" ] && adds=$a
      [ -n "$d" ] && dels=$d
    fi
    # Include staged changes too
    stat2=$(git -C "$cwd" diff --cached --stat 2>/dev/null | tail -1)
    if [ -n "$stat2" ]; then
      a2=$(printf '%s' "$stat2" | grep -o '[0-9]* insertion' | grep -o '[0-9]*')
      d2=$(printf '%s' "$stat2" | grep -o '[0-9]* deletion' | grep -o '[0-9]*')
      [ -n "$a2" ] && adds=$((adds + a2))
      [ -n "$d2" ] && dels=$((dels + d2))
    fi
    printf '===GIT=== %s %s %s\n' "$cwd" "$adds" "$dels"
  done
fi
"""##

final class Poller {
    private let interval: TimeInterval
    private let bridge: SSHBridge
    private let store: SessionStore
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "notch-monitor.poller")

    init(interval: TimeInterval, bridge: SSHBridge, store: SessionStore) {
        self.interval = interval
        self.bridge = bridge
        self.store = store
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// Force an immediate poll. Cheap because per-host re-entrancy guards
    /// will skip hosts that already have a tick in flight.
    /// When `clearMarkers` is true, all `.awaiting` marker files are removed
    /// on each host before scanning — a hard reset for stale permission state.
    func reloadNow(clearMarkers: Bool = true) {
        queue.async { [weak self] in self?.tick(clearMarkers: clearMarkers) }
    }

    /// Per-host last-known snapshots. We keep these around so a single failed
    /// SSH tick doesn't make a host's sessions disappear from the UI — the
    /// stale data shows for up to `hostStaleAfter` seconds before being dropped.
    private var lastSnapshotsByHost: [String: [SessionSnapshot]] = [:]
    private var lastTotalsByHost: [String: DailyTotals] = [:]
    private var lastSuccessByHost: [String: Date] = [:]
    private static let hostStaleAfter: TimeInterval = 30

    /// Per-(host, rel) cache: the parsed snapshot + raw activity inputs,
    /// keyed by file mtime. Used when the remote sends `===META===` for an
    /// unchanged file. We keep the inputs so time-decay states (e.g.
    /// `.justFinished` → `.idle` after 60s) can be recomputed without
    /// re-tailing.
    private struct CachedSnapshot {
        let snapshot: SessionSnapshot
        let inputs: JSONLParser.ActivityInputs
        let mtime: TimeInterval
    }
    private var fileCache: [String: [String: CachedSnapshot]] = [:]   // host.alias -> rel -> entry


    /// Per-host re-entrancy guard: skip a host if its previous poll is still
    /// running. Prevents pile-ups when a host is slow.
    private var inFlightHosts: Set<String> = []
    private let inFlightLock = NSLock()

    /// Per-host lifecycle state for the footer in the UI.
    private var hostStateByAlias: [String: HostState] = [:]

    private func tick(clearMarkers: Bool = false) {
        let hosts = HostDiscovery.discover()
        let group = DispatchGroup()
        let resultsLock = NSLock()
        var perHostSnapshots: [String: [SessionSnapshot]] = [:]
        var perHostError: [String: String] = [:]
        var perHostState: [String: HostState] = [:]
        var perHostTotals: [String: DailyTotals] = [:]
        var perHostGitStatus: [String: [String: GitStatus]] = [:]
        var perHostPermRequests: [String: [String: PermissionRequest]] = [:]

        // Snapshot once per tick so all hosts use a consistent window even if
        // the user flips the setting mid-tick.
        let window = AppSettings.shared.activityWindow
        let windowSeconds = window.seconds
        let windowMinutes = window.minutes

        // Mark not-yet-seen hosts as connecting on the first time we touch them.
        var publishedInitialConnecting = false
        for host in hosts {
            if hostStateByAlias[host.alias] == nil {
                hostStateByAlias[host.alias] = host.isLocal ? .localOk : .connecting
                publishedInitialConnecting = true
            }
        }

        // Publish the initial "connecting…" footer immediately so the UI
        // shows it during the (potentially multi-second) first SSH probe,
        // rather than only flipping to active or offline after the probe
        // finishes.
        if publishedInitialConnecting {
            let initialHostStatuses: [HostStatus] = hosts.map { h in
                HostStatus(
                    id: h.alias,
                    isLocal: h.isLocal,
                    state: hostStateByAlias[h.alias] ?? (h.isLocal ? .localOk : .connecting)
                )
            }
            DispatchQueue.main.async { [store] in
                store.hosts = initialHostStatuses
            }
        }

        for host in hosts {
            inFlightLock.lock()
            let alreadyRunning = inFlightHosts.contains(host.alias)
            if !alreadyRunning { inFlightHosts.insert(host.alias) }
            inFlightLock.unlock()
            if alreadyRunning { continue }

            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer {
                    self?.inFlightLock.lock()
                    self?.inFlightHosts.remove(host.alias)
                    self?.inFlightLock.unlock()
                    group.leave()
                }
                guard let self = self else { return }
                self.inFlightLock.lock()
                let cache = self.fileCache[host.alias] ?? [:]
                self.inFlightLock.unlock()
                let known = cache
                    .map { "\($0.key)=\(Int($0.value.mtime))" }
                    .joined(separator: ":")
                // Quote because rels contain `-` and other shell-safe chars
                // but never `'` (they're filesystem paths Claude Code wrote).
                let clearEnv = clearMarkers ? "CLEAR_MARKERS=1 " : ""
                let gitEnv = AppSettings.shared.gitTrackingEnabled ? "GIT_TRACKING=1 " : ""
                let cmd = "\(clearEnv)\(gitEnv)KNOWN_MTIMES='\(known)' WINDOW_MIN=\(windowMinutes) " + remoteScript
                // Generous: cold SSH connect to corp dev hosts can take 3-4s
                // and the script does install + tail work on first run.
                switch self.bridge.run(host: host, command: cmd, timeout: 25) {
                case .success(let out):
                    let (snaps, remoteState, totals, gitStatuses, permReqs) = self.parse(output: out, host: host, stalenessWindow: windowSeconds)
                    resultsLock.lock()
                    perHostSnapshots[host.alias] = snaps
                    perHostTotals[host.alias] = totals
                    perHostGitStatus[host.alias] = gitStatuses
                    perHostPermRequests[host.alias] = permReqs
                    if host.isLocal {
                        perHostState[host.alias] = .localOk
                    } else if let rs = remoteState {
                        perHostState[host.alias] = rs
                    } else {
                        perHostState[host.alias] = .active
                    }
                    resultsLock.unlock()
                case .failure(let err):
                    resultsLock.lock()
                    perHostError[host.alias] = "\(host.alias): \(err)"
                    perHostState[host.alias] = .offline
                    resultsLock.unlock()
                    NSLog("[notch-monitor] %@ SSH failed: %@", host.alias, "\(err)")
                }
            }
        }

        // Wait for all hosts; bounded by SSHBridge's per-call timeout.
        group.wait()

        // Merge into the per-host cache so stale-on-failure logic can reuse.
        var allSnapshots: [SessionSnapshot] = []
        var anyConnected = false
        var lastErr: String?
        for host in hosts {
            if let snaps = perHostSnapshots[host.alias] {
                lastSnapshotsByHost[host.alias] = snaps
                if let t = perHostTotals[host.alias] {
                    lastTotalsByHost[host.alias] = t
                }
                lastSuccessByHost[host.alias] = Date()
                allSnapshots.append(contentsOf: snaps)
                anyConnected = true
            } else if perHostError[host.alias] != nil ||
                      inFlightHosts.contains(host.alias) {
                // Only surface the error to the UI when we have no fresh
                // cache to fall back on. Transient failures (Bad file
                // descriptor from Pipe teardown races, JSONL rotation
                // mid-cat, etc.) should be silent if the previous tick's
                // data is still recent — the next tick almost always
                // succeeds.
                if let lastAt = lastSuccessByHost[host.alias],
                   Date().timeIntervalSince(lastAt) <= Self.hostStaleAfter,
                   let cached = lastSnapshotsByHost[host.alias] {
                    allSnapshots.append(contentsOf: cached)
                    anyConnected = true
                } else {
                    if let err = perHostError[host.alias] { lastErr = err }
                    lastSnapshotsByHost.removeValue(forKey: host.alias)
                }
            } else {
                // Skipped due to prior in-flight tick — reuse cache silently.
                if let cached = lastSnapshotsByHost[host.alias] {
                    allSnapshots.append(contentsOf: cached)
                    anyConnected = true
                }
            }
            // Merge state. If host wasn't probed this tick (still in flight
            // or skipped), retain whatever state we previously had.
            if let s = perHostState[host.alias] {
                hostStateByAlias[host.alias] = s
            }
        }

        let hostStatuses: [HostStatus] = hosts.map { h in
            HostStatus(
                id: h.alias,
                isLocal: h.isLocal,
                state: hostStateByAlias[h.alias] ?? (h.isLocal ? .localOk : .connecting)
            )
        }

        // Aggregate today totals across every host we've ever heard from.
        var aggAllTokens = 0
        var agg24Tokens = 0
        for (_, t) in lastTotalsByHost {
            aggAllTokens += t.tokensAllTime
            agg24Tokens  += t.tokensLast24h
        }
        let aggTotals = DailyTotals(
            tokensAllTime: aggAllTokens,
            tokensLast24h: agg24Tokens
        )

        // Merge git statuses from all hosts into a single dict.
        var mergedGitStatus: [String: GitStatus] = [:]
        for (_, statuses) in perHostGitStatus {
            for (path, status) in statuses {
                mergedGitStatus[path] = status
            }
        }

        // Merge permission requests from all hosts.
        var mergedPermRequests: [String: PermissionRequest] = [:]
        for (_, reqs) in perHostPermRequests {
            for (sid, req) in reqs {
                mergedPermRequests[sid] = req
            }
        }

        let snapshots = allSnapshots
        let connected = anyConnected
        let err = lastErr
        let gitStatus = mergedGitStatus
        let permReqs = mergedPermRequests
        DispatchQueue.main.async { [store] in
            store.update(
                snapshots,
                connected: connected,
                error: err,
                hosts: hostStatuses,
                todayTotals: aggTotals,
                gitStatus: gitStatus,
                permissionRequests: permReqs
            )
        }
    }

    private func parse(output: String, host: DetectedHost, stalenessWindow: TimeInterval) -> ([SessionSnapshot], HostState?, DailyTotals, [String: GitStatus], [String: PermissionRequest]) {
        var snapshots: [SessionSnapshot] = []
        var currentRel: String?
        var currentMTime: Date = Date()
        var buffer: [String] = []
        var gitStatuses: [String: GitStatus] = [:]
        var permRequests: [String: PermissionRequest] = [:]

        // Phases: AWAITING markers, then settings, then file blocks.
        var inSettings = false
        var settingsBuffer = ""
        var defaultModelHint: String?
        var awaitingSessionMarkers: [String: Date] = [:]  // session_id -> marker mtime
        var remoteState: HostState?


        // Cache subtree we'll mutate as we go.
        var hostFileCache = fileCache[host.alias] ?? [:]
        // Track keys seen this tick so we can prune cache entries for files
        // that have aged out of the 60-min window on the remote.
        var seenKeys: Set<String> = []

        func awaiting(for sid: String, fileMTime: Date) -> Bool {
            return awaitingSessionMarkers[sid] != nil
        }

        func parseAndAppend(rel: String, mtime: Date, lines: [String]) {
            let parts = rel.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let projectDir = parts[0]
            let sessionId = parts[1].replacingOccurrences(of: ".jsonl", with: "")
            guard let (snap, inputs) = JSONLParser.parse(
                sessionId: sessionId,
                projectDir: projectDir,
                host: host,
                defaultModelHint: defaultModelHint,
                awaitingPermission: awaiting(for: sessionId, fileMTime: mtime),
                lines: lines,
                fileMTime: mtime
            ) else { return }
            if Date().timeIntervalSince(snap.lastMessageAt) <= stalenessWindow {
                snapshots.append(snap)
                hostFileCache[rel] = CachedSnapshot(
                    snapshot: snap,
                    inputs: inputs,
                    mtime: mtime.timeIntervalSince1970
                )
                seenKeys.insert(rel)
            }
        }

        func reuseCached(rel: String, mtime: Date) {
            guard let cached = hostFileCache[rel] else { return }
            let parts = rel.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let sessionId = parts[1].replacingOccurrences(of: ".jsonl", with: "")
            // Always recompute activity. Two reasons:
            //   1. Awaiting flag can flip between polls without mtime change.
            //   2. Time-decay states (`.justFinished` → `.idle` after 60s)
            //      need the current `Date()` to evaluate.
            let recomputed = JSONLParser.recomputeActivity(
                inputs: cached.inputs,
                awaitingPermission: awaiting(for: sessionId, fileMTime: mtime)
            )
            let cachedSnap = cached.snapshot
            let snap: SessionSnapshot = (recomputed == cachedSnap.activity) ? cachedSnap :
                SessionSnapshot(
                    id: cachedSnap.id, host: cachedSnap.host, isLocal: cachedSnap.isLocal,
                    project: cachedSnap.project,
                    activity: recomputed,
                    lastMessageAt: cachedSnap.lastMessageAt,
                    inputTokens: cachedSnap.inputTokens,
                    outputTokens: cachedSnap.outputTokens,
                    cacheReadTokens: cachedSnap.cacheReadTokens,
                    cacheCreationTokens: cachedSnap.cacheCreationTokens,
                    lastAssistantPreview: cachedSnap.lastAssistantPreview,
                    model: cachedSnap.model, gitBranch: cachedSnap.gitBranch,
                    cwd: cachedSnap.cwd,
                    contextTokens: cachedSnap.contextTokens,
                    modelContextLimit: cachedSnap.modelContextLimit
                )
            if Date().timeIntervalSince(snap.lastMessageAt) <= stalenessWindow {
                snapshots.append(snap)
                // Refresh the cache so future ticks see the current activity
                // without recomputing more than once per tick.
                hostFileCache[rel] = CachedSnapshot(
                    snapshot: snap,
                    inputs: cached.inputs,
                    mtime: cached.mtime
                )
                seenKeys.insert(rel)
            }
        }

        func flushFileBlock() {
            guard let rel = currentRel else { return }
            parseAndAppend(rel: rel, mtime: currentMTime, lines: buffer)
            buffer.removeAll(keepingCapacity: true)
            currentRel = nil
        }

        var daily24: Int = 0
        var dailyAll: Int = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("===DAILY24=== ") {
                daily24 = Int(line.dropFirst("===DAILY24=== ".count).trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }
            if line.hasPrefix("===DAILYALL=== ") {
                dailyAll = Int(line.dropFirst("===DAILYALL=== ".count).trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }
            if line.hasPrefix("===GIT=== ") {
                let parts = line.dropFirst("===GIT=== ".count)
                    .split(separator: " ")
                if parts.count >= 3 {
                    let cwd = String(parts[0..<(parts.count - 2)].joined(separator: " "))
                    let additions = Int(parts[parts.count - 2]) ?? 0
                    let deletions = Int(parts[parts.count - 1]) ?? 0
                    gitStatuses[cwd] = GitStatus(additions: additions, deletions: deletions)
                }
                continue
            }
            if line.hasPrefix("===STATE=== ") {
                let value = String(line.dropFirst("===STATE=== ".count))
                    .trimmingCharacters(in: .whitespaces)
                switch value {
                case "active": remoteState = .active
                case "setup":  remoteState = .settingUp
                default: break
                }
                continue
            }
            if line.hasPrefix("===AWAITING=== ") {
                let rest = line.dropFirst("===AWAITING=== ".count)
                let parts = rest.split(separator: " ", maxSplits: 2)
                let sid = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                let markerMTime: Date? = parts.count > 1
                    ? TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) }
                    : nil
                if !sid.isEmpty {
                    awaitingSessionMarkers[sid] = markerMTime ?? Date.distantPast
                    if parts.count > 2,
                       let jsonData = String(parts[2]).data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let toolName = obj["tool_name"] as? String {
                        let toolInput = (obj["tool_input"] as? [String: Any]) ?? [:]
                        permRequests[sid] = PermissionRequest(
                            sessionId: sid,
                            toolName: toolName,
                            toolInput: toolInput
                        )
                    }
                }
                continue
            }
            if line == "===SETTINGS===" {
                flushFileBlock()
                inSettings = true
                continue
            }
            if line.hasPrefix("===META=== ") {
                if inSettings {
                    inSettings = false
                    defaultModelHint = extractModelField(fromSettingsJSON: settingsBuffer)
                    settingsBuffer = ""
                }
                flushFileBlock()
                let rest = line.dropFirst("===META=== ".count)
                if let spaceIdx = rest.lastIndex(of: " ") {
                    let rel = String(rest[..<spaceIdx])
                    let mt = String(rest[rest.index(after: spaceIdx)...])
                    let mtDate = TimeInterval(mt).map { Date(timeIntervalSince1970: $0) } ?? Date()
                    reuseCached(rel: rel, mtime: mtDate)
                }
                continue
            }
            if line.hasPrefix("===FILE=== ") {
                if inSettings {
                    inSettings = false
                    defaultModelHint = extractModelField(fromSettingsJSON: settingsBuffer)
                    settingsBuffer = ""
                }
                flushFileBlock()
                let rest = line.dropFirst("===FILE=== ".count)
                if let spaceIdx = rest.lastIndex(of: " ") {
                    currentRel = String(rest[..<spaceIdx])
                    let mt = String(rest[rest.index(after: spaceIdx)...])
                    currentMTime = TimeInterval(mt).map { Date(timeIntervalSince1970: $0) } ?? Date()
                }
            } else if inSettings {
                settingsBuffer.append(String(line))
                settingsBuffer.append("\n")
            } else {
                buffer.append(String(line))
            }
        }
        flushFileBlock()

        // Prune cache entries for files we no longer see (aged out of the
        // remote's 60-min window) so memory doesn't grow unbounded.
        for key in hostFileCache.keys where !seenKeys.contains(key) {
            hostFileCache.removeValue(forKey: key)
        }

        // Persist cache + high-water mark for this host.
        // Since `tick()` runs concurrent hosts off the main queue, guard with
        // the in-flight lock (poller methods otherwise serialize on the timer
        // queue, but `parse` is invoked from the global utility queue).
        inFlightLock.lock()
        fileCache[host.alias] = hostFileCache
        inFlightLock.unlock()

        let hostTotals = DailyTotals(tokensAllTime: dailyAll, tokensLast24h: daily24)
        return (snapshots, remoteState, hostTotals, gitStatuses, permRequests)
    }

    /// Pulls the top-level "model" field out of settings.json. Settings can be
    /// large; we only care about that one string.
    private func extractModelField(fromSettingsJSON s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["model"] as? String
    }

}
