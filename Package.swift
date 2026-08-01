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
    .binaryTarget(
      name: "SherpaOnnxNative",
      path: "vendor/sherpa-onnx-v1.13.4/sherpa-onnx.xcframework"
    ),
    .binaryTarget(
      name: "OnnxRuntimeNative",
      path: "vendor/sherpa-onnx-v1.13.4/onnxruntime.xcframework"
    ),
    .target(
      name: "CSherpaOnnx",
      dependencies: [],
      publicHeadersPath: "include",
      cSettings: [
        .unsafeFlags([
          "-Ivendor/sherpa-onnx-v1.13.4/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers"
        ])
      ],
      linkerSettings: [
        .linkedLibrary("c++"),
        .linkedFramework("Accelerate"),
      ]
    ),
    .target(
      name: "RillSherpaRuntime",
      dependencies: ["CSherpaOnnx"],
      resources: [
        .copy("Resources/silero_vad.onnx"),
        .copy("Resources/LICENSE.silero-vad"),
      ]
    ),
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
        "RillSherpaRuntime",
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
        "SherpaOnnxNative",
        "OnnxRuntimeNative",
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
        "SherpaOnnxNative",
        "OnnxRuntimeNative",
      ]
    ),
    .testTarget(name: "RillCoreTests", dependencies: ["RillCore"]),
    .testTarget(
      name: "RillSherpaRuntimeTests",
      dependencies: [
        "RillSherpaRuntime",
        "SherpaOnnxNative",
        "OnnxRuntimeNative",
      ]
    ),
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
        "RillProviders",
        "RillSherpaRuntime",
        "SherpaOnnxNative",
        "OnnxRuntimeNative",
      ]
    ),
    .testTarget(
      name: "RillMLXRuntimeTests",
      dependencies: [
        "RillCore",
        "RillMLXRuntime",
        "RillProviders",
        "SherpaOnnxNative",
        "OnnxRuntimeNative",
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
        "SherpaOnnxNative",
        "OnnxRuntimeNative",
      ]
    ),
  ]
)
