// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YukkuriEditor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YukkuriCore", targets: ["YukkuriCore"]),
        .executable(name: "YukkuriEditor", targets: ["YukkuriEditor"]),
        .executable(name: "yukkuri-cli", targets: ["yukkuri-cli"]),
    ],
    targets: [
        .target(name: "YukkuriCore"),
        .executableTarget(name: "YukkuriEditor", dependencies: ["YukkuriCore"]),
        .executableTarget(name: "yukkuri-cli", dependencies: ["YukkuriCore"]),
        .testTarget(
            name: "YukkuriCoreTests",
            dependencies: ["YukkuriCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
