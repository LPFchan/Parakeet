// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Parakeet",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Parakeet", path: "Sources/Parakeet")
    ],
    swiftLanguageModes: [.v5]
)
