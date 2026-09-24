// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "RillMacOS",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "RillApp", targets: ["RillApp"]),
    .executable(name: "RillSpeechWorker", targets: ["RillSpeechWorker"]),
    .executable(name: "RillInputMethod", targets: ["RillInputMethod"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/mattt/swift-toml.git",
      exact: "2.0.0"
    ),
    .package(
      url: "https://github.com/Blaizzy/mlx-audio-swift.git",
      exact: "0.1.3"
    ),
    .package(
      url: "https://github.com/huggingface/swift-huggingface.git",
      exact: "0.8.1"
    ),
    .package(
      url: "https://github.com/ml-explore/mlx-swift.git",
      exact: "0.31.4"
    ),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.2.1"),
    .package(
      url: "https://github.com/MacPaw/OpenAI.git",
      exact: "0.5.1"
    ),
  ],
  targets: [
    .target(name: "RillCore"),
    .target(name: "CRime", linkerSettings: [.linkedLibrary("dl")]),
    .target(name: "RillInputMethodContracts"),
    .target(name: "RillInputMethodIPC", dependencies: ["RillInputMethodContracts"],
      linkerSettings: [.linkedFramework("Security")]),
    .target(name: "RillInputMethodKit", dependencies: ["CRime", "RillInputMethodContracts", "RillInputMethodIPC"],
      linkerSettings: [.linkedFramework("InputMethodKit"), .linkedFramework("Carbon")]),
    .executableTarget(name: "RillInputMethod", dependencies: ["RillInputMethodKit", "RillInputMethodContracts"]),
    .target(name: "RillSpeechContracts", dependencies: ["RillCore"]),
    .target(
      name: "RillPlatform",
      dependencies: [
        "RillInputMethodContracts",
        "RillCore",
        .product(name: "TOML", package: "swift-toml"),
      ],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .target(
      name: "RillProviders",
      dependencies: [
        "RillSpeech",
        "RillSpeechContracts",
        "RillCore",
        .product(name: "OpenAI", package: "OpenAI"),
      ]
    ),
    .target(
      name: "RillMLXRuntime",
      dependencies: [
        "RillSpeechContracts",
        "RillCore",
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
        .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
      ]
    ),
    .target(name: "RillRecords", dependencies: ["RillCore"]),
    .target(name: "RillKnowledge", dependencies: ["RillCore"]),
    .target(name: "RillSpeech", dependencies: ["RillCore", "RillPlatform", "RillSpeechContracts"]),
    .target(name: "RillClipboard", dependencies: ["RillCore", "RillPlatform", "RillRecords"]),
    .target(name: "RillWorkflows", dependencies: ["RillSpeechContracts", "RillCore", "RillSpeech", "RillRecords", "RillKnowledge"]),
    .target(
      name: "RillPersistence",
      dependencies: ["RillCore"],
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .target(name: "RillUI", dependencies: ["RillInputMethodContracts", "RillInputMethodIPC", "RillCore", "RillWorkflows", "RillRecords", "RillKnowledge", "RillSpeech"]),
    .executableTarget(
      name: "RillApp",
      dependencies: [
        "RillClipboard",
        "RillSpeechContracts",
        "RillCore",
        "RillPlatform",
        "RillProviders",
        "RillWorkflows", "RillRecords", "RillKnowledge", "RillSpeech",
        "RillPersistence",
        "RillUI",
      ],
      resources: [
        .process("Resources/BuiltinWorkflowManifest.json"),
        .process("Resources/BuiltinWorkflows.toml"),
        .process("Resources/RillMenuBarTemplate.pdf"),
        .process("Resources/RillMenuBarRecordsTemplate.pdf"),
        .copy("Resources/WorkflowTemplates"),
      ]
    ),
    .executableTarget(
      name: "RillSpeechWorker",
      dependencies: [
        "RillSpeechContracts",
        "RillCore",
        "RillMLXRuntime",
      ]
    ),
    .testTarget(name: "RillKnowledgeTests", dependencies: ["RillKnowledge"]),
    .testTarget(name: "RillInputMethodTests", dependencies: ["RillInputMethodIPC", "RillInputMethodContracts", "RillInputMethodKit"]),
    .testTarget(name: "RillCoreTests", dependencies: ["RillCore"]),
    .testTarget(
      name: "RillPersistenceTests",
      dependencies: ["RillCore", "RillPersistence"]
    ),
    .testTarget(
      name: "RillRuntimeTests",
      dependencies: [
        "RillCore",
        "RillPersistence",
        "RillPlatform",
        "RillProviders",
        "RillWorkflows", "RillRecords", "RillKnowledge", "RillSpeech",
      ]
    ),
    .testTarget(
      name: "RillProvidersTests",
      dependencies: [
        "RillSpeech", "RillWorkflows",
        "RillSpeechContracts",
        "RillCore",
        "RillPlatform",
        "RillProviders",
      ]
    ),
    .testTarget(
      name: "RillMLXRuntimeTests",
      dependencies: [
        "RillSpeechContracts",
        "RillCore",
        "RillMLXRuntime",
      ]
    ),
    .testTarget(
      name: "RillPlatformTests",
      dependencies: ["RillCore", "RillPlatform"]
    ),
    .testTarget(
      name: "RillUITests",
      dependencies: ["RillInputMethodContracts", "RillInputMethodIPC", "RillCore", "RillPlatform", "RillWorkflows", "RillRecords", "RillKnowledge", "RillSpeech", "RillUI"]
    ),
    .testTarget(
      name: "RillAppTests",
      dependencies: [
        "RillClipboard",
        "RillSpeechContracts",
        "RillApp",
        "RillCore",
        "RillPlatform",
        "RillProviders",
        "RillWorkflows", "RillRecords", "RillKnowledge", "RillSpeech",
      ]
    ),
  ]
)
