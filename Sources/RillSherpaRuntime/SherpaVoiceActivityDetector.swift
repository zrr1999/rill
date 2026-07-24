import CSherpaOnnx
import CryptoKit
import Darwin
import Foundation

private final class SherpaRuntimeBundleToken {}

enum SherpaBundledModelLocator {
  static let resourceBundleFilename = "RillMacOS_RillSherpaRuntime.bundle"

  static func locate(
    searchRoots: [URL?],
    resolveModelInBundle: (URL) -> URL?
  ) -> URL? {
    for root in searchRoots.compactMap({ $0 }) {
      let bundleURL = root.appendingPathComponent(
        resourceBundleFilename,
        isDirectory: true
      )
      if let modelURL = resolveModelInBundle(bundleURL) {
        return modelURL
      }
    }
    return nil
  }
}

private struct SherpaModelFileIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
  let size: off_t

  init(status: stat) {
    device = status.st_dev
    inode = status.st_ino
    size = status.st_size
  }
}

private final class SherpaValidatedModelFile {
  let modelURL: URL

  private let descriptor: Int32
  private let identity: SherpaModelFileIdentity
  private let expectedSHA256: String

  private init(
    modelURL: URL,
    descriptor: Int32,
    identity: SherpaModelFileIdentity,
    expectedSHA256: String
  ) {
    self.modelURL = modelURL
    self.descriptor = descriptor
    self.identity = identity
    self.expectedSHA256 = expectedSHA256
  }

  deinit {
    Darwin.close(descriptor)
  }

  static func openValidated(
    modelURL: URL,
    expectedSHA256: String
  ) throws -> SherpaValidatedModelFile {
    let descriptor = modelURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw SherpaVoiceActivityDetectorError.missingModel(modelURL)
    }

    do {
      let initialStatus = try descriptorStatus(descriptor, modelURL: modelURL)
      guard isRegularSingleLink(initialStatus) else {
        throw SherpaVoiceActivityDetectorError.missingModel(modelURL)
      }
      let identity = SherpaModelFileIdentity(status: initialStatus)
      let actualSHA256 = try sha256(
        descriptor: descriptor,
        byteCount: identity.size,
        modelURL: modelURL
      )
      let finalStatus = try descriptorStatus(descriptor, modelURL: modelURL)
      guard isRegularSingleLink(finalStatus),
        SherpaModelFileIdentity(status: finalStatus) == identity
      else {
        throw SherpaVoiceActivityDetectorError.modelChangedDuringLoad(modelURL)
      }
      guard actualSHA256 == expectedSHA256 else {
        throw SherpaVoiceActivityDetectorError.modelIntegrityCheckFailed(
          expected: expectedSHA256,
          actual: actualSHA256
        )
      }
      return SherpaValidatedModelFile(
        modelURL: modelURL,
        descriptor: descriptor,
        identity: identity,
        expectedSHA256: expectedSHA256
      )
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  func validatePathIdentity() throws {
    var pathStatus = stat()
    let result = modelURL.path.withCString { path in
      Darwin.lstat(path, &pathStatus)
    }
    guard result == 0,
      Self.isRegularSingleLink(pathStatus),
      SherpaModelFileIdentity(status: pathStatus) == identity
    else {
      throw SherpaVoiceActivityDetectorError.modelChangedDuringLoad(modelURL)
    }
  }

  func revalidateAfterNativeLoad() throws {
    let initialStatus = try Self.descriptorStatus(descriptor, modelURL: modelURL)
    guard Self.isRegularSingleLink(initialStatus),
      SherpaModelFileIdentity(status: initialStatus) == identity
    else {
      throw SherpaVoiceActivityDetectorError.modelChangedDuringLoad(modelURL)
    }

    let actualSHA256 = try Self.sha256(
      descriptor: descriptor,
      byteCount: identity.size,
      modelURL: modelURL
    )
    let finalStatus = try Self.descriptorStatus(descriptor, modelURL: modelURL)
    guard Self.isRegularSingleLink(finalStatus),
      SherpaModelFileIdentity(status: finalStatus) == identity,
      actualSHA256 == expectedSHA256
    else {
      throw SherpaVoiceActivityDetectorError.modelChangedDuringLoad(modelURL)
    }
  }

  private static func descriptorStatus(
    _ descriptor: Int32,
    modelURL: URL
  ) throws -> stat {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw SherpaVoiceActivityDetectorError.failedToReadModel(modelURL)
    }
    return status
  }

