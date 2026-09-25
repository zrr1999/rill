// swift-tools-version: 6.2
import PackageDescription
import Foundation

let package = Package(
  name: "RillMacOS",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "RillApp", targets: ["RillApp"]),
    .executable(name: "RillSpeechWorker", targets: ["RillSpeechWorker"]),
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
    .target(name: "RillSpeechContracts", dependencies: ["RillCore"]),
    .target(
      name: "RillPlatform",
      dependencies: [
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
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
      ]
    ),
    .target(name: "RillRuntime", dependencies: ["RillCore"]),
    .target(
      name: "RillPersistence",
      dependencies: ["RillCore"],
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .target(name: "RillUI", dependencies: [ "RillCore", "RillRuntime"]),
    .executableTarget(
      name: "RillApp",
      dependencies: [
        "RillSpeechContracts",
        "RillCore",
        "RillPlatform",
        "RillProviders",
        "RillRuntime",
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
        "RillRuntime",
      ]
    ),
    .testTarget(
      name: "RillProvidersTests",
      dependencies: [
        "RillSpeechContracts",
        "RillCore",
        "RillPlatform",
        "RillProviders",
        .product(name: "OpenAI", package: "OpenAI"),
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
      dependencies: ["RillCore", "RillPlatform", "RillRuntime", "RillUI"]
    ),
    .testTarget(
      name: "RillAppTests",
      dependencies: [
        "RillSpeechContracts",
        "RillApp",
        "RillCore",
        "RillPlatform",
        "RillProviders",
        "RillRuntime",
        "RillPersistence",
        "RillUI",
      ]
    ),
  ]
)

// One target declaration serves both full CI and the opt-in domain test build.
// Dependencies and Package.resolved remain identical to the production graph.
if ProcessInfo.processInfo.environment["RILL_BUILD_PROFILE"] == "domain-tests" {
  let excluded: Set<String> = [
    "RillApp", "RillUI", "RillSpeechWorker", "RillMLXRuntime",
    "RillAppTests", "RillUITests", "RillMLXRuntimeTests", "RillPlatformTests",
  ]
  package.targets.removeAll { excluded.contains($0.name) }
  package.products = []
}
