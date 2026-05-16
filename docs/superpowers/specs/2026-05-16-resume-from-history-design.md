# 状态栏菜单 · fresh session 恢复上次会话

## 背景与目标

当用户在某个 cwd 下新启动一个 `claude` 进程、还没发出第一句 prompt 时,该会话在状态栏菜单里只有一个孤零零的"○ {目录名} · pid X"主行 —— `SessionContextStore` 给它的 `recentPrompt` 是 `nil`,`secondaryLine(for:)` 返回 `nil`,`makeSessionDetailItem` 因为还没有 assistant 输出也读不出 SessionDetails。

但同一个 cwd 下经常已经有若干历史 jsonl —— 用户上次/上上次的对话。这些历史对一个刚开始干活的 fresh session 是宝贵的"接着上次干"上下文。

本期目标:**fresh session 行下面挂一个"恢复上次会话 ▸"子菜单,列出同 cwd 下最近 5 个历史会话,点击任意一条把 `claude --resume <sessionId>` 复制到剪贴板**。

判定 fresh 的信号:`SessionContextStore.contextByPid[pid]?.recentPrompt == nil`(包含两种情况:`contextByPid` 里压根没这个 pid,或扫过了但 jsonl 里没拿到 user-string prompt)。

## 非目标

- 不做"自动注入历史到当前 fresh session"。Claude Code CLI 没有这个能力 —— `--resume` 起的是新 session 继承历史,不是把历史挂到运行中的 session 上。所以"恢复"本质是"把命令交给用户,用户自己处理 fresh session 的去留"。
- 不做新终端窗口、不做 osascript 注入。**只复制命令**。
- 不做跨 cwd 历史(同 cwd 的最近会话才有上下文意义)。
- 不在主菜单底部独立挂"最近会话"区(超出"当前会话没上下文"的触发语义)。
- 不改 SessionRowView 自定义视图、不改 SessionContextStore、不改 SessionWatcher。

## 触发条件

`AppDelegate.rebuildMenu` 在 session 循环里:

```
contextStore.contextByPid[s.pid]?.recentPrompt == nil
```

注意:`contextByPid[pid]` 可能是 `nil`(SessionContextStore 还没扫过这个 pid 的 jsonl,异步 workQueue 几十~几百 ms 延迟),也可能 `recentPrompt == nil`(扫过但 jsonl 里没找到 user-string prompt)。**两种情况都视为 fresh**。代价:刚启动那一瞬间的"未确定 fresh" session 会被多挂一次子菜单,几百 ms 后下一次 rebuild(`store.$sessions` / `usageTracker` 推动)会修正。视觉抖动可接受。

## 架构改动

### 文件清单

| 类型 | 路径 | 用途 |
|------|------|------|
| 新增 | `Sources/ClaudeStatusBar/Models/RecentConversation.swift` | 数据模型,纯 Foundation 类型 |
| 新增 | `Sources/ClaudeStatusBar/Services/RecentConversationsReader.swift` | 纯静态 enum,读取同 cwd 历史 jsonl 摘要 |
| 改 | `Sources/ClaudeStatusBar/AppDelegate.swift` | 新增私有方法 `makeRecentResumeItem(for:)` 与 `@objc copyResumeCommand(_:)`;`rebuildMenu` 在 fresh session 后插入子菜单条目 |
| 新增 | `Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift` | 排序、排除、解析、size 限制、limit 等场景 |

### 数据流

```
SessionStore.sessions
        │
        ▼
SessionContextStore.contextByPid[pid].recentPrompt   ←── fresh 判定
        │
        ▼
AppDelegate.rebuildMenu (for s in sessions:)
        │
        ├─ addItem(SessionRowView)                  // 已有
        │
        ├─ if recentPrompt == nil (含 nil 整体不存在):
        │     items = RecentConversationsReader.read(
        │                  cwd: s.cwd,
        │                  excluding: s.sessionId)
        │     if !items.isEmpty:
        │         addItem("恢复上次会话 ▸" submenu)
        │
        └─ else:
              addItem(makeSessionDetailItem)        // 已有
        ▼
点击子项 → NSPasteboard.general.setString("claude --resume <id>")
        + WaitingNotifier.notify(title:body:)       // 已有通用 notify
```

`makeRecentResumeItem` 与 `makeSessionDetailItem` **二选一**:有 `recentPrompt` 的会话走 detail 行(展示模型 + 上下文 %),没有 prompt 的 fresh session 走 recent-resume 子菜单。两条路径不同时出现。

## RecentConversationsReader 详细设计

### API 签名

