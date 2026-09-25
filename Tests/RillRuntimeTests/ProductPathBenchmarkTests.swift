import CryptoKit
import Darwin
import Foundation
import RillCore
import RillDomainTestSupport
import RillPersistence
import RillPlatform
import RillProviders
import RillRecords
import RillSpeech
import Testing
@testable import RillWorkflows

struct ProductPathBenchmarkTests {
  @Test func fixedFixtureExercisesRecognitionProcessingCommitAndOrderedOutput() async throws {
    let fixture = try HostPipeline(recognizer: FixedBenchmarkRecognizer(), keyterms: [],
      replacements: [.init(pattern: "rill", replacement: "Rill")])
    defer { fixture.remove() }
    let result = try await fixture.run(audio: CapturedAudio(durationSeconds: 1,
      format: .init(sampleRateHz: 16000, channelCount: 1, encoding: .pcm16), inlineData: Data([0, 0])),
      options: .init(modelID: "fixture"))
    #expect(result.status == "ok")
    #expect(result.texts["raw"] == "  rill 不要 删除 2026  ")
    #expect(result.texts["vocabulary"] == "  Rill 不要 删除 2026  ")
    #expect(result.texts["final"] == "Rill 不要 删除 2026")
    #expect(result.storedBeforeDispatch)
    let metrics = result.metrics
    #expect(try #require(metrics["host_replay_to_final_ms"]) <= #require(metrics["host_replay_to_saved_ms"]))
    #expect(try #require(metrics["host_replay_to_saved_ms"]) <= #require(metrics["host_replay_to_isolated_dispatch_ms"]))
  }

  @Test func unexpectedModelIdentityCannotBecomeScoredText() async throws {
    let fixture = try HostPipeline(recognizer: FixedBenchmarkRecognizer(), keyterms: [],
      replacements: [], expectedModel: ("expected", "revision"))
    defer { fixture.remove() }
    let result = try await fixture.run(audio: CapturedAudio(durationSeconds: 1,
      format: .init(sampleRateHz: 16000, channelCount: 1, encoding: .pcm16), inlineData: Data([0, 0])),
      options: .init(modelID: "expected"))
    #expect(result.status == "failed")
    #expect(result.failure == "model_identity_mismatch")
    #expect(result.texts.isEmpty)
    #expect(result.metrics.isEmpty)
    #expect(try await fixture.store.snapshot().records.isEmpty)
  }

