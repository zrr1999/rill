import XCTest

@testable import RillCore
@testable import RillRecords

final class RecordGraphRulesTests: XCTestCase {
    func testStableUniqueKeepsFirstOccurrenceOrder() {
        XCTAssertEqual(RecordGraphRules.stableUnique(["b", "a", "b", "a"]), ["b", "a"])
    }

    func testNormalizedTagsTrimAndDropEmptyValues() {
        XCTAssertEqual(RecordGraphRules.normalizedTags(["  Alpha ", "", "Alpha", "  "]), ["Alpha"])
    }

    func testDisabledRuleWithoutDestinationStaysRepairable() {
        let collection = RecordCollectionID()
        var rule = DeliveryRouteRule(
            matcher: DeliveryRouteMatcher(),
            priority: 1,
            sourceCollectionIDs: [collection],
            sink: .recordCollection
        )
        rule.isEnabled = false
        XCTAssertTrue(RecordGraphRules.isValidDeliveryRule(rule, collectionIDs: [collection]))
        rule.isEnabled = true
        XCTAssertFalse(RecordGraphRules.isValidDeliveryRule(rule, collectionIDs: [collection]))
    }
}
