# 状态栏授权(允许 / 拒绝)

把 Claude Code 的权限询问搬到屏幕右上角的浮动小面板:每次 CLI 要授权一个工具调用时,弹一个带 **允许 / 拒绝** 按钮的面板,**单击直接生效**。

## 工作原理

Claude Code 的 `PermissionRequest` hook 在每次会触发交互式权限提示的时候同步触发。本仓库的 `ClaudeStatusBarHook` 注册到这个 hook 上,通过 Unix socket 把请求转给主 app(`ClaudeStatusBar.app`),主 app 弹一个浮动面板,用户点按钮,决策再通过 socket 回来,hook 把它包成 `hookSpecificOutput.decision` 输出到 stdout——CLI 收到后短路掉终端原生的 prompt。

```
claude (vanilla,无 flag)
   ↓ PermissionRequest hook(stdin JSON)
ClaudeStatusBarHook
   ↓ Unix socket
ClaudeStatusBar.app  →  浮动面板(允许/拒绝)
```

面板形态:屏幕右上角,`NSPanel` 浮动小窗口,工具名 + 会话名 + 可滚动的命令详情 + 两个按钮。多个并发请求会**纵向堆叠**,每个独立。

**键盘 / 焦点:**
- Return → 允许,Esc / ✕ → 拒绝
- 焦点在面板上时 Tab 在 拒绝/允许 间循环
- **全局热键**(无视当前焦点哪个 app):**Ctrl+Shift+Y** 允许最新一条权限请求,**Ctrl+Shift+N** 拒绝。这两个热键只在至少有一个面板可见时注册,关掉就反注册,不会污染你的全局快捷键。

`PermissionRequest` hook 跟终端原生 prompt 在 CLI 内部是 **`Promise.race`**——谁先回应谁赢。也就是说:
- 用户在面板点了允许 → hook 赢,终端 prompt 自动 abort
- 用户直接在终端按 y/n → 终端赢,面板对应那条会自动消失(主 app 收到 store.resolved 信号)
- 状态栏 app 没在跑 / socket 连不上 → hook 立即退出不输出任何东西,终端 prompt 直接生效,体验等同 vanilla claude

跟系统通知**无关**——面板是自家窗口,不走 `UNUserNotificationCenter`。所以你不需要配置「提醒样式」,也不依赖系统通知权限,Focus / Do Not Disturb 模式下也照常工作。

**系统通知不再用于工具权限请求。** 状态栏 app 现在只在 Claude Code **任务完成**(会话从 busy 转到 idle)时弹一条系统通知 banner,内容形如 `Claude Code 任务完成 · my-project`,点击跳回对应终端。工具权限请求只在面板里处理,不再发系统通知。

## 配置(两步)

### 1. 安装 app

把 release 构建的 `ClaudeStatusBar.app` 拷到 `/Applications`,启动一次。**不需要授予系统通知权限**——面板不走通知系统。

### 2. 在 settings.json 里注册 hook

编辑 `~/.claude/settings.json`,加上:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBarHook",
            "timeout": 600
          }
        ]
      }
    ]
  }
}
```

`timeout: 600` 给主 app 10 分钟(也是 CLI 的默认超时)。如果你已经有别的 `PermissionRequest` hook(例如 audit-hook),并存就行——sync hook 只参与决策的 race,async 的不参与,互不影响。

**没有 alias 改动,没有启动 flag**。装完直接跑 `claude` 就有效。

## 验证

启动 claude,跑一个会触发权限请求的命令,例如:

```
> 帮我跑一下 ls -la
```

如果配置正确:
- 终端会弹 CLI 自带的 "Bash command needs your approval" 之类的提示
- **同时**屏幕右上角弹出面板,带 **允许** / **拒绝** 按钮
- 点 **允许**(或敲回车) → CLI 立刻执行,终端那个 prompt 自动消失
- 点 **拒绝**(或敲 Esc) → CLI 报 "User denied via status bar"
- 直接在终端按 y/n → 也正常工作,面板自动消失
- 如果 10 分钟内两边都没动作 → CLI hook 超时,kill 掉子进程;面板这边主 app 内部也设了 5 分钟自动 deny 兜底

## 故障排查

### 面板没弹,但终端 prompt 出现了

最可能是 hook 自己崩了或者 app 没在跑——这种情况下 hook `exit(0)` 不输出,CLI 直接走原生 prompt,等于功能没生效但不影响使用。检查:
- 主 app 是否在跑(看菜单栏是否有🐙图标)
- socket 文件:`ls -la ~/Library/Application\ Support/ClaudeStatusBar/prompt.sock`
- 手动跑一下 hook 看错误:
  ```bash
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"manual-test"}' \
    | /Applications/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBarHook
  ```
  期望:有 socket 时面板出现,你点完按钮后 stdout 打印 `hookSpecificOutput` JSON;没 socket 时无输出退出。

### 面板出现但按钮点了没反应

你可能在 `swift run` 模式下跑——非 .app bundle 的进程不能正确处理 keyEquivalent 之外的某些 AppKit 事件。release 构建装到 `/Applications` 即可。

### CLI 完全没看到 hook 触发

```bash
claude --debug
```
跑命令时看输出里有没有 `Slow ... hooks` 类的日志——能跑出来证明 hook 至少 spawn 了。`PermissionRequest` 比 `PreToolUse` 晚一步触发,只在 CLI 决定要弹 prompt 时才有。如果你的 settings 把某个工具配成 always allow,这次就根本不会触发 hook,面板不会弹是正常的。

### 面板位置不对 / 在多显示器环境下错位

面板默认在主显示器(`NSScreen.main`)右上角。多显示器场景下"主"是包含菜单栏的那块。要改位置改 `Sources/ClaudeStatusBar/Services/PermissionPromptPanelManager.swift` 里的 `layout()`。

## 已知限制

- v1 不支持「记住决策」。每次都是允许一次(allow-once)。CLI 的输出 schema 支持 `updatedPermissions`(允许同时往 settings.json 写永久规则),将来可以加。
- 面板不在通知中心归档(因为压根不是系统通知)。错过了的请求,只能等 5 分钟自动 deny 后再重试。
- 锁屏状态下不会弹(锁屏阻止 NSPanel 显示)——这种情况下终端 prompt 会赢 race。
- 如果同时有 5 个以上 pending 请求,堆叠会超出屏幕高度——v1 不滚动也不折叠,后面的会跑到屏幕外。实际场景下并发 > 3 个的概率极低。
- helper 与主 app 之间的 socket 路径硬编码为 `~/Library/Application Support/ClaudeStatusBar/prompt.sock`(目录权限 0700,socket 0600)。多用户共享主目录的奇怪场景需要自己改 `AppDelegate.permissionSocketPath()` 和 `Sources/ClaudeStatusBarHook/main.swift` 的 `socketPath` 常量,确保两端一致。
- 已在 **Claude Code 2.1.140** 验证。`PermissionRequest` hook 是公开的钩子事件,但 `hookSpecificOutput.decision` 字段相对较新,过老的版本可能不识别(只会忽略输出,不会报错——等于功能不生效,不影响 CLI 正常使用)。
