@testable import RillWorkflows
import Foundation
import XCTest

@testable import RillCore

final class RecordCollectionEventSchedulerTests: XCTestCase {
    func testSubmissionDeduplicatesExactEventIdentityAndStopsAfterDrain() async {
        let scheduler = RecordCollectionEventScheduler(
            receiptRecorder: nil,
            registrationProvider: { [] }
        )
        let descriptor = makeDescriptor()

        let first = await scheduler.submit(descriptor)
        let duplicate = await scheduler.submit(descriptor)
        await scheduler.shutdown()
        let stopped = await scheduler.submit(makeDescriptor())

        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(duplicate, .duplicate)
        XCTAssertEqual(stopped, .stopped)
    }

    private func makeDescriptor() -> RecordCollectionEventDescriptor {
        RecordCollectionEventDescriptor(
            kind: .recordCreated,
            collectionID: .init(),
            recordID: .init(),
            membershipID: .init(),
            membershipRevision: 1,
            storeRevision: 1,
            captureTags: []
        )
    }
}
