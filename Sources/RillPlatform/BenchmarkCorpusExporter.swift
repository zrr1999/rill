import CryptoKit
import Darwin
import Foundation
import RillCore

/// Plaintext leaves encrypted storage only for an explicit, immutable selection.
public actor BenchmarkCorpusExporter: BenchmarkCorpusExporting {
  private let archive: any BenchmarkRecordingArchiveReading
  private let removeEntry: @Sendable (Int32, String, Int32) -> Bool

  public init(archive: any BenchmarkRecordingArchiveReading) {
    self.init(archive: archive, removeEntry: { directory, name, flags in
      unlinkat(directory, name, flags) == 0 || errno == ENOENT
    })
  }

  init(archive: any BenchmarkRecordingArchiveReading,
    removeEntry: @escaping @Sendable (Int32, String, Int32) -> Bool) {
    self.archive = archive
    self.removeEntry = removeEntry
  }

  public func export(_ selection: BenchmarkCorpusSelection, to parent: URL) async throws -> URL {
    guard !selection.runIDs.isEmpty, Set(selection.runIDs).count == selection.runIDs.count,
      parent.isFileURL else { throw BenchmarkRecordingArchiveError.invalidEntry }
    try Task.checkCancellation()
    let directory = parent.resolvingSymlinksInPath()
    let parentFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else { throw BenchmarkRecordingArchiveError.storageUnavailable }
    defer { Darwin.close(parentFD) }
    let name = "Rill-Evaluation-" + UUID().uuidString
    let stagingName = "." + name + ".partial"
    guard mkdirat(parentFD, stagingName, 0o700) == 0 else {
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
    let stagingFD = openat(parentFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard stagingFD >= 0 else {
      guard removeEntry(parentFD, stagingName, AT_REMOVEDIR) else {
        throw BenchmarkCorpusExportError.cleanupPending(directory.appendingPathComponent(stagingName))
      }
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
    var writtenFiles: [String] = []
    defer { Darwin.close(stagingFD) }
    do {
    var cases: [CorpusCase] = []
    for runID in selection.runIDs {
      try Task.checkCancellation()
      let recording = try await archive.recording(runID: runID)
      try Task.checkCancellation()
      guard recording.receipt.runID == runID,
        recording.receipt.format == .init(sampleRateHz: 16000, channelCount: 1, encoding: .pcm16)
      else { throw BenchmarkRecordingArchiveError.unsupportedPayload }
      let file = runID.uuidString + ".wav"
      writtenFiles.append(file)
      try write(recording.audioBytes, named: file, in: stagingFD)
      cases.append(CorpusCase(id: runID.uuidString, audio_path: file,
        audio_sha256: SHA256.hash(data: recording.audioBytes).map { String(format: "%02x", $0) }.joined(),
        split: selection.split.rawValue))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    writtenFiles.append("corpus.json")
    try write(encoder.encode(Corpus(evidence_kind: selection.evidenceKind.rawValue, cases: cases)),
      named: "corpus.json", in: stagingFD)
    writtenFiles.append("README.txt")
    try write(Data(Self.instructions.utf8), named: "README.txt", in: stagingFD)
    try Task.checkCancellation()
    guard fsync(stagingFD) == 0,
      renameatx_np(parentFD, stagingName, parentFD, name, UInt32(RENAME_EXCL)) == 0 else {
      throw BenchmarkRecordingArchiveError.storageUnavailable
    }
    return directory.appendingPathComponent(name, isDirectory: true)
    } catch {
      var cleaned = true
      for file in writtenFiles {
        if !removeEntry(stagingFD, file, 0) { cleaned = false }
      }
      if !removeEntry(parentFD, stagingName, AT_REMOVEDIR) { cleaned = false }
      guard cleaned else {
        throw BenchmarkCorpusExportError.cleanupPending(directory.appendingPathComponent(stagingName, isDirectory: true))
      }
      throw error
    }
  }

  private func write(_ data: Data, named name: String, in directory: Int32) throws {
    let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw BenchmarkRecordingArchiveError.storageUnavailable }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    try file.write(contentsOf: data)
    try file.synchronize()
  }

  private struct Corpus: Encodable {
    let schema_version = 1
    let annotation_status = "needs_review"
    let evidence_kind: String
    let cases: [CorpusCase]
  }

  private struct CorpusCase: Encodable {
    let id: String
    let audio_path: String
    let audio_sha256: String
    let consent = "authorized"
    let split: String
    let tags = ["unreviewed"]
    let references: [String: String] = [:]
  }

  private static let instructions = """
    Private ASR evaluation recordings / 私人语音评测录音

    These WAV files are plaintext. Keep this folder private; do not commit it to Git or upload it unintentionally.
    这些 WAV 文件为明文。请保管好目录，不要提交到 Git 或无意上传。

    Before quality comparison, listen to each recording and add references.raw and scenario tags in corpus.json.
    Missing reference text is not silence. Use an empty reference only after confirming actual silence.
    Confirm evidence_kind, and separate development and held-out validation cases before tuning.
    Worker replay may run before annotation; quality comparison rejects missing references.
    在质量对比前，请逐条听录音并填写 corpus.json 的 references.raw 和场景 tags。
    缺失标注不代表静音，只有确认静音后才能填写空字符串。
    请核实 evidence_kind，并在调参前分开开发集与保留验收集。
    可以先回放获取识别结果；缺失人工标注时，质量对比会拒绝执行。
    """
}
