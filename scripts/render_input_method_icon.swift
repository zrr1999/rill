import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
  let image = NSImage(contentsOfFile: CommandLine.arguments[1])
else { fatalError("Usage: render_input_method_icon.swift SOURCE.pdf OUTPUT.tiff") }

let size = image.size
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
  image.draw(in: NSRect(origin: .zero, size: size))
  NSGraphicsContext.restoreGraphicsState()
  return bitmap
}
let data = NSBitmapImageRep.representationOfImageReps(
  in: representations, using: .tiff, properties: [:]
)!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
