import Foundation
import XCTest
@testable import RillCore

final class VocabularyRecognitionHintsTests: XCTestCase {
    func testRuleSourceFailsClosedUntilRulesAreAvailable() throws {
        let source = VocabularyRuleSource()

        XCTAssertFalse(source.hasAvailableRules)
        XCTAssertThrowsError(try source.currentRules()) { error in
            XCTAssertEqual(error as? VocabularyRuleSourceError, .notReady)
        }

        let rule = VocabularyRule(kind: .hotword, pattern: "Rill", replacement: "ignored")
        source.update([rule])

        XCTAssertTrue(source.hasAvailableRules)
        XCTAssertEqual(try source.currentRules(), [rule])
    }

    func testRuleSourceDistinguishesAvailableEmptyRulesFromLoading() throws {
        let source = VocabularyRuleSource(initialRules: [])

        XCTAssertTrue(source.hasAvailableRules)
        XCTAssertEqual(try source.currentRules(), [])
    }

    func testRuleSourceDoesNotReturnStaleRulesAfterBecomingUnavailable() throws {
        let rule = VocabularyRule(kind: .hotword, pattern: "private term", replacement: "")
        let source = VocabularyRuleSource(initialRules: [rule])

        source.markUnavailable(reason: "invalid persisted snapshot")

        XCTAssertFalse(source.hasAvailableRules)
        XCTAssertThrowsError(try source.currentRules()) { error in
            XCTAssertEqual(
                error as? VocabularyRuleSourceError,
                .unavailable("invalid persisted snapshot")
            )
        }
    }

    func testRuleSourceCanRecoverAfterAnUnavailableState() throws {
        let source = VocabularyRuleSource()
        source.markUnavailable(reason: "load failed")

        source.update([])

        XCTAssertTrue(source.hasAvailableRules)
        XCTAssertEqual(try source.currentRules(), [])
    }

    func testRuleSourcePublishesWholeSnapshotsDuringConcurrentAccess() {
        let firstRule = Self.rule(id: Self.uuid(1), pattern: "first")
        let secondRule = Self.rule(id: Self.uuid(2), pattern: "second")
        let source = VocabularyRuleSource(
            initialRules: Array(repeating: firstRule, count: 20)
        )
        let failures = ThreadSafeFailureCounter()

        DispatchQueue.concurrentPerform(iterations: 500) { iteration in
            if iteration.isMultiple(of: 3) {
                let rule = iteration.isMultiple(of: 2) ? firstRule : secondRule
                source.update(Array(repeating: rule, count: 20))
                return
            }

            do {
                let rules = try source.currentRules()
                let identifiers = Set(rules.map(\.id))
                if rules.count != 20 || identifiers.count != 1 {
                    failures.recordFailure()
                }
            } catch {
                failures.recordFailure()
            }
        }

        XCTAssertEqual(failures.count, 0)
    }

    func testResolverIncludesOnlyEnabledScopedHotwords() {
        let matchingScope = VocabularyRuleScope(
            bundleIdentifier: "com.example.editor",
            recordCollectionID: Self.groupID,
            locale: "zh-CN"
        )
        let context = VocabularyRuleContext(
            bundleIdentifier: "com.example.editor",
            recordCollectionID: Self.groupID,
            locale: "zh-CN"
        )
        let rules = [
            Self.rule(pattern: "included", scope: matchingScope),
            Self.rule(pattern: "disabled", enabled: false, scope: matchingScope),
            Self.rule(pattern: "mapping", kind: .mapping, scope: matchingScope),
            Self.rule(
                pattern: "wrong bundle",
                scope: VocabularyRuleScope(bundleIdentifier: "com.example.other")
            ),
            Self.rule(
                pattern: "wrong group",
                scope: VocabularyRuleScope(recordCollectionID: UUID())
            ),
            Self.rule(
                pattern: "wrong locale",
                scope: VocabularyRuleScope(locale: "en-US")
            ),
        ]

        let resolution = VocabularyRecognitionHintResolver().resolve(
            rules: rules,
            context: context
        )

        XCTAssertEqual(resolution.hints.keyterms, ["included"])
        XCTAssertEqual(resolution.validKeytermCount, 1)
        XCTAssertEqual(resolution.omittedKeytermCount, 0)
        XCTAssertEqual(resolution.rejectedKeytermCount, 0)
    }

    func testResolverUsesDeterministicPriorityDateAndUUIDOrdering() {
        let earlyDate = Date(timeIntervalSince1970: 100)
        let lateDate = Date(timeIntervalSince1970: 200)
        let rules = [
            Self.rule(
                id: Self.uuid(4),
                pattern: "low priority",
                priority: 1,
                createdAt: earlyDate
            ),
            Self.rule(
                id: Self.uuid(3),
                pattern: "later",
                priority: 10,
                createdAt: lateDate
            ),
            Self.rule(
                id: Self.uuid(2),
                pattern: "UUID second",
                priority: 10,
                createdAt: earlyDate
            ),
            Self.rule(
                id: Self.uuid(1),
                pattern: "UUID first",
                priority: 10,
                createdAt: earlyDate
            ),
        ]

        let resolution = VocabularyRecognitionHintResolver().resolve(rules: rules)

        XCTAssertEqual(
            resolution.hints.keyterms,
            ["UUID first", "UUID second", "later", "low priority"]
        )
    }

