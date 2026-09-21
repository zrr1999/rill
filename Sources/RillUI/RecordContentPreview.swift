import AppKit
import ImageIO
import RillCore
import SwiftUI

actor RecordImageDecoder {
  static let shared = RecordImageDecoder()

  func thumbnail(data: Data, maximumPixelSize: Int) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: min(max(maximumPixelSize, 1), 2_048),
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary), !Task.isCancelled
    else { return nil }
    return image
  }
}

struct RecordContentPreview: View {
  let record: Record
  let language: AppLanguage
  var imageHeight: CGFloat = 240

  var body: some View {
    Group {
      switch record.payload {
      case .text(let text): RecordTextPreview(text: text, language: language)
      case .image(let data): RecordImagePreview(id: record.id, data: data, language: language, height: imageHeight)
      case .files(let urls): RecordFilesPreview(urls: urls, language: language)
      }
    }
    .id(record.id)
  }
}

struct RecordImagePreview: View {
  let id: RecordID
  let data: Data
  let language: AppLanguage
  var height: CGFloat = 240
  @State private var showsExpandedImage = false

  var body: some View {
    VStack(spacing: RillSpacing.row) {
      RecordImageContent(id: id, data: data, language: language, maximumPixelSize: 768)
        .frame(maxWidth: .infinity).frame(height: height)
      Button(L10n.quickRecord(.expandImage, language: language)) { showsExpandedImage = true }
        .accessibilityIdentifier("records.expand-image")
    }
    .sheet(isPresented: $showsExpandedImage) {
      VStack(spacing: RillSpacing.panel) {
        HStack {
          Text(L10n.quickRecord(.image, language: language)).font(.headline)
          Spacer()
          Button(L10n.quickRecord(.close, language: language)) { showsExpandedImage = false }
            .keyboardShortcut(.cancelAction)
        }
        RecordImageContent(id: id, data: data, language: language, maximumPixelSize: 2_048)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding(RillSpacing.panel)
      .frame(minWidth: 440, idealWidth: 720, maxWidth: 960, minHeight: 360, idealHeight: 560, maxHeight: 800)
    }
  }
}

private struct RecordImageContent: View {
  let id: RecordID
  let data: Data
  let language: AppLanguage
  let maximumPixelSize: Int
  @State private var image: CGImage?
  @State private var isLoading = true

  var body: some View {
    Group {
      if let image {
        Image(image, scale: 1, label: Text(L10n.quickRecord(.image, language: language)))
          .resizable().scaledToFit()
      } else if isLoading {
        ProgressView().controlSize(.small)
      } else {
        Label(L10n.quickRecord(.imageUnavailable, language: language),
          systemImage: RillSystemSymbol.photoBadgeExclamationmark.rawValue)
          .foregroundStyle(.secondary)
      }
    }
    .task(id: id) {
      image = nil
      isLoading = true
      let thumbnail = await RecordImageDecoder.shared.thumbnail(data: data, maximumPixelSize: maximumPixelSize)
      guard !Task.isCancelled else { return }
      image = thumbnail
      isLoading = false
    }
    .onDisappear { image = nil }
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
