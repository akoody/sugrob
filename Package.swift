// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sugrob",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Sugrob",
            path: "Sources/Sugrob",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