  private static func isRegularSingleLink(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 1 && status.st_size >= 0
  }

  private static func sha256(
    descriptor: Int32,
    byteCount: off_t,
    modelURL: URL
  ) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var offset: off_t = 0

    while offset < byteCount {
      let requestedCount = Int(min(off_t(buffer.count), byteCount - offset))
      let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        Darwin.pread(descriptor, bytes.baseAddress, requestedCount, offset)
      }
      if bytesRead < 0 {
        if errno == EINTR {
          continue
        }
        throw SherpaVoiceActivityDetectorError.failedToReadModel(modelURL)
      }
      guard bytesRead > 0 else {
        throw SherpaVoiceActivityDetectorError.modelChangedDuringLoad(modelURL)
      }
      hasher.update(data: Data(buffer[..<bytesRead]))
      offset += off_t(bytesRead)
    }

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public struct SherpaVoiceActivityObservation: Equatable, Sendable {
  public let isSpeech: Bool
  public let durationSeconds: Double
  public let normalizedRMS: Float

  public init(
    isSpeech: Bool,
    durationSeconds: Double,
    normalizedRMS: Float
  ) {
    self.isSpeech = isSpeech
    self.durationSeconds = durationSeconds
    self.normalizedRMS = normalizedRMS
  }
}

public struct SherpaSileroVADConfiguration: Equatable, Sendable {
  public static let bundledModelFilename = "silero_vad.onnx"
  public static let bundledModelSHA256 =
    "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
  public static let defaultThreshold: Float = 0.25
  public static let maximumThreadCount = 16
  public static let maximumDurationSeconds: Float = 600

  public var modelURL: URL
  public var expectedModelSHA256: String
  public var threshold: Float
  public var minimumSilenceDurationSeconds: Float
  public var minimumSpeechDurationSeconds: Float
  public var maximumSpeechDurationSeconds: Float
  public var bufferDurationSeconds: Float
  public var threadCount: Int

  public init(
    modelURL: URL,
    expectedModelSHA256: String,
    threshold: Float = Self.defaultThreshold,
    minimumSilenceDurationSeconds: Float = 0.1,
    minimumSpeechDurationSeconds: Float = 0.1,
    maximumSpeechDurationSeconds: Float = 120,
    bufferDurationSeconds: Float = 120,
    threadCount: Int = 1
  ) {
    self.modelURL = modelURL
    self.expectedModelSHA256 = expectedModelSHA256
    self.threshold = threshold
    self.minimumSilenceDurationSeconds = minimumSilenceDurationSeconds
    self.minimumSpeechDurationSeconds = minimumSpeechDurationSeconds
    self.maximumSpeechDurationSeconds = maximumSpeechDurationSeconds
    self.bufferDurationSeconds = bufferDurationSeconds
    self.threadCount = threadCount
  }

  public static var bundledModelURL: URL? {
    let releaseSafeURL = SherpaBundledModelLocator.locate(
      searchRoots: [
        Bundle.main.resourceURL,
        Bundle(for: SherpaRuntimeBundleToken.self).resourceURL,
        Bundle.main.bundleURL,
      ]
    ) { bundleURL in
      Bundle(url: bundleURL)?.url(
        forResource: "silero_vad",
        withExtension: "onnx"
      )
    }
    if let releaseSafeURL {
      return releaseSafeURL
    }

    #if DEBUG
      // SwiftPM's generated accessor knows the package build directory, but
      // can fatalError when a packaged app has lost its resource bundle.
      return Bundle.module.url(forResource: "silero_vad", withExtension: "onnx")
    #else
      return nil
    #endif
  }

  public static func bundled(
    threshold: Float = Self.defaultThreshold
  ) throws -> Self {
    guard let modelURL = bundledModelURL else {
      throw SherpaVoiceActivityDetectorError.bundledModelUnavailable
    }
    return Self(
      modelURL: modelURL,
      expectedModelSHA256: bundledModelSHA256,
      threshold: threshold
    )
  }

