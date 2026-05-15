# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS status-bar app (Swift + AppKit, SPM, no Xcode project) that observes the locally-running Claude Code CLI sessions and surfaces their state in the menu bar: aggregate icon, per-session list, lifetime token usage by model, current 5-hour rolling window, notifications when a session enters `waiting` / completes / has been waiting too long, an in-app permission-prompt panel, and a preferences window (icon colors, notification toggle, reminder interval, launch-at-login).

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

Two file-watching pipelines plus a bidirectional permission-prompt pipeline fan into `AppDelegate`, with three small detectors deriving notification events off `SessionStore.sessions`:

```
~/.claude/sessions/*.json  ──► SessionWatcher ──► SessionStore.@Published sessions ──┐
                                  (FSEvents + 30s safety timer)                       │
                                                                                      ├──► AppDelegate (Combine sinks)
                                                                                      │       ├─► StatusIcon, NSMenu (sessions, lifetime, 5h window)
~/.claude/projects/**/*.jsonl ──► UsageTracker ──► @Published lifetimeByModel ───────┤       ├─► WaitingNotifier (gated by SettingsStore.notificationsEnabled)
                                  (30s timer)    └► @Published currentWindow         │       └─► SettingsWindowController (preferences UI)
                                  + LiveUsageAggregator (lifetime sums)              │
                                  + RollingWindowAggregator (5h window, ISO ts)      │
                                                                                     │
SessionStore.sessions ──► WaitingTransitionDetector ─────────────────────────────────┤  (idle/busy → waiting edge → notify)
                      ──► TaskCompletionDetector  ───────────────────────────────────┤  (busy → idle edge → "任务完成"; first call absorbs baseline)
                      ──► WaitingReminderTracker (5s timer, mutating struct) ────────┘  (re-fires up to maxReminders × interval from SettingsStore)

SettingsStore (UserDefaults: workingColor, attentionColor, notificationsEnabled, reminderInterval) ──► AppDelegate.objectWillChange sink ──► icon refresh + reminder tracker rebuild

claude (PermissionRequest hook) ─► ClaudeStatusBarHook ─► Unix socket
                                                                ↓
                                PermissionPromptListener ─► PermissionPromptStore ──┬─► PermissionPromptPanelManager ─► PermissionPromptPanel (NSPanel)
                                                                                    │       (registers Ctrl+Shift+Y / Ctrl+Shift+N
                                                                                    │        global hotkeys while ≥1 panel is visible;
                                                                                    │        resolves the latest panel)
                                                                                    └◄────────── allow / deny ◄──────────────────────────────────────────
```

The permission-prompt pipeline is a separate SPM target (`ClaudeStatusBarHook` executable + `ClaudeStatusBarHookCore` library, with `SocketClient` and `HookProcessor`). The hook is spawned by `claude` per `PermissionRequest` event and short-circuits to the main app over a Unix domain socket at `~/Library/Application Support/ClaudeStatusBar/prompt.sock`. The hook races against Claude Code's terminal prompt (`Promise.race` inside the CLI's permission engine) — first response wins, the other is aborted, so the user can answer in either place. If the helper exits silently (no app, no socket), the terminal prompt simply takes over. The UI is a non-activating floating `NSPanel` (top-right), **not** a `UNUserNotificationCenter` notification — chosen because macOS folds multi-action notifications under an "Options" button, defeating single-click. See `docs/permission-prompt.md` for the user-facing setup.

Key conventions to keep when extending:

