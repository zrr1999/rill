import Foundation
import XCTest

@testable import RillCore
@testable import RillRecords
@testable import RillWorkflows

final class RecordStoreTests: XCTestCase {
    func testTextCorrectionPreservesOriginalAndCannotTriggerCollectionDelivery() async throws {
        let store = RecordStore()
        let runID = UUID()
        let original = try await store.ingest(RecordDraft(payload: .text("original"), provenance:
            RecordProvenance(source: .init(kind: .voiceInput), workflowRunID: runID)),
            into: [RecordCollection.inboxID])
        let operationID = UUID()
        let correction = try await store.saveTextCorrection(
            workflowRunID: runID, text: "corrected", operationID: operationID)
        XCTAssertEqual(correction.record.provenance.derivedFrom, original.id)
        XCTAssertNil(correction.record.provenance.supersedes)
        XCTAssertEqual(correction.record.payload.textValue, "corrected")
        XCTAssertTrue(correction.memberships.isEmpty)
        let unchanged = try await store.record(id: original.id)
        XCTAssertEqual(unchanged, original)
        let retry = try await store.saveTextCorrection(
            workflowRunID: runID, text: "corrected", operationID: operationID)
        XCTAssertEqual(retry.id, correction.id)
        let all = try await store.snapshot()
        XCTAssertEqual(all.records.count, 2)
    }

    func testTextCorrectionFailureRollsBackAndMissingOriginalIsNotRecreated() async throws {
        let persistence = FailingRecordGraphPersistence()
        let store = RecordStore(persistence: persistence)
        let runID = UUID()
        let original = try await store.ingest(RecordDraft(payload: .text("original"), provenance:
            RecordProvenance(source: .init(kind: .voiceInput), workflowRunID: runID)), into: [])
        let before = try await store.snapshot()
        await persistence.rejectWrites()
        do {
            _ = try await store.saveTextCorrection(workflowRunID: runID, text: "edit", operationID: UUID())
            XCTFail("Correction must require a successful commit")
        } catch let error as RecordStoreError { XCTAssertEqual(error, .persistenceUnavailable) }
        let failed = try await store.snapshot()
        XCTAssertEqual(failed, before)
        await persistence.allowWrites()
        try await store.deleteRecord(original.id)
        do {
            _ = try await store.saveTextCorrection(workflowRunID: runID, text: "edit", operationID: UUID())
            XCTFail("A deleted source must not be restored by a stale editor")
        } catch let error as RecordStoreError { XCTAssertEqual(error, .recordUnavailable) }
    }

