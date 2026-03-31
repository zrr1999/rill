// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxTypeMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoxTypeCore", targets: ["VoxTypeCore"]),
        .library(name: "VoxTypePlatform", targets: ["VoxTypePlatform"]),
        .library(name: "VoxTypeProviders", targets: ["VoxTypeProviders"]),
        .library(name: "VoxTypeRuntime", targets: ["VoxTypeRuntime"]),
        .library(name: "VoxTypePersistence", targets: ["VoxTypePersistence"]),
        .library(name: "VoxTypeUI", targets: ["VoxTypeUI"]),
        .executable(name: "VoxTypeApp", targets: ["VoxTypeApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(name: "VoxTypeCore"),
        .target(name: "VoxTypePlatform", dependencies: ["VoxTypeCore"]),
        .target(
            name: "VoxTypeProviders",
            dependencies: [
                "VoxTypeCore",
                "VoxTypePlatform",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .target(name: "VoxTypeRuntime", dependencies: ["VoxTypeCore", "VoxTypePlatform"]),
        .target(
            name: "VoxTypePersistence",
            dependencies: ["VoxTypeCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(name: "VoxTypeUI", dependencies: ["VoxTypeCore", "VoxTypeRuntime"]),
        .executableTarget(
            name: "VoxTypeApp",
            dependencies: [
                "VoxTypeCore",
                "VoxTypePlatform",
                "VoxTypeProviders",
                "VoxTypeRuntime",
                "VoxTypePersistence",
                "VoxTypeUI",
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(name: "VoxTypeCoreTests", dependencies: ["VoxTypeCore"]),
        .testTarget(
            name: "VoxTypePersistenceTests",
            dependencies: ["VoxTypeCore", "VoxTypePersistence"]
        ),
        .testTarget(name: "VoxTypeRuntimeTests", dependencies: ["VoxTypeCore", "VoxTypePlatform", "VoxTypeRuntime"]),
        .testTarget(
            name: "VoxTypeProvidersTests",
            dependencies: ["VoxTypeCore", "VoxTypeProviders"]
        ),
        .testTarget(
            name: "VoxTypePlatformTests",
            dependencies: ["VoxTypeCore", "VoxTypePlatform"]
        ),
        .testTarget(
            name: "VoxTypeUITests",
            dependencies: ["VoxTypeCore", "VoxTypeRuntime", "VoxTypeUI"]
        ),
    ]
)
