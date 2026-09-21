import AppKit
import ImageIO
import UniformTypeIdentifiers
import RillCore

@MainActor
public final class SystemClipboardPort: Sendable {
    /// Memory and shape limits for an exact temporary archive of the system
    /// pasteboard. These limits are separate from SystemClipboardStorageLimits: the
    /// archive is transaction-scoped and may contain arbitrary application
    /// types that must never enter clipboard history.
    public struct TemporaryPreservationLimits: Sendable, Equatable {
        public static let productDefault = TemporaryPreservationLimits(
            maximumItemCount: 128,
            maximumRepresentationCountPerItem: 32,
            maximumTotalRepresentationCount: 256,
            maximumTypeNameUTF8ByteCount: 1_024,
            maximumRepresentationByteCount: 32 * 1_024 * 1_024,
            maximumItemByteCount: 48 * 1_024 * 1_024,
            maximumTotalByteCount: 64 * 1_024 * 1_024,
            maximumMetadataByteCount: 4 * 1_024,
            maximumMetadataCaptureTagCount: 16
        )

        public var maximumItemCount: Int
        public var maximumRepresentationCountPerItem: Int
        public var maximumTotalRepresentationCount: Int
        public var maximumTypeNameUTF8ByteCount: Int
        public var maximumRepresentationByteCount: Int
        public var maximumItemByteCount: Int
        public var maximumTotalByteCount: Int
        public var maximumMetadataByteCount: Int
        public var maximumMetadataCaptureTagCount: Int

        public init(
            maximumItemCount: Int,
            maximumRepresentationCountPerItem: Int,
            maximumTotalRepresentationCount: Int,
            maximumTypeNameUTF8ByteCount: Int,
            maximumRepresentationByteCount: Int,
            maximumItemByteCount: Int,
            maximumTotalByteCount: Int,
            maximumMetadataByteCount: Int,
            maximumMetadataCaptureTagCount: Int
        ) {
            precondition(maximumItemCount > 0)
            precondition(maximumRepresentationCountPerItem > 0)
            precondition(
                maximumTotalRepresentationCount >= maximumRepresentationCountPerItem
            )
            precondition(maximumTypeNameUTF8ByteCount > 0)
            precondition(maximumRepresentationByteCount > 0)
            precondition(maximumItemByteCount >= maximumRepresentationByteCount)
            precondition(maximumTotalByteCount >= maximumItemByteCount)
            precondition(maximumMetadataByteCount > 0)
            precondition(maximumMetadataCaptureTagCount > 0)

            self.maximumItemCount = maximumItemCount
            self.maximumRepresentationCountPerItem = maximumRepresentationCountPerItem
            self.maximumTotalRepresentationCount = maximumTotalRepresentationCount
            self.maximumTypeNameUTF8ByteCount = maximumTypeNameUTF8ByteCount
            self.maximumRepresentationByteCount = maximumRepresentationByteCount
            self.maximumItemByteCount = maximumItemByteCount
            self.maximumTotalByteCount = maximumTotalByteCount
            self.maximumMetadataByteCount = maximumMetadataByteCount
            self.maximumMetadataCaptureTagCount = maximumMetadataCaptureTagCount
        }
    }

    public enum TemporaryPreservationLimit: String, Sendable, Equatable {
        case itemCount = "item-count"
        case representationsPerItem = "representations-per-item"
        case totalRepresentationCount = "total-representation-count"
        case typeNameByteCount = "type-name-byte-count"
        case representationByteCount = "representation-byte-count"
        case itemByteCount = "item-byte-count"
        case totalByteCount = "total-byte-count"
    }

    public enum ConditionalWriteError: Error, Sendable, Equatable {
        case protectedClipboard([SystemClipboardProtection])
        case changeCountChanged
        case unreadableRepresentation(itemIndex: Int, typeName: String)
        case preservationLimitExceeded(TemporaryPreservationLimit)
    }

    public enum TemporaryRestoreOutcome: Sendable, Equatable {
        case restored
        case skippedChangeCount
        /// The restore write changed the pasteboard but could not be verified
        /// representation-for-representation. The archive remains authoritative
        /// and may be retried only while this exact change count still wins.
        case writeFailed(retryChangeCount: Int)
    }

