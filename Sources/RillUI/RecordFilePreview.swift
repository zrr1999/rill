import AppKit
import Observation
import QuickLookThumbnailing
import Quartz
import SwiftUI

struct RecordFilePreviewMetadata: Sendable {
  let typeDescription: String?
  let byteCount: Int?
  let isDirectory: Bool

  @concurrent
  static func read(_ url: URL) async -> Self? {
    guard url.isFileURL, !Task.isCancelled else { return nil }
    var url = url
    url.removeAllCachedResourceValues()
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard let values = try? url.resourceValues(forKeys: [
      .isRegularFileKey, .isDirectoryKey, .isReadableKey, .fileSizeKey, .localizedTypeDescriptionKey,
    ]), values.isReadable == true,
      values.isRegularFile == true || values.isDirectory == true else { return nil }
    return .init(typeDescription: values.localizedTypeDescription,
      byteCount: values.isRegularFile == true ? values.fileSize : nil,
      isDirectory: values.isDirectory == true)
  }
}

@MainActor @Observable
final class RecordFilePreviewModel {
  enum State {
    case loading
    case available(RecordFilePreviewMetadata)
    case unavailable
  }

  private(set) var state: State = .loading
  private(set) var thumbnail: CGImage?
  private var generation: UUID?
  private var request: QLThumbnailGenerator.Request?
  private var scopedURL: URL?

  func load(_ url: URL, generatesThumbnail: Bool = true) async {
    cancel()
    state = .loading
    let generation = UUID()
    self.generation = generation
    guard let metadata = await RecordFilePreviewMetadata.read(url) else {
      if !Task.isCancelled, self.generation == generation { state = .unavailable }
      return
    }
    guard !Task.isCancelled, self.generation == generation else { return }
    state = .available(metadata)
    if url.startAccessingSecurityScopedResource() { scopedURL = url }
    guard generatesThumbnail, !metadata.isDirectory else { return }
    let request = QLThumbnailGenerator.Request(fileAt: url,
      size: CGSize(width: 64, height: 64), scale: 2, representationTypes: .all)
    self.request = request
    let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
    guard !Task.isCancelled, self.generation == generation else { return }
    thumbnail = representation?.cgImage
    self.request = nil
  }

  func cancel() {
    generation = nil
    if let request { QLThumbnailGenerator.shared.cancel(request) }
    request = nil
    thumbnail = nil
    scopedURL?.stopAccessingSecurityScopedResource()
    scopedURL = nil
  }

  isolated deinit {
    if let request { QLThumbnailGenerator.shared.cancel(request) }
    scopedURL?.stopAccessingSecurityScopedResource()
  }
}

struct RecordFilesPreview: View {
  let urls: [URL]
  let language: AppLanguage
  @State private var selectedFile: Selection?

  private struct Selection: Identifiable {
    let id: Int
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: RillSpacing.row) {
      ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
        RecordFilePreviewRow(url: url, language: language) {
          selectedFile = Selection(id: index)
        }
      }
    }
    .sheet(item: $selectedFile) { selection in
      RecordFilePreviewSheet(urls: urls, initialIndex: selection.id, language: language)
    }
  }
}

private struct RecordFilePreviewRow: View {
  let url: URL
  let language: AppLanguage
  let onPreview: () -> Void
  @State private var model = RecordFilePreviewModel()

  var body: some View {
    HStack(spacing: RillSpacing.row) {
      Group {
        if let thumbnail = model.thumbnail {
          Image(decorative: thumbnail, scale: 2).resizable().scaledToFit()
        } else {
          Image(systemName: symbol.rawValue).font(.title)
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 48, height: 48)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(url.lastPathComponent).lineLimit(2).truncationMode(.middle)
        switch model.state {
        case .loading: ProgressView().controlSize(.small)
        case .unavailable:
          Text(L10n.quickRecord(.fileUnavailable, language: language))
            .font(.caption).foregroundStyle(.secondary)
        case .available(let metadata):
          Text([metadata.typeDescription, metadata.byteCount.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
          }].compactMap { $0 }.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      if case .available(let metadata) = model.state, !metadata.isDirectory {
        Button(action: onPreview) {
          Image(systemName: RillSystemSymbol.docTextMagnifyingglass.rawValue)
        }
        .help(L10n.quickRecord(.preview, language: language))
        .accessibilityLabel(L10n.quickRecord(.preview, language: language) + ": " + url.lastPathComponent)
        .accessibilityIdentifier("records.preview-file")
      }
    }
    .padding(.vertical, 4)
    .task(id: url) { await model.load(url) }
    .onDisappear { model.cancel() }
  }

  private var symbol: RillSystemSymbol {
    if case .available(let metadata) = model.state, metadata.isDirectory { return .folder }
    return .doc
  }
}

struct RecordFilePreviewSheet: View {
  let urls: [URL]
  let language: AppLanguage
  @State private var index: Int
  @Environment(\.dismiss) private var dismiss

  init(urls: [URL], initialIndex: Int, language: AppLanguage) {
    self.urls = urls
    self.language = language
    _index = State(initialValue: initialIndex)
  }

  var body: some View {
    VStack(spacing: RillSpacing.panel) {
      HStack {
        Text(urls[index].lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
        Spacer()
        if urls.count > 1 {
          Button { index -= 1 } label: { Image(systemName: RillSystemSymbol.chevronLeft.rawValue) }
            .disabled(index == 0)
            .accessibilityLabel(L10n.quickRecord(.previousFile, language: language))
          Text("\(index + 1) / \(urls.count)").monospacedDigit().foregroundStyle(.secondary)
          Button { index += 1 } label: { Image(systemName: RillSystemSymbol.chevronRight.rawValue) }
            .disabled(index == urls.count - 1)
            .accessibilityLabel(L10n.quickRecord(.nextFile, language: language))
        }
        Button(L10n.quickRecord(.close, language: language)) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      RecordFileQuickLookContent(url: urls[index], language: language)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(index)
    }
    .padding(RillSpacing.panel)
    .frame(minWidth: 440, idealWidth: 720, maxWidth: 960, minHeight: 360, idealHeight: 560, maxHeight: 800)

  }
}

private struct RecordFileQuickLookContent: View {
  let url: URL
  let language: AppLanguage
  @State private var model = RecordFilePreviewModel()

  var body: some View {
    Group {
      switch model.state {
      case .loading: ProgressView()
      case .unavailable:
        ContentUnavailableView(L10n.quickRecord(.fileUnavailable, language: language),
          systemImage: RillSystemSymbol.doc.rawValue)
      case .available: RecordQuickLookView(url: url)
      }
    }
    .task(id: url) { await model.load(url, generatesThumbnail: false) }
    .onDisappear { model.cancel() }
  }
}

struct RecordQuickLookView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal)!
    view.shouldCloseWithWindow = false
    view.autostarts = false
    view.previewItem = url as NSURL
    return view
  }

  func updateNSView(_ view: QLPreviewView, context: Context) {
    if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
  }

  static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
    view.close()
  }
}
