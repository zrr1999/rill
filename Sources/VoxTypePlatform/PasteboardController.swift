import AppKit
import VoxTypeCore

@MainActor
public final class PasteboardController: Sendable {
    private struct PasteboardMetadata: Codable {
        var captureTags: [ClipboardCaptureTag]
    }

    private static let metadataType = NSPasteboard.PasteboardType("dev.voxtype.metadata")
    private var ownedChangeCounts: [Int: Date] = [:]

    public init() {}

    public func currentSnapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let imagePNGData: Data?
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let image = images.first {
            imagePNGData = Self.pngData(for: image)
        } else {
            imagePNGData = nil
        }
        let captureTags = Self.captureTags(from: pasteboard)
        return ClipboardSnapshot(
            plainText: pasteboard.string(forType: .string) ?? "",
            imagePNGData: imagePNGData,
            fileURLs: fileURLs,
            changeCount: pasteboard.changeCount,
            captureTags: captureTags
        )
    }

    @discardableResult
    public func writePlainText(
        _ text: String,
        captureTags: [ClipboardCaptureTag] = []
    ) -> Int {
        writeSnapshot(
            ClipboardSnapshot(plainText: text, changeCount: 0),
            captureTags: captureTags
        )
    }

    @discardableResult
    public func writeSnapshot(
        _ snapshot: ClipboardSnapshot,
        captureTags: [ClipboardCaptureTag]? = nil
    ) -> Int {
        let snapshotToWrite = captureTags.map { snapshot.appendingCaptureTags($0) } ?? snapshot
        let pasteboard = NSPasteboard.general
        Self.writeContents(of: snapshotToWrite, to: pasteboard)
        let changeCount = pasteboard.changeCount
        markOwnedChangeCount(changeCount)
        return changeCount
    }

    public func restore(_ snapshot: ClipboardSnapshot, ifChangeCountIs expected: Int) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expected else { return false }
        Self.writeContents(of: snapshot, to: pasteboard)
        let restoredChangeCount = pasteboard.changeCount
        markOwnedChangeCount(restoredChangeCount)
        return true
    }

    public func isOwnedChangeCount(_ changeCount: Int) -> Bool {
        pruneOwnedChangeCounts()
        return ownedChangeCounts[changeCount] != nil
    }

    private func markOwnedChangeCount(_ changeCount: Int) {
        ownedChangeCounts[changeCount] = Date()
        pruneOwnedChangeCounts()
    }

    private func pruneOwnedChangeCounts() {
        let cutoff = Date().addingTimeInterval(-30)
        ownedChangeCounts = ownedChangeCounts.filter { $0.value >= cutoff }
    }

    private static func writeContents(of snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !snapshot.plainText.isEmpty {
            pasteboard.setString(snapshot.plainText, forType: .string)
        }
        if !snapshot.fileURLs.isEmpty {
            _ = pasteboard.writeObjects(snapshot.fileURLs as [NSURL])
        }
        if let imagePNGData = snapshot.imagePNGData, let image = NSImage(data: imagePNGData) {
            _ = pasteboard.writeObjects([image])
        }
        if let metadata = encodedMetadata(for: snapshot.captureTags) {
            pasteboard.setData(metadata, forType: metadataType)
        }
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func captureTags(from pasteboard: NSPasteboard) -> [ClipboardCaptureTag] {
        guard
            let data = pasteboard.data(forType: metadataType),
            let metadata = try? JSONDecoder().decode(PasteboardMetadata.self, from: data)
        else {
            return []
        }
        return metadata.captureTags
    }

    private static func encodedMetadata(for captureTags: [ClipboardCaptureTag]) -> Data? {
        guard !captureTags.isEmpty else { return nil }
        return try? JSONEncoder().encode(PasteboardMetadata(captureTags: captureTags))
    }
}