  public func validate() throws {
    try validateParameters()
    let validatedModel = try openValidatedModel()
    try validatedModel.validatePathIdentity()
  }

  fileprivate func validateParameters() throws {
    guard threshold.isFinite, threshold > 0, threshold < 1 else {
      throw SherpaVoiceActivityDetectorError.invalidConfiguration(
        "threshold must be finite and in the interval (0, 1)"
      )
    }
    try Self.validateDuration(
      minimumSilenceDurationSeconds,
      named: "minimumSilenceDurationSeconds"
    )
    try Self.validateDuration(
      minimumSpeechDurationSeconds,
      named: "minimumSpeechDurationSeconds"
    )
    try Self.validateDuration(
      maximumSpeechDurationSeconds,
      named: "maximumSpeechDurationSeconds"
    )
    try Self.validateDuration(
      bufferDurationSeconds,
      named: "bufferDurationSeconds"
    )
    guard maximumSpeechDurationSeconds > minimumSpeechDurationSeconds,
      maximumSpeechDurationSeconds > minimumSilenceDurationSeconds
    else {
      throw SherpaVoiceActivityDetectorError.invalidConfiguration(
        "maximumSpeechDurationSeconds must exceed the minimum speech and silence durations"
      )
    }
    guard bufferDurationSeconds >= maximumSpeechDurationSeconds else {
      throw SherpaVoiceActivityDetectorError.invalidConfiguration(
        "bufferDurationSeconds must be at least maximumSpeechDurationSeconds"
      )
    }
    guard threadCount > 0, threadCount <= Self.maximumThreadCount else {
      throw SherpaVoiceActivityDetectorError.invalidConfiguration(
        "threadCount must be in 1...\(Self.maximumThreadCount)"
      )
    }
    guard expectedModelSHA256.count == 64,
      expectedModelSHA256.unicodeScalars.allSatisfy({ scalar in
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
      })
    else {
      throw SherpaVoiceActivityDetectorError.invalidConfiguration(
        "expectedModelSHA256 must contain 64 lowercase hexadecimal characters"
      )
    }
  }

  fileprivate func openValidatedModel() throws -> SherpaValidatedModelFile {
    try SherpaValidatedModelFile.openValidated(
      modelURL: modelURL,
      expectedSHA256: expectedModelSHA256
    )
  }

  private static func validateDuration(_ value: Float, named name: String) throws {
    guard value.isFinite, value > 0, value <= maximumDurationSeconds else {
      throw SherpaVoiceActivityDetectorError.invalidConfiguration(
        "\(name) must be finite and in (0, \(Int(maximumDurationSeconds))]"
      )
    }
  }
}

public enum SherpaVoiceActivityDetectorError: Error, Equatable, Sendable {
  case invalidConfiguration(String)
  case bundledModelUnavailable
  case missingModel(URL)
  case failedToReadModel(URL)
  case modelIntegrityCheckFailed(expected: String, actual: String)
  case modelChangedDuringLoad(URL)
  case failedToCreateDetector
  case invalidAudioSample(index: Int)
  case nativeProcessingFailed(status: Int32)
}

/// Actor-confined streaming Silero VAD.
///
/// This reference type deliberately does not conform to `Sendable`. Construct
/// and use it within one actor so the native recurrent model state and partial
/// frame buffer have a single owner.
public final class SherpaVoiceActivityDetector {
  public static let sampleRate = 16_000
  public static let frameSize = 512
  public static let frameDurationSeconds = Double(frameSize) / Double(sampleRate)

  public let configuration: SherpaSileroVADConfiguration

  private let handle: OpaquePointer
  private var pendingSamples: [Float] = []

  public convenience init(configuration: SherpaSileroVADConfiguration) throws {
    try self.init(configuration: configuration, afterNativeCreateForTesting: nil)
  }

