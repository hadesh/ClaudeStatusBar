# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS status-bar app (Swift + AppKit, SPM, no Xcode project) that observes the locally-running Claude Code CLI sessions and surfaces their state in the menu bar: aggregate icon, per-session list, lifetime token usage by model, and a notification when a session enters `waiting`.

## Build / test

SwiftPM, macOS 13+. No external dependencies.

```bash
swift build                 # debug build (.build/debug/ClaudeStatusBar)
swift run                   # build + launch the menu bar app
swift test                  # run all XCTest targets
swift test --filter ClaudeStatusBarTests.SessionTests                       # one suite
swift test --filter ClaudeStatusBarTests.SessionTests/testDecodesBusySession # one test
```

Notifications use `UNUserNotificationCenter` only when launched from a bundle with an `Info.plist` (i.e. packaged as `.app`). When run via `swift run`, `WaitingNotifier` falls back to `osascript display notification`.

## Architecture

Three observation pipelines plus one bidirectional permission-prompt pipeline fan into `AppDelegate`, which is the only thing that touches AppKit:

```
~/.claude/sessions/*.json  ──► SessionWatcher ──► SessionStore.@Published sessions ──┐
                                  (FSEvents + 30s safety timer)                       │
                                                                                      ├──► AppDelegate (Combine sinks)
                                                                                      │       └─► StatusIcon, NSMenu
~/.claude/projects/**/*.jsonl ──► UsageTracker ──► @Published lifetimeByModel ───────┘           └─► WaitingNotifier
                                  (30s timer + LiveUsageAggregator)

SessionStore.sessions ──► WaitingTransitionDetector ──► WaitingNotifier (only on idle/busy → waiting edge)

claude (PermissionRequest hook) ─► ClaudeStatusBarHook ─► Unix socket
                                                                ↓
                                PermissionPromptListener ─► PermissionPromptStore ──┬─► PermissionPromptPanelManager ─► PermissionPromptPanel (NSPanel)
                                                                                    │                                            │
                                                                                    └◄────────── allow / deny ◄──────────────────┘
```

The permission-prompt pipeline is a separate SPM target (`ClaudeStatusBarHook` executable + `ClaudeStatusBarHookCore` library, with `SocketClient` and `HookProcessor`). The hook is spawned by `claude` per `PermissionRequest` event and short-circuits to the main app over a Unix domain socket at `~/Library/Application Support/ClaudeStatusBar/prompt.sock`. The hook races against Claude Code's terminal prompt (`Promise.race` inside the CLI's permission engine) — first response wins, the other is aborted, so the user can answer in either place. If the helper exits silently (no app, no socket), the terminal prompt simply takes over. The UI is a non-activating floating `NSPanel` (top-right), **not** a `UNUserNotificationCenter` notification — chosen because macOS folds multi-action notifications under an "Options" button, defeating single-click. See `docs/permission-prompt.md` for the user-facing setup.

Key conventions to keep when extending:

- **Pure-static aggregators.** `LiveUsageAggregator`, `SessionDetailsReader`, `SessionWatcher.readSessions(from:)` are stateless functions that take a URL/Data and return decoded values. Tests construct a temp directory, write fixtures, and call the static method directly. Keep new file-format readers in this shape.
- **Liveness filter.** `SessionWatcher.readSessions` drops any session whose pid is dead (`kill(pid, 0)` via `ProcessLiveness.isAlive`). Stale `.json` files left behind by crashed CLIs are silently ignored — don't add a delete step, that's the CLI's job.
- **Edge-triggered notifications.** `WaitingTransitionDetector` is a `mutating struct` that remembers the previous waiting-pid set so we only notify on the transition into `waiting`, not every refresh tick. Keep this stateful — making it pure would re-fire on every scan.
- **cwd → projects directory encoding.** `SessionDetailsReader.encodeProjectPath` replaces every non-alphanumeric character with `-`. This must match the encoding the Claude Code CLI uses when writing under `~/.claude/projects/`. If lookup starts failing, that's the first thing to verify.
- **Context-window table.** `SessionDetails.contextWindow(forModel:)` is the source of truth for `model → window size`. When a new model class ships, edit only this method. `usageRatio` deliberately doesn't cap at 1.0 — values >100% are the signal that the table is stale.
- **AppKit lives only in `AppDelegate` + `UI/`.** Services and models import only `Foundation`/`Combine`/`Darwin`/`CoreServices`/`UserNotifications`. Don't pull `Cocoa` into `Services/` — it breaks the testability that the rest of the codebase relies on.
- **Single UN delegate.** `NotificationDispatcher` is the only `UNUserNotificationCenterDelegate`. `WaitingNotifier` is post-only. Permission prompts go through `PermissionPromptPanelManager` + `PermissionPromptPanel` (NSPanel) and don't touch UN at all.
- **Resolved signal.** `PermissionPromptStore` exposes both `incoming` (new request) and `resolved` (any reason an entry leaves: explicit allow/deny, timeout). The panel manager subscribes to both — `incoming` to spawn a panel, `resolved` to dismiss whatever panel was showing for that id. This keeps the UI in sync when the request was settled by the terminal prompt or by timeout rather than the panel itself.
- **Helper / app duplication of wire types.** `PermissionPromptRequest`/`Decision` live in `ClaudeStatusBar` (Swift `Codable`). The hook helper does not import them — it round-trips the same JSON via `JSONSerialization` dictionaries in `HookProcessor`. If the wire format changes, update both sides; there is no shared module by design (kept the SPM tree flat).
- **Hook output schema is `PermissionRequest`-specific.** The CLI accepts `{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"|"deny", ...}}}` — note `decision: {behavior}`, not the `permissionDecision: "allow"` string used by `PreToolUse`. The two events have separate Zod schemas inside the CLI; do not copy fields between them.

## External file contracts (read-only, mostly)

The session/project files under `~/.claude/` are written by the Claude Code CLI; this app never writes to them.

- `~/.claude/sessions/{pid}.json` — one file per live CLI session. Schema in `Models/Session.swift` (`pid, sessionId, cwd, version, kind, entrypoint, startedAt, updatedAt, status, waitingFor?`). `startedAt`/`updatedAt` are **milliseconds** since epoch. Files are written non-atomically; partial-read JSON decode failures are expected and skipped (FSEvents will fire again).
- `~/.claude/projects/{encoded-cwd}/{sessionId}.jsonl` (or `.../{sessionId}/*.jsonl`) — append-only event log. Lines with `type == "assistant"` carry `message.model` and `message.usage.{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}`. `LiveUsageAggregator` sums across all of them; `SessionDetailsReader` reverse-scans for the most recent one.

**App-owned, writable:** `~/Library/Application Support/ClaudeStatusBar/prompt.sock` — Unix domain socket the listener binds to (perms 0700 on the directory, 0600 on the socket). Helper subprocesses dial in here per `tools/call`. Both ends use newline-delimited JSON; one connection = one request + one reply, then close.

## UI

- `OctopusIcon` rasterises a hard-coded 12×12 grid into an `NSImage`. Colour is parameterised; `isTemplate=true` for idle (AppKit auto-inverts for dark/light menu bars), `isTemplate=false` for the orange "working" / yellow "needs attention" states so the colour survives.
- Menu strings are Chinese; match the existing tone when adding entries.
