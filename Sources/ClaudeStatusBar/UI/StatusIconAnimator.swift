import AppKit

/// 把状态栏图标的「画到 button.image」+「working 态切帧动画」收到一处。
/// 调用方只需在状态/颜色/角标变化时调 `update(...)`,内部决定是否需要 timer。
///
/// 设计要点:
/// - 仅 working 态启动 timer;idle / needsAttention / none 一律静帧,timer 立即停。
/// - 帧间隔 0.4s(2.5 fps):八爪鱼触手左右摆,微动效,不打扰也不耗电。
/// - 状态切回 working 时 frameIndex 复位到 0,避免接续上次摆动相位看起来像跳帧。
final class StatusIconAnimator {
    /// 帧切换间隔。状态栏视觉粒度低,慢一点更舒服。
    private static let frameInterval: TimeInterval = 0.4

    weak var button: NSStatusBarButton?

    private var status: AggregateStatus = .none
    private var workingColor: NSColor = SettingsStore.defaultWorkingColor
    private var attentionColor: NSColor = SettingsStore.defaultAttentionColor
    private var badgeCount: Int = 0
    private var frameIndex: Int = 0
    private var timer: DispatchSourceTimer?

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    deinit {
        timer?.cancel()
    }

    func update(
        status: AggregateStatus,
        workingColor: NSColor,
        attentionColor: NSColor,
        badgeCount: Int
    ) {
        let wasWorking = self.status == .working
        self.status = status
        self.workingColor = workingColor
        self.attentionColor = attentionColor
        self.badgeCount = badgeCount

        if status == .working {
            if !wasWorking { frameIndex = 0 }
            redraw()
            if timer == nil { startTimer() }
        } else {
            stopTimer()
            frameIndex = 0
            redraw()
        }
    }

    func stop() {
        stopTimer()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(
            deadline: .now() + Self.frameInterval,
            repeating: Self.frameInterval
        )
        t.setEventHandler { [weak self] in
            guard let self, self.status == .working else { return }
            self.frameIndex = (self.frameIndex + 1) % OctopusIcon.frameCount
            self.redraw()
        }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func redraw() {
        button?.image = StatusIcon.image(
            for: status,
            working: workingColor,
            attention: attentionColor,
            badgeCount: badgeCount,
            frameIndex: frameIndex
        )
    }
}