    func testResolverTrimsAndExactlyDeduplicatesWithoutNormalizingContent() {
        let rules = [
            Self.rule(id: Self.uuid(1), pattern: "  Vox Type 2.0!  ", priority: 10),
            Self.rule(id: Self.uuid(2), pattern: "Vox Type 2.0!", priority: 5),
            Self.rule(id: Self.uuid(3), pattern: "vox Type 2.0!", priority: 4),
            Self.rule(id: Self.uuid(4), pattern: "多词 术语，保留标点", priority: 3),
        ]

        let resolution = VocabularyRecognitionHintResolver().resolve(rules: rules)

        XCTAssertEqual(
            resolution.hints.keyterms,
            ["Vox Type 2.0!", "vox Type 2.0!", "多词 术语，保留标点"]
        )
        XCTAssertEqual(resolution.validKeytermCount, 3)
        XCTAssertEqual(resolution.omittedKeytermCount, 0)
        XCTAssertEqual(resolution.rejectedKeytermCount, 0)
    }

    func testResolverRejectsEmptyNewlineAndControlCharacterPatterns() {
        let rules = [
            Self.rule(pattern: "   "),
            Self.rule(pattern: "line one\nline two"),
            Self.rule(pattern: "carriage\rreturn"),
            Self.rule(pattern: "tab\tterm"),
            Self.rule(pattern: "null\u{0000}term"),
            Self.rule(pattern: "unicode\u{2028}line"),
            Self.rule(pattern: " valid term "),
        ]

        let resolution = VocabularyRecognitionHintResolver().resolve(rules: rules)

        XCTAssertEqual(resolution.hints.keyterms, ["valid term"])
        XCTAssertEqual(resolution.validKeytermCount, 1)
        XCTAssertEqual(resolution.rejectedKeytermCount, 6)
    }

    func testResolverCapsAfterValidationAndReportsValidAndOmittedCounts() {
        let rules = (0..<55).map { index in
            Self.rule(
                id: Self.uuid(index + 1),
                pattern: "term \(index)",
                priority: 55 - index
            )
        } + [Self.rule(pattern: "\nrejected")]

        let resolution = VocabularyRecognitionHintResolver().resolve(rules: rules)

        XCTAssertEqual(resolution.hints.keyterms.count, 50)
        XCTAssertEqual(resolution.hints.keyterms.first, "term 0")
        XCTAssertEqual(resolution.hints.keyterms.last, "term 49")
        XCTAssertEqual(resolution.validKeytermCount, 55)
        XCTAssertEqual(resolution.omittedKeytermCount, 5)
        XCTAssertEqual(resolution.rejectedKeytermCount, 1)
    }

    func testResolverDoesNotUseReplacementMatchModeOrCaseSensitivity() {
        let rule = VocabularyRule(
            kind: .hotword,
            pattern: "[Vox Type]+",
            replacement: "must never be sent",
            matchMode: .regex,
            caseSensitive: true
        )

        let resolution = VocabularyRecognitionHintResolver().resolve(rules: [rule])

        XCTAssertEqual(resolution.hints.keyterms, ["[Vox Type]+"])
        XCTAssertFalse(resolution.hints.keyterms.contains(rule.replacement))
    }

    func testResolverSupportsAnExplicitZeroLimit() {
        let resolution = VocabularyRecognitionHintResolver(maximumKeytermCount: 0).resolve(
            rules: [Self.rule(pattern: "valid")]
        )

        XCTAssertEqual(resolution.hints, .empty)
        XCTAssertEqual(resolution.validKeytermCount, 1)
        XCTAssertEqual(resolution.omittedKeytermCount, 1)
        XCTAssertEqual(resolution.rejectedKeytermCount, 0)
    }

    private static let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!

    private static func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private static func rule(
        id: UUID = UUID(),
        pattern: String,
        enabled: Bool = true,
        kind: VocabularyRuleKind = .hotword,
        scope: VocabularyRuleScope = .init(),
        priority: Int = 0,
        createdAt: Date = .init(timeIntervalSince1970: 0)
    ) -> VocabularyRule {
        VocabularyRule(
            id: id,
            kind: kind,
            enabled: enabled,
            pattern: pattern,
            replacement: "ignored replacement",
            scope: scope,
            priority: priority,
            createdAt: createdAt
        )
    }
}

private final class ThreadSafeFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func recordFailure() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
