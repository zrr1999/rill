#!/usr/bin/env swift

import AppKit
import Darwin
import Foundation

private struct AppIconError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct Rendition {
    let filename: String
    let pixels: Int
}

private let renditions = [
    Rendition(filename: "icon_16x16.png", pixels: 16),
    Rendition(filename: "icon_16x16@2x.png", pixels: 32),
    Rendition(filename: "icon_32x32.png", pixels: 32),
    Rendition(filename: "icon_32x32@2x.png", pixels: 64),
    Rendition(filename: "icon_128x128.png", pixels: 128),
    Rendition(filename: "icon_128x128@2x.png", pixels: 256),
    Rendition(filename: "icon_256x256.png", pixels: 256),
    Rendition(filename: "icon_256x256@2x.png", pixels: 512),
    Rendition(filename: "icon_512x512.png", pixels: 512),
    Rendition(filename: "icon_512x512@2x.png", pixels: 1024),
]

private struct RenderGeometry {
    let bodyInset: CGFloat
    let sourceCropFraction: CGFloat
    let shadowBlur: CGFloat
    let shadowOffset: CGFloat
}

private func geometry(for pixels: Int) -> RenderGeometry {
    let size = CGFloat(pixels)
    switch pixels {
    case ...16:
        return RenderGeometry(
            bodyInset: 1,
            sourceCropFraction: 0.78,
            shadowBlur: 0.5,
            shadowOffset: -0.5
        )
    case ...32:
        return RenderGeometry(
            bodyInset: 2,
            sourceCropFraction: 0.82,
            shadowBlur: 0.75,
            shadowOffset: -0.75
        )
    case ...64:
        return RenderGeometry(
            bodyInset: 3,
            sourceCropFraction: 0.88,
            shadowBlur: 1.25,
            shadowOffset: -1
        )
    case ...128:
        return RenderGeometry(
            bodyInset: ceil(size * 0.055),
            sourceCropFraction: 0.92,
            shadowBlur: size * 0.022,
            shadowOffset: -size * 0.016
        )
    default:
        return RenderGeometry(
            bodyInset: ceil(size * 0.055),
            sourceCropFraction: 0.94,
            shadowBlur: size * 0.022,
            shadowOffset: -size * 0.016
        )
    }
}

private func loadSourceImage(at url: URL) throws -> NSImage {
    guard let data = try? Data(contentsOf: url),
          let representation = NSBitmapImageRep(data: data) else {
        throw AppIconError(message: "cannot decode app icon source: \(url.path)")
    }
    guard representation.pixelsWide == 1024, representation.pixelsHigh == 1024 else {
        throw AppIconError(message: "app icon source must be exactly 1024 x 1024 pixels")
    }
    guard let image = NSImage(data: data) else {
        throw AppIconError(message: "cannot load app icon source: \(url.path)")
    }
    image.size = NSSize(width: 1024, height: 1024)
    return image
}

private func render(
    source: NSImage,
    pixels: Int,
    destinationURL: URL
) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: NSColorSpaceName.deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw AppIconError(message: "cannot allocate \(pixels) px app icon bitmap")
    }
    guard let bitmapData = bitmap.bitmapData else {
        throw AppIconError(message: "cannot access \(pixels) px app icon bitmap")
    }
    memset(bitmapData, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
    bitmap.size = NSSize(width: pixels, height: pixels)

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw AppIconError(message: "cannot create \(pixels) px app icon context")
    }

    let size = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let renderGeometry = geometry(for: pixels)
    let body = canvas.insetBy(
        dx: renderGeometry.bodyInset,
        dy: renderGeometry.bodyInset
    )
    let bodyPath = NSBezierPath(
        roundedRect: body,
        xRadius: floor(body.width * 0.225),
        yRadius: floor(body.height * 0.225)
    )

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = NSImageInterpolation.high
    context.shouldAntialias = true

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    shadow.shadowBlurRadius = renderGeometry.shadowBlur
    shadow.shadowOffset = NSSize(width: 0, height: renderGeometry.shadowOffset)
    shadow.set()
    NSColor.black.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    let cropFraction = renderGeometry.sourceCropFraction
    let cropOrigin = 1024 * (1 - cropFraction) / 2
    let sourceRect = NSRect(
        x: cropOrigin,
        y: cropOrigin,
        width: 1024 * cropFraction,
        height: 1024 * cropFraction
    )
    source.draw(
        in: body,
        from: sourceRect,
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: nil
    )
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else {
        throw AppIconError(message: "cannot encode \(pixels) px app icon PNG")
    }
    try png.write(to: destinationURL, options: Data.WritingOptions.atomic)
}

