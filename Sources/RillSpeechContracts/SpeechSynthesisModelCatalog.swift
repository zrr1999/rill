import CryptoKit
import Foundation

public enum SpeechSynthesisModelID: String, Codable, CaseIterable, Sendable {
  case qwen3TTS06BCustomVoiceInt4 = "qwen3-tts-0.6b-customvoice-mlx-4bit"
  case qwen3TTS06BCustomVoiceInt8 = "qwen3-tts-0.6b-customvoice-mlx-8bit"
  case qwen3TTS06BCustomVoiceBF16 = "qwen3-tts-0.6b-customvoice-mlx-bf16"
}

public struct SpeechSynthesisModelFile: Equatable, Sendable {
  public let path: String
  public let byteCount: UInt64
  public let sha256: String
}

public struct SpeechSynthesisModelDescriptor: Equatable, Sendable {
  public let id: SpeechSynthesisModelID
  public let repository: String
  public let revision: String
  public let approximateDownloadByteCount: UInt64
  public let files: [SpeechSynthesisModelFile]
}

public enum SpeechSynthesisModelCatalog {
  public static let qwen3TTS06BCustomVoiceInt4 = SpeechSynthesisModelDescriptor(
    id: .qwen3TTS06BCustomVoiceInt4,
    repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit",
    revision: "08c72cad5e2fd0f41730c8bd1f28149585e46361",
    approximateDownloadByteCount: 1_694_000_000,
    files: modelFiles(
      configByteCount: 6_058,
      configSHA256: "612cb591b44547319e5c68a78c0e93e4defb57882a4aa9ef5f06cc2f071ed036",
      modelByteCount: 1_006_772_520,
      modelSHA256: "4ab02a20be381700f6e73dbb5efdc424cadf9f1d0652cbffd662872ea41e296a",
      indexByteCount: 71_447,
      indexSHA256: "f3b84ec5c1b38220008c3a300b8a73502f7d4ec67b232e0193d9376909fc4e3e"
    )
  )

  public static let qwen3TTS06BCustomVoiceInt8 = SpeechSynthesisModelDescriptor(
    id: .qwen3TTS06BCustomVoiceInt8,
    repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
    revision: "049ef77fe8816b536193c0c25f9a214d17921282",
    approximateDownloadByteCount: 1_974_000_000,
    files: modelFiles(
      configByteCount: 6_058,
      configSHA256: "2eea3665564268139c3beb8d497fd3c2e4524e9eed5452836cdf1de96ed3cdbd",
      modelByteCount: 1_286_743_170,
      modelSHA256: "3bcb2c4a127e6243e81a30b7126c7865f686d3559de4f938e5d3b150c6a9560d",
      indexByteCount: 71_447,
      indexSHA256: "0c92041960fa189cf35ae538c8d9ca07c468edddd0c9bb52274c5d4d287a860b"
    )
  )

  public static let qwen3TTS06BCustomVoiceBF16 = SpeechSynthesisModelDescriptor(
    id: .qwen3TTS06BCustomVoiceBF16,
    repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
    revision: "6415d95f88be018ff9e46813119dc3bc12261328",
    approximateDownloadByteCount: 2_500_000_000,
    files: modelFiles(
      configByteCount: 5_853,
      configSHA256: "69c1b78421a5e408b5e91a74a9995213546613ffe2a1d87a00c7743900ead6ee",
      modelByteCount: 1_811_626_550,
      modelSHA256: "e6eb20e645c5a28ee66bf8434edb5b67a5f151530dab63afe22787d71bcf5382",
      indexByteCount: 32_289,
      indexSHA256: "1b1e10fb201a65a1b24991cf8f6800d785441ad9ca0ad83828d6bf00f6d5e8ec"
    )
  )

  public static let defaultModel = qwen3TTS06BCustomVoiceInt8

  public static let supportedModels = [
    qwen3TTS06BCustomVoiceInt4,
    qwen3TTS06BCustomVoiceInt8,
    qwen3TTS06BCustomVoiceBF16,
  ]

  public static let supportedModelIdentifiers = Set(
    supportedModels.map(\.id.rawValue)
  )

  public static func descriptor(
    for id: SpeechSynthesisModelID
  ) -> SpeechSynthesisModelDescriptor {
    switch id {
    case .qwen3TTS06BCustomVoiceInt4:
      qwen3TTS06BCustomVoiceInt4
    case .qwen3TTS06BCustomVoiceInt8:
      qwen3TTS06BCustomVoiceInt8
    case .qwen3TTS06BCustomVoiceBF16:
      qwen3TTS06BCustomVoiceBF16
    }
  }