    func testOneCaptureCreatesOneRecordWithMultipleMemberships() async throws {
        let store = RecordStore()
        let second = try await store.createCollection(named: "Second", preset: .queue)
        let projection = try await store.ingest(
            draft("one"),
            into: [RecordCollection.inboxID, second.id, RecordCollection.inboxID]
        )

        XCTAssertEqual(projection.memberships.count, 2)
        XCTAssertEqual(
            Set(projection.memberships.map(\.collectionID)),
            [
                RecordCollection.inboxID,
                second.id,
            ])
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, 1)
    }

    func testIdenticalPayloadReusesEarliestRecord() async throws {
        let store = RecordStore()
        let first = try await store.ingest(draft("same"), into: [RecordCollection.inboxID])
        let otherProvenance = RecordDraft(
            payload: .text("same"),
            provenance: RecordProvenance(
                source: RecordSourceIdentity(kind: .voiceInput),
                sourceBundleIdentifier: "com.example.other"
            )
        )
        let again = try await store.ingest(otherProvenance, into: [RecordCollection.inboxID])
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.record.provenance, first.record.provenance)
        XCTAssertEqual(again.record.createdAt, first.record.createdAt)
        XCTAssertEqual(again.memberships.map(\.ordinal), first.memberships.map(\.ordinal))
        XCTAssertEqual(again.memberships.map(\.revision), first.memberships.map(\.revision))

        let other = try await store.createCollection(named: "Other", preset: .list)
        let added = try await store.ingest(draft("same"), into: [other.id])
        XCTAssertEqual(added.id, first.id)
        XCTAssertEqual(
            Set(added.memberships.map(\.collectionID)),
            [RecordCollection.inboxID, other.id]
        )
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [first.id])

        _ = try await store.ingest(draft("same "), into: [])
        let distinct = try await store.snapshot()
        XCTAssertEqual(distinct.records.count, 2)
    }

    func testClipboardCopiesStaySeparateFromUses() async throws {
        let store = RecordStore()
        let first = try await store.ingest(draft("same"), into: [])
        XCTAssertEqual(first.activity.copyCount, 1)
        XCTAssertEqual(first.activity.useCount, 0)

        let again = try await store.ingest(draft("same"), into: [])
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.activity.copyCount, 2)
        XCTAssertEqual(again.activity.useCount, 0)

        let voiced = try await store.ingest(
            RecordDraft(
                payload: .text("same"),
                provenance: RecordProvenance(source: RecordSourceIdentity(kind: .voiceInput))
            ),
            into: []
        )
        XCTAssertEqual(voiced.id, first.id)
        XCTAssertEqual(voiced.activity.copyCount, 2)

        let copied = try await store.beginReuse(
            RecordReuseSubject(recordID: first.id, metadataRevision: voiced.metadata.revision),
            sink: .systemClipboard
        )
        _ = try await store.completeDelivery(leaseID: copied.id)
        let copiedRecord = try await store.record(id: first.id)
        let afterCopy = try XCTUnwrap(copiedRecord)
        XCTAssertEqual(afterCopy.activity.copyCount, 3)
        XCTAssertEqual(afterCopy.activity.useCount, 0)

        let pasted = try await store.beginReuse(
            RecordReuseSubject(recordID: first.id, metadataRevision: afterCopy.metadata.revision),
            sink: .focusedApplication
        )
        _ = try await store.completeDelivery(leaseID: pasted.id)
        let usedRecord = try await store.record(id: first.id)
        let afterUse = try XCTUnwrap(usedRecord)
        XCTAssertEqual(afterUse.activity.copyCount, 3)
        XCTAssertEqual(afterUse.activity.useCount, 1)
        XCTAssertNotNil(afterUse.activity.lastDeliveredAt)
    }

    func testActivityWithoutCopyCountDecodesAsZero() throws {
        let activity = RecordActivity(recordID: RecordID(), useCount: 4, copyCount: 2)
        let encoded = try JSONEncoder().encode(activity)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var stripped = object
        stripped.removeValue(forKey: "copyCount")
        let data = try JSONSerialization.data(withJSONObject: stripped)
        let decoded = try JSONDecoder().decode(RecordActivity.self, from: data)
        XCTAssertEqual(decoded.useCount, 4)
        XCTAssertEqual(decoded.copyCount, 0)
        XCTAssertEqual(decoded.recordID, activity.recordID)
    }

    func testHistoryOnlyDuplicateDoesNotCreateAnotherRecord() async throws {
        let store = RecordStore()
        let first = try await store.ingest(draft("orphan"), into: [])
        let again = try await store.ingest(draft("orphan"), into: [])
        XCTAssertEqual(again.id, first.id)
        XCTAssertTrue(again.memberships.isEmpty)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [first.id])
    }

    func testImageAndFilePayloadsDeduplicateByExactContent() async throws {
        let store = RecordStore()
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        let firstImage = try await store.ingest(
            RecordDraft(payload: .image(image), provenance: clipboardProvenance),
            into: [RecordCollection.inboxID]
        )
        let sameImage = try await store.ingest(
            RecordDraft(payload: .image(image), provenance: clipboardProvenance),
            into: [RecordCollection.inboxID]
        )
        let otherImage = try await store.ingest(
            RecordDraft(payload: .image(image + [0x01]), provenance: clipboardProvenance),
            into: []
        )
        XCTAssertEqual(sameImage.id, firstImage.id)
        XCTAssertNotEqual(otherImage.id, firstImage.id)

        let file = URL(fileURLWithPath: "/tmp/report.txt")
        let firstFiles = try await store.ingest(
            RecordDraft(payload: .files([file]), provenance: clipboardProvenance),
            into: []
        )
        let sameFiles = try await store.ingest(
            RecordDraft(payload: .files([file]), provenance: clipboardProvenance),
            into: []
        )
        let reordered = try await store.ingest(
            RecordDraft(
                payload: .files([file, URL(fileURLWithPath: "/tmp/notes.txt")]),
                provenance: clipboardProvenance
            ),
            into: []
        )
        XCTAssertEqual(sameFiles.id, firstFiles.id)
        XCTAssertNotEqual(reordered.id, firstFiles.id)
    }

    func testConsumedMembershipReturnsToFrontOfCollection() async throws {
        let events = RecordCollectionEventProbe()
        let store = RecordStore(collectionEventSink: events)
        let first = try await store.ingest(draft("first"), into: [RecordCollection.inboxID])
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
        _ = try await store.completeDelivery(leaseID: lease.id)
        let second = try await store.ingest(draft("second"), into: [RecordCollection.inboxID])
        let eventsBeforeReuse = await events.events()
        let again = try await store.ingest(draft("first"), into: [RecordCollection.inboxID])

        XCTAssertEqual(again.id, first.id)
        let revived = try XCTUnwrap(again.memberships.first)
        let secondRecord = try await store.record(id: second.id)
        let secondMembership = try XCTUnwrap(secondRecord?.memberships.first)
        XCTAssertEqual(revived.state, .active)
        XCTAssertGreaterThan(revived.ordinal, secondMembership.ordinal)
        let eventsAfterReuse = await events.events()
        XCTAssertEqual(eventsAfterReuse.count, eventsBeforeReuse.count)
    }

    func testDerivedCaptureStaysDistinctFromMatchingPayload() async throws {
        let store = RecordStore()
        let first = try await store.ingest(draft("same"), into: [])
        var provenance = first.record.provenance
        provenance.derivedFrom = first.id
        let derived = try await store.ingest(
            RecordDraft(
                payload: .text("same"),
                provenance: provenance,
                createdAt: first.record.createdAt.addingTimeInterval(1)
            ),
            into: []
        )
        XCTAssertNotEqual(derived.id, first.id)
        let again = try await store.ingest(draft("same"), into: [])
        XCTAssertEqual(again.id, first.id)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(Set(snapshot.records.map(\.id)), [first.id, derived.id])
    }

    func testDuplicateIngestRollsBackWhenCommitFails() async throws {
        let persistence = FailingRecordGraphPersistence()
        let store = RecordStore(persistence: persistence)
        let first = try await store.ingest(draft("again"), into: [RecordCollection.inboxID])
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
        _ = try await store.completeDelivery(leaseID: lease.id)
        let before = try await store.snapshot()
        await persistence.rejectWrites()
        do {
            _ = try await store.ingest(draft("again"), into: [RecordCollection.inboxID])
            XCTFail("Reactivation must commit before it becomes visible")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .persistenceUnavailable)
        }
        let failed = try await store.snapshot()
        XCTAssertEqual(failed, before)
        await persistence.allowWrites()
        let restored = try await store.ingest(draft("again"), into: [RecordCollection.inboxID])
        XCTAssertEqual(restored.id, first.id)
        XCTAssertEqual(restored.memberships.first?.state, .active)
    }

    func testMissingContentDigestIsFilledBeforeReuse() async throws {
        let record = Record(
            payload: .text("same"),
            provenance: clipboardProvenance,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let persistence = try MissingDigestCatalog(record: record, payload: Data("same".utf8))
        let store = RecordStore(persistence: persistence)
        let again = try await store.ingest(draft("same"), into: [])
        XCTAssertEqual(again.id, record.id)
        XCTAssertTrue(again.memberships.isEmpty)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [record.id])
        let committedHeader = await persistence.committedRecordHeader()
        let header = try XCTUnwrap(committedHeader)
        XCTAssertEqual(header.id, record.id)
        XCTAssertEqual(header.contentDigest?.count, 32)
    }

    func testRecordWithZeroMembershipRemainsInAllRecords() async throws {
        let store = RecordStore()
        let projection = try await store.ingest(draft("orphan"), into: [])

        XCTAssertTrue(projection.memberships.isEmpty)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [projection.id])
    }

    func testManualCollectionRequiresExplicitMembership() async throws {
        let store = RecordStore()
        let manual = try await store.createCollection(named: "Manual", preset: .list)
        let projection = try await store.ingest(draft("pick me"), into: [manual.id])

        do {
            _ = try await store.beginDelivery(
                sourceCollectionIDs: [manual.id],
                sink: .focusedApplication
            )
            XCTFail("Expected manual selection to be required")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .manualSelectionRequired)
        }

        let membership = try XCTUnwrap(projection.memberships.first)
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [manual.id],
            sink: .focusedApplication,
            manualMembershipID: membership.id
        )
        _ = try await store.completeDelivery(leaseID: lease.id)
        let loaded = try await store.record(id: projection.id)
        let updated = try XCTUnwrap(loaded)
        XCTAssertEqual(updated.memberships.first?.state, .active)
    }

    func testSuccessfulDeliveryConsumesOnlyOriginatingMembership() async throws {
        let store = RecordStore()
        let second = try await store.createCollection(named: "Second", preset: .stack)
        let projection = try await store.ingest(
            draft("shared"),
            into: [RecordCollection.inboxID, second.id]
        )
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [second.id],
            sink: .focusedApplication
        )

        _ = try await store.completeDelivery(leaseID: lease.id)

        let loaded = try await store.record(id: projection.id)
        let updated = try XCTUnwrap(loaded)
        XCTAssertEqual(
            updated.memberships.first(where: { $0.collectionID == second.id })?.state,
            .consumed
        )
        XCTAssertEqual(
            updated.memberships.first(where: { $0.collectionID == RecordCollection.inboxID })?
                .state,
            .active
        )
    }

    func testFailedDeliveryRestoresLeaseAndRecordsClosedFailure() async throws {
        let store = RecordStore()
        let projection = try await store.ingest(
            draft("retry"),
            into: [RecordCollection.inboxID]
        )
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
        try await store.failDelivery(leaseID: lease.id)

        let loaded = try await store.record(id: projection.id)
        let updated = try XCTUnwrap(loaded)
        XCTAssertEqual(updated.memberships.first?.state, .active)
        XCTAssertEqual(updated.activity.latestFailure, .deliveryFailed)
        _ = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
    }

    func testLocalReplaceSwapsOnlySelectedMembershipAndPreservesOriginalRecord() async throws {
        let store = RecordStore()
        let second = try await store.createCollection(named: "Second")
        let original = try await store.ingest(
            draft("before"),
            into: [RecordCollection.inboxID, second.id]
        )
        let selected = try XCTUnwrap(
            original.memberships.first(where: { $0.collectionID == second.id })
        )

        let replacement = try await store.replace(
            membershipID: selected.id,
            expectedRevision: selected.revision,
            with: .text("after")
        )

        let loadedOriginal = try await store.record(id: original.id)
        let originalAfter = try XCTUnwrap(loadedOriginal)
        XCTAssertEqual(originalAfter.memberships.map(\.collectionID), [RecordCollection.inboxID])
        XCTAssertEqual(replacement.memberships.map(\.collectionID), [second.id])
        XCTAssertEqual(replacement.record.provenance.derivedFrom, original.id)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, 2)
    }

    func testGlobalReplaceSwapsEveryMembership() async throws {
        let store = RecordStore()
        let second = try await store.createCollection(named: "Second")
        let original = try await store.ingest(
            draft("before"),
            into: [RecordCollection.inboxID, second.id]
        )
        let selected = try XCTUnwrap(original.memberships.first)

        let replacement = try await store.replace(
            membershipID: selected.id,
            expectedRevision: selected.revision,
            with: .text("after"),
            inAllCollections: true
        )

        let loadedOriginal = try await store.record(id: original.id)
        XCTAssertTrue(try XCTUnwrap(loadedOriginal).memberships.isEmpty)
        XCTAssertEqual(
            Set(replacement.memberships.map(\.collectionID)),
            [
                RecordCollection.inboxID,
                second.id,
            ])
    }

    func testCaptureRouteUsesStableUnionAndDeliveryRouteUsesHighestPriorityStableID() async throws {
        let store = RecordStore()
        let second = try await store.createCollection(named: "Second")
        let third = try await store.createCollection(named: "Third")
        try await store.replaceCaptureRules([
            CaptureRouteRule(
                matcher: CaptureRouteMatcher(sourceKinds: [.workflow]),
                destinationCollectionIDs: [second.id, third.id]
            ),
            CaptureRouteRule(
                matcher: CaptureRouteMatcher(sourceKinds: [.workflow]),
                destinationCollectionIDs: [RecordCollection.inboxID, second.id]
            ),
        ])
        let destinations = try await store.routedCaptureDestinations(
            for: RecordCaptureEnvelope(
                draft: draft("route", source: .workflow),
                requestedCollectionIDs: [third.id]
            )
        )
        XCTAssertEqual(destinations, [third.id, second.id, RecordCollection.inboxID])

        let lowerID = RecordRouteRuleID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let higherID = RecordRouteRuleID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        try await store.replaceDeliveryRules([
            DeliveryRouteRule(
                id: higherID,
                matcher: DeliveryRouteMatcher(),
                priority: 10,
                sourceCollectionIDs: [third.id],
                sink: .focusedApplication
            ),
            DeliveryRouteRule(
                id: lowerID,
                matcher: DeliveryRouteMatcher(),
                priority: 10,
                sourceCollectionIDs: [second.id],
                sink: .systemClipboard
            ),
        ])
        let resolved = try await store.resolveDeliveryRoute(target: FocusedApplicationIdentity())
        XCTAssertEqual(resolved?.id, lowerID)
        XCTAssertEqual(resolved?.sourceCollectionIDs, [second.id])
    }

    func testConsumedMembershipDoesNotProtectRetention() async throws {
        let store = RecordStore()
        let projection = try await store.ingest(
            draft("expire"),
            into: [RecordCollection.inboxID]
        )
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
        _ = try await store.completeDelivery(leaseID: lease.id)

        let protectedBeforePin = try await store.isProtectedFromRetention(projection.id)
        XCTAssertFalse(protectedBeforePin)
        _ = try await store.updateMetadata(recordID: projection.id, isPinned: true)
        let protectedAfterPin = try await store.isProtectedFromRetention(projection.id)
        XCTAssertTrue(protectedAfterPin)
    }

    func testAdmissionBudgetCountsPayloadOnceAcrossMembershipsAndRejectsAtomically() async throws {
        var limits = RecordStorageLimits.productDefault
        limits.maximumTextUTF8ByteCount = 4
        limits.maximumTotalPayloadByteCount = 5
        let store = RecordStore(storageLimits: limits)
        let second = try await store.createCollection(named: "Second")

        _ = try await store.ingest(
            draft("four"),
            into: [RecordCollection.inboxID, second.id]
        )
        let before = try await store.snapshot()

        do {
            _ = try await store.ingest(draft("xx"), into: [])
            XCTFail("Expected total payload admission to fail")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .totalPayloadLimitReached)
        }
        let after = try await store.snapshot()
        XCTAssertEqual(after, before)
    }

    func testPerCollectionActiveLimitDoesNotDeleteExistingRecord() async throws {
        var limits = RecordStorageLimits.productDefault
        limits.maximumActiveMembershipCountPerCollection = 1
        let store = RecordStore(storageLimits: limits)
        _ = try await store.ingest(draft("first"), into: [RecordCollection.inboxID])
        let before = try await store.snapshot()

        do {
            _ = try await store.ingest(draft("second"), into: [RecordCollection.inboxID])
            XCTFail("Expected collection admission to fail")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .recordLimitReached)
        }
        let after = try await store.snapshot()
        XCTAssertEqual(after, before)
    }

    func testPersistenceFailureRollsBackPublishedAndReadableState() async throws {
        let persistence = FailingRecordGraphPersistence()
        let store = RecordStore(persistence: persistence)
        let before = try await store.snapshot()
        await persistence.rejectWrites()

        do {
            _ = try await store.createCollection(named: "Must Roll Back")
            XCTFail("Expected persistence failure")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .persistenceUnavailable)
        }

        let after = try await store.snapshot()
        XCTAssertEqual(after, before)
    }

    func testConcurrentGraphMutationsSerializePersistenceAndRevisionChain() async throws {
        let persistence = ReentrantRecordGraphPersistenceProbe()
        let store = RecordStore(persistence: persistence)
        let names = (0..<12).map { "Concurrent \($0)" }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask {
                    _ = try await store.createCollection(name: name, preset: .list)
                }
            }
            try await group.waitForAll()
        }

        let snapshot = try await store.snapshot()
        XCTAssertEqual(
            Set(snapshot.collections.map(\.name)).intersection(names),
            Set(names)
        )
        let observation = await persistence.observation()
        XCTAssertEqual(observation.maximumConcurrentWriteCount, 1)
        XCTAssertEqual(
            observation.expectedRevisions,
            [nil] + (1..<Int64(names.count)).map(Optional.some)
        )
    }

    func testCompletionPersistenceFailurePreservesLeaseForRetry() async throws {
        let persistence = FailingRecordGraphPersistence()
        let store = RecordStore(persistence: persistence)
        let projection = try await store.ingest(
            draft("complete once"),
            into: [RecordCollection.inboxID]
        )
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
        let membership = try XCTUnwrap(projection.memberships.first)
        let subject = RecordDeliverySubject(
            recordID: projection.id,
            membershipID: membership.id,
            membershipRevision: membership.revision,
            collectionID: membership.collectionID,
            payloadKind: projection.record.payload.kind,
            captureTags: projection.record.provenance.captureTags
        )
        let before = try await store.snapshot()
        await persistence.rejectWrites()

        do {
            _ = try await store.completeDelivery(leaseID: lease.id)
            XCTFail("Expected completion persistence failure")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .persistenceUnavailable)
        }
        let afterFailure = try await store.snapshot()
        XCTAssertEqual(afterFailure, before)

        do {
            _ = try await store.beginDelivery(matching: subject, sink: .focusedApplication)
            XCTFail("Expected the failed settlement to preserve its lease")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .membershipAlreadyInUse)
        }

        await persistence.allowWrites()
        _ = try await store.completeDelivery(leaseID: lease.id)
        let loaded = try await store.record(id: projection.id)
        let updated = try XCTUnwrap(loaded)
        XCTAssertEqual(updated.memberships.first?.state, .consumed)
        XCTAssertEqual(updated.activity.useCount, 1)
    }

    func testFailurePersistenceFailurePreservesLeaseForRetry() async throws {
        let persistence = FailingRecordGraphPersistence()
        let store = RecordStore(persistence: persistence)
        let projection = try await store.ingest(
            draft("fail once"),
            into: [RecordCollection.inboxID]
        )
        let lease = try await store.beginDelivery(
            sourceCollectionIDs: [RecordCollection.inboxID],
            sink: .focusedApplication
        )
        let before = try await store.snapshot()
        await persistence.rejectWrites()

        do {
            try await store.failDelivery(leaseID: lease.id)
            XCTFail("Expected failure persistence failure")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .persistenceUnavailable)
        }
        let afterFailure = try await store.snapshot()
        XCTAssertEqual(afterFailure, before)

        await persistence.allowWrites()
        try await store.failDelivery(leaseID: lease.id)
        let loaded = try await store.record(id: projection.id)
        let updated = try XCTUnwrap(loaded)
        XCTAssertEqual(updated.memberships.first?.state, .active)
        XCTAssertEqual(updated.activity.latestFailure, .deliveryFailed)
    }

    func testSnapshotStreamPublishesCommittedMutation() async throws {
        let store = RecordStore()
        let stream = try await store.snapshotStream()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()

        _ = try await store.ingest(draft("streamed"), into: [])

        let updated = await iterator.next()
        XCTAssertEqual(initial?.records.count, 0)
        XCTAssertEqual(updated?.records.map(\.record.payload), [.text("streamed")])
    }

    func testCollectionDeletionWithActiveLeaseDoesNotPartiallyRewriteRoutes() async throws {
        let store = RecordStore()
        let source = try await store.createCollection(named: "Leased")
        _ = try await store.ingest(draft("busy"), into: [source.id])
        try await store.replaceCaptureRules([
            CaptureRouteRule(
                matcher: .init(sourceKinds: [.workflow]),
                destinationCollectionIDs: [source.id]
            )
        ])
        _ = try await store.beginDelivery(
            sourceCollectionIDs: [source.id],
            sink: .focusedApplication
        )
        let before = try await store.snapshot()

        do {
            try await store.deleteCollection(
                source.id,
                resolvingReferences: .replace(with: RecordCollection.inboxID)
            )
            XCTFail("Expected active lease to block deletion")
        } catch let error as RecordStoreError {
            XCTAssertEqual(error, .membershipAlreadyInUse)
        }

        let after = try await store.snapshot()
        XCTAssertEqual(after, before)
    }

    func testCommittedMembershipMutationsPublishExactRecordCollectionEvents() async throws {
        let sink = RecordCollectionEventProbe()
        let store = RecordStore(collectionEventSink: sink)
        let created = try await store.ingest(
            draft("created"),
            into: [RecordCollection.inboxID]
        )
        let originalMembership = try XCTUnwrap(created.memberships.first)
        let replacement = try await store.replace(
            membershipID: originalMembership.id,
            expectedRevision: originalMembership.revision,
            with: .text("edited")
        )
        let replacementMembership = try XCTUnwrap(replacement.memberships.first)
        try await store.removeMembership(
            replacementMembership.id,
            expectedRevision: replacementMembership.revision
        )

        let events = await sink.events()
        XCTAssertEqual(events.map(\.kind), [.recordCreated, .recordEdited, .recordRemoved])
        XCTAssertEqual(events.map(\.recordID), [created.id, replacement.id, replacement.id])
        XCTAssertEqual(
            events.map(\.membershipID),
            [
                originalMembership.id,
                replacementMembership.id,
                replacementMembership.id,
            ])
        XCTAssertEqual(
            events.map(\.membershipRevision),
            [
                originalMembership.revision,
                replacementMembership.revision,
                replacementMembership.revision,
            ])
        XCTAssertTrue(events.allSatisfy { $0.storeRevision > 0 })
    }

    private func draft(
        _ text: String,
        source: RecordSourceKind = .systemClipboard
    ) -> RecordDraft {
        RecordDraft(
            payload: .text(text),
            provenance: RecordProvenance(
                source: RecordSourceIdentity(kind: source)
            )
        )
    }

    private var clipboardProvenance: RecordProvenance {
        RecordProvenance(source: RecordSourceIdentity(kind: .systemClipboard))
    }
}