private func renderIconset(sourceURL: URL, iconsetURL: URL) throws {
    let source = try loadSourceImage(at: sourceURL)
    try FileManager.default.createDirectory(
        at: iconsetURL,
        withIntermediateDirectories: true
    )
    for rendition in renditions {
        try render(
            source: source,
            pixels: rendition.pixels,
            destinationURL: iconsetURL.appendingPathComponent(rendition.filename)
        )
    }
}

private func color(
    in bitmap: NSBitmapImageRep,
    x: Int,
    y: Int
) throws -> NSColor {
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
        throw AppIconError(message: "cannot inspect app icon pixel at \(x),\(y)")
    }
    return color
}

private func verifyTransparency(
    bitmap: NSBitmapImageRep,
    filename: String
) throws {
    guard bitmap.hasAlpha else {
        throw AppIconError(message: "\(filename) must preserve an alpha channel")
    }
    let lastX = bitmap.pixelsWide - 1
    let lastY = bitmap.pixelsHigh - 1
    for (x, y) in [(0, 0), (lastX, 0), (0, lastY), (lastX, lastY)] {
        let corner = try color(in: bitmap, x: x, y: y)
        guard corner.alphaComponent < 0.05 else {
            throw AppIconError(message: "\(filename) must have transparent corners")
        }
    }
    let center = try color(
        in: bitmap,
        x: bitmap.pixelsWide / 2,
        y: bitmap.pixelsHigh / 2
    )
    guard center.alphaComponent > 0.95 else {
        throw AppIconError(message: "\(filename) icon body must remain opaque")
    }

    let width = bitmap.pixelsWide
    let last = width - 1
    for offset in 0 ..< width {
        for (x, y) in [(offset, 0), (offset, last), (0, offset), (last, offset)] {
            let edge = try color(in: bitmap, x: x, y: y)
            guard edge.alphaComponent < 0.35 else {
                throw AppIconError(message: "\(filename) outer edge must not become opaque")
            }
        }
    }

    let renderGeometry = geometry(for: width)
    let inset = Int(renderGeometry.bodyInset.rounded(.up))
    let bodyWidth = width - (2 * inset)
    let radius = floor(CGFloat(bodyWidth) * 0.225)
    let outsideCornerOffset = Int(floor(radius * 0.25))
    let insideCornerOffset = Int(ceil(radius * 0.80))
    let outsideLow = inset + outsideCornerOffset
    let outsideHigh = last - outsideLow
    let insideLow = inset + insideCornerOffset
    let insideHigh = last - insideLow

    for (x, y) in [
        (outsideLow, outsideLow),
        (outsideLow, outsideHigh),
        (outsideHigh, outsideLow),
        (outsideHigh, outsideHigh),
    ] {
        let outsideCorner = try color(in: bitmap, x: x, y: y)
        guard outsideCorner.alphaComponent < 0.40 else {
            throw AppIconError(message: "\(filename) must preserve a rounded alpha mask")
        }
    }
    for (x, y) in [
        (insideLow, insideLow),
        (insideLow, insideHigh),
        (insideHigh, insideLow),
        (insideHigh, insideHigh),
    ] {
        let insideCorner = try color(in: bitmap, x: x, y: y)
        guard insideCorner.alphaComponent > 0.90 else {
            throw AppIconError(message: "\(filename) rounded body is excessively inset")
        }
    }

    var opaqueMinX = width
    var opaqueMaxX = -1
    var opaqueMinY = width
    var opaqueMaxY = -1
    let bodyCenter = CGFloat(width) / 2
    let bodyHalfExtent = CGFloat(bodyWidth) / 2
    let roundedCoreHalfExtent = bodyHalfExtent - radius
    var outsideAlphaTotal = 0.0
    var outsidePixelCount = 0
    for y in 0 ..< width {
        for x in 0 ..< width {
            let sample = try color(in: bitmap, x: x, y: y)
            let pointX = CGFloat(x) + 0.5
            let pointY = CGFloat(y) + 0.5
            let deltaX = abs(pointX - bodyCenter) - roundedCoreHalfExtent
            let deltaY = abs(pointY - bodyCenter) - roundedCoreHalfExtent
            let outsideX = max(deltaX, 0)
            let outsideY = max(deltaY, 0)
            let roundedDistance = hypot(outsideX, outsideY)
                + min(max(deltaX, deltaY), 0)
                - radius
            if roundedDistance <= -0.75 {
                guard sample.alphaComponent > 0.80 else {
                    throw AppIconError(
                        message: "\(filename) has a hole in the rounded icon body"
                    )
                }
            } else if roundedDistance >= 0.75 {
                outsideAlphaTotal += Double(sample.alphaComponent)
                outsidePixelCount += 1
                guard sample.alphaComponent < 0.30 else {
                    throw AppIconError(
                        message: "\(filename) has opaque pixels outside the rounded body"
                    )
                }
            }
            guard sample.alphaComponent > 0.95 else { continue }
            opaqueMinX = min(opaqueMinX, x)
            opaqueMaxX = max(opaqueMaxX, x)
            opaqueMinY = min(opaqueMinY, y)
            opaqueMaxY = max(opaqueMaxY, y)
        }
    }
    let averageOutsideAlpha = outsidePixelCount > 0
        ? outsideAlphaTotal / Double(outsidePixelCount)
        : 0
    guard averageOutsideAlpha < 0.04 else {
        throw AppIconError(
            message: "\(filename) has excessive shadow coverage outside the rounded body"
        )
    }
    let expectedMaximum = last - inset
    guard abs(opaqueMinX - inset) <= 1,
          abs(opaqueMinY - inset) <= 1,
          abs(opaqueMaxX - expectedMaximum) <= 1,
          abs(opaqueMaxY - expectedMaximum) <= 1 else {
        throw AppIconError(message: "\(filename) legacy icon body geometry changed")
    }
}

