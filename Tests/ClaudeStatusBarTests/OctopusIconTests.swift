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
}
