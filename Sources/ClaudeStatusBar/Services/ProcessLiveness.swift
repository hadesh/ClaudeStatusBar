import Darwin
import Foundation

public enum ProcessLiveness {
    /// 用 `kill(pid, 0)` 探测进程是否存活,不真正发送信号。
    /// 返回 0 → 存活;EPERM → 存活但无权限,仍视为存活;ESRCH → 进程不存在。
    public static func isAlive(pid: Int) -> Bool {
        if pid <= 0 { return false }
        let ret = kill(pid_t(pid), 0)
        if ret == 0 { return true }
        return errno == EPERM
    }
}