  private static func modelFiles(
    configByteCount: UInt64,
    configSHA256: String,
    modelByteCount: UInt64,
    modelSHA256: String,
    indexByteCount: UInt64,
    indexSHA256: String
  ) -> [SpeechSynthesisModelFile] {
    [
      .init(path: "config.json", byteCount: configByteCount, sha256: configSHA256),
      .init(
        path: "generation_config.json",
        byteCount: 245,
        sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"
      ),
      .init(
        path: "merges.txt",
        byteCount: 1_671_839,
        sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"
      ),
      .init(path: "model.safetensors", byteCount: modelByteCount, sha256: modelSHA256),
      .init(
        path: "model.safetensors.index.json",
        byteCount: indexByteCount,
        sha256: indexSHA256
      ),
      .init(
        path: "preprocessor_config.json",
        byteCount: 127,
        sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"
      ),
      .init(
        path: "speech_tokenizer/config.json",
        byteCount: 2_336,
        sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"
      ),
      .init(
        path: "speech_tokenizer/configuration.json",
        byteCount: 76,
        sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"
      ),
      .init(
        path: "speech_tokenizer/model.safetensors",
        byteCount: 682_293_092,
        sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"
      ),
      .init(
        path: "speech_tokenizer/preprocessor_config.json",
        byteCount: 234,
        sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"
      ),
      .init(
        path: "tokenizer_config.json",
        byteCount: 7_344,
        sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"
      ),
      .init(
        path: "vocab.json",
        byteCount: 2_776_833,
        sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
      ),
    ]
  }
}

public enum SpeechSynthesisModelInventory {
  private struct Receipt: Codable, Equatable {
    struct File: Codable, Equatable {
      let path: String
      let byteCount: UInt64
      let sha256: String
    }

    let schemaVersion: Int
    let modelID: String
    let repository: String
    let revision: String
    let files: [File]
  }

  public static let receiptFileName = ".rill-mlx-audio-swift-tts-model.json"

  public static func defaultModelRootURL(
    fileManager: FileManager = .default
  ) -> URL {
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support",
        isDirectory: true
      )
    return support.appendingPathComponent(
      "Rill/Models/mlx-audio-swift",
      isDirectory: true
    )
  }

  public static func publicationURL(
    for descriptor: SpeechSynthesisModelDescriptor,
    modelRootURL: URL
  ) -> URL {
    modelRootURL
      .appendingPathComponent("tts", isDirectory: true)
      .appendingPathComponent(
        descriptor.id.rawValue + "-" + descriptor.revision.prefix(12),
        isDirectory: true
      )
  }

  public static func installedModelIdentifiers(
    descriptors: [SpeechSynthesisModelDescriptor] =
      SpeechSynthesisModelCatalog.supportedModels,
    modelRootURL: URL = defaultModelRootURL()
  ) -> Set<String> {
    Set(
      descriptors.compactMap { descriptor in
        let publicationURL = publicationURL(
          for: descriptor,
          modelRootURL: modelRootURL
        )
        return (try? validatePublication(
          publicationURL,
          descriptor: descriptor,
          verifyDigests: false
        )) == true
          ? descriptor.id.rawValue
          : nil
      }
    )
  }

  public static func receiptData(
    for descriptor: SpeechSynthesisModelDescriptor
  ) throws -> Data {
    try JSONEncoder().encode(receipt(for: descriptor))
  }

  public static func validatePublication(
    _ directory: URL,
    descriptor: SpeechSynthesisModelDescriptor,
    verifyDigests: Bool
  ) throws -> Bool {
    let directoryValues = try? directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard
      directoryValues?.isDirectory == true,
      directoryValues?.isSymbolicLink != true
    else {
      return false
    }
    for file in descriptor.files {
      let url = directory.appendingPathComponent(file.path)
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      guard
        values?.isRegularFile == true,
        values?.isSymbolicLink != true,
        let fileSize = values?.fileSize,
        fileSize >= 0,
        UInt64(fileSize) == file.byteCount
      else {
        return false
      }
      if verifyDigests, try sha256(url) != file.sha256 {
        return false
      }
    }
    let receiptURL = directory.appendingPathComponent(receiptFileName)
    let receiptValues = try? receiptURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard
      receiptValues?.isRegularFile == true,
      receiptValues?.isSymbolicLink != true,
      let size = receiptValues?.fileSize,
      size > 0,
      size <= 32 * 1_024
    else {
      return false
    }
    return try JSONDecoder().decode(
      Receipt.self,
      from: Data(contentsOf: receiptURL)
    ) == receipt(for: descriptor)
  }

  private static func receipt(
    for descriptor: SpeechSynthesisModelDescriptor
  ) -> Receipt {
    Receipt(
      schemaVersion: 1,
      modelID: descriptor.id.rawValue,
      repository: descriptor.repository,
      revision: descriptor.revision,
      files: descriptor.files.map {
        .init(path: $0.path, byteCount: $0.byteCount, sha256: $0.sha256)
      }
    )
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