private actor FailingRecordGraphPersistence: RecordGraphPersistenceStore {
    private var shouldRejectWrites = false

    func rejectWrites() {
        shouldRejectWrites = true
    }

    func allowWrites() {
        shouldRejectWrites = false
    }

    func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot {
        .empty
    }

    func replaceRecordGraph(
        with snapshot: RecordGraphPersistenceWriteSnapshot
    ) async throws -> Int64 {
        _ = snapshot
        guard !shouldRejectWrites else { throw FailingRecordGraphPersistenceError.rejected }
        return 1
    }

    func removeRecordGraph() async throws -> RecordGraphRemovalResult {
        .removed
    }
}

private actor ReentrantRecordGraphPersistenceProbe: RecordGraphPersistenceStore {
    struct Observation: Sendable, Equatable {
        var maximumConcurrentWriteCount: Int
        var expectedRevisions: [Int64?]
    }

    private var activeWriteCount = 0
    private var maximumConcurrentWriteCount = 0
    private var expectedRevisions: [Int64?] = []
    private var nextRevision: Int64 = 1

    func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot {
        .empty
    }

    func replaceRecordGraph(
        with snapshot: RecordGraphPersistenceWriteSnapshot
    ) async throws -> Int64 {
        let committedRevision = nextRevision
        nextRevision += 1
        activeWriteCount += 1
        maximumConcurrentWriteCount = max(maximumConcurrentWriteCount, activeWriteCount)
        expectedRevisions.append(snapshot.expectedRevision)
        await Task.yield()
        activeWriteCount -= 1
        return committedRevision
    }

    func removeRecordGraph() async throws -> RecordGraphRemovalResult {
        .removed
    }

    func observation() -> Observation {
        Observation(
            maximumConcurrentWriteCount: maximumConcurrentWriteCount,
            expectedRevisions: expectedRevisions
        )
    }
}

