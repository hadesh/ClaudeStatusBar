# 信息密度提效设计 (v0.7.0 候选)

**日期**: 2026-05-15
**目标**: 在不破坏现有架构的前提下,提升状态栏 app 在「不展开菜单」「展开菜单」「AskUserQuestion 交互」三个环节传递的信息量,减少用户切回终端的频次。

## 范围与非目标

**范围内**:
1. 状态栏图标右上角叠加红圈数字角标
2. 展开菜单时每条 session 多展示「最近 prompt + 当前 tool_use + waitingFor」
3. AskUserQuestion 触发时,把当前的系统通知 banner 替换为浮窗,完整呈现问题文案与所有选项

**非目标**:
- 跨 session 全局仪表盘(用户上一轮已明确放弃 D 方向)
- AskUserQuestion 的菜单栏内代答(CLI 协议无外部代答通道,需 Agent SDK host 模式才能彻底解,不在本轮范围)
- 单 session token 成本(用户多选时未勾选)
- 状态计时(用户多选时未勾选)

## 设计

### 1. 状态栏图标角标

**视觉**: 现有 12×12 八爪鱼图标右上角叠一个直径约 7px 的实心红圆,圆内白色加粗数字。idle/working 颜色规则保持不变,角标只在 `attentionCount > 0` 时绘制;`attentionCount >= 10` 时显示 `9+`。

**数据**: `attentionCount` 按 sessionId 取集合并,避免一个 session 同时进入 waiting + 出现在 permission 浮窗时被双计:

```
waitingIds   = SessionStore.sessions.filter { $0.status == .waiting }.map(\.sessionId) → Set
pendingIds   = permissionStore.pendingSessionIds()           // 已有,含 AskUserQuestion
attentionCount = waitingIds.union(pendingIds).count
```

`pendingSessionIds()` 已经把 AskUserQuestion 的浮窗算在内(它仍走同一个 `PermissionPromptStore`,只是被路由到不同的 panel manager)。理论上 `PermissionPromptRequest.sessionId` 可能为 nil(模型字段是 `String?`),实际 CLI 总是带,本期不为这个边缘场景增加计数补偿——少计 1 远比双计明显,可接受。

**实现位置**:

- `OctopusIcon.image(color:isTemplate:badgeCount:)` 增加 `badgeCount: Int` 参数,内部 `>0` 时叠角标层
- `StatusIcon.update(state:badgeCount:)` 接受新参数透传给 `OctopusIcon`
- `AppDelegate` 在原有 `refreshIcon()` 路径里把 `attentionCount` 一起算出来传下去

**刷新触发**: `AppDelegate` 已有 `SessionStore.objectWillChange`、`permissionStore.incoming`、`permissionStore.resolved`、`SettingsStore.objectWillChange` 四路 sink,这些 sink 已经在调 `refreshIcon()`。`attentionCount` 是这两个 store 的纯函数,不引入新的定时器或新的事件源。

**模板图标兼容**: 当前 idle 状态用 `isTemplate=true`(AppKit 自动反转黑白)。角标是有色的,模板模式会被强制变灰。规则: **`badgeCount > 0` 时图标整体 `isTemplate=false`**——角标即代表「需要你注意」,牺牲跟随系统反转换取颜色保真。`badgeCount == 0` 时模板/非模板规则与现状一致(idle 模板,working/waiting 非模板)。

### 2. 菜单条目补充字段

**视觉**: 每条 session 的 NSMenuItem 由当前的单行 title 改为 `attributedTitle` 的两行结构:

```
ClaudeStatusBar · waiting · Sonnet 4.6 · 32%
⏳ Bash: rm -rf .build
```

副行文本按状态切换:

| 状态     | 副行                                                   |
|----------|--------------------------------------------------------|
| working  | `▸ {toolName}: {keyArg}` (取最后一条 assistant tool_use) |
| waiting  | `⏳ {waitingFor}` (Session JSON 直读),fallback 到 prompt |
| idle/busy | `» {recentPrompt 截 50 字}…`                           |

**关键参数提取**:

- Bash: `command` 截 60 字
- Edit / Write / NotebookEdit: `file_path` 的 basename
- Read: `file_path` 的 basename
- 其他工具: 仅 `toolName`,不展开 input

**数据来源**:

- `waitingFor`: 直接读 `Session` model(已存在,不动)
- `recentPrompt` / `lastTool`: 新增 `SessionContextReader.swift`,纯静态函数,反扫 `~/.claude/projects/{encoded-cwd}/{sessionId}.jsonl`(或 `.../{sessionId}/*.jsonl`)。复用 `SessionDetailsReader.encodeProjectPath` 的编码规则。

**反扫策略**:

