// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Parakeet",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.16.1")
    ],
    targets: [
        .executableTarget(
            name: "Parakeet",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Parakeet"
        )
    ],
    swiftLanguageModes: [.v5]
)
