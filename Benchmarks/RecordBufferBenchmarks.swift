import Darwin
import Foundation
import RillCore
import RillPersistence
import RillRuntime
import SQLite3

@main
struct RecordBufferBenchmarks {
    static let entryCount = 10_000

    static func main() async throws {
        let recorder = CodSpeedRecorder()
        let rounds = recorder.isInstrumented ? 5 : 1
        for buffer in RecordBuffer.defaults {
            var batches: [String: [Double]] = [:]
            for round in 0..<rounds {
                let result = try await run(buffer: buffer, recorder: recorder)
                for (operation, elapsed) in result.batches {
                    batches[operation, default: []].append(elapsed)
                }
                print("Validated \(buffer.policy.rawValue): \(entryCount) encrypted entries, round \(round + 1)")
                for (operation, samples) in result.operations.sorted(by: { $0.key < $1.key }) {
                    print("  \(operation) P50/P95/P99 ms: \(percentiles(samples))")
                }
                print("  resident delta bytes: \(result.residentDelta); database delta bytes: \(result.databaseDelta)")
            }
            for (operation, samples) in batches.sorted(by: { $0.key < $1.key }) {
                recorder.record(
                    name: "\(buffer.policy.rawValue) \(operation)", uri: uri(buffer, operation),
                    samples: samples, warmupIterations: 0
                )
            }
        }
        try recorder.write()
    }

    private struct Result {
        var batches: [String: Double] = [:]
        var operations: [String: [Double]] = [:]
        var residentDelta: Int64 = 0
        var databaseDelta: Int = 0
    }

    private static func run(buffer: RecordBuffer, recorder: CodSpeedRecorder) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-buffer-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLitePersistenceStore(
            databaseURL: directory.appendingPathComponent("data.sqlite"),
            localDataProtector: AESGCMDataProtector(key: Data(repeating: 0x45, count: AESGCMDataProtector.keyByteCount))
        )
        let ids = try await seed(repository)
        let store = RecordStore(persistence: repository)
        _ = try await store.bufferSnapshot()
        // Warm the write and payload-read paths without retaining a pending entry.
        _ = try await store.enqueueRecord(ids[0], in: buffer.id)
        let warmup = try await store.beginBufferOutput()
        try await store.finishBufferOutput(warmup.entry.id)

        var result = Result()
        let beforeMemory = try residentBytes()
        let beforeBytes = try diskBytes(directory)
        recorder.begin()
        let enqueueStart = ContinuousClock.now
        let enqueue = try await __codspeed_root_frame__enqueue(store, buffer.id, ids)
        result.batches["enqueue"] = nanoseconds(enqueueStart.duration(to: .now))
        recorder.end(uri: uri(buffer, "enqueue"))
        result.residentDelta = Int64(try residentBytes()) - Int64(beforeMemory)
        result.databaseDelta = try diskBytes(directory) - beforeBytes
        result.operations["enqueue"] = enqueue.samples
        let fullSnapshot = try await store.bufferSnapshot()
        precondition(fullSnapshot.remainingCount == entryCount)
        let restored = RecordStore(persistence: repository)
        let restoredSnapshot = try await restored.bufferSnapshot()
        precondition(restoredSnapshot.remainingCount == entryCount)
        let expected = buffer.policy == .stack ? Array(enqueue.entries.reversed()) : enqueue.entries
        precondition(restoredSnapshot.next?.id == expected[0])

        recorder.begin()
        let selectStart = ContinuousClock.now
        result.operations["select"] = try await __codspeed_root_frame__select(store, expected[0])
        result.batches["select"] = nanoseconds(selectStart.duration(to: .now))
        recorder.end(uri: uri(buffer, "select"))