private enum FailingRecordGraphPersistenceError: Error {
    case rejected
}

private actor MissingDigestCatalog: RecordCatalogPersistenceStore {
    private let catalog: RecordCatalogRead
    private let payload: Data
    private var revision: Int64 = 1
    private var committedHeader: RecordHeader?

    init(record: Record, payload: Data) throws {
        let header = RecordHeader(record: record, byteCount: payload.count)
        let encoder = JSONEncoder()
        var nodes: [RecordCatalogNode] = []
        func append<T: Encodable>(
            _ kind: RecordCatalogNode.Kind,
            _ id: String,
            _ value: T
        ) throws {
            nodes.append(RecordCatalogNode(kind: kind, id: id, value: try encoder.encode(value)))
        }
        for collection in [RecordCollection.inbox, RecordCollection.voiceInput] {
            try append(.collection, collection.id.description, collection)
        }
        try append(.record, record.id.description, header)
        try append(.metadata, record.id.description, RecordMetadata(recordID: record.id))
        try append(.activity, record.id.description, RecordActivity(recordID: record.id))
        catalog = RecordCatalogRead(
            revision: revision,
            manifest: RecordCatalogManifest(
                nextMembershipOrdinal: 1,
                recordOrder: [record.id],
                collectionOrder: [RecordCollection.inboxID, RecordCollection.voiceInputID]
            ),
            nodes: nodes,
            references: [
                RecordGraphPersistenceBlobReference(
                    blobID: UUID(),
                    recordID: record.id,
                    kind: .text,
                    byteCount: payload.count
                )
            ]
        )
        self.payload = payload
    }

    func committedRecordHeader() -> RecordHeader? { committedHeader }

    func loadRecordCatalog() async throws -> RecordCatalogRead? { catalog }

    func loadRecordPayload(
        _ reference: RecordGraphPersistenceBlobReference
    ) async throws -> Data {
        payload
    }

    func commitRecordCatalog(_ mutation: RecordCatalogMutation) async throws -> Int64 {
        let decoder = JSONDecoder()
        if let node = mutation.upserts.first(where: { $0.kind == .record }),
           let header = try? decoder.decode(RecordHeader.self, from: node.value) {
            committedHeader = header
        }
        revision += 1
        return revision
    }

    func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot { .empty }

    func replaceRecordGraph(
        with snapshot: RecordGraphPersistenceWriteSnapshot
    ) async throws -> Int64 {
        throw RecordStoreError.persistenceUnavailable
    }

    func removeRecordGraph() async throws -> RecordGraphRemovalResult {
        throw RecordStoreError.persistenceUnavailable
    }
}

private actor RecordCollectionEventProbe: RecordCollectionEventSink {
    private var submitted: [RecordCollectionEventDescriptor] = []

    func submit(
        _ descriptor: RecordCollectionEventDescriptor
    ) -> RecordCollectionEventSubmissionResult {
        submitted.append(descriptor)
        return .accepted
    }

    func events() -> [RecordCollectionEventDescriptor] {
        submitted
    }
}

extension RecordStore {
    fileprivate func createCollection(
        named name: String,
        preset: RecordCollectionPreset = .stack
    ) async throws -> RecordCollection {
        try await createCollection(name: name, preset: preset)
    }
}
