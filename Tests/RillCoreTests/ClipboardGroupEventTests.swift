import XCTest
@testable import RillCore

final class ClipboardGroupEventTests: XCTestCase {
    func testDescriptorCarriesOnlyContentFreeSchedulingFields() throws {
        let eventID = UUID()
        let itemID = UUID()
        let itemVersion = ClipboardItemVersion()
        let timestamp = Date(timeIntervalSince1970: 1_234)
        let descriptor = ClipboardGroupEventDescriptor(
            eventID: eventID,
            kind: .itemEdited,
            groupID: ClipboardGroup.voiceGroupID,
            itemID: itemID,
            itemVersion: itemVersion,
            storeRevision: 42,
            captureTags: [.polishGenerated],
            timestamp: timestamp
        )

        XCTAssertEqual(descriptor.eventID, eventID)
        XCTAssertEqual(descriptor.kind, .itemEdited)
        XCTAssertEqual(descriptor.groupID, ClipboardGroup.voiceGroupID)
        XCTAssertEqual(descriptor.itemID, itemID)
        XCTAssertEqual(descriptor.itemVersion, itemVersion)
        XCTAssertEqual(descriptor.storeRevision, 42)
        XCTAssertEqual(descriptor.captureTags, [.polishGenerated])
        XCTAssertEqual(
            descriptor.lineage,
            ClipboardGroupEventLineage(rootEventID: eventID)
        )
        XCTAssertEqual(descriptor.timestamp, timestamp)

        let encoded = try JSONEncoder().encode(descriptor)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "eventID",
                "kind",
                "groupID",
                "itemID",
                "itemVersion",
                "storeRevision",
                "captureTags",
                "lineage",
                "timestamp",
            ])
        )
    }

    func testLineageAdvancesWithFixedHopCapAndRejectsWorkflowReentry() throws {
        let rootEventID = UUID()
        let firstWorkflowID = UUID()
        let secondWorkflowID = UUID()
        let root = ClipboardGroupEventLineage(rootEventID: rootEventID)

        guard case .advanced(let firstHop) = root.advancing(
            through: firstWorkflowID
        ) else {
            return XCTFail("A root lineage must permit its first workflow.")
        }
        XCTAssertEqual(firstHop.rootEventID, rootEventID)
        XCTAssertEqual(firstHop.workflowPath, [firstWorkflowID])
        XCTAssertEqual(firstHop.hopCount, 1)
        XCTAssertEqual(
            firstHop.advancing(through: firstWorkflowID),
            .workflowAlreadyVisited
        )

        guard case .advanced(let secondHop) = firstHop.advancing(
            through: secondWorkflowID
        ) else {
            return XCTFail("A distinct workflow must advance the lineage.")
        }
        XCTAssertEqual(secondHop.workflowPath, [firstWorkflowID, secondWorkflowID])

        var saturated = root
        for _ in 0..<ClipboardGroupEventLineage.maximumHopCount {
            guard case .advanced(let next) = saturated.advancing(through: UUID()) else {
                return XCTFail("A unique workflow must advance below the hop cap.")
            }
            saturated = next
        }
        XCTAssertEqual(saturated.advancing(through: UUID()), .hopLimitReached)
        XCTAssertTrue(root.isValid(for: rootEventID))
        XCTAssertFalse(root.isValid(for: UUID()))
        XCTAssertTrue(firstHop.isValid(for: UUID()))

        let invalidLineageObject: [String: Any] = [
            "rootEventID": rootEventID.uuidString,
            "workflowPath": [firstWorkflowID.uuidString, firstWorkflowID.uuidString],
        ]
        let invalidLineageData = try JSONSerialization.data(
            withJSONObject: invalidLineageObject
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ClipboardGroupEventLineage.self,
                from: invalidLineageData
            )
        )
    }

    func testDescriptorDecodesLegacyPayloadAsRootLineage() throws {
        let eventID = UUID()
        let itemID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_234)
        let legacyObject: [String: Any] = [
            "eventID": eventID.uuidString,
            "kind": ClipboardGroupEventKind.itemCreated.rawValue,
            "groupID": ClipboardGroup.voiceGroupID.uuidString,
            "itemID": itemID.uuidString,
            "storeRevision": 3,
            "captureTags": [],
            "timestamp": timestamp.timeIntervalSinceReferenceDate,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyObject)

        let descriptor = try JSONDecoder().decode(
            ClipboardGroupEventDescriptor.self,
            from: data
        )

        XCTAssertEqual(
            descriptor.lineage,
            ClipboardGroupEventLineage(rootEventID: eventID)
        )
    }

    func testVoiceGroupPolishTriggerMatchesPlainVoiceItem() {
        let itemID = UUID()
        let event = ClipboardGroupEventDescriptor(
            kind: .itemCreated,
            groupID: ClipboardGroup.voiceGroupID,
            itemID: itemID,
            captureTags: []
        )

        let result = ClipboardGroupTrigger.voiceGroupPolish.matchResult(for: event)

        XCTAssertTrue(result.matched)
        XCTAssertTrue(ClipboardGroupTrigger.voiceGroupPolish.matches(descriptor: event))
        XCTAssertNil(result.skipReason)
    }

    func testVoiceGroupPolishTriggerExplainsLoopPreventionTag() {
        let itemID = UUID()
        let event = ClipboardGroupEventDescriptor(
            kind: .itemCreated,
            groupID: ClipboardGroup.voiceGroupID,
            itemID: itemID,
            captureTags: [.polishGenerated]
        )

        let result = ClipboardGroupTrigger.voiceGroupPolish.matchResult(for: event)

        XCTAssertFalse(result.matched)
        XCTAssertFalse(ClipboardGroupTrigger.voiceGroupPolish.matches(descriptor: event))
        XCTAssertEqual(result.skipReason, .loopPrevented)
        XCTAssertEqual(result.failedConditionIndex, 0)
    }

    func testTriggerRuleMatchesContentFreeDescriptor() {
        let descriptor = ClipboardGroupEventDescriptor(
            kind: .itemCreated,
            groupID: ClipboardGroup.voiceGroupID,
            itemID: UUID(),
            captureTags: []
        )

        let trigger = ClipboardGroupTrigger.voiceGroupPolish

        XCTAssertEqual(trigger.rule.matchResult(for: descriptor), .matched)
        XCTAssertEqual(trigger.matchResult(for: descriptor), .matched)
        XCTAssertTrue(trigger.matches(descriptor: descriptor))
    }

    func testPolishLoopReasonIsSpecificToPolishTag() {
        let rule = ClipboardGroupTriggerRule(
            eventKind: .itemCreated,
            conditions: [.excludingTag(.excludeFromWorkflowCapture)]
        )
        let descriptor = ClipboardGroupEventDescriptor(
            kind: .itemCreated,
            groupID: ClipboardGroup.voiceGroupID,
            itemID: UUID(),
            captureTags: [.excludeFromWorkflowCapture]
        )

        XCTAssertEqual(
            rule.matchResult(for: descriptor).skipReason,
            .excludedByCaptureTag
        )
    }

    func testExcludingTagFailsClosedWhenEventItemIsMissing() {
        let event = ClipboardGroupEventDescriptor(
            kind: .itemCreated,
            groupID: ClipboardGroup.voiceGroupID,
            itemID: UUID(),
            captureTags: nil
        )

        let result = ClipboardGroupTrigger.voiceGroupPolish.matchResult(for: event)

        XCTAssertFalse(result.matched)
        XCTAssertFalse(ClipboardGroupTrigger.voiceGroupPolish.matches(descriptor: event))
        XCTAssertEqual(result.skipReason, .itemMissing)
        XCTAssertEqual(result.failedConditionIndex, 0)
    }

    func testTriggerExplainsEventKindAndSourceGroupMismatch() {
        let itemID = UUID()
        let wrongKind = ClipboardGroupEventDescriptor(
            kind: .itemEdited,
            groupID: ClipboardGroup.voiceGroupID,
            itemID: itemID
        )
        let wrongGroup = ClipboardGroupEventDescriptor(
            kind: .itemCreated,
            groupID: ClipboardGroup.defaultGroupID,
            itemID: itemID
        )

        XCTAssertEqual(
            ClipboardGroupTrigger.voiceGroupPolish.matchResult(for: wrongKind).skipReason,
            .eventKindMismatch
        )
        XCTAssertEqual(
            ClipboardGroupTrigger.voiceGroupPolish.matchResult(for: wrongGroup).skipReason,
            .sourceGroupMismatch
        )
    }

    func testEveryTriggerSkipReasonMapsToClosedWorkflowSkipCode() {
        let expectedMappings: [(
            ClipboardGroupTriggerSkipReason,
            WorkflowRunSkipCode
        )] = [
            (.eventKindMismatch, .eventKindMismatch),
            (.sourceGroupMismatch, .sourceGroupMismatch),
            (.excludedByCaptureTag, .excludedByCaptureTag),
            (.conditionFailed, .conditionFailed),
            (.itemMissing, .itemMissing),
            (.loopPrevented, .loopPrevented),
        ]

        XCTAssertEqual(
            expectedMappings.map(\.0),
            ClipboardGroupTriggerSkipReason.allCases
        )
        for (reason, expectedCode) in expectedMappings {
            XCTAssertEqual(reason.workflowRunSkipCode, expectedCode)
        }
    }
}
