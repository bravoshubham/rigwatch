// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RigWatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RigWatch",
            path: "Sources/RigWatch",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
