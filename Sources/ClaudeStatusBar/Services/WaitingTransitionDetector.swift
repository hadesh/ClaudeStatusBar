import Foundation

public struct WaitingTransitionDetector {
    /// `nil` 表示尚未扫描过任何一帧。首帧只用于建立基线,避免启动时把
    /// CLI 已经留下的 waiting 会话误报为新事件。
    private var lastWaitingPids: Set<Int>?

    public init() {}

    /// 返回本次扫描中"新进入 waiting 状态"的会话(本轮 waiting 且上一轮不在 waiting 集合)。
    /// 第一次调用永远返回空,只把当前 waiting 集合作为基线吸收。
    public mutating func detect(in sessions: [Session]) -> [Session] {
        let nowWaiting = sessions.filter { $0.status == .waiting }
        let nowPids = Set(nowWaiting.map(\.pid))
        defer { lastWaitingPids = nowPids }
        guard let last = lastWaitingPids else { return [] }
        return nowWaiting.filter { !last.contains($0.pid) }
    }
}