  @Test func recognizedSilenceIsSuccessfulRecognitionWithoutCommitOrOutput() async throws {
    let fixture = try HostPipeline(recognizer: FixedBenchmarkRecognizer(text: ""), keyterms: [], replacements: [])
    defer { fixture.remove() }
    let result = try await fixture.run(audio: CapturedAudio(durationSeconds: 1,
      format: .init(sampleRateHz: 16000, channelCount: 1, encoding: .pcm16), inlineData: Data([0, 0])),
      options: .init(modelID: "fixture"))
    #expect(result.status == "ok")
    #expect(result.productOutcome == "no_speech")
    #expect(result.texts == ["raw": ""])
    #expect(result.metrics.keys.sorted() == ["host_replay_to_final_ms"])
    #expect(!result.storedBeforeDispatch)
    #expect(try await fixture.store.snapshot().records.isEmpty)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_PRODUCT_BENCHMARK_REQUEST"] != nil))
  func authorizedReleaseCorpusThroughProductionHostPipeline() async throws {
    #if DEBUG
    throw BenchmarkFailure.releaseRequired
    #else
    let environment = ProcessInfo.processInfo.environment
    let requestURL = URL(fileURLWithPath: try #require(environment["RILL_PRODUCT_BENCHMARK_REQUEST"]))
    let request = try JSONDecoder().decode(HostBenchmarkRequest.self, from: Data(contentsOf: requestURL))
    let supervisor = SpeechWorkerSupervisor(configuration: .init(executableURL: URL(fileURLWithPath: request.worker)))
    let settings = LocalSpeechSettings(model: request.modelID, downloadIfNeeded: false,
      enabledModelIDs: [request.modelID], residentModelIDs: [request.modelID])
    let recognizer = MLXAudioSwiftWorkerRecognizer(supervisor: supervisor, settingsProvider: { settings })
    do {
      _ = try await recognizer.prepareModel(modelIdentifier: request.modelID, downloadIfNeeded: false)
      let fixture = try HostPipeline(recognizer: recognizer, keyterms: request.keyterms, replacements: request.replacements,
        expectedModel: (request.modelID, request.modelRevision))
      defer { fixture.remove() }
      let output = try FileHandle(forWritingTo: URL(fileURLWithPath: request.output))
      defer { try? output.close() }
      try output.seekToEnd()
      if request.cacheState == "warm", let item = request.cases.first, let warmupOutput = request.warmupOutput {
        let audio = try copyFixture(item)
        defer { _ = try? audio.removeManagedTemporaryFile() }
        var result = try await fixture.run(audio: audio, options: .init(modelID: request.modelID, language: request.language))
        result.caseID = item.id
        result.audioSHA256 = item.audioSHA256
        result.cacheState = "first_inference"
        let warmup = try FileHandle(forWritingTo: URL(fileURLWithPath: warmupOutput))
        defer { try? warmup.close() }
        try warmup.seekToEnd()
        try warmup.write(contentsOf: JSONEncoder().encode(result) + Data([10]))
        try warmup.synchronize()
        guard result.status == "ok" else { throw BenchmarkFailure.incompletePipeline }
      }
      for repetition in 1...request.repetitions {
        for item in request.cases {
          if request.cacheState == "first_inference" {
            try await recognizer.releaseLoadedModel()
            _ = try await recognizer.prepareModel(modelIdentifier: request.modelID, downloadIfNeeded: false)
          }
          let audio = try copyFixture(item)
          defer { _ = try? audio.removeManagedTemporaryFile() }
          var result = try await fixture.run(audio: audio, options: .init(modelID: request.modelID, language: request.language))
          result.caseID = item.id
          result.audioSHA256 = item.audioSHA256
          result.repetition = repetition
          result.cacheState = request.cacheState
          try output.write(contentsOf: JSONEncoder().encode(result) + Data([10]))
          try output.synchronize()
        }
      }
      await fixture.coordinator.shutdownRecordDeliverySettlements()
      try await supervisor.shutdown()
    } catch {
      try? await supervisor.shutdown()
      throw error
    }
    #endif
  }
}

private enum BenchmarkFailure: Error { case releaseRequired, fixtureChanged, incompletePipeline, outputBeforeCommit, modelIdentityMismatch }

private struct HostBenchmarkRequest: Decodable {
  struct Fixture: Decodable {
    let id: String
    let audioPath: String
    let audioSHA256: String
    let durationSeconds: Double
    let consent: String
  }
  let worker: String
  let output: String
  let modelID: String
  let modelRevision: String
  let cacheState: String
  let warmupOutput: String?
  let language: String?
  let keyterms: [String]
  let replacements: [BenchmarkReplacement]
  let repetitions: Int
  let cases: [Fixture]
}

private struct BenchmarkReplacement: Codable, Sendable {
  let pattern: String
  let replacement: String
}

private struct HostBenchmarkResult: Encodable, Sendable {
  var caseID = "fixture"
  var audioSHA256 = ""
  var repetition = 1
  var cacheState = "warm"
  let status: String
  let failure: String?
  let texts: [String: String]
  let metrics: [String: Double]
  let storedBeforeDispatch: Bool
  var productOutcome: String? = nil
  enum CodingKeys: String, CodingKey {
    case caseID = "case_id", audioSHA256 = "audio_sha256", repetition, cacheState = "cache_state"
    case status, failure, texts, metrics, storedBeforeDispatch = "stored_before_dispatch"
    case productOutcome = "product_outcome"
  }
}

private struct HostPipeline {
  let directory: URL
  let database: SQLitePersistenceStore
  let store: RecordStore
  let coordinator: SessionCoordinator
  let workflow: WorkflowDefinition
  let measurements: HostMeasurements

  init(recognizer: any SpeechRecognizer, keyterms: [String], replacements: [BenchmarkReplacement],
    expectedModel: (id: String, revision: String)? = nil) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-host-benchmark-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    database = try SQLitePersistenceStore(databaseURL: directory.appendingPathComponent("evaluation.sqlite"),
      localDataProtector: AESGCMDataProtector(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }))
    store = RecordStore(persistence: database)
    measurements = HostMeasurements(store: store)
    let eventBus = EventBus()
    let collection = VocabularyCollection.personal(entries:
      keyterms.enumerated().map { VocabularyEntry(content: .hotword(phrase: $0.element), priority: -$0.offset) }
      + replacements.enumerated().map { VocabularyEntry(rule: VocabularyRule(pattern: $0.element.pattern,
        replacement: $0.element.replacement, priority: -$0.offset)) })
    var declaration = WorkflowDefinition(name: "Private host replay",
      pipeline: .init(recognizerID: recognizer.id,
        postProcessSteps: [.init(kind: .normalizeWhitespace)],
        outputActions: [.init(id: RecordActionID.store), .init(id: "system-clipboard.copy")],
        uncertaintyPolicy: .init(mode: .off)),
      ui: .init(symbolName: "waveform", accentColorName: "blue"))
    declaration.plan.setup.vocabularyBindings = [.init(collectionID: collection.id)]
    workflow = declaration
    let save = RecordStoreAction(ingestion: MeasuredIngestion(base: RecordIngestionCoordinator(store: store), measurements: measurements))
    coordinator = makeTestSessionCoordinator(
      recognizerRegistry: .init(recognizers: [MeasuredRecognizer(base: recognizer, measurements: measurements, expectedModel: expectedModel)]),
      transformerRegistry: .init(transformers: [WhitespaceNormalizerTransformer()]),
      actionRegistry: .init(actions: [save,
        IsolatedBenchmarkOutput(measurements: measurements)]),
      candidateResolver: CandidateResolver(eventBus: eventBus), recordStore: store,
      eventBus: eventBus, runReceiptRecorder: WorkflowRunReceiptRecorder(repository: database),
      vocabularyCollectionProvider: { [collection] })
  }