- 从文件末尾反向读取,最多回退 200 行
- `lastTool`: 第一次遇到 `type=="assistant"` 的行,提取 `message.content[]` 中第一个 `type=="tool_use"` 的 `name` + 关键 input
- `recentPrompt`: 第一次遇到 `type=="user"` 且 `message.content` 是 string(跳过 tool_result 形式的 user 消息)的行,截 50 字

**刷新策略**: 不跟 `SessionStore` 的高频 tick 走。新增 `SessionContextStore`,内部维护 `[Int32: SessionContext]`,刷新时机:

1. 应用启动后立刻扫一次
2. 自持一个 30s 间隔的 `DispatchSourceTimer`(与 `UsageTracker` 风格一致,逻辑解耦)
3. `SessionStore.sessions` 新增/删除 pid 时,只针对差集做扫描

30s 延迟可接受——副行是「展开看一眼」的辅助信息,不在关键决策路径上。

**菜单渲染**: `AppDelegate` 构建 NSMenuItem 时,从 `SessionContextStore` 读对应 pid 的字段,用 `NSAttributedString` 拼出主行(默认 systemFont 13pt) + 换行 + 副行(systemFont 11pt + `secondaryLabelColor`)。NSMenuItem 原生支持多行 attributedTitle。

### 3. AskUserQuestion 浮窗

**现状**: `AppDelegate.routeAskUserQuestionToTerminal(_:)` 弹一条系统通知 + 立刻 `store.abandon(id:)`。banner 一闪即逝、问题文案+选项不可见。

**目标**: 把通知换成浮窗;**本轮不代答**(CLI 无外部代答通道);浮窗仅提供「跳回终端答」按钮 + ✕。

**新文件**:

- `Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift` (NSPanel,样式仿 `PermissionPromptPanel`)
- `Sources/ClaudeStatusBar/Services/AskUserQuestionPanelManager.swift`

**Store**: 不新建。AskUserQuestion 仍然是一个 `PermissionPromptRequest`(`toolName == "AskUserQuestion"`),仍然走 `PermissionPromptStore`。订阅关系变成:

```
PermissionPromptStore.incoming ─┬─► PermissionPromptPanelManager  (filter: toolName ∉ toolsRoutedAwayFromPanel)
                                └─► AskUserQuestionPanelManager   (filter: toolName == "AskUserQuestion")

PermissionPromptStore.resolved ─┬─► PermissionPromptPanelManager  (关闭对应面板)
                                └─► AskUserQuestionPanelManager   (关闭对应面板)
```

`PermissionPromptPanelManager.toolsRoutedAwayFromPanel` 保留,语义不变(常规权限浮窗的「跳过」名单)。新 manager 自己匹配 `"AskUserQuestion"`,不读这个集合,避免两处共用一个静态名单又往不同方向解读的混乱。

**`AppDelegate.routeAskUserQuestionToTerminal` 删除**。原本由它做的「abandon + 通知」改由 `AskUserQuestionPanelManager` 接管:

- 浮窗 ✕ → `store.abandon(id:)`(同现有 `PermissionPromptPanel.Outcome.abandon`)
- 「跳回终端答」 → `TerminalNavigator.bringToFront(cwd:)` + `store.abandon(id:)`
- CLI 端用户已答完(socket EOF) → `PermissionPromptListener` 已经会 `resolveDeny(message:)`,触发 `resolved` 信号,新 manager 跟着关闭浮窗。**这条路径已存在,不动 listener**。

**浮窗内容**:

```
┌─────────────────────────────────────────────┐
│ Claude Code 需要你回答          [✕]         │
│ {projectName} · {sessionShortId}            │
├─────────────────────────────────────────────┤
│ ❓ {questions[0].question}                  │
│   ① {options[0].label}                      │
│      {options[0].description}               │
│   ② {options[1].label}                      │
│   ...                                       │
│                                             │
│ (questions[1] 以此类推)                     │
├─────────────────────────────────────────────┤
│              [ 跳回终端答 ]                 │
└─────────────────────────────────────────────┘
```

序号 ① ② ③ 与终端 select prompt 实际按键一一对应——浮窗不代答,但用户瞄一眼就知道终端要按哪个数字。

**Input 解析**: `PermissionPromptRequest.input` 已经是 `[String: JSONValue]`,AskUserQuestion 的结构是 `{questions: [{question: string, options: [{value, label, description?}]}]}`(claude-code-guide 已确认)。新增一个解析函数(放在 `AskUserQuestionPanel.swift` 内部即可,不需要单独 model 文件):

```swift
struct AskUserQuestionInput {
    struct Option { let value: String; let label: String; let description: String? }
    struct Question { let question: String; let options: [Option] }
    let questions: [Question]
}
```

解析失败 → 浮窗只展示原始 toolName + 跳回终端按钮(降级,但仍优于现在的 banner)。

**Outcome enum**: 仿 `PermissionPromptPanel.Outcome` 的轻量风格:

