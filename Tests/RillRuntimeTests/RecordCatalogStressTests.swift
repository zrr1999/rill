@testable import RillWorkflows
@testable import RillRecords
import Foundation
import XCTest

@testable import RillCore
@testable import RillPersistence

final class RecordCatalogStressTests: XCTestCase {
  func testTenThousandMixedRecordsNearByteCapacity() async throws {
    guard ProcessInfo.processInfo.environment["RILL_RECORD_STRESS"] == "1" else {
      throw XCTSkip("Set RILL_RECORD_STRESS=1 to run the 10,000-record / 497 MiB storage fixture.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-record-stress-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let protector = try AESGCMDataProtector(
      key: Data(repeating: 0x4E, count: AESGCMDataProtector.keyByteCount))
    let persistence = try SQLitePersistenceStore(
      databaseURL: directory.appendingPathComponent("stress.sqlite"), localDataProtector: protector)
    let seed = try await RecordStore().catalogSnapshot()
    let encoder = JSONEncoder()
    var nodes: [RecordCatalogNode] = []
    func node<T: Encodable>(_ kind: RecordCatalogNode.Kind, id: String, value: T) throws {
      nodes.append(.init(kind: kind, id: id, value: try encoder.encode(value)))
    }
    for collection in seed.collections {
      try node(.collection, id: collection.id.description, value: collection)
    }
    for rule in seed.captureRules { try node(.captureRule, id: rule.id.description, value: rule) }
    for rule in seed.deliveryRules { try node(.deliveryRule, id: rule.id.description, value: rule) }
    var order: [RecordID] = []
    var blobs: [RecordGraphPersistenceBlob] = []
    var totalBytes = 0
    for index in 0..<10_000 {
      let payload: RecordPayload
      let data: Data
      if index < 16 {
        data = Data(repeating: UInt8(index), count: 31 * 1_024 * 1_024)
        payload = .image(data)
      } else if index.isMultiple(of: 10) {
        let urls = [URL(fileURLWithPath: "/tmp/报告-\(index).pdf")]
        payload = .files(urls)
        data = try encoder.encode(urls)
      } else {
        let text = "中文 clipboard record \(index): mixed content used to measure bounded search."
        payload = .text(text)
        data = Data(text.utf8)
      }
      let record = Record(
        payload: payload,
        provenance: .init(source: .init(kind: .systemClipboard), sourceApplicationName: "Editor"),
        createdAt: Date(timeIntervalSince1970: Double(index)))
      order.append(record.id)
      totalBytes += data.count
      try node(
        .record, id: record.id.description,
        value: RecordHeader(record: record, byteCount: data.count))
      try node(.metadata, id: record.id.description, value: RecordMetadata(recordID: record.id))
      try node(.activity, id: record.id.description, value: RecordActivity(recordID: record.id))
      blobs.append(
        .init(
          reference: .init(
            blobID: UUID(), recordID: record.id, kind: payload.kind, byteCount: data.count),
          payload: data))
    }
    _ = try await persistence.commitRecordCatalog(
      .init(
        expectedRevision: nil,
        manifest: .init(
          nextMembershipOrdinal: 1, recordOrder: order.reversed(),
          collectionOrder: seed.collections.map(\.id)),
        upserts: nodes, removedKeys: [], newPayloadBlobs: blobs, removedPayloadBlobIDs: []))
    blobs.removeAll()
    nodes.removeAll()
    let store = RecordStore(persistence: persistence)
    let coldStart = ContinuousClock.now
    let initial = try await store.catalogSnapshot()
    let coldSeconds = seconds(coldStart.duration(to: .now))
    XCTAssertEqual(initial.records.count, 10_000)
    XCTAssertEqual(initial.capacity.byteCount, totalBytes)
    XCTAssertTrue(initial.capacity.isFull)
    XCTAssertGreaterThan(totalBytes, 496 * 1_024 * 1_024)
    _ = try await store.query(.init(text: "中文 clipboard"))
    var catalogTimes: [Double] = []
    var searchTimes: [Double] = []
    for _ in 0..<30 {
      let start = ContinuousClock.now
      _ = try await store.catalogSnapshot()
      catalogTimes.append(seconds(start.duration(to: .now)))
      let searchStart = ContinuousClock.now
      let page = try await store.query(.init(text: "中文 clipboard"))
      XCTAssertEqual(page.records.count, 50)
      searchTimes.append(seconds(searchStart.duration(to: .now)))
    }
    let catalogP95 = catalogTimes.sorted()[28]
    let searchP95 = searchTimes.sorted()[28]
    print(
      "RECORD_STRESS records=10000 bytes=\(totalBytes) cold_catalog_ms=\(coldSeconds * 1000) warm_catalog_p95_ms=\(catalogP95 * 1000) search_first_page_p95_ms=\(searchP95 * 1000)"
    )
    XCTAssertLessThanOrEqual(catalogP95, 0.150)
    XCTAssertLessThanOrEqual(searchP95, 0.100)
    let miss = RecordQuery(text: "unfindablexyz", matching: .approximate)
    let coldMissStart = ContinuousClock.now
    let coldMiss = try await allMatches(in: store, query: miss)
    let coldMissSeconds = seconds(coldMissStart.duration(to: .now))
    XCTAssertTrue(coldMiss.isEmpty)
    var missTimes: [Double] = []
    for _ in 0..<5 {
      let start = ContinuousClock.now
      let result = try await allMatches(in: store, query: miss)
      missTimes.append(seconds(start.duration(to: .now)))
      XCTAssertTrue(result.isEmpty)
    }
    let pinyin = try await store.query(.init(text: "zhongwen", matching: .approximate))
    XCTAssertEqual(pinyin.records.count, 50)
    var transposed = Array("clipboard")
    transposed.swapAt(5, 6)
    let typo = try await store.query(.init(text: String(transposed), matching: .approximate))
    XCTAssertEqual(typo.records.count, 50)
    print(
      "RECORD_APPROXIMATE_STRESS records=10000 cold_full_miss_ms=\(coldMissSeconds * 1000) warm_full_miss_max_ms=\((missTimes.max() ?? 0) * 1000) samples=5"
    )
    // Catch whole-cache maintenance on every payload read, which made the cold scan quadratic.
    XCTAssertLessThan(coldMissSeconds, 5)
    XCTAssertLessThan(missTimes.max() ?? 0, 1)
    let cleanup = try await store.prepareCleanup()
    _ = try await store.confirmCleanup(cleanup)
    let empty = try await RecordStore(persistence: persistence).catalogSnapshot()
    XCTAssertEqual(empty.records.count, 0)
    XCTAssertEqual(empty.capacity.byteCount, 0)
  }
  private func allMatches(in store: RecordStore, query: RecordQuery) async throws -> [RecordSummary] {
    var records: [RecordSummary] = [], offset = 0
    repeat {
      let page = try await store.query(query, offset: offset)
      records += page.records
      guard let next = page.nextOffset else { return records }
      offset = next
    } while true
  }

  private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
