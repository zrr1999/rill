import AppKit
import ImageIO
import RillCore
import SwiftUI

actor RecordThumbnailCache {
  static let shared = RecordThumbnailCache()
  private var images: [RecordID: CGImage] = [:]
  private var order: [RecordID] = []
  private var byteCount = 0

  func thumbnail(for id: RecordID, data: Data) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    if let image = images[id] { return image }
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 768,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary), !Task.isCancelled
    else { return nil }
    let bytes = image.bytesPerRow * image.height
    guard bytes <= 8 * 1_024 * 1_024 else { return image }
    while byteCount + bytes > 8 * 1_024 * 1_024, !order.isEmpty {
      if let removed = images.removeValue(forKey: order.removeFirst()) {
        byteCount -= removed.bytesPerRow * removed.height
      }
    }
    images[id] = image
    order.append(id)
    byteCount += bytes
    return image
  }
}

struct RecordImagePreview: View {
  let id: RecordID
  let data: Data
  @State private var image: CGImage?
  @State private var isLoading = true

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
      } else if isLoading {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: RillSystemSymbol.photoBadgeExclamationmark.rawValue).foregroundStyle(
          .secondary)
      }
    }
    .task(id: id) {
      image = nil
      isLoading = true
      let thumbnail = await RecordThumbnailCache.shared.thumbnail(for: id, data: data)
      guard !Task.isCancelled else { return }
      image = thumbnail
      isLoading = false
    }
  }
}

struct RecordTextPreview: View {
  let text: String
  let language: AppLanguage
  @State private var visibleCount = 8_192

  var body: some View {
    VStack(alignment: .leading, spacing: RillSpacing.row) {
      Text(String(text.prefix(visibleCount)))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !text.dropFirst(visibleCount).isEmpty {
        Button(L10n.quickRecord(.loadMore, language: language)) { visibleCount += 8_192 }
      }
    }
  }
}
