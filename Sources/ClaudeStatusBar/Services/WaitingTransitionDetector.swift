import Foundation

public struct WaitingTransitionDetector {
    private var lastWaitingPids: Set<Int> = []

    public init() {}

    /// 返回本次扫描中"新进入 waiting 状态"的会话(本轮 waiting 且上一轮不在 waiting 集合)。
    public mutating func detect(in sessions: [Session]) -> [Session] {
        let nowWaiting = sessions.filter { $0.status == .waiting }
        let nowPids = Set(nowWaiting.map(\.pid))
        let newly = nowWaiting.filter { !lastWaitingPids.contains($0.pid) }
        lastWaitingPids = nowPids
        return newly
    }
}