- **Pure-static aggregators.** `LiveUsageAggregator`, `SessionDetailsReader`, `SessionWatcher.readSessions(from:)` are stateless functions that take a URL/Data and return decoded values. Tests construct a temp directory, write fixtures, and call the static method directly. Keep new file-format readers in this shape.
- **Liveness filter.** `SessionWatcher.readSessions` drops any session whose pid is dead (`kill(pid, 0)` via `ProcessLiveness.isAlive`). Stale `.json` files left behind by crashed CLIs are silently ignored — don't add a delete step, that's the CLI's job.
- **Edge-triggered notifications.** `WaitingTransitionDetector` and `TaskCompletionDetector` are both `mutating struct`s that remember the previous pid set (waiting / busy respectively) so we only notify on the transition, not every refresh tick. Keep them stateful — making them pure would re-fire on every scan. `TaskCompletionDetector` additionally absorbs its first call as a baseline so app start doesn't fire spurious "任务完成" for sessions that were already idle.
- **Reminder tracker is timer-driven.** `WaitingReminderTracker.tick(sessions:now:)` is called every 5s from `AppDelegate`. It re-fires the waiting notification up to `config.maxReminders` times, with `initialDelay` and `interval` taken from `SettingsStore.reminderInterval` (nil = disabled, in which case `maxReminders = 0` and `tick` is a no-op). When the user changes the interval in preferences, the tracker is rebuilt — losing in-flight per-pid state is intentional.
- **Notifications gated by settings + active panels.** All `WaitingNotifier` posts (transition, reminder, completion) are gated by `SettingsStore.notificationsEnabled` in `AppDelegate`. On top of that, *waiting* notifications (transition + reminder) are also suppressed for any session whose sessionId is in `permissionStore.pendingSessionIds()` — the floating panel already owns that user-attention event, so a system banner would just double up. Completion notifications don't get this filter (busy → idle isn't a permission state). Detectors still run unconditionally so their internal state stays consistent across toggles; only the post is suppressed.
- **cwd → projects directory encoding.** `SessionDetailsReader.encodeProjectPath` replaces every non-alphanumeric character with `-`. This must match the encoding the Claude Code CLI uses when writing under `~/.claude/projects/`. If lookup starts failing, that's the first thing to verify.
- **Context-window table.** `SessionDetails.contextWindow(forModel:)` is the source of truth for `model → window size`. When a new model class ships, edit only this method. `usageRatio` deliberately doesn't cap at 1.0 — values >100% are the signal that the table is stale.
- **AppKit isolation, with documented exceptions.** Most of `Services/` and all of `Models/` import only `Foundation`/`Combine`/`Darwin`/`CoreServices`/`UserNotifications`/`ServiceManagement`, and the test target relies on that. The known exceptions (each justified by what they wrap) are: `SettingsStore` imports `AppKit` for `NSColor`; `GlobalHotkey` imports `Cocoa` + `Carbon.HIToolbox` for `RegisterEventHotKey`; `PermissionPromptPanelManager` imports `Cocoa` + `Carbon.HIToolbox` for window placement and key constants. Don't add new AppKit imports to `Services/` without a similarly hard reason.
- **Single UN delegate.** `NotificationDispatcher` is the only `UNUserNotificationCenterDelegate`. `WaitingNotifier` is post-only. Permission prompts go through `PermissionPromptPanelManager` + `PermissionPromptPanel` (NSPanel) and don't touch UN at all.
- **Resolved signal.** `PermissionPromptStore` exposes both `incoming` (new request) and `resolved` (any reason an entry leaves: explicit allow / always-allow / deny, **abandon** via panel ✕, timeout, or helper-disconnect). The panel manager subscribes to both — `incoming` to spawn a panel, `resolved` to dismiss whatever panel was showing for that id. The helper-disconnect path is what dismisses the panel when the user answered y/n in the terminal: `PermissionPromptListener` installs a `DispatchSource.makeReadSource` on the accepted client FD; on EOF (CLI killed the helper because terminal won the race) it calls `store.resolveDeny(message: "Settled by terminal prompt")`, which fires `resolved`. Don't try to detect this another way (heartbeat, polling) — EOF on the socket is the canonical signal.
- **Abandon path (✕ on panel).** `Store.Reply` is `(Decision?) -> Void`; passing `nil` is the abandon signal. `Store.abandon(id:)` invokes `reply(nil)` and fires `resolved`. The listener checks for nil and **closes the client fd without writing any response** — the helper's `SocketClient.requestResponse` then sees EOF on read, returns nil, `HookProcessor` returns nil, the helper exits 0 with no stdout, and the CLI's terminal prompt wins the race. Intent: ✕ means "I'll answer in the terminal", not "deny". Don't change ✕ to fire `resolveDeny`; that would silently reject the tool call.
- **Panel-internal `Outcome` is decoupled from wire `Behavior`.** `PermissionPromptPanel.Outcome` (`allow / allowAlways / deny / abandon`) is panel-only. `PermissionPromptDecision.Behavior` (`allow / deny / allowAlways`) is the app→helper wire enum. The two intentionally don't share a type — `abandon` has no business being JSON-encoded, and conflating them invited "what does abandon serialize to?" bugs. Manager translates `Outcome` → store calls explicitly.
- **Helper / app duplication of wire types.** `PermissionPromptRequest`/`Decision` live in `ClaudeStatusBar` (Swift `Codable`). The hook helper does not import them — it round-trips the same JSON via `JSONSerialization` dictionaries in `HookProcessor`. If the wire format changes, update both sides; there is no shared module by design (kept the SPM tree flat). Currently `Decision.Behavior` has three cases: `allow`, `deny`, `allowAlways` (raw value `"allow_always"`); the helper recognizes all three string forms.
- **Hook output schema is `PermissionRequest`-specific.** The CLI accepts `{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"|"deny", ...}}}` — note `decision: {behavior}`, not the `permissionDecision: "allow"` string used by `PreToolUse`. The two events have separate Zod schemas inside the CLI; do not copy fields between them. For "always allow" the helper flattens `allow_always` into `behavior: "allow"` plus an `updatedPermissions: [{type: "addRules", behavior: "allow", destination: "session", rules: [{toolName, ruleContent?}]}]` array — Bash pins `ruleContent` to the exact command string, other tools omit it (each tool has its own ruleContent grammar; we don't guess). Scope is intentionally `"session"`: kept on par with the terminal prompt's "Yes, and don't ask again this session", and deliberately *not* `"userSettings"` / `"projectSettings"` — broadening the scope means writing to the user's `settings.json`, which should be an explicit choice rather than a button click.
- **Permission-panel hotkeys are scoped to panel visibility.** `PermissionPromptPanelManager` registers Ctrl+Shift+Y / Ctrl+Shift+N via `GlobalHotkey` only while ≥1 panel is visible, and unregisters when the last one resolves. The hotkey resolves the **most recent** panel (`entries.last`), matching what "the latest 气泡" means visually. Don't make these hotkeys always-on — they'd silently swallow keystrokes the rest of the time. The "一直允许" button has no global hotkey by design (in-panel only, Tab to focus, Space to activate) — it's a "remember this" decision and should require the user to look at the panel.
- **Some tool requests skip the panel entirely.** `PermissionPromptPanelManager.toolsRoutedAwayFromPanel` (currently `["AskUserQuestion"]`) is the canonical list. The manager's `present(_:)` early-returns for these; in parallel, `AppDelegate` subscribes to the same `incoming` stream and routes them to a system notification (`Claude Code 需要你回答 · {project}`) plus an immediate `store.abandon(id:)`. Rationale: AskUserQuestion is a structured multi-choice prompt — "allow / deny" buttons are meaningless; the user must answer in the terminal. abandon lets the CLI's terminal prompt take over. To add another tool to this list, edit only the static set; both subscribers self-route on it.
- **No SIGPIPE on accepted sockets.** `PermissionPromptListener.acceptLoop` sets `SO_NOSIGPIPE` on every accepted client FD. Without it, writing the response back after the helper has already disconnected (terminal won the race, or 5-min timeout fired and we then attempted to deliver) raises SIGPIPE process-wide and tears down the app. We always check `write`'s return value, so EPIPE is fine — we just need the kernel to not signal us.
- **Rolling 5-hour window.** `RollingWindowAggregator.currentWindow(now:projectsRoot:)` reverse-scans every `*.jsonl` under `~/.claude/projects/` for assistant entries with an ISO-8601 `timestamp` within `now − 5h`. The window's `startedAt` is the earliest qualifying entry, `resetsAt = startedAt + 5h`, and `RollingWindow.remaining(now:)` powers the "重置 Xh Ym 后" menu line. Returns `nil` when there's no recent activity (rendered as "(无活动)"). Pure-static like the other aggregators.

## External file contracts (read-only, mostly)

The session/project files under `~/.claude/` are written by the Claude Code CLI; this app never writes to them.

- `~/.claude/sessions/{pid}.json` — one file per live CLI session. Schema in `Models/Session.swift` (`pid, sessionId, cwd, version, kind, entrypoint, startedAt, updatedAt, status, waitingFor?`). `startedAt`/`updatedAt` are **milliseconds** since epoch. Files are written non-atomically; partial-read JSON decode failures are expected and skipped (FSEvents will fire again).
- `~/.claude/projects/{encoded-cwd}/{sessionId}.jsonl` (or `.../{sessionId}/*.jsonl`) — append-only event log. Lines with `type == "assistant"` carry `message.model` and `message.usage.{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}`. `LiveUsageAggregator` sums across all of them; `SessionDetailsReader` reverse-scans for the most recent one.

**App-owned, writable:** `~/Library/Application Support/ClaudeStatusBar/prompt.sock` — Unix domain socket the listener binds to (perms 0700 on the directory, 0600 on the socket). Helper subprocesses dial in here per `tools/call`. Both ends use newline-delimited JSON; one connection = one request + one reply, then close.

## UI

- `OctopusIcon` rasterises a hard-coded 12×12 grid into an `NSImage`. Colour is parameterised; `isTemplate=true` for idle (AppKit auto-inverts for dark/light menu bars), `isTemplate=false` for the "working" / "needs attention" states so the colour survives. The two non-idle colours come from `SettingsStore.workingColor` / `attentionColor` — user-customisable in the Appearance preferences pane, defaulting to orange / system yellow.
- `SettingsWindowController` is a 3-tab window (通用 / 外观 / 关于) opened via the menu's "偏好设置..." item (⌘,). The General tab toggles notifications, picks a reminder interval, and surfaces launch-at-login through `LoginItemController` (hidden when running unbundled, since `SMAppService.mainApp` requires a code-signed bundle). Appearance edits the icon colors. About is static metadata.
- Menu strings are Chinese; match the existing tone when adding entries.