    public struct TemporaryWriteTransaction: Sendable, Equatable {
        public let temporaryChangeCount: Int
        let preservedContents: PreservedPasteboardContents

        init(
            preservedContents: PreservedPasteboardContents,
            temporaryChangeCount: Int
        ) {
            self.preservedContents = preservedContents
            self.temporaryChangeCount = temporaryChangeCount
        }
    }

    /// A transaction-only archive of every pasteboard item representation.
    /// SystemClipboardSnapshot intentionally remains a policy/history projection and
    /// must not become responsible for preserving arbitrary application data.
    struct PreservedPasteboardContents: Sendable, Equatable {
        struct Item: Sendable, Equatable {
            struct Representation: Sendable, Equatable {
                let typeName: String
                let data: Data
            }

            let representations: [Representation]
        }

        let items: [Item]
    }

    private struct PasteboardMetadata: Codable {
        var captureTags: [SystemClipboardCaptureTag]
        var writerInstanceID: UUID?
    }

    private static let metadataType = NSPasteboard.PasteboardType("dev.rill.metadata")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    private let pasteboard: NSPasteboard
    private let storageLimits: SystemClipboardStorageLimits
    private let temporaryPreservationLimits: TemporaryPreservationLimits
    private let imageProcessingGate: (@Sendable () async -> Void)?
    private let writerInstanceID = UUID()
    private var ownedChangeCounts: [Int: Date] = [:]
    private var imageProcessingFlight: ImageProcessingFlight?

    public convenience init() {
        self.init(
            pasteboard: .general,
            storageLimits: .productDefault,
            temporaryPreservationLimits: .productDefault,
            imageProcessingGate: nil
        )
    }

    init(
        pasteboard: NSPasteboard,
        storageLimits: SystemClipboardStorageLimits = .productDefault,
        temporaryPreservationLimits: TemporaryPreservationLimits = .productDefault,
        imageProcessingGate: (@Sendable () async -> Void)? = nil
    ) {
        self.pasteboard = pasteboard
        self.storageLimits = storageLimits
        self.temporaryPreservationLimits = temporaryPreservationLimits
        self.imageProcessingGate = imageProcessingGate
    }

    public func currentSnapshot() async -> SystemClipboardSnapshot {
        let descriptor = currentDescriptor()
        if let snapshot = await readSnapshot(ifChangeCountIs: descriptor.changeCount) {
            return snapshot
        }

        let retryDescriptor = currentDescriptor()
        return await readSnapshot(ifChangeCountIs: retryDescriptor.changeCount)
            ?? retryDescriptor.policySnapshot
    }

    public func privacySafeSnapshot() async -> SystemClipboardSnapshot {
        let descriptor = currentDescriptor()
        guard descriptor.protections.isEmpty else {
            return descriptor.policySnapshot
        }
        return await readSnapshot(ifChangeCountIs: descriptor.changeCount)
            ?? descriptor.policySnapshot
    }

    public func currentChangeCount() -> Int {
        pasteboard.changeCount
    }

    public func currentDescriptor() -> SystemClipboardDescriptor {
        let availableTypes = Set(pasteboard.types ?? [])
        return SystemClipboardDescriptor(
            hasPlainText: availableTypes.contains(.string),
            hasImage: availableTypes.contains(.png) || availableTypes.contains(.tiff),
            hasFiles: availableTypes.contains(.fileURL),
            changeCount: pasteboard.changeCount,
            captureTags: Self.captureTags(
                from: pasteboard,
                limits: temporaryPreservationLimits
            ),
            protections: Self.protections(
                forPasteboardTypeNames: Set(availableTypes.map(\.rawValue))
            )
        )
    }

