// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoroCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LoroCore", targets: ["LoroCore"]),
        .library(name: "LoroKit", targets: ["LoroKit"]),
        .executable(name: "loro", targets: ["loro"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
    ],
    targets: [
        .target(name: "LoroObjC"),
        .target(
            name: "LoroCore",
            dependencies: [
                "LoroObjC",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(name: "LoroKit", dependencies: ["LoroCore"]),
        .testTarget(name: "LoroCoreTests", dependencies: ["LoroCore"]),
        .executableTarget(
            name: "loro",
            dependencies: [
                "LoroCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
