# ClaudeNotch

A notch-anchored HUD for macOS that shows live Claude Code session status —
locally and on remote machines you SSH into.

## What it shows

**Collapsed:** a black pill that wraps around the notch. A small colored dot
on the right wing indicates the most attention-grabbing session state across
all hosts. When more than one session shares that state, the dot grows into
a colored badge with the count.

| Color  | State           | Meaning                                                       |
|--------|-----------------|---------------------------------------------------------------|
| green  | thinking        | Assistant is mid-turn, streaming text/thinking.               |
| blue   | running *tool*  | Tool dispatched, waiting on its result.                       |
| cyan   | processing      | Tool returned, assistant about to react.                      |
| pink   | awaiting input  | Permission prompt is open OR `AskUserQuestion`/`ExitPlanMode`.|
| gray   | idle            | Nothing happening; turn ended; or session went stale.         |

**Expanded** (click or hover for ½s): a per-project card with each session's
model, state, context-window usage bar, token breakdown, and estimated USD
cost. Footer shows per-host connection state.

## Build and run

### Quick dev loop

```sh
swift run
```

Runs against `~/.claude/projects/` and any SSH hosts with a `dev-dsk*` alias.
Quit with the menu-bar icon → Quit, or Ctrl-C in the terminal.

### Build a shareable `.app`

```sh
VERSION=0.4.0 ./scripts/build-app.sh
```

This:

1. Compiles the icon (`scripts/make-icon.swift` → `resources/AppIcon.icns`).
2. Builds the release binary (`swift build -c release`).
3. Assembles `dist/ClaudeNotch.app` with a generated `Info.plist`.
4. Ad-hoc codesigns it.
5. Zips it to `dist/ClaudeNotch.zip`.

`VERSION` defaults to `0.1.0`; override per release. The bundle identifier
(`com.eppacher.claudenotch`) is constant, so installing a new build over an
old one is a normal in-place update — macOS treats them as the same app.

### Distribute

Send `dist/ClaudeNotch.zip`. Recipients:

1. Unzip it.
2. Drag `ClaudeNotch.app` to `/Applications` (recommended — cleaner login-item
   path, fewer Gatekeeper friction points).
3. **First launch only:** right-click the app → **Open** → confirm.
   (Gatekeeper requires this gesture for ad-hoc-signed apps.)
4. Subsequent launches: double-click normally.

### Make/regenerate the icon

The icon is a black squircle with a pink dot in the center, drawn at every
required iconset size and packaged with `iconutil`:

```sh
swiftc -O scripts/make-icon.swift -o /tmp/make-icon
/tmp/make-icon
```

Output: `resources/AppIcon.iconset/*.png` and `resources/AppIcon.icns`.
`build-app.sh` runs this automatically.

To customize: edit colors / proportions in `scripts/make-icon.swift`. Constants
worth knowing:

- `inset = pxSize * 0.10` — Apple-recommended padding around the artwork.
- `cornerRadius = body.width * 0.22` — squircle corner ratio.
- `dotDiameter = body.width * 0.30` — pink dot relative to the squircle.

## Menu-bar item

A second status item appears in the menu bar with three entries:

- **ClaudeNotch *version*** — disabled header showing the build version.
- **Start at Login** — toggles a LaunchAgent at
  `~/Library/LaunchAgents/com.eppacher.claudenotch.plist` that runs
  `open -a /Applications/ClaudeNotch.app` at login. Visible in
  *System Settings → General → Login Items → Allow in the Background*
  (not the top "Open at Login" list — that's reserved for SMAppService apps,
  which require Developer ID signing).
- **Quit ClaudeNotch** — terminates the app.

## How polling works

`Poller` ticks every 1 second, fanning out across `local` and any discovered
SSH hosts concurrently on a global utility queue. Each tick:

