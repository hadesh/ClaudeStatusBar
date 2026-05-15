# Changelog

## 0.6.1 — 2026-05-15

授权面板的三处修复。

### 新增

- **「一直允许」按钮**：浮窗按钮变成 **拒绝 / 一直允许 / 允许** 三个。「一直允许」把规则加进当前 CLI 会话的临时白名单(scope = `session`),退出 `claude` 即失效,不会写到 `~/.claude/settings.json`。Bash 按命令字符串精确匹配;其他工具是 tool-wide-for-this-session(每种工具的 `ruleContent` 语法不同,helper 不去猜)。Tab 顺序: 拒绝 → 一直允许 → 允许。无全局热键,在面板里点。

### 修复

- **重复通知**:浮窗弹出的同时还会收到「Claude Code 等待响应」系统通知 banner —— 现在 `AppDelegate` 通过 `PermissionPromptStore.pendingSessionIds()` 过滤掉这些会话,transition 通知和 5s 周期的二次提醒都跳过。完成通知(busy → idle)不在此列。
- **终端先动作时浮窗不消失**:`PermissionPromptListener` 现在用 `DispatchSource.makeReadSource` 监听已 accept 的客户端 fd 的 EOF。CLI 因为终端赢 race 杀掉 hook 子进程时,EOF 会触发 `store.resolveDeny` → `store.resolved` 信号 → 面板消失。
- **SIGPIPE 闪退**:在已 accept 的 socket 上 set `SO_NOSIGPIPE`。否则在 helper 已断开后写回响应(终端先动 / 5min 超时后 panel 才点)会被 EPIPE → SIGPIPE 整个 app 拉死。这是 0.6.0 起就潜伏的 bug,只是上面这条修好之后才会有 reliable 重现。

### Wire 协议

- `PermissionPromptDecision.Behavior` 新增 `allowAlways`(rawValue `"allow_always"`)。app → helper 的 wire 形态多一种;helper → CLI 的 envelope 仍然是 `behavior: "allow"`,「always」语义放进新增的 `updatedPermissions: [{type:"addRules", behavior:"allow", destination:"session", rules:[{toolName, ruleContent?}]}]` 字段。

---

## 0.6.0 — 2026-05-14

新功能：状态栏权限审批面板。

### 新增

- **权限审批浮窗**：Claude Code 触发工具权限请求时，屏幕右上角弹一个浮动小面板，**单击「允许 / 拒绝」**直接回应，不用切回终端。面板里显示工具名、会话名（项目目录的 basename）、可滚动的命令详情。([`docs/permission-prompt.md`](docs/permission-prompt.md))
- **全局热键**：`Ctrl+Shift+Y` 允许、`Ctrl+Shift+N` 拒绝**最新一条**待审批请求。仅在至少一个面板可见时注册，不污染全局快捷键。
- **多面板堆叠**：并发权限请求纵向堆叠在右上角，每个面板独立处理。
- **race-with-terminal**：用户在终端直接按 y/n，CLI 会赢 race，对应面板自动消失（基于 `store.resolved` 信号）。
- **内置 `ClaudeStatusBarHook` 二进制**：作为 Claude Code `PermissionRequest` hook 在 .app bundle 里随主 app 一起分发。注册方式见配置说明。

### 改动

- **系统通知重定向**：原本会话进入 `waiting` 状态时弹的「Claude Code 等待响应」banner **不再使用**——权限请求由面板处理。banner 改成**任务完成**触发：CLI 会话从 `busy` 转回 `idle` 时弹「Claude Code 任务完成 · {项目名}」，点击仍跳回对应终端。
- **`scripts/package.sh`**：构建前先 `swift package clean` 防止删除文件后增量缓存残留旧 `.o`；不再用 `--product` 过滤构建（在某些 Swift 版本会静默跳过主 target）；同时打包主 app 和 hook helper 进同一个 `.app` bundle。

### 删除

- `WaitingTransitionDetector` / `WaitingReminderTracker` 及其测试 —— `waiting` 状态由面板覆盖，这两个类无用武之地。
- `WaitingNotifier.notify(session:)` —— 旧的"等待响应" banner 入口。

### Wire 协议

- `PermissionPromptRequest` 新增 `cwd: String?`、`sessionId: String?` 两个可选字段，由 hook helper 从 stdin 透传。
- 移除 `toolUseId`（MCP 路径残留，hook 路径用不到）。

### 设计抉择记录

- **为什么是 `PermissionRequest` hook 而不是 `--permission-prompt-tool` MCP**：MCP 需要用户给 `claude` alias 加启动 flag；hook 只在 `~/.claude/settings.json` 配一次即可，对 vanilla `claude` 直接生效，且 hook 与终端原生 prompt 在 CLI 内部是 `Promise.race`——任一边先回应另一边自动 abort。
- **为什么是自家 `NSPanel` 而不是 `UNUserNotificationCenter`**：macOS 通知里多个 action 会被折叠到「选项」按钮后面，破坏了"单击允许 / 拒绝"的体验；浮动面板不依赖系统通知权限和 Focus 模式。
- **多个 binary 放进一个 `.app`**：分发对外仍是一个 .app，但 hook helper 保持 Foundation-only 体积小、冷启动快（CLI 每次权限请求都要 spawn）。

### 依赖

- macOS 13+（`Network.framework` Unix socket、`NSPanel` 行为）
- 验证 Claude Code CLI 版本：2.1.140

---

## 0.3.0 及更早

见 git history。本仓库此前没有 CHANGELOG.md。
