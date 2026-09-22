import AppKit
import SwiftUI
import XCTest
import RillUI

@testable import RillApp

@MainActor
final class RillMenuBarIconTests: XCTestCase {
    func testBrandImagesRenderFromPackageResourcesWithVisibleRecordIndicator() throws {
        let ready = try render(.waveform)
        let records = try render(.squareStack3dUpFill)

        XCTAssertGreaterThan(visiblePixels(in: ready), 80)
        XCTAssertGreaterThan(visiblePixels(in: records), visiblePixels(in: ready))
    }

    private func render(_ symbol: RillSystemSymbol) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(
            content: RillMenuBarIcon.image(for: symbol).foregroundStyle(.black)
        )
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size, NSSize(width: 20, height: 18))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    private func visiblePixels(in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 {
                    count += 1
                }
            }
        }
        return count
    }
}