  init(
    configuration: SherpaSileroVADConfiguration,
    afterNativeCreateForTesting: (() -> Void)?
  ) throws {
    try configuration.validateParameters()
    let validatedModel = try configuration.openValidatedModel()
    try validatedModel.validatePathIdentity()
    let createdHandle = configuration.modelURL.path.withCString { model in
      RillSherpaCreateSileroVad(
        model,
        configuration.threshold,
        configuration.minimumSilenceDurationSeconds,
        configuration.minimumSpeechDurationSeconds,
        configuration.maximumSpeechDurationSeconds,
        Int32(configuration.threadCount),
        configuration.bufferDurationSeconds
      )
    }
    afterNativeCreateForTesting?()

    do {
      try validatedModel.validatePathIdentity()
      try validatedModel.revalidateAfterNativeLoad()
    } catch {
      if let createdHandle {
        RillSherpaDestroySileroVad(createdHandle)
      }
      throw error
    }
    guard let createdHandle else {
      throw SherpaVoiceActivityDetectorError.failedToCreateDetector
    }

    self.configuration = configuration
    handle = createdHandle
    pendingSamples.reserveCapacity(Self.frameSize)
  }

  public static func bundled(
    threshold: Float = SherpaSileroVADConfiguration.defaultThreshold
  ) throws -> SherpaVoiceActivityDetector {
    try SherpaVoiceActivityDetector(configuration: .bundled(threshold: threshold))
  }

  deinit {
    RillSherpaDestroySileroVad(handle)
  }

  public func accept(samples: [Float]) throws -> [SherpaVoiceActivityObservation] {
    if let invalidIndex = samples.firstIndex(where: { !$0.isFinite }) {
      throw SherpaVoiceActivityDetectorError.invalidAudioSample(index: invalidIndex)
    }
    guard !samples.isEmpty else { return [] }
    let clampedSamples = samples.map { min(max($0, -1), 1) }

    var observations: [SherpaVoiceActivityObservation] = []
    observations.reserveCapacity(
      (pendingSamples.count + clampedSamples.count) / Self.frameSize
    )
    var cursor = 0

    if !pendingSamples.isEmpty {
      let count = min(Self.frameSize - pendingSamples.count, clampedSamples.count)
      pendingSamples.append(contentsOf: clampedSamples[..<count])
      cursor += count
      if pendingSamples.count == Self.frameSize {
        observations.append(try classify(frame: pendingSamples))
        pendingSamples.removeAll(keepingCapacity: true)
      }
    }

    while clampedSamples.count - cursor >= Self.frameSize {
      let end = cursor + Self.frameSize
      observations.append(try classify(frame: Array(clampedSamples[cursor..<end])))
      cursor = end
    }

    if cursor < clampedSamples.count {
      pendingSamples.append(contentsOf: clampedSamples[cursor...])
    }
    return observations
  }

  public func reset() {
    pendingSamples.removeAll(keepingCapacity: true)
    _ = RillSherpaSileroVadReset(handle)
  }

  private func classify(frame: [Float]) throws -> SherpaVoiceActivityObservation {
    var isSpeech: Int32 = 0
    let status = frame.withUnsafeBufferPointer { buffer in
      RillSherpaSileroVadAcceptFrame(
        handle,
        buffer.baseAddress,
        Int32(buffer.count),
        &isSpeech
      )
    }
    guard status == Int32(RILL_SHERPA_VAD_STATUS_OK.rawValue) else {
      pendingSamples.removeAll(keepingCapacity: true)
      _ = RillSherpaSileroVadReset(handle)
      throw SherpaVoiceActivityDetectorError.nativeProcessingFailed(status: status)
    }

    let squaredSum = frame.reduce(into: Double.zero) { sum, sample in
      let value = Double(sample)
      sum += value * value
    }
    let rms = Float((squaredSum / Double(Self.frameSize)).squareRoot())
    guard rms.isFinite else {
      pendingSamples.removeAll(keepingCapacity: true)
      _ = RillSherpaSileroVadReset(handle)
      throw SherpaVoiceActivityDetectorError.nativeProcessingFailed(
        status: Int32(RILL_SHERPA_VAD_STATUS_NATIVE_FAILURE.rawValue)
      )
    }
    return SherpaVoiceActivityObservation(
      isSpeech: isSpeech == 1,
      durationSeconds: Self.frameDurationSeconds,
      normalizedRMS: rms
    )
  }
}
