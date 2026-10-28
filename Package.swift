// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .target(
            name: "TranscriberCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(name: "TranscriberApp", dependencies: ["TranscriberCore"]),
        .executableTarget(name: "transcriber-cli", dependencies: ["TranscriberCore"]),
        .testTarget(name: "TranscriberCoreTests", dependencies: ["TranscriberCore"]),
    ]
)
