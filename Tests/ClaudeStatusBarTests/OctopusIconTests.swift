import XCTest
import AppKit
@testable import ClaudeStatusBar

final class OctopusIconTests: XCTestCase {

    func testRendersAtRequestedSize() {
        let img = OctopusIcon.image(color: .red, size: NSSize(width: 32, height: 32), isTemplate: false)
        XCTAssertEqual(img.size, NSSize(width: 32, height: 32))
    }

    func testTemplateFlagPropagated() {
        XCTAssertTrue(OctopusIcon.image(color: .black, isTemplate: true).isTemplate)
        XCTAssertFalse(OctopusIcon.image(color: .red, isTemplate: false).isTemplate)
    }

    func testHasOpaquePixels() {
        let img = OctopusIcon.image(color: .red, size: NSSize(width: 24, height: 24), isTemplate: false)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return XCTFail("failed to create bitmap rep")
        }
        var anyOpaque = false
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 {
                    anyOpaque = true; break
                }
            }
            if anyOpaque { break }
        }
        XCTAssertTrue(anyOpaque)
    }

    func testBadgeCountZeroProducesSameImageAsNoBadge() {
        // badgeCount=0 (默认) 应该等价于不带角标,像素相同。
        let withoutArg = OctopusIcon.image(color: .red, isTemplate: false)
        let withZero = OctopusIcon.image(color: .red, isTemplate: false, badgeCount: 0)
        XCTAssertEqual(withoutArg.tiffRepresentation, withZero.tiffRepresentation)
    }

    func testBadgeCountAddsRedPixelsTopRight() {
        let plain = OctopusIcon.image(color: .black, size: NSSize(width: 32, height: 32), isTemplate: false, badgeCount: 0)
        let badged = OctopusIcon.image(color: .black, size: NSSize(width: 32, height: 32), isTemplate: false, badgeCount: 3)
        guard
            let plainRep = plain.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
            let badgedRep = badged.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        else { return XCTFail("bitmap rep") }

        // 角标在右上角四分之一区域。
        var plainRedish = 0, badgedRedish = 0
        let xRange = (plainRep.pixelsWide / 2)..<plainRep.pixelsWide
        let yRange = 0..<(plainRep.pixelsHigh / 2)  // bitmap 坐标系 y=0 在顶部
        for x in xRange {
            for y in yRange {
                if let c = plainRep.colorAt(x: x, y: y),
                   c.redComponent > 0.7, c.greenComponent < 0.3 { plainRedish += 1 }
                if let c = badgedRep.colorAt(x: x, y: y),
                   c.redComponent > 0.7, c.greenComponent < 0.3 { badgedRedish += 1 }
            }
        }
        XCTAssertEqual(plainRedish, 0, "plain icon should have no red badge pixels")
        XCTAssertGreaterThan(badgedRedish, 5, "badged icon should have visible red badge pixels")
    }

    func testBadgeCountClampsAtNinePlus() {
        // 渲染不应崩溃;具体字符样式不强制,只验证渲染完成。
        let img = OctopusIcon.image(color: .black, size: NSSize(width: 32, height: 32), isTemplate: false, badgeCount: 42)
        XCTAssertEqual(img.size, NSSize(width: 32, height: 32))
    }
}