1. Runs a small shell script on the host (locally or via SSH).
2. Script lists JSONL files in `~/.claude/projects/` touched in the last
   60 minutes, plus `===META===` mtime entries for files we've already
   parsed and `===FILE===` blocks (full `cat`) for files newer than
   our cached mtime. Differential streaming keeps SSH bytes low.
3. Script also installs a one-shot pair of hooks on first run
   (`PermissionRequest`, `PreToolUse`, `PostToolUse`, `PermissionDenied`,
   `Stop`) that touch/remove marker files in `~/.claude/notch/`. The poller
   reads those markers to detect "Claude is currently blocked on a permission
   prompt" — there's no JSONL signal for that, so we use the hook system.
4. Swift parses the new content and recomputes activity per session.

SSH connections are kept warm with `ControlMaster=auto` + `ControlPersist=600`
so successive polls reuse the open socket. Sockets are stored at
`$TMPDIR/claude-notch-ssh/<hashed-alias>.sock` (filename is hashed so long
host FQDNs don't blow the AF_UNIX 104-byte path limit).

### Host detection

Hosts are auto-discovered by `HostDiscovery`:

1. `local` is always included.
2. VSCode Remote: scans `~/Library/Application Support/Code/.../storage.json`
   and `workspaceStorage/*/workspace.json` for `ssh-remote+<alias>` URIs.
3. `~/.ssh/config`: any non-wildcard `Host` entries.

Remote aliases are filtered to those starting with **`dev-dsk`**. To change
the prefix, edit `allowedHostPrefix` in `Sources/ClaudeNotch/HostDiscovery.swift`.

### Requirements for remote hosts

- Key-based SSH auth (no password prompts — we run with `BatchMode=yes`).
- Claude Code installed and run there (so `~/.claude/projects/` exists).
- POSIX `find`, `stat`, `tail`, plus `python3` for the one-time hook install.

The remote's `~/.claude/settings.json` is auto-patched on first poll to add
the marker hooks. Patches are idempotent — adding our entries doesn't disturb
existing hook configurations.

## Files

| File | Purpose |
|---|---|
| `Sources/ClaudeNotch/AppDelegate.swift` | App entry, wires store → poller → notch window → menu bar. |
| `Sources/ClaudeNotch/NotchWindow.swift` | Borderless `NSPanel` anchored to the menu-bar row. |
| `Sources/ClaudeNotch/NotchRootView.swift` | SwiftUI views: collapsed pill, expanded panel, project cards. |
| `Sources/ClaudeNotch/MenuBarController.swift` | `NSStatusItem` with version/Login/Quit menu. |
| `Sources/ClaudeNotch/SessionStore.swift` | Observable state shared by UI and poller; pricing table. |
| `Sources/ClaudeNotch/JSONLParser.swift` | Tail-of-JSONL → `SessionSnapshot` with cached activity inputs for time-decay. |
| `Sources/ClaudeNotch/HostDiscovery.swift` | Local + VSCode Remote + `~/.ssh/config` host enumeration. |
| `Sources/ClaudeNotch/SSHBridge.swift` | Subprocess runner with `ControlMaster` reuse. |
| `Sources/ClaudeNotch/Poller.swift` | 1s timer, concurrent host fanout, differential streaming, hook install. |
| `scripts/build-app.sh` | One-shot build + bundle + sign + zip. |
| `scripts/make-icon.swift` | Programmatic icon generator (black squircle + pink dot). |

## Known limitations

- Ad-hoc signed; not notarized. Recipients must right-click → Open the first
  time. To notarize, you'd need an Apple Developer account ($99/yr).
- "Start at Login" uses a LaunchAgent plist (works without signing) rather
  than `SMAppService.mainApp` (requires Developer ID *or* `/Applications`
  install). Side effect: it appears under "Allow in the Background" rather
  than the top "Open at Login" list.
- Token totals come from `usage` fields on assistant messages. If Claude
  Code changes its JSONL schema, this may need updating.
