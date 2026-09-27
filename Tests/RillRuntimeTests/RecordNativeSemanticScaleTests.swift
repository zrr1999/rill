import CryptoKit
import Foundation
import XCTest

@testable import RillCore
@testable import RillPersistence
@testable import RillProviders
@testable import RillSpeech
@testable import RillWorkflows
@testable import RillRecords
@testable import RillKnowledge

/// Opt-in measurement through encrypted storage and the real supervised MLX helper.
final class RecordNativeSemanticScaleTests: XCTestCase {
  func testPublicCorpusColdWarmAndIdleResume() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let corpusPath = env["RILL_NATIVE_SEMANTIC_CORPUS"],
      let workerPath = env["RILL_NATIVE_SEMANTIC_WORKER"],
      let reportPath = env["RILL_NATIVE_SEMANTIC_REPORT"]
    else {
      throw XCTSkip(
        "Set RILL_NATIVE_SEMANTIC_CORPUS, WORKER and REPORT to measure the real helper.")
    }
    let count = Int(env["RILL_NATIVE_SEMANTIC_COUNT"] ?? "1000") ?? 1_000
    let longCount = Int(env["RILL_NATIVE_SEMANTIC_LONG_COUNT"] ?? "32") ?? 32
    guard (1...10_000).contains(count), (0...count).contains(longCount) else {
      throw RecordEmbeddingError.invalidInput
    }
    let reportURL = URL(fileURLWithPath: reportPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportPath))
    let corpus = try Data(contentsOf: URL(fileURLWithPath: corpusPath))
    let rows = try JSONDecoder().decode([PublicRow].self, from: corpus)
    guard rows.count >= count else { throw RecordEmbeddingError.invalidInput }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-native-semantic-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("fixture.sqlite")
    let (store, payloadBytes) = try await seed(
      rows: Array(rows.prefix(count)), longCount: longCount, database: database)
    let supervisor = SpeechWorkerSupervisor(
      configuration: .init(executableURL: URL(fileURLWithPath: workerPath)))
    let embedder = CountingNativeEmbedder(base: RecordWorkerEmbedder(supervisor: supervisor))
    let search = RecordSemanticSearch(store: store, embedder: embedder)
    do {
      let coldStart = ContinuousClock.now
      let cold = try await search.search(.init(text: "如何配置开发环境并解决连接问题"))
      let coldMilliseconds = milliseconds(since: coldStart)
      let coldCalls = await embedder.documentCalls
      XCTAssertEqual(coldCalls, count)
      let coldPID = await supervisor.activeProcessIdentifier()
      let workerPID = try XCTUnwrap(coldPID)
      let warmQueries = [
        "如何设置代理连接", "如何安装开发工具", "查看项目运行日志", "查找网络错误原因",
        "如何备份数据库", "导出文档内容", "配置本地环境", "如何撤销一次修改",
        "检查服务是否正常", "修复权限问题", "清理临时文件", "关闭后台任务",
        "保存当前工作进度", "查找软件版本", "如何优化查询速度", "更新依赖包",
        "恢复之前的配置", "设置文件共享", "运行自动化检查", "管理多个项目",
      ]
      var warm: [Double] = []
      var literalMiss: [Double] = []
      for query in warmQueries {
        let start = ContinuousClock.now
        _ = try await search.search(.init(text: query))
        warm.append(milliseconds(since: start))
      }
      let warmCalls = await embedder.documentCalls - coldCalls
      XCTAssertEqual(warmCalls, 0, "This fixture's vectors should fit the logical cache budget")
      for index in 0..<20 {
        let start = ContinuousClock.now
        let page = try await store.query(.init(text: "absent-native-benchmark-\(index)"))
        literalMiss.append(milliseconds(since: start))
        XCTAssertTrue(page.records.isEmpty)
      }
      let idleStart = ContinuousClock.now
      let deadline = idleStart.advanced(by: .seconds(35))
      while await supervisor.activeProcessIdentifier() != nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      let idlePID = await supervisor.activeProcessIdentifier()
      XCTAssertNil(idlePID, "The production 30-second idle policy must retire its worker")
      let idleMilliseconds = milliseconds(since: idleStart)
      let resumeStart = ContinuousClock.now
      _ = try await search.search(.init(text: "恢复之前的工作环境"))
      let resumeMilliseconds = milliseconds(since: resumeStart)
      let warmPID = await supervisor.activeProcessIdentifier()
      let resumedPID = try XCTUnwrap(warmPID)
      XCTAssertNotEqual(workerPID, resumedPID)
      let resumeCalls = await embedder.documentCalls - coldCalls - warmCalls
      XCTAssertEqual(resumeCalls, 0, "Process retirement must not invalidate document vectors")
      let windows = await embedder.documentWindows
      await search.shutdown()
      let remainingPID = await supervisor.activeProcessIdentifier()
      XCTAssertNil(remainingPID)
      let report = NativeReport(
        corpusSHA256: SHA256.hash(data: corpus).map { String(format: "%02x", $0) }.joined(),
        records: count, repeatedLongRecords: longCount, payloadBytes: payloadBytes,
        documentWindows: windows, limitedRecords: cold.limitedRecordCount,
        coldMilliseconds: coldMilliseconds, warmMilliseconds: warm,
        literalEmptyFirstPageMilliseconds: literalMiss, idleWaitMilliseconds: idleMilliseconds,
        resumeMilliseconds: resumeMilliseconds, coldDocumentEncodes: coldCalls,
        warmDocumentEncodes: warmCalls, resumeDocumentEncodes: resumeCalls,
        workerPIDs: [workerPID, resumedPID], workerStopped: remainingPID == nil,
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: reportURL, options: .withoutOverwriting)
      print(
        "NATIVE_SEMANTIC_SCALE records=\(count) long_records=\(longCount) cold_ms=\(coldMilliseconds) warm_p95_ms=\(warm.sorted()[18]) resume_ms=\(resumeMilliseconds)"
      )
    } catch {
      await search.shutdown()
      throw error
    }
  }

  func testPublicCorpusLiteralFullScan() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let corpusPath = env["RILL_NATIVE_SEMANTIC_CORPUS"],
      let reportPath = env["RILL_NATIVE_LITERAL_REPORT"]
    else {
      throw XCTSkip(
        "Set RILL_NATIVE_SEMANTIC_CORPUS and RILL_NATIVE_LITERAL_REPORT for full scans.")
    }
    let count = Int(env["RILL_NATIVE_SEMANTIC_COUNT"] ?? "1000") ?? 1_000
    let longCount = Int(env["RILL_NATIVE_SEMANTIC_LONG_COUNT"] ?? "32") ?? 32
    let corpus = try Data(contentsOf: URL(fileURLWithPath: corpusPath))
    let rows = try JSONDecoder().decode([PublicRow].self, from: corpus)
    guard (1...10_000).contains(count), rows.count >= count, (0...count).contains(longCount),
      !FileManager.default.fileExists(atPath: reportPath)
    else { throw RecordEmbeddingError.invalidInput }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-literal-scale-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (store, payloadBytes) = try await seed(
      rows: Array(rows.prefix(count)), longCount: longCount,
      database: directory.appendingPathComponent("fixture.sqlite"))
    let start = ContinuousClock.now
    let pages = try await fullMiss(in: store, text: "absent-native-full-scan-cold")
    let cold = milliseconds(since: start)
    var samples: [Double] = []
    for index in 0..<20 {
      let start = ContinuousClock.now
      let warmPages = try await fullMiss(in: store, text: "absent-native-full-scan-\(index)")
      samples.append(milliseconds(since: start))
      XCTAssertEqual(warmPages, pages)
    }
    let report = LiteralReport(
      records: count, repeatedLongRecords: longCount, payloadBytes: payloadBytes,
      pagesPerQuery: pages, coldMilliseconds: cold, warmMilliseconds: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(
      to: URL(fileURLWithPath: reportPath), options: .withoutOverwriting)
    print(
      "NATIVE_LITERAL_FULL_SCAN records=\(count) pages=\(pages) cold_ms=\(cold) warm_p95_ms=\(samples.sorted()[18])"
    )
  }

  private func fullMiss(in store: RecordStore, text: String) async throws -> Int {
    var offset = 0
    var pages = 0
    while true {
      let page = try await store.query(.init(text: text), offset: offset)
      XCTAssertTrue(page.records.isEmpty)
      pages += 1
      guard let next = page.nextOffset else { return pages }
      offset = next
    }
  }

  private struct LiteralReport: Encodable {
    let records: Int
    let repeatedLongRecords: Int
    let payloadBytes: Int
    let pagesPerQuery: Int
    let coldMilliseconds: Double
    let warmMilliseconds: [Double]
  }

  private struct PublicRow: Decodable { let text: String }

  private struct NativeReport: Encodable {
    let corpusSHA256: String
    let records: Int
    let repeatedLongRecords: Int
    let payloadBytes: Int
    let documentWindows: Int
    let limitedRecords: Int
    let coldMilliseconds: Double
    let warmMilliseconds: [Double]
    let literalEmptyFirstPageMilliseconds: [Double]
    let idleWaitMilliseconds: Double
    let resumeMilliseconds: Double
    let coldDocumentEncodes: Int
    let warmDocumentEncodes: Int
    let resumeDocumentEncodes: Int
    let workerPIDs: [pid_t]
    let workerStopped: Bool
    let operatingSystem: String
  }

  private func seed(rows: [PublicRow], longCount: Int, database: URL) async throws -> (
    RecordStore, Int
  ) {
    let protector = try AESGCMDataProtector(
      key: Data(repeating: 0x4E, count: AESGCMDataProtector.keyByteCount))
    let persistence = try SQLitePersistenceStore(
      databaseURL: database, localDataProtector: protector)
    let initial = try await RecordStore().catalogSnapshot()
    let encoder = JSONEncoder()
    var nodes: [RecordCatalogNode] = []
    var blobs: [RecordGraphPersistenceBlob] = []
    var order: [RecordID] = []
    func node<T: Encodable>(_ kind: RecordCatalogNode.Kind, id: String, value: T) throws {
      nodes.append(.init(kind: kind, id: id, value: try encoder.encode(value)))
    }
    for value in initial.collections {
      try node(.collection, id: value.id.description, value: value)
    }
    for value in initial.captureRules {
      try node(.captureRule, id: value.id.description, value: value)
    }
    for value in initial.deliveryRules {
      try node(.deliveryRule, id: value.id.description, value: value)
    }
    var total = 0
    for (index, row) in rows.enumerated() {
      let text = index < longCount ? String(repeating: row.text + "\n", count: 100) : row.text
      let data = Data(text.utf8)
      let record = Record(
        payload: .text(text),
        provenance: .init(
          source: .init(kind: .systemClipboard), sourceApplicationName: "PublicCorpus"),
        createdAt: Date(timeIntervalSince1970: Double(index)))
      order.append(record.id)
      total += data.count
      try node(
        .record, id: record.id.description,
        value: RecordHeader(record: record, byteCount: data.count))
      try node(.metadata, id: record.id.description, value: RecordMetadata(recordID: record.id))
      try node(.activity, id: record.id.description, value: RecordActivity(recordID: record.id))
      blobs.append(
        .init(
          reference: .init(blobID: UUID(), recordID: record.id, kind: .text, byteCount: data.count),
          payload: data))
    }
    _ = try await persistence.commitRecordCatalog(
      .init(
        expectedRevision: nil,
        manifest: .init(
          nextMembershipOrdinal: 1, recordOrder: order.reversed(),
          collectionOrder: initial.collections.map(\.id)), upserts: nodes, removedKeys: [],
        newPayloadBlobs: blobs, removedPayloadBlobIDs: []))
    return (RecordStore(persistence: persistence), total)
  }

  private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
  }
}

private actor CountingNativeEmbedder: RecordEmbeddingProvider {
  let base: RecordWorkerEmbedder
  var documentCalls = 0
  var documentWindows = 0
  init(base: RecordWorkerEmbedder) { self.base = base }
  func prepare(downloadIfNeeded: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
  {
    try await base.prepare(downloadIfNeeded: downloadIfNeeded, progress: progress)
  }
  func embed(_ text: String, purpose: RecordEmbeddingPurpose) async throws -> RecordTextEmbedding {
    let result = try await base.embed(text, purpose: purpose)
    if purpose == .document {
      documentCalls += 1
      documentWindows += result.vectors.count
    }
    return result
  }
  func shutdown() async { await base.shutdown() }
}