```swift
public enum RecentConversationsReader {
    public static let maxFileBytes: Int = 100 * 1024 * 1024
    public static let defaultLimit: Int = 5
    public static let promptMaxChars: Int = 80

    public static func read(
        cwd: String,
        excluding sessionId: String?,
        limit: Int = defaultLimit,
        projectsRoot: URL = SessionDetailsReader.defaultProjectsRoot
    ) -> [RecentConversation]
}
```

返回值按 mtime 倒序(最新在前)。

### 算法

```
1. dir = projectsRoot / encodeProjectPath(cwd)         // 复用 SessionDetailsReader 的编码
2. candidates: [(URL, mtime: Date)] = []
   - 列 dir 下扁平 *.jsonl
   - 每个一级子目录:取该目录下 mtime 最新的 *.jsonl 一个
3. 排除 candidates 中:
   - filename == "<excluding>.jsonl"
   - parent.lastPathComponent == "<excluding>"
4. 按 mtime 倒序排序
5. 逐个 parse,直到凑齐 limit 个有效项:
   - size > maxFileBytes (100MB) → skip
   - 读 Data,**正向** line-by-line,decode UserEntry
   - 第一条 type == "user" 且 content 是 string 且非空 → firstPrompt = truncate(s, 80)
   - 整个文件没找到 user-string prompt → skip
6. 从 URL 推 sessionId:
   - 扁平形式:filename 去 .jsonl
   - 子目录形式:parent.lastPathComponent
7. 返回 [RecentConversation]
```

### 关键决策

- **正向扫,不是反向。**`SessionContextReader` 反扫是要"最新" prompt;我们要"第一句",从头扫第一行命中就停。docstring 里明示这个差异。
- **跳过 tool_result 形态的 user。** `content` 是 array 时跳过(`/clear` 后或 hook 注入的 user 消息),只取 string content 的首句。和 `SessionContextReader.parse` 保持一致。
- **truncate 80 字符。**子菜单宽度比 secondary 行宽,80 放得下;`SessionContextReader` 截 50 是因为夹在主行下方。
- **修改时间用文件 mtime。**不去 parse jsonl 里的 timestamp 字段。文件 mtime ≈ 最后一条消息时间,够用,且省一次 parse。
- **空目录 / 全部 skip → 返回 `[]`。**AppDelegate 看到空就不挂"恢复上次会话"条目,视觉上跟现在完全一样,不引入空 affordance。
- **size 阈值复用 100MB。**跟 `SessionContextReader.maxFileBytes` 一致(常量在两个 Reader 里各自声明,不强抽到公共位置 —— 跟项目"flat、不过早抽象"的风格一致)。

### 边界场景

| 场景 | 处理 |
|---|---|
| `cwd` 编码后的目录不存在 | 返回 `[]`(用户在新目录刚启动) |
| 子目录里有多个 jsonl | 取 mtime 最新那一个 |
| jsonl 第一行是 system / hook 注入 | 顺序扫直到第一条 user-string entry,而不是死认第一行 |
| jsonl 损坏 / partial JSON 单行 | 单行 decode 失败就跳过,继续下一行 |
| jsonl 整个没有 user-string prompt | 该候选 skip,继续下一个候选 |
| 候选数 > limit + 被排除/skip 的余量 | 排序后逐个 parse,凑够 limit 就 break |

### Models/RecentConversation.swift

```swift
import Foundation

public struct RecentConversation: Equatable {
    public let sessionId: String
    public let firstPrompt: String     // 已截断
    public let modifiedAt: Date        // jsonl 文件 mtime
    public let jsonlURL: URL
}
```

`Equatable` 是测试断言用。

## UI 详细设计

### NSMenuItem 装配

```swift
private func makeRecentResumeItem(for s: Session) -> NSMenuItem? {
    let recents = RecentConversationsReader.read(cwd: s.cwd, excluding: s.sessionId)
    guard !recents.isEmpty else { return nil }

    let parent = NSMenuItem(title: "恢复上次会话", action: nil, keyEquivalent: "")
    parent.indentationLevel = 1
    let submenu = NSMenu()
    for r in recents {
        let title = "\(r.firstPrompt)  ·  \(formatRelative(r.modifiedAt))"
        let it = NSMenuItem(
            title: title,
            action: #selector(copyResumeCommand(_:)),
            keyEquivalent: ""
        )
        it.target = self
        it.toolTip = "claude --resume \(r.sessionId)"
        it.representedObject = r.sessionId
        submenu.addItem(it)
    }
    parent.submenu = submenu
    return parent
}

@objc private func copyResumeCommand(_ sender: NSMenuItem) {
    guard let sid = sender.representedObject as? String else { return }
    let cmd = "claude --resume \(sid)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(cmd, forType: .string)
    notifier.notify(title: "已复制 resume 命令", body: cmd)
}
```

`indentationLevel = 1` 跟 `makeSessionDetailItem` 对齐,在缩进上视觉上明确"属于上面那条 session"。

