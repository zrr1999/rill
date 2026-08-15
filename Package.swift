// swift-tools-version: 6.2
import PackageDescription

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
    .package(
      url: "https://github.com/MacPaw/OpenAI.git",
      exact: "0.5.1"
    ),
  ],
  targets: [
    .target(name: "RillCore"),
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
        "RillCore",
        "RillPlatform",
        .product(name: "OpenAI", package: "OpenAI"),
      ]
    ),
    .target(
      name: "RillMLXRuntime",
      dependencies: [
        "RillCore",
        "RillProviders",
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
        .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
      ]
    ),
    .target(name: "RillRuntime", dependencies: ["RillCore", "RillPlatform"]),
    .target(
      name: "RillPersistence",
      dependencies: ["RillCore"],
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .target(name: "RillUI", dependencies: ["RillCore", "RillRuntime"]),
    .executableTarget(
      name: "RillApp",
      dependencies: [
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
        .copy("Resources/WorkflowTemplates"),
      ]
    ),
    .executableTarget(
      name: "RillSpeechWorker",
      dependencies: [
        "RillCore",
        "RillMLXRuntime",
        "RillProviders",
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
        "RillRuntime",
      ]
    ),
    .testTarget(
      name: "RillProvidersTests",
      dependencies: [
        "RillCore",
        "RillPlatform",
        "RillProviders",
      ]
    ),
    .testTarget(
      name: "RillMLXRuntimeTests",
      dependencies: [
        "RillCore",
        "RillMLXRuntime",
        "RillProviders",
      ]
    ),
    .testTarget(
      name: "RillPlatformTests",
      dependencies: ["RillCore", "RillPlatform"]
    ),
    .testTarget(
      name: "RillUITests",
      dependencies: ["RillCore", "RillRuntime", "RillUI"]
    ),
    .testTarget(
      name: "RillAppTests",
      dependencies: [
        "RillApp",
        "RillCore",
        "RillPlatform",
        "RillRuntime",
      ]
    ),
  ]
)
