// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Minuta",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Minuta",
            path: "Sources/Minuta",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
