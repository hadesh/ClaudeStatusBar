import AppKit

/// 12x12 像素栅格自绘的通用八爪鱼图标。1=填充,0=透明。
public enum OctopusIcon {
    private static let grid: [[UInt8]] = [
        [0,0,0,0,1,1,1,1,0,0,0,0],
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
    ]

    public static func image(
        color: NSColor,
        size: NSSize = NSSize(width: 18, height: 18),
        isTemplate: Bool
    ) -> NSImage {
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
        img.isTemplate = isTemplate
        return img
    }
}