        recorder.begin()
        let outputStart = ContinuousClock.now
        let output = try await __codspeed_root_frame__output(store, expected, policy: buffer.policy)
        result.batches["output"] = nanoseconds(outputStart.duration(to: .now))
        recorder.end(uri: uri(buffer, "output"))
        result.operations["prepare"] = output.prepare
        result.operations["commit"] = output.commit
        let empty = try await store.bufferSnapshot()
        precondition(empty.remainingCount == 0 && empty.active == nil && empty.next == nil)
        let finalStore = RecordStore(persistence: repository)
        let persisted = try await finalStore.bufferSnapshot()
        precondition(persisted.remainingCount == 0 && persisted.active == nil)
        return result
    }

    @inline(never)
    private static func __codspeed_root_frame__enqueue(
        _ store: RecordStore, _ bufferID: RecordBufferID, _ ids: [RecordID]
    ) async throws -> (entries: [BufferEntryID], samples: [Double]) {
        var entries: [BufferEntryID] = []
        var samples: [Double] = []
        entries.reserveCapacity(entryCount)
        samples.reserveCapacity(entryCount)
        for id in ids {
            let start = ContinuousClock.now
            let entry = try await store.enqueueRecord(id, in: bufferID)
            samples.append(nanoseconds(start.duration(to: .now)))
            entries.append(entry)
        }
        return (entries, samples)
    }

    @inline(never)
    private static func __codspeed_root_frame__select(
        _ store: RecordStore, _ expected: BufferEntryID
    ) async throws -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let start = ContinuousClock.now
            let snapshot = try await store.bufferSnapshot()
            samples.append(nanoseconds(start.duration(to: .now)))
            precondition(snapshot.next?.id == expected && snapshot.remainingCount == entryCount)
        }
        return samples
    }

    @inline(never)
    private static func __codspeed_root_frame__output(
        _ store: RecordStore, _ expected: [BufferEntryID], policy: RecordBuffer.Policy
    ) async throws -> (prepare: [Double], commit: [Double]) {
        var prepare: [Double] = []
        var commit: [Double] = []
        prepare.reserveCapacity(entryCount)
        commit.reserveCapacity(entryCount)
        for (offset, id) in expected.enumerated() {
            var start = ContinuousClock.now
            let output = try await store.beginBufferOutput()
            prepare.append(nanoseconds(start.duration(to: .now)))
            precondition(output.entry.id == id && output.record.id == output.entry.recordID)
            let index = policy == .stack ? entryCount - 1 - offset : offset
            precondition(output.record.payload == .text(fixtureText(index)))
            start = .now
            try await store.finishBufferOutput(id)
            commit.append(nanoseconds(start.duration(to: .now)))
        }
        return (prepare, commit)
    }

    private static func seed(_ repository: SQLitePersistenceStore) async throws -> [RecordID] {
        let encoder = JSONEncoder()
        var nodes: [RecordCatalogNode] = []
        var blobs: [RecordGraphPersistenceBlob] = []
        func node<T: Encodable>(_ kind: RecordCatalogNode.Kind, _ id: String, _ value: T) throws {
            nodes.append(.init(kind: kind, id: id, value: try encoder.encode(value)))
        }
        let collections = [RecordCollection.inbox, .voiceInput]
        for collection in collections { try node(.collection, collection.id.description, collection) }
        for buffer in RecordBuffer.defaults { try node(.buffer, buffer.id.description, buffer) }
        try node(.bufferClock, "input-sequence", UInt64(1))
        var ids: [RecordID] = []
        for index in 0..<entryCount {
            let text = fixtureText(index)
            let data = Data(text.utf8)
            let record = Record(payload: .text(text), provenance: .init(source: .init(kind: .systemClipboard)))
            ids.append(record.id)
            try node(.record, record.id.description, RecordHeader(record: record, byteCount: data.count))
            try node(.metadata, record.id.description, RecordMetadata(recordID: record.id))
            try node(.activity, record.id.description, RecordActivity(recordID: record.id))
            blobs.append(.init(
                reference: .init(blobID: UUID(), recordID: record.id, kind: .text, byteCount: data.count), payload: data
            ))
        }
        _ = try await repository.commitRecordCatalog(.init(
            expectedRevision: nil,
            manifest: .init(nextMembershipOrdinal: 1, recordOrder: ids, collectionOrder: collections.map(\.id)),
            upserts: nodes, removedKeys: [], newPayloadBlobs: blobs, removedPayloadBlobIDs: []
        ))
        return ids
    }

    private static func uri(_ buffer: RecordBuffer, _ operation: String) -> String {
        "Benchmarks/RecordBufferBenchmarks.swift::\(buffer.policy.rawValue) \(operation)[\(entryCount)]"
    }

    private static func fixtureText(_ index: Int) -> String {
        "Benchmark 中文 🙂 \(index)"
    }

    private static func nanoseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e9 + Double(duration.components.attoseconds) / 1e9
    }

    private static func percentiles(_ values: [Double]) -> String {
        let sorted = values.sorted()
        return [0.50, 0.95, 0.99].map {
            String(format: "%.3f", sorted[Int(Double(sorted.count - 1) * $0)] / 1e6)
        }.joined(separator: "/")
    }

    private static func diskBytes(_ directory: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("data.sqlite").path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) {
            try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    private static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw CocoaError(.featureUnsupported) }
        return info.resident_size
    }
}
