import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import RillCore
@testable import RillRuntime
@testable import RillUI

@MainActor
struct RecordContentPreviewTests {
  @Test func imageDecodeIsBoundedAndRejectsCorruptData() async throws {
    let data = try RecordPreviewFixture.imageData(width: 3_000, height: 2_000)
    let decoder = RecordImageDecoder()
    let small = try #require(await decoder.thumbnail(data: data, maximumPixelSize: 768))
    #expect(small.width == 768)
    #expect(small.height == 512)
    let expanded = try #require(await decoder.thumbnail(data: data, maximumPixelSize: 10_000))
    #expect(max(expanded.width, expanded.height) == 2_048)
    #expect(await decoder.thumbnail(data: Data("broken image".utf8), maximumPixelSize: 768) == nil)
    let cancelled = Task {
      await decoder.thumbnail(data: data, maximumPixelSize: 768)
    }
    cancelled.cancel()
    #expect(await cancelled.value == nil)
  }

  @Test func fileMetadataHandlesFilesFoldersAndMissingReferences() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("preview.txt")
    let content = Data("Clipboard file preview".utf8)
    try content.write(to: file)
    let metadata = try #require(await RecordFilePreviewMetadata.read(file))
    #expect(metadata.byteCount == content.count)
    #expect(!metadata.isDirectory)
    #expect(await RecordFilePreviewMetadata.read(directory)?.isDirectory == true)
    #expect(await RecordFilePreviewMetadata.read(URL(string: "https://example.com/preview.txt")!) == nil)
    try FileManager.default.removeItem(at: file)
    #expect(await RecordFilePreviewMetadata.read(file) == nil)

    let model = RecordFilePreviewModel()
    await model.load(file)
    guard case .unavailable = model.state else {
      Issue.record("A missing file must have an explicit unavailable state.")
      return
    }
    #expect(model.thumbnail == nil)
  }

  @Test func previewFollowsSelectionWithoutMutatingRecordsAndClosesDuringLoad() async throws {
    let store = RecordStore()
    let image = try await store.ingest(.init(payload: .image(try RecordPreviewFixture.imageData()),
      provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    let file = try await store.ingest(.init(payload: .files([URL(fileURLWithPath: "/tmp/rill-preview.txt")]),
      provenance: .init(source: .init(kind: .systemClipboard))), into: [])
    let before = try await store.catalogSnapshot()
    let panel = RecordQuickPanelModel(store: store)
    panel.start(sourceBundleIdentifier: nil)
    defer { panel.stop() }
    await waitUntil { !panel.isSearching && panel.results.count == 2 }
    #expect(panel.preview == nil)
    panel.selectedID = image.id
    panel.togglePreview()
    await waitUntil { !panel.isLoadingPreview }
    #expect(panel.preview?.id == image.id)
    panel.selectedID = file.id
    #expect(panel.preview == nil)
    await waitUntil { !panel.isLoadingPreview }
    #expect(panel.isPreviewVisible)
    #expect(panel.preview?.id == file.id)
    panel.kind = .files
    #expect(panel.preview?.id == file.id)
    await waitUntil { !panel.isSearching }
    #expect(panel.preview?.id == file.id)
    panel.kind = nil
    await waitUntil { !panel.isSearching }
    panel.selectedID = image.id
    panel.closePreview()
    await Task.yield()
    #expect(!panel.isPreviewVisible)
    #expect(panel.preview == nil)
    #expect(!panel.isLoadingPreview)
    let after = try await store.catalogSnapshot()
    #expect(before.revision == after.revision)

    panel.togglePreview()
    await waitUntil { !panel.isLoadingPreview }
    try await store.deleteRecord(image.id)
    await waitUntil { panel.selectedID == file.id && panel.preview?.id == file.id }
    #expect(panel.preview?.id == file.id)
    panel.stop()
    #expect(!panel.isPreviewVisible)
    #expect(panel.preview == nil)
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(condition())
  }
}

enum RecordPreviewFixture {
  static func imageData(width: Int = 960, height: Int = 540) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.06, green: 0.22, blue: 0.31, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.16, green: 0.79, blue: 0.72, alpha: 1))
    context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}