```swift
enum AskUserQuestionPanelOutcome { case goToTerminal, abandon }
```

`goToTerminal` 不是 wire 类型(同 `Outcome.abandon` 也不是 wire 类型的设计),不会 JSON encode。Manager 拿到后做副作用(`TerminalNavigator.bringToFront` + `store.abandon`)。

**全局热键**: 不注册。AskUserQuestion 是结构化选项,没有「答 1」的快捷键语义;✕ 在浮窗内点即可。

**多窗堆叠**: 沿用 `PermissionPromptPanelManager` 的纵向堆叠思路,如果同时来多个 AskUserQuestion 请求(不太可能,但要防御),纵向堆在常规权限浮窗下方;两个 manager 各管各的窗位,position 计算各自独立。**简化方案**: AskUserQuestion 浮窗固定最右上,**不参与**权限浮窗的堆叠队列;并发场景由用户依次处理。如果实测发现并发严重再做合并。

## 架构变更总览

```
新增文件:
  Sources/ClaudeStatusBar/Services/SessionContextReader.swift     (纯静态)
  Sources/ClaudeStatusBar/Services/SessionContextStore.swift      (Combine @Published)
  Sources/ClaudeStatusBar/Services/AskUserQuestionPanelManager.swift
  Sources/ClaudeStatusBar/UI/AskUserQuestionPanel.swift

修改文件:
  Sources/ClaudeStatusBar/UI/OctopusIcon.swift                    (新增 badgeCount 参数)
  Sources/ClaudeStatusBar/UI/StatusIcon.swift                     (透传 badgeCount)
  Sources/ClaudeStatusBar/Services/UsageTracker.swift             (不变,新 SessionContextStore 自持 30s timer)
  Sources/ClaudeStatusBar/AppDelegate.swift
    - 接入 SessionContextStore (sink + 在菜单构造时读取)
    - 接入 AskUserQuestionPanelManager 替代 routeAskUserQuestionToTerminal
    - refreshIcon 计算 attentionCount

无变化:
  Sources/ClaudeStatusBarHook/                                    (helper 二进制)
  Sources/ClaudeStatusBarHookCore/                                (helper 库)
  PermissionPromptListener                                        (EOF/SO_NOSIGPIPE 路径已通用)
  PermissionPromptStore                                           (除 pendingCount 外不动)
  Models/PermissionPrompt.swift                                   (wire 类型不变)
```

Wire 协议不变,helper 二进制不需要重发版本。

## 测试策略

每块功能至少一个单元测试,沿用现有 `Tests/ClaudeStatusBarTests/` 的「写 fixture 到临时目录,调静态函数,断言」风格:

- `SessionContextReaderTests`:
  - 空 jsonl → `(nil, nil)`
  - 仅 user prompt → `(prompt, nil)`
  - tool_use + 之前的 user prompt → `(prompt, "Bash: ...")`
  - tool_result 形式的 user 消息不应被当作 prompt
  - prompt 截断在 50 字内
- `OctopusIconBadgeTests`: 渲染后图像尺寸不变,渲染 `badgeCount=0` 与不传是相同图像(等价)
- `AskUserQuestionInputParsingTests`: 合法 input → 解析成功;缺字段 → 降级
- `AskUserQuestionPanelManagerTests`: incoming(toolName=AskUserQuestion) → 浮窗出现;resolved → 浮窗消失;✕ → store.abandon 被调用

UI 层(NSPanel 实际显示、菜单 attributedTitle 的视觉)不写自动化测试,依赖手测——和现有 `PermissionPromptPanel` 的测试边界一致。

## 风险与降级

- **OctopusIcon 角标在某些 Retina 缩放下渲染模糊**: 用 `NSImage.lockFocusFlipped` + 整数像素对齐;若仍模糊,fallback 成纯红圈不带数字(`>0` 即点亮)
- **jsonl 反扫被超大文件拖慢**: 限制 200 行回退 + 文件大小 > 100MB 时跳过(返回 nil),避免阻塞 30s 定时器
- **AskUserQuestion 浮窗与权限浮窗位置打架**: 确认两个 manager 各自维护 origin,本期不合并队列;实测有问题再迭代
- **AskUserQuestion input schema 漂移**: 解析失败 → 降级到「仅显示 toolName + 跳回终端」,不阻塞用户;打 log 但不弹错

## 兼容性

- macOS 13+ (不变)
- 现有 `~/.claude/settings.json` 的 hook 配置不变
- 现有 `dist/ClaudeStatusBar.app` bundle 结构不变
- 用户偏好设置 (UserDefaults) 不新增 key

## 后续(本轮范围外)

- AskUserQuestion 浮窗内代答(等 Agent SDK host 模式或 CLI 暴露 IPC)
- 单 session token 成本展示
- 跨 session 全局仪表盘 / 预算告警
- 状态计时(已等多久 / 已跑多久)
