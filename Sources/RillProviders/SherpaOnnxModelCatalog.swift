import Foundation

/// The release-pinned sherpa-onnx model identities known to the source tree.
///
/// Presence in this enum is not a distribution grant. Product entry points
/// must use ``SherpaOnnxModelCatalog/distributable`` so preview-only trust
/// material cannot become user-selectable by merely adding an enum case.
public enum SherpaOnnxModelID: String, CaseIterable, Codable, Sendable {
  case qwen3ASR06BInt8 = "qwen3-asr-0.6b-int8"
  case funASRNano08BInt8 = "funasr-nano-0.8b-int8"
  case funASRNano08BFP16 = "funasr-nano-0.8b-fp16"
  case omnilingualASRCTCV2300MInt8 = "omnilingual-asr-ctc-v2-300m-int8"
  case omnilingualASRCTCV21BInt8 = "omnilingual-asr-ctc-v2-1b-int8"
  case cohereTranscribe2BInt8 = "cohere-transcribe-2b-int8"
  case senseVoiceSmallInt8 = "sense-voice-small-int8"
  case streamingZipformerBilingualPreviewInt8 =
    "streaming-zipformer-small-bilingual-zh-en-preview-int8"
}

public struct SherpaOnnxModelDescriptor: Equatable, Sendable {
  public enum Architecture: String, Codable, Sendable {
    case qwen3ASR
    case funASRNano
    case omnilingualASRCTC
    case cohereTranscribe
    case senseVoice
    case streamingTransducer
  }

  public struct RequiredEntry: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
      case regularFile
      case directory
    }

    public let relativePath: String
    public let kind: Kind

  }

  public let id: SherpaOnnxModelID
  public let architecture: Architecture
  public let archiveURL: URL
  public let archiveByteCount: UInt64
  public let archiveSHA256: String
  public let archiveRootDirectoryName: String
  /// SHA-256 of the versioned canonical inventory for every installed regular file.
  public let installedFileInventorySHA256: String
  public let requiredEntries: [RequiredEntry]

}

/// Immutable release trust anchors for local sherpa-onnx recognition.
public enum SherpaOnnxModelCatalog {
  public static let defaultModelID: SherpaOnnxModelID = .qwen3ASR06BInt8

  public static let qwen3ASR06BInt8 = SherpaOnnxModelDescriptor(
    id: .qwen3ASR06BInt8,
    architecture: .qwen3ASR,
    archiveURL: URL(
      string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2"
    )!,
    archiveByteCount: 878_702_423,
    archiveSHA256: "393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96",
    archiveRootDirectoryName: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
    installedFileInventorySHA256:
      "24fd5947756b66b37fb4cb7193450c6212c84eba976027fe42de788447af787d",
    requiredEntries: [
      .init(relativePath: "conv_frontend.onnx", kind: .regularFile),
      .init(relativePath: "encoder.int8.onnx", kind: .regularFile),
      .init(relativePath: "decoder.int8.onnx", kind: .regularFile),
      .init(relativePath: "tokenizer", kind: .directory),
    ]
  )

  public static let funASRNano08BInt8 = SherpaOnnxModelDescriptor(
    id: .funASRNano08BInt8,
    architecture: .funASRNano,
    archiveURL: URL(
      string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2"
    )!,
    archiveByteCount: 841_730_611,
    archiveSHA256: "eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b",
    archiveRootDirectoryName: "sherpa-onnx-funasr-nano-int8-2025-12-30",
    installedFileInventorySHA256:
      "8be2559116da7fa361886d4079ce4de11ec338c530eae38f82d955a48e58a445",
    requiredEntries: [
      .init(relativePath: "encoder_adaptor.int8.onnx", kind: .regularFile),
      .init(relativePath: "embedding.int8.onnx", kind: .regularFile),
      .init(relativePath: "llm.int8.onnx", kind: .regularFile),
      .init(relativePath: "Qwen3-0.6B", kind: .directory),
    ]
  )