private struct PixelComponent {
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int
    var pixelCount: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

private func connectedComponents(
    mask: [Bool],
    width: Int,
    height: Int
) -> [PixelComponent] {
    var visited = Array(repeating: false, count: mask.count)
    var result: [PixelComponent] = []

    for start in mask.indices where mask[start] && !visited[start] {
        var queue = [start]
        var queueIndex = 0
        visited[start] = true
        let startX = start % width
        let startY = start / width
        var component = PixelComponent(
            minX: startX,
            maxX: startX,
            minY: startY,
            maxY: startY,
            pixelCount: 0
        )

        while queueIndex < queue.count {
            let index = queue[queueIndex]
            queueIndex += 1
            let x = index % width
            let y = index / width
            component.minX = min(component.minX, x)
            component.maxX = max(component.maxX, x)
            component.minY = min(component.minY, y)
            component.maxY = max(component.maxY, y)
            component.pixelCount += 1

            for deltaY in -1 ... 1 {
                for deltaX in -1 ... 1 where deltaX != 0 || deltaY != 0 {
                    let neighborX = x + deltaX
                    let neighborY = y + deltaY
                    guard neighborX >= 0, neighborX < width,
                          neighborY >= 0, neighborY < height else {
                        continue
                    }
                    let neighbor = (neighborY * width) + neighborX
                    guard mask[neighbor], !visited[neighbor] else { continue }
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
        }
        result.append(component)
    }
    return result
}

private func verifySmallSizeLegibility(
    bitmap: NSBitmapImageRep,
    filename: String
) throws {
    let width = bitmap.pixelsWide
    var foregroundMinX = width
    var foregroundMaxX = -1
    var foregroundMinY = width
    var foregroundMaxY = -1
    var ivoryCount = 0
    var coralCount = 0
    var coralMinX = width
    var coralMaxX = -1
    var coralMask = Array(
        repeating: false,
        count: bitmap.pixelsWide * bitmap.pixelsHigh
    )
    var semanticIvoryMask = Array(
        repeating: false,
        count: bitmap.pixelsWide * bitmap.pixelsHigh
    )

    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< width {
            let sample = try color(in: bitmap, x: x, y: y)
            guard sample.alphaComponent > 0.6 else { continue }
            let red = sample.redComponent
            let green = sample.greenComponent
            let blue = sample.blueComponent
            let isIvory = red > 0.65 && green > 0.55 && blue > 0.42
            let isCoral = red > 0.68 && red - green > 0.12 && red - blue > 0.10
            let isSemanticIvory = sample.alphaComponent > 0.30
                && red > 0.40
                && green > 0.36
                && blue > 0.28
                && red - green < 0.24
                && green - blue < 0.28
            if isSemanticIvory {
                semanticIvoryMask[(y * width) + x] = true
            }
            guard isIvory || isCoral else { continue }

            foregroundMinX = min(foregroundMinX, x)
            foregroundMaxX = max(foregroundMaxX, x)
            foregroundMinY = min(foregroundMinY, y)
            foregroundMaxY = max(foregroundMaxY, y)
            if isIvory {
                ivoryCount += 1
            }
            if isCoral {
                coralCount += 1
                coralMinX = min(coralMinX, x)
                coralMaxX = max(coralMaxX, x)
                coralMask[(y * width) + x] = true
            }
        }
    }

    let foregroundWidth = foregroundMaxX - foregroundMinX + 1
    let foregroundHeight = foregroundMaxY - foregroundMinY + 1
    let minimumForegroundWidth = Int(ceil(Double(width) * 0.68))
    let minimumForegroundHeight = Int(ceil(Double(width) * 0.30))
    guard foregroundWidth >= minimumForegroundWidth,
          foregroundHeight >= minimumForegroundHeight else {
        throw AppIconError(
            message: "\(filename) foreground is too small (\(foregroundWidth)x\(foregroundHeight))"
        )
    }

    let minimumIvoryPixels = max(6, width * width / 30)
    let minimumCoralPixels = max(3, width * width / 100)
    guard ivoryCount >= minimumIvoryPixels else {
        throw AppIconError(message: "\(filename) loses the ivory input lanes")
    }
    guard coralCount >= minimumCoralPixels else {
        throw AppIconError(message: "\(filename) loses the coral routing marks")
    }

    let coralSpan = coralMaxX - coralMinX + 1
    let minimumCoralSpan = Int(ceil(Double(width) * 0.22))
    guard coralSpan >= minimumCoralSpan else {
        throw AppIconError(
            message: "\(filename) routing node and insertion cursor collapse together"
        )
    }

    let minimumComponentPixels = max(2, width * width / 160)
    let coralComponents = connectedComponents(
        mask: coralMask,
        width: width,
        height: bitmap.pixelsHigh
    )
    .filter { $0.pixelCount >= minimumComponentPixels }
    .sorted { $0.minX < $1.minX }
    guard coralComponents.count == 2 else {
        throw AppIconError(
            message: "\(filename) must retain separate routing-node and cursor shapes"
        )
    }

    let routingNode = coralComponents[0]
    let insertionCursor = coralComponents[1]
    let minimumCursorHeight = Int(ceil(Double(width) * 0.30))
    guard routingNode.minX >= Int(floor(Double(width) * 0.45)),
          routingNode.width >= routingNode.height,
          routingNode.maxX < insertionCursor.minX,
          insertionCursor.minX >= Int(floor(Double(width) * 0.72)),
          insertionCursor.height >= minimumCursorHeight,
          insertionCursor.height >= insertionCursor.width * 2 else {
        throw AppIconError(
            message: "\(filename) routing-node or insertion-cursor geometry changed"
        )
    }

    let inputRange = foregroundMinX ..< routingNode.minX
    var twoLaneColumnCount = 0
    var upperLaneContour: [Int] = []
    let minimumLaneGap = max(2, width / 16)
    for x in inputRange {
        var ivoryRows: [Int] = []
        for y in 0 ..< bitmap.pixelsHigh where semanticIvoryMask[(y * width) + x] {
            ivoryRows.append(y)
        }
        guard ivoryRows.count >= 2 else { continue }
        var containsLaneGap = false
        for index in 1 ..< ivoryRows.count
            where ivoryRows[index] - ivoryRows[index - 1] >= minimumLaneGap {
            containsLaneGap = true
            break
        }
        guard containsLaneGap else { continue }
        twoLaneColumnCount += 1
        if let first = ivoryRows.first {
            upperLaneContour.append(first)
        }
    }

    let minimumTwoLaneColumns = max(2, width / 8)
    guard twoLaneColumnCount >= minimumTwoLaneColumns,
          let upperMinimum = upperLaneContour.min(),
          let upperMaximum = upperLaneContour.max(),
          upperMaximum - upperMinimum >= max(1, width / 16) else {
        throw AppIconError(
            message: "\(filename) loses the separate workflow lane or voice pulse"
        )
    }

    let outputStart = routingNode.maxX + 1
    let outputEnd = insertionCursor.minX
    guard outputStart < outputEnd else {
        throw AppIconError(message: "\(filename) loses the ivory output lane")
    }
    var outputColumnsWithIvory = 0
    for x in outputStart ..< outputEnd {
        let containsIvory = (0 ..< bitmap.pixelsHigh).contains {
            semanticIvoryMask[($0 * width) + x]
        }
        if containsIvory {
            outputColumnsWithIvory += 1
        }
    }
    let outputColumnCount = outputEnd - outputStart
    guard outputColumnsWithIvory >= max(1, outputColumnCount - 1) else {
        throw AppIconError(message: "\(filename) loses the ivory output lane")
    }
}

private func verifyIconset(at iconsetURL: URL) throws {
    for rendition in renditions {
        let url = iconsetURL.appendingPathComponent(rendition.filename)
        guard let data = try? Data(contentsOf: url),
              let bitmap = NSBitmapImageRep(data: data) else {
            throw AppIconError(message: "missing or invalid rendition: \(rendition.filename)")
        }
        guard bitmap.pixelsWide == rendition.pixels,
              bitmap.pixelsHigh == rendition.pixels else {
            throw AppIconError(
                message: "\(rendition.filename) must be \(rendition.pixels)x\(rendition.pixels)"
            )
        }
        try verifyTransparency(bitmap: bitmap, filename: rendition.filename)
        if rendition.filename == "icon_16x16.png"
            || rendition.filename == "icon_32x32.png" {
            try verifySmallSizeLegibility(bitmap: bitmap, filename: rendition.filename)
        }
    }
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else {
        throw AppIconError(
            message: "usage: render_app_icon_renditions.swift render SOURCE_PNG ICONSET | verify ICONSET"
        )
    }

    switch arguments[1] {
    case "render":
        guard arguments.count == 4 else {
            throw AppIconError(message: "usage: render_app_icon_renditions.swift render SOURCE_PNG ICONSET")
        }
        try renderIconset(
            sourceURL: URL(fileURLWithPath: arguments[2]),
            iconsetURL: URL(fileURLWithPath: arguments[3])
        )
    case "verify":
        guard arguments.count == 3 else {
            throw AppIconError(message: "usage: render_app_icon_renditions.swift verify ICONSET")
        }
        try verifyIconset(at: URL(fileURLWithPath: arguments[2]))
    default:
        throw AppIconError(message: "unknown command: \(arguments[1])")
    }
}

do {
    try run()
} catch {
    let message = "error: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
