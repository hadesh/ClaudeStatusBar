import Darwin
import Foundation

/// 给指定 pid 发 SIGINT,语义等同终端按 Ctrl+C —— 中断当前正在跑的 turn,
/// 不结束 CLI 进程、会话保留。`killFn` 是注入点,默认走 BSD `kill(2)`,
/// 测试时可替换。形状参考 `ProcessLiveness`。
public enum ProcessTerminator {
    public typealias KillFunction = (pid_t, Int32) -> Int32

    public static var killFn: KillFunction = { Darwin.kill($0, $1) }

    /// pid <= 0 直接拒(防 0/-1 这种"全进程组"式的危险目标)。
    /// 返回 false 表示 kill 调用失败(进程已退、权限不足等),
    /// 调用方一般无需关心 —— SessionWatcher 下次扫描会清掉死会话。
    @discardableResult
    public static func sendInterrupt(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return killFn(pid_t(pid), SIGINT) == 0
    }
}
