// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiscStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Disc Studio", targets: ["BR"]), .library(name: "BRCore", targets: ["BRCore"])],
    targets: [
        .target(
            name: "DiscBridge", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("DiscRecording"), .linkedFramework("DiskArbitration")]),
        .target(name: "BRCore", dependencies: ["DiscBridge"]),
        .executableTarget(
            name: "BR", dependencies: ["BRCore"],
            resources: [.process("Resources")]),
        .testTarget(name: "BRCoreTests", dependencies: ["BRCore", "DiscBridge"]),
    ],
    swiftLanguageModes: [.v6]
)