    public func readSnapshot(ifChangeCountIs expected: Int) async -> SystemClipboardSnapshot? {
        guard pasteboard.changeCount == expected else { return nil }
        let availableTypes = Set(pasteboard.types ?? [])
        let fileReadResult = Self.fileURLReadResult(
            from: pasteboard,
            availableTypes: availableTypes,
            limits: storageLimits
        )
        let captureTags = Self.captureTags(
            from: pasteboard,
            limits: temporaryPreservationLimits
        )
        let protections = Self.protections(
            forPasteboardTypeNames: Set(availableTypes.map(\.rawValue))
        )
        let textReadResult = Self.plainTextReadResult(
            from: pasteboard,
            availableTypes: availableTypes,
            limits: storageLimits
        )
        guard pasteboard.changeCount == expected else { return nil }
        guard let imageReadResult = await imageReadResult(
            ifChangeCountIs: expected,
            availableTypes: availableTypes
        ) else {
            return nil
        }
        guard pasteboard.changeCount == expected else { return nil }
        let captureStorageRejection = textReadResult.text.isEmpty
            && fileReadResult.urls.isEmpty
            && imageReadResult.data == nil
            ? fileReadResult.rejection
                ?? imageReadResult.rejection
                ?? textReadResult.rejection
            : nil
        return SystemClipboardSnapshot(
            plainText: textReadResult.text,
            imagePNGData: imageReadResult.data,
            fileURLs: fileReadResult.urls,
            changeCount: expected,
            captureTags: captureTags,
            protections: protections,
            captureStorageRejection: captureStorageRejection
        )
    }

    @discardableResult
    public func writePlainText(
        _ text: String,
        captureTags: [SystemClipboardCaptureTag] = []
    ) -> Int {
        writeSnapshot(
            SystemClipboardSnapshot(plainText: text, changeCount: 0),
            captureTags: captureTags
        )
    }

    @discardableResult
    public func writeSnapshot(
        _ snapshot: SystemClipboardSnapshot,
        captureTags: [SystemClipboardCaptureTag]? = nil
    ) -> Int {
        let snapshotToWrite = captureTags.map { snapshot.appendingCaptureTags($0) } ?? snapshot
        Self.writeContents(
            of: snapshotToWrite,
            to: pasteboard,
            writerInstanceID: writerInstanceID,
            limits: temporaryPreservationLimits
        )
        let changeCount = pasteboard.changeCount
        markOwnedChangeCount(changeCount)
        return changeCount
    }

    /// Conditionally replaces the pasteboard while retaining an exact archive
    /// to restore. Descriptor/protection checks, payload capture, the final
    /// change-count check, and the write run synchronously on MainActor without
    /// an application-level suspension point.
    ///
    /// NSPasteboard does not expose a cross-process compare-and-swap primitive,
    /// so another process can still race the final check at the OS boundary.
    /// The change count makes such races fail closed whenever macOS publishes
    /// the external change before this method's final check.
    public func beginTemporaryWrite(
        _ replacement: SystemClipboardSnapshot,
        ifChangeCountIs expectedChangeCount: Int,
        captureTags: [SystemClipboardCaptureTag]? = nil
    ) throws -> TemporaryWriteTransaction {
        let descriptor = currentDescriptor()
        guard descriptor.protections.isEmpty else {
            throw ConditionalWriteError.protectedClipboard(descriptor.protections)
        }
        guard descriptor.changeCount == expectedChangeCount else {
            throw ConditionalWriteError.changeCountChanged
        }
        let preservedContents = try preserveContents(ifChangeCountIs: expectedChangeCount)
        guard pasteboard.changeCount == expectedChangeCount else {
            throw ConditionalWriteError.changeCountChanged
        }

        let temporaryChangeCount = writeSnapshot(
            replacement,
            captureTags: captureTags
        )
        return TemporaryWriteTransaction(
            preservedContents: preservedContents,
            temporaryChangeCount: temporaryChangeCount
        )
    }

    /// Performs the same synchronous protection/change-count gate for callers
    /// that already hold an authorized preserved snapshot.
    @discardableResult
    public func writeSnapshot(
        _ snapshot: SystemClipboardSnapshot,
        ifChangeCountIs expectedChangeCount: Int
    ) -> Int? {
        let descriptor = currentDescriptor()
        guard descriptor.protections.isEmpty,
              descriptor.changeCount == expectedChangeCount,
              pasteboard.changeCount == expectedChangeCount
        else {
            return nil
        }
        return writeSnapshot(snapshot)
    }