### `rebuildMenu` 改动点

```swift
for s in sessions.sorted(by: { $0.pid < $1.pid }) {
    menu.addItem(makeSessionItem(s))
    if contextStore.contextByPid[s.pid]?.recentPrompt == nil {
        if let resume = makeRecentResumeItem(for: s) {
            menu.addItem(resume)
        }
    } else {
        if let detail = makeSessionDetailItem(s) {
            menu.addItem(detail)
        }
    }
}
```

### 时间格式

`RelativeDateTimeFormatter`,locale `zh_CN`,unitsStyle `.short`。预期输出:"5 分钟前" / "2 小时前" / "昨天" / "3 天前" / "上周" 等。

formatter 在 AppDelegate 里以一个私有 lazy 属性持有(避免每次 rebuild 都新建)。

### 通知反馈不受 settings 限制

`notifier.notify(title:body:)` 是一个通用 post(等同 `notifyTerminalNotFound` 的写法),不过 `settings.notificationsEnabled` 网关 —— 这是用户**主动**操作的反馈,不是被动打扰。要明确区别于"会话进入 waiting"那类系统级通知。

## 测试策略

新建 `Tests/ClaudeStatusBarTests/RecentConversationsReaderTests.swift`,沿用 `SessionContextReaderTests` 的 fixture 写法(临时目录 + 写 jsonl)。

| 测试名 | 验证 |
|---|---|
| `testReturnsEmptyWhenDirectoryMissing` | cwd 编码目录不存在 → `[]` |
| `testReturnsEmptyWhenNoJsonl` | 目录存在但里面没 jsonl → `[]` |
| `testSortsByMtimeDescending` | 写 3 个不同 mtime,断言顺序 |
| `testExcludesGivenSessionIdFlat` | 排除 `<sid>.jsonl` |
| `testExcludesGivenSessionIdSubdir` | 排除 `<sid>/anything.jsonl` |
| `testFindsFirstUserPromptSkippingSystemEntries` | 第 1 行非 user,第 2 行 user-string |
| `testSkipsToolResultUserContent` | content 是 array 的跳过,继续找 |
| `testSkipsFilesOverSizeLimit` | fixture 写一个 >maxFileBytes 的稀疏文件 |
| `testTruncatesLongPromptToConfiguredMax` | >80 字符 → 截到 80 + `…` |
| `testRespectsLimitParameter` | 候选 7 个、limit 3 → 返回 3 |
| `testSkipsCorruptJsonlLines` | 中间有损坏行 → 跳过损坏行继续找 |
| `testSkipsJsonlWithNoUserStringPrompt` | 只有 system / tool_result 的 jsonl → 整个候选 skip |

不测 `AppDelegate`/UI,沿用项目"AppKit isolation"约定。

## 与现有代码的契合点

- **纯静态 Reader 模式。**与 `LiveUsageAggregator` / `SessionDetailsReader` / `SessionContextReader` / `RollingWindowAggregator` / `SessionWatcher.readSessions` 同构,测试方式完全一致。
- **cwd → projects 编码。**复用 `SessionDetailsReader.encodeProjectPath`(全局唯一来源)。
- **大文件 100MB 阈值。**与 `SessionContextReader.maxFileBytes` 一致。
- **detail 行 vs resume 行二选一。**与既有"detail 行只在能读到 SessionDetails 时显示"逻辑同形 —— fresh session 由于没 assistant 输出,detail 本来就读不到,我们把这个空位让给 resume 子菜单。
- **`WaitingNotifier.notify(title:body:)` 直接 post。**与 `notifyTerminalNotFound` 同一个反馈通道。
- **`AppKit` 隔离。**Models/RecentConversation 与 Services/RecentConversationsReader 都只 import Foundation,符合 `Services/` 的约束。

## 风险与回退

- **首次启动那一瞬抖动:**`SessionContextStore` 异步扫 jsonl 期间,`contextByPid[pid]` 短暂为 `nil`,resume 子菜单可能短暂出现在一个其实有 prompt 的 session 下。下一次 rebuild 修正。可接受。
- **同 cwd jsonl 数量异常多:**算法是排序后 take limit,即使有 100+ 候选,parse 也只跑前 limit + 少量 skip 余量。整体 disk I/O 在 KB-MB 量级。如果实际遇到性能问题,后续可加 SessionContextStore 那样的 30s 缓存。本期不做。
- **回退路径:**功能完全在 `AppDelegate.rebuildMenu` 的 session 循环里加分支,关掉只需把 `if recentPrompt == nil { … } else { detail }` 退化回 `if let detail = makeSessionDetailItem(s) { menu.addItem(detail) }`。Reader 与 Model 文件即使留下也不会被引用。
