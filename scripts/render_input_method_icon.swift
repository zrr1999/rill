import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
  let image = NSImage(contentsOfFile: CommandLine.arguments[1])
else { fatalError("Usage: render_input_method_icon.swift SOURCE.pdf OUTPUT.tiff") }

let size = NSSize(width: 22, height: 18)
let markSize = NSSize(width: 16, height: 14.4)
let representations = [1, 2].map { scale in
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width) * scale,
    pixelsHigh: Int(size.height) * scale,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )!
  bitmap.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  NSColor.black.setFill()
  NSBezierPath(
    roundedRect: NSRect(x: 0, y: 1, width: size.width, height: 16),
    xRadius: 4,
    yRadius: 4
  ).fill()
  // Template images use alpha as their mask, so the mark must be a cutout.
  image.draw(
    in: NSRect(
      x: (size.width - markSize.width) / 2,
      y: (size.height - markSize.height) / 2,
      width: markSize.width,
      height: markSize.height
    ),
    from: .zero,
    operation: .destinationOut,
    fraction: 1
  )
  NSGraphicsContext.restoreGraphicsState()
  return bitmap
}
let data = NSBitmapImageRep.representationOfImageReps(
  in: representations, using: .tiff, properties: [:]
)!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