    public func restore(_ snapshot: SystemClipboardSnapshot, ifChangeCountIs expected: Int) -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        Self.writeContents(
            of: snapshot,
            to: pasteboard,
            writerInstanceID: writerInstanceID,
            limits: temporaryPreservationLimits
        )
        let restoredChangeCount = pasteboard.changeCount
        markOwnedChangeCount(restoredChangeCount)
        return true
    }

    /// Restores the exact item/type/data layout captured by beginTemporaryWrite.
    /// An external clipboard change always wins and is never overwritten.
    public func restore(_ transaction: TemporaryWriteTransaction) -> TemporaryRestoreOutcome {
        restore(transaction, ifChangeCountIs: transaction.temporaryChangeCount)
    }

    /// Restores a transaction after the temporary representation has been
    /// replaced by another Rill-owned preview. The caller must supply the
    /// exact current change count; an external clipboard write still wins.
    public func restore(
        _ transaction: TemporaryWriteTransaction,
        ifChangeCountIs expectedChangeCount: Int
    ) -> TemporaryRestoreOutcome {
        guard pasteboard.changeCount == expectedChangeCount else {
            return .skippedChangeCount
        }

        let wroteContents = Self.writeContents(
            transaction.preservedContents,
            to: pasteboard
        )
        let restoredChangeCount = pasteboard.changeCount
        guard wroteContents else {
            return .writeFailed(retryChangeCount: restoredChangeCount)
        }
        do {
            guard try contentsMatch(
                transaction.preservedContents,
                ifChangeCountIs: restoredChangeCount
            ) else {
                return .writeFailed(retryChangeCount: restoredChangeCount)
            }
        } catch ConditionalWriteError.changeCountChanged {
            // A writer changed the pasteboard while exact verification was in
            // progress. That external value is the explicit winner and must
            // never be replaced by a retry.
            return .skippedChangeCount
        } catch {
            return .writeFailed(retryChangeCount: restoredChangeCount)
        }
        markOwnedChangeCount(restoredChangeCount)
        return .restored
    }

    public func isOwnedChangeCount(_ changeCount: Int) -> Bool {
        if pasteboard.changeCount == changeCount,
           Self.writerInstanceID(
               from: pasteboard,
               limits: temporaryPreservationLimits
           ) == writerInstanceID {
            return true
        }
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

    private static func writeContents(
        of snapshot: SystemClipboardSnapshot,
        to pasteboard: NSPasteboard,
        writerInstanceID: UUID,
        limits: TemporaryPreservationLimits
    ) {
        pasteboard.clearContents()
        if !snapshot.plainText.isEmpty {
            pasteboard.setString(snapshot.plainText, forType: .string)
        }
        if !snapshot.fileURLs.isEmpty {
            _ = pasteboard.writeObjects(snapshot.fileURLs as [NSURL])
        }
        if let imagePNGData = snapshot.imagePNGData {
            pasteboard.setData(imagePNGData, forType: .png)
        }
        if snapshot.protections.contains(.concealed) {
            pasteboard.setData(Data(), forType: concealedType)
        }
        if snapshot.protections.contains(.transient) {
            pasteboard.setData(Data(), forType: transientType)
        }
        if snapshot.protections.contains(.autoGenerated) {
            pasteboard.setData(Data(), forType: autoGeneratedType)
        }
        let metadata = encodedMetadata(
            for: snapshot.captureTags,
            writerInstanceID: writerInstanceID,
            limits: limits
        )
        pasteboard.setData(metadata, forType: metadataType)
    }

    private func preserveContents(
        ifChangeCountIs expectedChangeCount: Int
    ) throws -> PreservedPasteboardContents {
        guard pasteboard.changeCount == expectedChangeCount else {
            throw ConditionalWriteError.changeCountChanged
        }

        let pasteboardItems = pasteboard.pasteboardItems ?? []
        guard pasteboardItems.count <= temporaryPreservationLimits.maximumItemCount else {
            throw ConditionalWriteError.preservationLimitExceeded(.itemCount)
        }

        var totalRepresentationCount = 0
        var totalByteCount = 0
        var archivedItems: [PreservedPasteboardContents.Item] = []
        archivedItems.reserveCapacity(pasteboardItems.count)

        for (itemIndex, item) in pasteboardItems.enumerated() {
            let types = item.types
            guard types.count <= temporaryPreservationLimits.maximumRepresentationCountPerItem else {
                throw ConditionalWriteError.preservationLimitExceeded(.representationsPerItem)
            }
            let (nextRepresentationCount, representationCountOverflow) =
                totalRepresentationCount.addingReportingOverflow(types.count)
            guard !representationCountOverflow,
                  nextRepresentationCount
                    <= temporaryPreservationLimits.maximumTotalRepresentationCount else {
                throw ConditionalWriteError.preservationLimitExceeded(.totalRepresentationCount)
            }
            totalRepresentationCount = nextRepresentationCount

            var itemByteCount = 0
            var representations: [PreservedPasteboardContents.Item.Representation] = []
            representations.reserveCapacity(types.count)
            for type in types {
                guard pasteboard.changeCount == expectedChangeCount else {
                    throw ConditionalWriteError.changeCountChanged
                }
                guard type.rawValue.utf8.count
                    <= temporaryPreservationLimits.maximumTypeNameUTF8ByteCount else {
                    throw ConditionalWriteError.preservationLimitExceeded(.typeNameByteCount)
                }
                // NSPasteboardItem exposes neither a byte-count probe nor a
                // streaming read. Validate immediately after materializing
                // each representation so an over-budget value is released
                // instead of being accumulated into the transaction archive.
                guard let data = item.data(forType: type) else {
                    throw ConditionalWriteError.unreadableRepresentation(
                        itemIndex: itemIndex,
                        typeName: type.rawValue
                    )
                }
                guard data.count
                    <= temporaryPreservationLimits.maximumRepresentationByteCount else {
                    throw ConditionalWriteError.preservationLimitExceeded(
                        .representationByteCount
                    )
                }
                let (nextItemByteCount, itemByteCountOverflow) =
                    itemByteCount.addingReportingOverflow(data.count)
                guard !itemByteCountOverflow,
                      nextItemByteCount <= temporaryPreservationLimits.maximumItemByteCount else {
                    throw ConditionalWriteError.preservationLimitExceeded(.itemByteCount)
                }
                let (nextTotalByteCount, totalByteCountOverflow) =
                    totalByteCount.addingReportingOverflow(data.count)
                guard !totalByteCountOverflow,
                      nextTotalByteCount <= temporaryPreservationLimits.maximumTotalByteCount else {
                    throw ConditionalWriteError.preservationLimitExceeded(.totalByteCount)
                }
                itemByteCount = nextItemByteCount
                totalByteCount = nextTotalByteCount
                representations.append(PreservedPasteboardContents.Item.Representation(
                    typeName: type.rawValue,
                    data: data
                ))
            }
            archivedItems.append(PreservedPasteboardContents.Item(
                representations: representations
            ))
        }

        guard pasteboard.changeCount == expectedChangeCount else {
            throw ConditionalWriteError.changeCountChanged
        }
        return PreservedPasteboardContents(items: archivedItems)
    }

    /// Verifies a restored transaction one representation at a time. Keeping
    /// a second complete archive here would double the transaction's bounded
    /// memory footprint at the exact point where the original archive is
    /// necessarily still alive.
    private func contentsMatch(
        _ expectedContents: PreservedPasteboardContents,
        ifChangeCountIs expectedChangeCount: Int
    ) throws -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else {
            throw ConditionalWriteError.changeCountChanged
        }
        let actualItems = pasteboard.pasteboardItems ?? []
        guard actualItems.count == expectedContents.items.count else {
            return false
        }
        for (itemIndex, pair) in zip(actualItems, expectedContents.items).enumerated() {
            let (actualItem, expectedItem) = pair
            let actualTypes = actualItem.types
            guard actualTypes.map(\.rawValue)
                == expectedItem.representations.map(\.typeName) else {
                return false
            }
            for (type, expectedRepresentation) in zip(
                actualTypes,
                expectedItem.representations
            ) {
                guard pasteboard.changeCount == expectedChangeCount else {
                    throw ConditionalWriteError.changeCountChanged
                }
                guard let actualData = actualItem.data(forType: type) else {
                    throw ConditionalWriteError.unreadableRepresentation(
                        itemIndex: itemIndex,
                        typeName: type.rawValue
                    )
                }
                guard actualData == expectedRepresentation.data else {
                    return false
                }
            }
        }
        guard pasteboard.changeCount == expectedChangeCount else {
            throw ConditionalWriteError.changeCountChanged
        }
        return true
    }

    private static func writeContents(
        _ contents: PreservedPasteboardContents,
        to pasteboard: NSPasteboard
    ) -> Bool {
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(contents.items.count)
        for archivedItem in contents.items {
            let item = NSPasteboardItem()
            for representation in archivedItem.representations {
                guard item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.typeName)
                ) else {
                    // Materialize the complete replacement before touching the
                    // system pasteboard. A type the process cannot recreate
                    // must fail closed while the temporary contents are still
                    // present.
                    return false
                }
            }
            items.append(item)
        }

        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        return pasteboard.writeObjects(items)
    }

    static func protections(forPasteboardTypeNames typeNames: Set<String>) -> [SystemClipboardProtection] {
        var protections: [SystemClipboardProtection] = []
        if typeNames.contains(concealedType.rawValue) {
            protections.append(.concealed)
        }
        if typeNames.contains(transientType.rawValue) {
            protections.append(.transient)
        }
        if typeNames.contains(autoGeneratedType.rawValue) {
            protections.append(.autoGenerated)
        }
        return protections
    }

    private struct ImageReadResult: Sendable {
        let data: Data?
        let rejection: SystemClipboardStorageRejectionReason?
    }

    private struct PlainTextReadResult {
        let text: String
        let rejection: SystemClipboardStorageRejectionReason?
    }

    private struct FileURLReadResult {
        let urls: [URL]
        let rejection: SystemClipboardStorageRejectionReason?
    }

    private struct ImageProcessingFlight {
        let id: UUID
        let changeCount: Int
        let task: Task<PasteboardImageIngress.Result, Never>
    }

    private static func plainTextReadResult(
        from pasteboard: NSPasteboard,
        availableTypes: Set<NSPasteboard.PasteboardType>,
        limits: SystemClipboardStorageLimits
    ) -> PlainTextReadResult {
        guard availableTypes.contains(.string),
              let text = pasteboard.string(forType: .string) else {
            return PlainTextReadResult(text: "", rejection: nil)
        }
        guard text.utf8.count <= limits.maximumTextUTF8ByteCount else {
            return PlainTextReadResult(text: "", rejection: .itemTooLarge)
        }
        return PlainTextReadResult(text: text, rejection: nil)
    }

    private static func fileURLReadResult(
        from pasteboard: NSPasteboard,
        availableTypes: Set<NSPasteboard.PasteboardType>,
        limits: SystemClipboardStorageLimits
    ) -> FileURLReadResult {
        guard availableTypes.contains(.fileURL) else {
            return FileURLReadResult(urls: [], rejection: nil)
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard urls.count <= limits.maximumFileURLCount else {
            return FileURLReadResult(urls: [], rejection: .itemTooLarge)
        }
        var totalUTF8ByteCount = 0
        for url in urls {
            let byteCount = url.absoluteString.utf8.count
            guard byteCount <= limits.maximumFileURLUTF8ByteCount else {
                return FileURLReadResult(urls: [], rejection: .itemTooLarge)
            }
            let (nextTotal, overflowed) = totalUTF8ByteCount.addingReportingOverflow(byteCount)
            guard !overflowed,
                  nextTotal <= limits.maximumTotalFileURLUTF8ByteCount else {
                return FileURLReadResult(urls: [], rejection: .itemTooLarge)
            }
            totalUTF8ByteCount = nextTotal
        }
        return FileURLReadResult(urls: urls, rejection: nil)
    }

    private enum PendingImageRead: Sendable {
        case none
        case rejected(SystemClipboardStorageRejectionReason)
        case unprocessed(data: Data, declaredFormat: PasteboardImageIngress.DeclaredFormat)
    }

    /// Captures the AppKit-owned representation while still on MainActor.
    /// No ImageIO work is permitted in this phase.
    private static func pendingImageRead(
        from pasteboard: NSPasteboard,
        availableTypes: Set<NSPasteboard.PasteboardType>
    ) -> PendingImageRead {
        if availableTypes.contains(.png) {
            guard let pngData = pasteboard.data(forType: .png) else {
                return .rejected(.imageRepresentationInvalid)
            }
            return .unprocessed(data: pngData, declaredFormat: .png)
        }
        guard availableTypes.contains(.tiff) else {
            return .none
        }
        guard let tiffData = pasteboard.data(forType: .tiff) else {
            return .rejected(.imageRepresentationInvalid)
        }
        return .unprocessed(data: tiffData, declaredFormat: .tiff)
    }

    /// Serializes ImageIO work for this controller. Concurrent reads of one
    /// pasteboard generation share a flight, while a newer generation waits
    /// for the old worker before its AppKit-owned representation is copied.
    /// Completed flights are cleared immediately rather than becoming a cache
    /// that could retain an obsolete large image.
    private func imageReadResult(
        ifChangeCountIs expected: Int,
        availableTypes: Set<NSPasteboard.PasteboardType>
    ) async -> ImageReadResult? {
        guard !availableTypes.contains(.fileURL),
              availableTypes.contains(.png) || availableTypes.contains(.tiff) else {
            return ImageReadResult(data: nil, rejection: nil)
        }

        while let flight = imageProcessingFlight {
            let result = Self.imageReadResult(from: await flight.task.value)
            if imageProcessingFlight?.id == flight.id {
                imageProcessingFlight = nil
            }
            guard pasteboard.changeCount == expected else { return nil }
            if flight.changeCount == expected {
                return result
            }
        }

        guard pasteboard.changeCount == expected else { return nil }
        let pendingRead = Self.pendingImageRead(
            from: pasteboard,
            availableTypes: availableTypes
        )
        guard pasteboard.changeCount == expected else { return nil }

        switch pendingRead {
        case .none:
            return ImageReadResult(data: nil, rejection: nil)
        case .rejected(let reason):
            return ImageReadResult(data: nil, rejection: reason)
        case .unprocessed(let data, let declaredFormat):
            let gate = imageProcessingGate
            let limits = storageLimits
            let id = UUID()
            let task = Task.detached(priority: .userInitiated) {
                if let gate {
                    await gate()
                }
                return PasteboardImageIngress.normalizedPNGData(
                    from: data,
                    declaredFormat: declaredFormat,
                    limits: limits
                )
            }
            imageProcessingFlight = ImageProcessingFlight(
                id: id,
                changeCount: expected,
                task: task
            )
            let result = Self.imageReadResult(from: await task.value)
            if imageProcessingFlight?.id == id {
                imageProcessingFlight = nil
            }
            guard pasteboard.changeCount == expected else { return nil }
            return result
        }
    }

    private static func imageReadResult(
        from result: PasteboardImageIngress.Result
    ) -> ImageReadResult {
        switch result {
        case .accepted(let data):
            return ImageReadResult(data: data, rejection: nil)
        case .rejected(let reason):
            return ImageReadResult(data: nil, rejection: reason)
        }
    }

    private static func captureTags(
        from pasteboard: NSPasteboard,
        limits: TemporaryPreservationLimits
    ) -> [SystemClipboardCaptureTag] {
        decodedMetadata(from: pasteboard, limits: limits)?.captureTags ?? []
    }

    private static func writerInstanceID(
        from pasteboard: NSPasteboard,
        limits: TemporaryPreservationLimits
    ) -> UUID? {
        decodedMetadata(from: pasteboard, limits: limits)?.writerInstanceID
    }

    private static func decodedMetadata(
        from pasteboard: NSPasteboard,
        limits: TemporaryPreservationLimits
    ) -> PasteboardMetadata? {
        guard let data = pasteboard.data(forType: metadataType),
              data.count <= limits.maximumMetadataByteCount,
              let metadata = try? JSONDecoder().decode(PasteboardMetadata.self, from: data),
              metadata.captureTags.count <= limits.maximumMetadataCaptureTagCount else {
            return nil
        }
        return metadata
    }

    private static func encodedMetadata(
        for captureTags: [SystemClipboardCaptureTag],
        writerInstanceID: UUID,
        limits: TemporaryPreservationLimits
    ) -> Data {
        let metadata = PasteboardMetadata(
            captureTags: Array(
                captureTags.prefix(limits.maximumMetadataCaptureTagCount)
            ),
            writerInstanceID: writerInstanceID
        )
        guard let data = try? JSONEncoder().encode(metadata),
              data.count <= limits.maximumMetadataByteCount else {
            return Data()
        }
        return data
    }
}

