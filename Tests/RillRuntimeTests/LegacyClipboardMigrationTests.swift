import Foundation
import XCTest

@testable import RillCore
@testable import RillRuntime

final class LegacyClipboardMigrationTests: XCTestCase {
    func testTextImageFilesModesMetadataActivityAndRoutesMigrateDeterministically() throws {
        let customID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let textID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        let imageID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let filesID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000003")!
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let items = [
            LegacyClipboardMigration.LegacyItem(
                id: textID,
                groupID: RecordCollection.inboxID.rawValue,
                text: "text",
                createdAt: baseDate,
                sourceKind: .system,
                sourceApplicationName: "Source",
                sourceBundleIdentifier: "dev.rill.source",
                latestError: "private failure detail",
                useCount: 4,
                lastUsedAt: baseDate.addingTimeInterval(5),
                tags: ["alpha"],
                isPinned: true
            ),
            LegacyClipboardMigration.LegacyItem(
                id: imageID,
                groupID: customID,
                contentKind: .image,
                text: "",
                imagePNGData: Data([1, 2, 3]),
                createdAt: baseDate.addingTimeInterval(1),
                sourceKind: .system
            ),
            LegacyClipboardMigration.LegacyItem(
                id: filesID,
                groupID: RecordCollection.voiceInputID.rawValue,
                contentKind: .files,
                text: "",
                fileURLs: [URL(fileURLWithPath: "/tmp/example.txt")],
                createdAt: baseDate.addingTimeInterval(2),
                sourceKind: .rillWorkflow
            ),
        ]
        let custom = LegacyClipboardMigration.LegacyGroup(
            id: customID,
            name: "Queue Collection",
            mode: .queue,
            allowsCrossGroupPaste: true,
            fallbackPriority: 2,
            createdAt: baseDate
        )
        let state = LegacyFixtureState(
            schemaVersion: 7,
            items: items,
            groups: [custom],
            groupEntries: [
                LegacyFixtureGroupEntry(groupID: customID, itemIDs: []),
                LegacyFixtureGroupEntry(groupID: RecordCollection.voiceInputID.rawValue, itemIDs: [filesID]),
            ],
            defaultGroupEntries: [textID],
            defaultGroupMode: .list,
            appAssignments: [
                LegacyClipboardMigration.LegacyAppAssignment(
                    bundleIdentifier: "dev.rill.target",
                    applicationName: "Target",
                    groupID: customID,
                    updatedAt: baseDate
                )
            ]
        )

        let migrated = try LegacyClipboardMigration.decodeAndMigrate(
            metadata: try JSONEncoder().encode(state),
            imageBlobs: []
        )

        XCTAssertEqual(migrated.records.map(\.id), items.map { RecordID($0.id) })
        XCTAssertEqual(migrated.records.map(\.payload), [
            .text("text"),
            .image(Data([1, 2, 3])),
            .files([URL(fileURLWithPath: "/tmp/example.txt")]),
        ])
        XCTAssertEqual(migrated.metadata.first?.tags, ["alpha"])
        XCTAssertEqual(migrated.metadata.first?.isPinned, true)
        XCTAssertEqual(migrated.activity.first?.useCount, 4)
        XCTAssertEqual(migrated.activity.first?.latestFailure, .deliveryFailed)
        XCTAssertEqual(
            migrated.collections.first(where: { $0.id == RecordCollection.inboxID })?.matchingPreset,
            .list
        )
        XCTAssertEqual(
            migrated.collections.first(where: { $0.id == RecordCollectionID(customID) })?.matchingPreset,
            .queue
        )
        XCTAssertEqual(
            migrated.memberships.map(\.id),
            items.map { RecordMembershipID($0.id) }
        )
        XCTAssertEqual(
            migrated.memberships.first(where: { $0.recordID == RecordID(imageID) })?.state,
            .consumed
        )
        XCTAssertEqual(migrated.captureRules.first?.destinationCollectionIDs, [RecordCollectionID(customID)])
        XCTAssertEqual(
            migrated.deliveryRules.first?.sourceCollectionIDs,
            [RecordCollectionID(customID), RecordCollection.voiceInputID]
        )
        XCTAssertEqual(migrated.deliveryRules.first?.sink, .focusedApplication)
    }

    func testSchema8MissingOrMismatchedBlobFailsBeforeGraphInstallation() throws {
        let itemID = UUID()
        let blobID = UUID()
        let item = LegacyClipboardMigration.LegacyItem(
            id: itemID,
            groupID: RecordCollection.inboxID.rawValue,
            contentKind: .image,
            text: "",
            createdAt: Date(timeIntervalSince1970: 1),
            sourceKind: .system
        )
        let state = LegacyFixtureBlobState(
            schemaVersion: 8,
            items: [
                LegacyFixtureItemEntry(
                    metadata: item,
                    imageBlob: LegacyFixtureBlobReference(blobID: blobID, byteCount: 4)
                )
            ],
            groups: [],
            groupEntries: [],
            defaultGroupEntries: [itemID],
            defaultGroupMode: .stack,
            appAssignments: []
        )

        XCTAssertThrowsError(
            try LegacyClipboardMigration.decodeAndMigrate(
                metadata: JSONEncoder().encode(state),
                imageBlobs: []
            )
        )

        let wrongBlob = LegacyRecordGraphImageBlob(
            reference: LegacyRecordGraphBlobReference(
                blobID: blobID,
                itemID: itemID,
                byteCount: 3
            ),
            payload: Data([1, 2, 3])
        )
        XCTAssertThrowsError(
            try LegacyClipboardMigration.decodeAndMigrate(
                metadata: JSONEncoder().encode(state),
                imageBlobs: [wrongBlob]
            )
        )
    }
}

private struct LegacyFixtureState: Encodable {
    var schemaVersion: Int
    var items: [LegacyClipboardMigration.LegacyItem]
    var groups: [LegacyClipboardMigration.LegacyGroup]
    var groupEntries: [LegacyFixtureGroupEntry]
    var defaultGroupEntries: [UUID]
    var defaultGroupMode: LegacyClipboardMigration.LegacyPasteMode
    var appAssignments: [LegacyClipboardMigration.LegacyAppAssignment]
}

private struct LegacyFixtureBlobState: Encodable {
    var schemaVersion: Int
    var items: [LegacyFixtureItemEntry]
    var groups: [LegacyClipboardMigration.LegacyGroup]
    var groupEntries: [LegacyFixtureGroupEntry]
    var defaultGroupEntries: [UUID]
    var defaultGroupMode: LegacyClipboardMigration.LegacyPasteMode
    var appAssignments: [LegacyClipboardMigration.LegacyAppAssignment]
}

private struct LegacyFixtureItemEntry: Encodable {
    var metadata: LegacyClipboardMigration.LegacyItem
    var imageBlob: LegacyFixtureBlobReference?
}

private struct LegacyFixtureBlobReference: Encodable {
    var blobID: UUID
    var byteCount: Int
}

private struct LegacyFixtureGroupEntry: Encodable {
    var groupID: UUID
    var itemIDs: [UUID]
}