  public static let funASRNano08BFP16 = SherpaOnnxModelDescriptor(
    id: .funASRNano08BFP16,
    architecture: .funASRNano,
    archiveURL: URL(
      string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-funasr-nano-fp16-2025-12-30.tar.bz2"
    )!,
    archiveByteCount: 1_030_076_153,
    archiveSHA256: "a07a996361aa2f8b2c4f47861fe01953b5509664efa3392b734580b1eeb362e3",
    archiveRootDirectoryName: "sherpa-onnx-funasr-nano-fp16-2025-12-30",
    installedFileInventorySHA256:
      "3ac066dff02daab16a9af1c4a64e1a9e2ae67b499310c030c047bf55b831b216",
    requiredEntries: [
      .init(relativePath: "encoder_adaptor.int8.onnx", kind: .regularFile),
      .init(relativePath: "embedding.int8.onnx", kind: .regularFile),
      .init(relativePath: "llm.fp16.onnx", kind: .regularFile),
      .init(relativePath: "Qwen3-0.6B", kind: .directory),
    ]
  )

  public static let omnilingualASRCTCV2300MInt8 = SherpaOnnxModelDescriptor(
    id: .omnilingualASRCTCV2300MInt8,
    architecture: .omnilingualASRCTC,
    archiveURL: URL(
      string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-v2-int8-2026-02-05.tar.bz2"
    )!,
    archiveByteCount: 292_313_120,
    archiveSHA256: "951b32409aade32bd525310bb39e9666773ba3fc611a39e817f620936d76c631",
    archiveRootDirectoryName:
      "sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-v2-int8-2026-02-05",
    installedFileInventorySHA256:
      "0969be2410ec23a4f8af72d01b9a34b9116f4f5f681f9a6dbd301d795dc7535b",
    requiredEntries: [
      .init(relativePath: "model.int8.onnx", kind: .regularFile),
      .init(relativePath: "tokens.txt", kind: .regularFile),
      .init(relativePath: "LICENSE", kind: .regularFile),
    ]
  )

  public static let omnilingualASRCTCV21BInt8 = SherpaOnnxModelDescriptor(
    id: .omnilingualASRCTCV21BInt8,
    architecture: .omnilingualASRCTC,
    archiveURL: URL(
      string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-v2-int8-2026-02-05.tar.bz2"
    )!,
    archiveByteCount: 787_296_506,
    archiveSHA256: "f4deae6e6cbf4ca785b89eaa3836156581208bf977ea2e6d7ae84d7efcfc3a40",
    archiveRootDirectoryName:
      "sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-v2-int8-2026-02-05",
    installedFileInventorySHA256:
      "8bc2f5b579365eba2ea3f5d9c818d726f3cafc205c98276209a42b1e234f9489",
    requiredEntries: [
      .init(relativePath: "model.int8.onnx", kind: .regularFile),
      .init(relativePath: "tokens.txt", kind: .regularFile),
      .init(relativePath: "LICENSE", kind: .regularFile),
    ]
  )

  public static let cohereTranscribe2BInt8 = SherpaOnnxModelDescriptor(
    id: .cohereTranscribe2BInt8,
    architecture: .cohereTranscribe,
    archiveURL: URL(
      string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01.tar.bz2"
    )!,
    archiveByteCount: 1_699_791_751,
    archiveSHA256: "bd582588d50685a795dcd2807ab77e11361b8312d96c53884682def45ab4206d",
    archiveRootDirectoryName: "sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01",
    installedFileInventorySHA256:
      "b230d5c78f7b6a50246a1b175504c9d0f0c58aa3ef8e11a493bfd349f740d2ec",
    requiredEntries: [
      .init(relativePath: "encoder.int8.onnx", kind: .regularFile),
      .init(relativePath: "encoder.int8.onnx.data", kind: .regularFile),
      .init(relativePath: "decoder.int8.onnx", kind: .regularFile),
      .init(relativePath: "tokens.txt", kind: .regularFile),
    ]
  )

  public static let senseVoiceSmallInt8 = SherpaOnnxModelDescriptor(
    id: .senseVoiceSmallInt8,
    architecture: .senseVoice,
    archiveURL: URL(
      string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2"
    )!,
    archiveByteCount: 163_002_883,
    archiveSHA256: "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e",
    archiveRootDirectoryName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
    installedFileInventorySHA256:
      "856703c2ab4cf4dc79cf3efb17df1ad18d3afcd5922d1be227af0955d646ae38",
    requiredEntries: [
      .init(relativePath: "model.int8.onnx", kind: .regularFile),
      .init(relativePath: "tokens.txt", kind: .regularFile),
      .init(relativePath: "LICENSE", kind: .regularFile),
    ]
  )

