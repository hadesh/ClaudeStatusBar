import Foundation

/// 检测 sessionId「离开 waiting 状态」的事件,包括 status 推进到 busy/idle、
/// 或会话整个消失(CLI 退出)。
///
/// **背景**:hook helper 阻塞在 socket read 等服务端响应。CLAUDE.md 写的
/// "CLI 杀掉 race loser helper → socket EOF → 浮窗关" 实测不成立 —— Claude
/// Code CLI 在终端 prompt 胜出后并不杀 helper(只关它的 stdin,而 Swift
/// FileHandle.readToEnd 完成后已自动关闭 fd 0,不再监控)。helper 卡死,浮窗
/// 只能等 5 分钟超时。
///
/// 这个 detector 用 session.status 离开 waiting 当替代信号:用户在终端答完
/// y/n 后 CLI 必然推进 session 状态,识别这个事件后让上层 abandon 该 sessionId
/// 下所有 in-flight 浮窗(语义同 ✕「我去终端答」:helper 看到 socket EOF
/// exit(0) 不写 stdout,CLI 拿终端答案)。
///
/// 与项目里其他 detector 一致:第一帧只建立基线,不报告任何离开事件。
public struct PermissionPromptSessionExitDetector {
    private var lastWaitingSessionIds: Set<String>?

    public init() {}

    /// 返回本帧从 waiting 状态消失的 sessionId 集合。
    public mutating func detect(in sessions: [Session]) -> Set<String> {
        let nowWaitingIds = Set(sessions.filter { $0.status == .waiting }.map(\.sessionId))
        defer { lastWaitingSessionIds = nowWaitingIds }
        guard let last = lastWaitingSessionIds else { return [] }
        return last.subtracting(nowWaitingIds)
    }
}
