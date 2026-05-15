import AppKit

/// 12x12 像素栅格自绘的通用八爪鱼图标。1=填充,0=透明。
/// 多帧:身体不动,最后两行的触手在帧间左右错 1 列,模拟摆动。
/// 帧 0 与改造前的静态布局完全一致 —— 默认参数下旧测试照常通过。
public enum OctopusIcon {
    private static let frames: [[[UInt8]]] = [
        // 帧 0:触手原位
        [
            [0,0,0,0,0,0,0,0,0,0,0,0],
            [0,0,0,1,1,1,1,1,1,0,0,0],
            [0,0,1,1,1,1,1,1,1,1,0,0],
            [0,1,1,1,1,1,1,1,1,1,1,0],
            [0,1,1,0,1,1,1,1,0,1,1,0],  // 眼睛
            [0,1,1,0,1,1,1,1,0,1,1,0],
            [0,1,1,1,1,1,1,1,1,1,1,0],
            [0,1,1,1,1,1,1,1,1,1,1,0],
            [0,0,1,1,1,1,1,1,1,1,0,0],
            [0,1,0,1,0,1,0,1,0,1,0,0],  // 触手起点
            [1,0,0,1,0,0,1,0,0,1,0,1],  // 触手卷曲尾端
            [0,0,0,0,0,0,0,0,0,0,0,0],
        ],
        // 帧 1:触手向右摆 1 列
        [
            [0,0,0,0,0,0,0,0,0,0,0,0],
            [0,0,0,1,1,1,1,1,1,0,0,0],
            [0,0,1,1,1,1,1,1,1,1,0,0],
            [0,1,1,1,1,1,1,1,1,1,1,0],
            [0,1,1,0,1,1,1,1,0,1,1,0],
            [0,1,1,0,1,1,1,1,0,1,1,0],
            [0,1,1,1,1,1,1,1,1,1,1,0],
            [0,1,1,1,1,1,1,1,1,1,1,0],
            [0,0,1,1,1,1,1,1,1,1,0,0],
            [0,0,1,0,1,0,1,0,1,0,1,0],  // 触手起点 +1
            [0,1,0,0,1,0,0,1,0,0,1,0],  // 触手卷曲尾端 +1
            [0,0,0,0,0,0,0,0,0,0,0,0],
        ],
    ]

    /// 可用帧数。Animator 用它做循环边界。
    public static var frameCount: Int { frames.count }

    public static func image(
        color: NSColor,
        size: NSSize = NSSize(width: 18, height: 18),
        isTemplate: Bool,
        badgeCount: Int = 0,
        frameIndex: Int = 0
    ) -> NSImage {
        let grid = frames[((frameIndex % frames.count) + frames.count) % frames.count]
        let cols = grid[0].count
        let rows = grid.count
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)

        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        let ctx = NSGraphicsContext.current
        ctx?.shouldAntialias = false
        ctx?.imageInterpolation = .none

        color.setFill()
        for (r, row) in grid.enumerated() {
            for (c, cell) in row.enumerated() where cell == 1 {
                let x = CGFloat(c) * cellW
                let y = size.height - CGFloat(r + 1) * cellH  // 翻转 Y 轴
                NSRect(x: x, y: y, width: cellW, height: cellH).fill()
            }
        }

        if badgeCount > 0 {
            drawBadge(count: badgeCount, in: size)
        }

        img.isTemplate = isTemplate
        return img
    }

    /// 在 NSImage 当前 lockFocus 上下文里画角标。圆心定在右上角往内 ~3px。
    /// 数字 ≥10 显示 "9+"。badge 半径按 size 缩放保证 18x18 / 32x32 都看得清。
    private static func drawBadge(count: Int, in size: NSSize) {
        let radius = max(size.width * 0.22, 5)
        let diameter = radius * 2
        let cx = size.width - radius
        let cy = size.height - radius
        let rect = NSRect(x: cx - radius, y: cy - radius, width: diameter, height: diameter)

        let ctx = NSGraphicsContext.current
        ctx?.shouldAntialias = true

        NSColor.red.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let label = count >= 10 ? "9+" : "\(count)"
        let fontSize = radius * 1.1
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let textSize = attr.size()
        let textOrigin = NSPoint(
            x: cx - textSize.width / 2,
            y: cy - textSize.height / 2
        )
        attr.draw(at: textOrigin)

        ctx?.shouldAntialias = false
    }
}