/// Conservative decoded workspace accounting for ImageIO normalization.
/// kCGImagePropertyDepth is the bit depth of each color sample, not the total
/// bytes per pixel. Four samples cover RGB plus alpha, while the 16-byte floor
/// also reserves room for expanded or floating-point decode workspaces.
enum PasteboardImageBudget {
    static let minimumWorkspaceByteCountPerPixel: UInt64 = 16
    private static let conservativeColorSampleCount: UInt64 = 4

    static func decodedWorkspaceByteCount(
        width: UInt64,
        height: UInt64,
        depthBitsPerSample: UInt64
    ) -> UInt64? {
        guard width > 0, height > 0, depthBitsPerSample > 0 else {
            return nil
        }
        let (roundedDepth, depthOverflow) = depthBitsPerSample.addingReportingOverflow(7)
        guard !depthOverflow else { return nil }
        let byteCountPerSample = roundedDepth / 8
        let (declaredByteCountPerPixel, sampleOverflow) =
            byteCountPerSample.multipliedReportingOverflow(
                by: conservativeColorSampleCount
            )
        guard !sampleOverflow else { return nil }
        let workspaceByteCountPerPixel = max(
            declaredByteCountPerPixel,
            minimumWorkspaceByteCountPerPixel
        )
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (workspaceByteCount, workspaceOverflow) =
            pixelCount.multipliedReportingOverflow(by: workspaceByteCountPerPixel)
        guard !workspaceOverflow else { return nil }
        return workspaceByteCount
    }
}

