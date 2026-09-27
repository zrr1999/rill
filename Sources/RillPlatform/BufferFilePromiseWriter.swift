import AppKit
import ImageIO
import UniformTypeIdentifiers

package final class BufferFilePromiseWriter: NSObject, NSFilePromiseProviderDelegate, Sendable {
  package enum Source: Sendable {
    case file(URL)
    case image(Data)
  }
  private let source: Source
  private let feedback: @Sendable (Bool) -> Void
  package init(source: Source, feedback: @escaping @Sendable (Bool) -> Void) {
    self.source = source
    self.feedback = feedback
  }

  @MainActor package func provider() -> NSFilePromiseProvider {
    let type: UTType
    switch source {
    case .image: type = .png
    case .file(let url):
      type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
    }
    return NSFilePromiseProvider(fileType: type.identifier, delegate: self)
  }

  @MainActor package func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
  ) -> String {
    switch source {
    case .file(let url): url.lastPathComponent
    case .image: "Rill-image.png"
    }
  }

  package func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    do {
      switch source {
      case .file(let sourceURL): try FileManager.default.copyItem(at: sourceURL, to: url)
      case .image(let data):
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0,
          CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { throw CocoaError(.fileReadCorruptFile) }
        let png = NSMutableData()
        guard
          let destination = CGImageDestinationCreateWithData(
            png, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try (png as Data).write(to: url, options: .withoutOverwriting)
      }
      completionHandler(nil)
      feedback(true)
    } catch {
      completionHandler(error)
      feedback(false)
    }
  }

  @MainActor package func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
    .init()
  }
}