  /// Fixed low-latency model used only for local live subtitle hypotheses.
  /// The storage identifier retains its original `small` spelling so an
  /// authenticated upgrade replaces the earlier preview cache in place.
  /// Final transcription continues to use the user's selected tier model.
  public static let streamingZipformerBilingualPreviewInt8 = SherpaOnnxModelDescriptor(
    id: .streamingZipformerBilingualPreviewInt8,
    architecture: .streamingTransducer,
    archiveURL: URL(
      string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2"
    )!,
    archiveByteCount: 511_274_346,
    archiveSHA256: "27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8",
    archiveRootDirectoryName:
      "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20",
    installedFileInventorySHA256:
      "9adc9ead5f64877832a928980b189b12ba36fe192a137ec8c1ae39540b640c62",
    requiredEntries: [
      .init(relativePath: "encoder-epoch-99-avg-1.int8.onnx", kind: .regularFile),
      .init(relativePath: "decoder-epoch-99-avg-1.int8.onnx", kind: .regularFile),
      .init(relativePath: "joiner-epoch-99-avg-1.int8.onnx", kind: .regularFile),
      .init(relativePath: "tokens.txt", kind: .regularFile),
    ]
  )

  /// Models approved for the public Rill build.
  ///
  /// Only models approved for selection and installation in the public build.
  /// Cohere Transcribe was retired from this surface after product review.
  public static let distributable: [SherpaOnnxModelDescriptor] = [
    qwen3ASR06BInt8,
  ]

  /// Candidate final-model identities retained for evaluation only. Public
  /// selection, installation, and recognition reject them.
  public static let candidateOnly: [SherpaOnnxModelDescriptor] = [
    omnilingualASRCTCV2300MInt8,
    omnilingualASRCTCV21BInt8,
  ]

  /// Pinned preview descriptors retained for internal compatibility testing.
  public static let previewOnly: [SherpaOnnxModelDescriptor] = [
    senseVoiceSmallInt8,
  ]

  /// Retired pinned identities retained only to recognize and migrate old
  /// installations. They are not selectable or accepted by the public
  /// installer and final-transcription recognizer.
  public static let compatibilityOnly: [SherpaOnnxModelDescriptor] = [
    funASRNano08BInt8,
    funASRNano08BFP16,
    cohereTranscribe2BInt8,
  ]

  /// Offline identities understood by compatibility-aware internal runtime
  /// construction. The public recognizer and installer use `distributable`.
  public static let offlineKnown: [SherpaOnnxModelDescriptor] =
    distributable + candidateOnly + previewOnly + compatibilityOnly

  public static let allKnown: [SherpaOnnxModelDescriptor] =
    offlineKnown + [streamingZipformerBilingualPreviewInt8]

  public static let distributableModelIdentifiers: Set<String> = Set(
    distributable.map { $0.id.rawValue }
  )

  public static let allKnownModelIdentifiers: Set<String> = Set(
    allKnown.map { $0.id.rawValue }
  )

  public static let offlineKnownModelIdentifiers: Set<String> = Set(
    offlineKnown.map { $0.id.rawValue }
  )

  public static func distributableDescriptor(
    for id: SherpaOnnxModelID
  ) -> SherpaOnnxModelDescriptor? {
    distributable.first { $0.id == id }
  }

  /// Resolves pinned trust material, including internal preview models.
  public static func descriptor(for id: SherpaOnnxModelID) -> SherpaOnnxModelDescriptor {
    switch id {
    case .qwen3ASR06BInt8:
      qwen3ASR06BInt8
    case .funASRNano08BInt8:
      funASRNano08BInt8
    case .funASRNano08BFP16:
      funASRNano08BFP16
    case .omnilingualASRCTCV2300MInt8:
      omnilingualASRCTCV2300MInt8
    case .omnilingualASRCTCV21BInt8:
      omnilingualASRCTCV21BInt8
    case .cohereTranscribe2BInt8:
      cohereTranscribe2BInt8
    case .senseVoiceSmallInt8:
      senseVoiceSmallInt8
    case .streamingZipformerBilingualPreviewInt8:
      streamingZipformerBilingualPreviewInt8
    }
  }
}