/// A pure ImageIO boundary kept outside SystemClipboardPort's MainActor
/// isolation. Clipboard reads must remain on MainActor, but validation and
/// normalization execute in a detached task without changing the policy or
/// result model here.
private enum PasteboardImageIngress {
    enum DeclaredFormat: Sendable {
        case png
        case tiff

        var typeIdentifier: String {
            switch self {
            case .png: UTType.png.identifier
            case .tiff: UTType.tiff.identifier
            }
        }
    }

    enum Result: Sendable {
        case accepted(Data)
        case rejected(SystemClipboardStorageRejectionReason)
    }

    static func normalizedPNGData(
        from data: Data,
        declaredFormat: DeclaredFormat,
        limits: SystemClipboardStorageLimits
    ) -> Result {
        switch validatedSource(
            from: data,
            declaredFormat: declaredFormat,
            limits: limits
        ) {
        case .failure(let reason):
            return .rejected(reason)
        case .success(let source):
            guard declaredFormat == .tiff else {
                return .accepted(data)
            }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return .rejected(.imageRepresentationInvalid)
            }
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            guard CGImageDestinationFinalize(destination) else {
                return .rejected(.imageRepresentationInvalid)
            }
            let pngData = output as Data
            guard pngData.count <= limits.maximumImageByteCount else {
                return .rejected(.itemTooLarge)
            }
            switch validatedSource(
                from: pngData,
                declaredFormat: .png,
                limits: limits
            ) {
            case .success:
                return .accepted(pngData)
            case .failure(let reason):
                return .rejected(reason)
            }
        }
    }

    private static func validatedSource(
        from data: Data,
        declaredFormat: DeclaredFormat,
        limits: SystemClipboardStorageLimits
    ) -> Swift.Result<CGImageSource, SystemClipboardStorageRejectionReason> {
        guard data.count <= limits.maximumImageByteCount else {
            return .failure(.itemTooLarge)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              (CGImageSourceGetType(source) as String?)
                == declaredFormat.typeIdentifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value,
              width > 0,
              height > 0 else {
            return .failure(.imageRepresentationInvalid)
        }
        let depthBitsPerSample =
            (properties[kCGImagePropertyDepth] as? NSNumber)?.uint64Value ?? 8
        guard limits.maximumDecodedImageByteCount > 0,
              let decodedWorkspaceByteCount =
            PasteboardImageBudget.decodedWorkspaceByteCount(
                width: width,
                height: height,
                depthBitsPerSample: depthBitsPerSample
            ),
              decodedWorkspaceByteCount <= UInt64(limits.maximumDecodedImageByteCount) else {
            return .failure(.itemTooLarge)
        }
        return .success(source)
    }
}
