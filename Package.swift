// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MovieCut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MovieCutCore", targets: ["MovieCutCore"]),
        .executable(name: "MovieCut", targets: ["MovieCut"]),
        .executable(name: "moviecut-cli", targets: ["moviecut-cli"]),
    ],
    targets: [
        .target(name: "MovieCutCore"),
        .executableTarget(name: "MovieCut", dependencies: ["MovieCutCore"]),
        .executableTarget(name: "moviecut-cli", dependencies: ["MovieCutCore"]),
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