  func run(audio: CapturedAudio, options: SpeechRecognitionRequestOptions) async throws -> HostBenchmarkResult {
    let runID = UUID()
    await measurements.begin()
    let result = await coordinator.runReportingOutcome(workflow: workflow, runID: runID,
      capturedAudio: audio, contextSnapshot: .empty, recognitionOptions: options)
    let measured = await measurements.snapshot()
    switch result {
    case .completed(let summary):
      let receipts = try await database.receipts(matching: .init(runID: runID))
      guard receipts.first?.actionDetails.map(\.result) == [.storedRecord, .copiedToClipboard],
        measured.storedBeforeDispatch else { throw BenchmarkFailure.incompletePipeline }
      let raw = try #require(measured.raw)
      let vocabulary = summary.correctionSource?.processingSteps?.first { $0.kind == .applyVocabulary }?.outputText
      return .init(status: "ok", failure: nil,
        texts: ["raw": raw, "vocabulary": vocabulary ?? raw, "final": summary.finalText],
        metrics: measured.metrics, storedBeforeDispatch: measured.storedBeforeDispatch)
    case .failed(let failure):
      if failure.code == .noSpeech, let raw = measured.raw {
        guard try await !store.snapshot().records.contains(where: { $0.record.provenance.workflowRunID == runID }),
          measured.metrics["host_replay_to_saved_ms"] == nil, !measured.storedBeforeDispatch else {
          throw BenchmarkFailure.incompletePipeline
        }
        return .init(status: "ok", failure: nil, texts: ["raw": raw], metrics: measured.metrics,
          storedBeforeDispatch: false, productOutcome: "no_speech")
      }
      return .init(status: "failed", failure: measured.failure ?? failure.code.rawValue,
        texts: measured.raw.map { ["raw": $0] } ?? [:], metrics: measured.metrics, storedBeforeDispatch: false)
    case .cancelled:
      return .init(status: "cancelled", failure: "cancelled", texts: measured.raw.map { ["raw": $0] } ?? [:], metrics: measured.metrics, storedBeforeDispatch: false)
    }
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor HostMeasurements {
  let store: RecordStore
  var start = ContinuousClock.now
  var raw: String?
  var failure: String?
  var storedID: RecordID?
  var metrics: [String: Double] = [:]
  var storedBeforeDispatch = false
  init(store: RecordStore) { self.store = store }
  func begin() { start = .now; raw = nil; failure = nil; storedID = nil; metrics = [:]; storedBeforeDispatch = false }
  func recognized(_ text: String, at instant: ContinuousClock.Instant) {
    raw = text
    metrics["host_replay_to_final_ms"] = milliseconds(to: instant)
  }
  func saved(id: RecordID, at instant: ContinuousClock.Instant) { storedID = id; metrics["host_replay_to_saved_ms"] = milliseconds(to: instant) }
  func identityMismatch() { failure = "model_identity_mismatch" }
  func dispatch(_ draft: RecordDraft, runID: UUID) async throws {
    let dispatchedAt = ContinuousClock.now
    guard let storedID, let stored = try await store.record(id: storedID),
      stored.record.provenance.workflowRunID == runID && stored.record.payload == draft.payload else {
      throw BenchmarkFailure.outputBeforeCommit
    }
    storedBeforeDispatch = true
    metrics["host_replay_to_isolated_dispatch_ms"] = milliseconds(to: dispatchedAt)
  }
  func snapshot() -> (raw: String?, failure: String?, metrics: [String: Double], storedBeforeDispatch: Bool) { (raw, failure, metrics, storedBeforeDispatch) }
  private func milliseconds(to instant: ContinuousClock.Instant) -> Double {
    let parts = start.duration(to: instant).components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
  }
}

private struct MeasuredRecognizer: SpeechRecognizer {
  let base: any SpeechRecognizer
  let measurements: HostMeasurements
  let expectedModel: (id: String, revision: String)?
  var id: String { base.id }
  var capabilities: SpeechRecognizerCapabilities { base.capabilities }
  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    let result = try await base.recognize(request)
    if let expectedModel,
      result.metadata["provider.model"] != expectedModel.id || result.metadata["provider.model_revision"] != expectedModel.revision {
      await measurements.identityMismatch()
      throw BenchmarkFailure.modelIdentityMismatch
    }
    await measurements.recognized(result.rawText, at: .now)
    return result
  }
}

private struct MeasuredIngestion: RecordIngestionSink {
  let base: RecordIngestionCoordinator
  let measurements: HostMeasurements
  func ingest(_ envelope: RecordCaptureEnvelope) async throws -> RecordProjection {
    let projection = try await base.ingest(envelope)
    await measurements.saved(id: projection.record.id, at: .now)
    return projection
  }
}

private struct IsolatedBenchmarkOutput: OutputAction {
  let id = "system-clipboard.copy"
  let measurements: HostMeasurements
  func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    try await measurements.dispatch(record, runID: context.runID)
    return .copiedToClipboard
  }
}

private struct FixedBenchmarkRecognizer: SpeechRecognizer {
  let id = "local-speech"
  let capabilities = SpeechRecognizerCapabilities(supportedHintKinds: [.keyterm])
  var text = "  rill 不要 删除 2026  "
  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    .init(rawText: text, bestText: text)
  }
}

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func copyFixture(_ item: HostBenchmarkRequest.Fixture) throws -> CapturedAudio {
  let bytes = try Data(contentsOf: URL(fileURLWithPath: item.audioPath))
  guard item.consent == "authorized", sha256(bytes) == item.audioSHA256 else { throw BenchmarkFailure.fixtureChanged }
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rill-benchmark-" + UUID().uuidString + ".wav")
  let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  guard descriptor >= 0 else { throw BenchmarkFailure.fixtureChanged }
  let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  defer { try? file.close() }
  do {
    try file.write(contentsOf: bytes)
    return try CapturedAudio(durationSeconds: item.durationSeconds,
      format: .init(sampleRateHz: 16000, channelCount: 1, encoding: .pcm16), fileURL: temporary, fileOwnership: .managedTemporary)
  } catch {
    try? FileManager.default.removeItem(at: temporary)
    throw error
  }
}
