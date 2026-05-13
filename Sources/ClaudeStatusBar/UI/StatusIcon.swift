import AppKit

public enum StatusIcon {
    /// 活动状态时的暖橙色。改这里即可换色。
    public static let activeOrange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.27, alpha: 1.0)

    public static func image(for status: AggregateStatus) -> NSImage {
        switch status {
        case .none, .idle:
            // 模板图,AppKit 按当前外观自动反相:浅色栏 → 深色 icon,深色栏 → 浅色 icon。
            return OctopusIcon.image(color: .black, isTemplate: true)
        case .working:
            return OctopusIcon.image(color: activeOrange, isTemplate: false)
        case .needsAttention:
            return OctopusIcon.image(color: .systemYellow, isTemplate: false)
        }
    }
}
