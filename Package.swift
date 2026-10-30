// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MovieCut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MovieCutCore", targets: ["MovieCutCore"]),
        .executable(name: "MovieCut", targets: ["MovieCut"]),
        .executable(name: "moviecut-cli", targets: ["moviecut-cli"]),
        .executable(name: "moviecut-fanhelper", targets: ["moviecut-fanhelper"]),
    ],
    targets: [
        .target(name: "MovieCutCore"),
        .executableTarget(name: "MovieCut", dependencies: ["MovieCutCore"]),
        .executableTarget(name: "moviecut-cli", dependencies: ["MovieCutCore"]),
        // 書き出し中のファン最大化用の特権ヘルパー(root の LaunchDaemon として動く。Movie Cut 本体とは別プロセス)
        .executableTarget(name: "moviecut-fanhelper"),
        .testTarget(
            name: "MovieCutTests",
            dependencies: ["MovieCut", "MovieCutCore"]
        ),
        .testTarget(
            name: "MovieCutCoreTests",
            dependencies: ["MovieCutCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
