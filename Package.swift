// swift-tools-version: 6.0
import PackageDescription
import Foundation

// 自動アップデート(Sparkle)は配布版だけに入れる。Scripts/make-app.sh --edition public が MOVIECUT_SPARKLE=1 を付けて
// ビルドする。個人版・swift test は Sparkle を取得もリンクもしない(アップデートの確認を一切しない)。
let withSparkle = ProcessInfo.processInfo.environment["MOVIECUT_SPARKLE"] == "1"

let package = Package(
    name: "MovieCut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MovieCutCore", targets: ["MovieCutCore"]),
        .executable(name: "MovieCut", targets: ["MovieCut"]),
        .executable(name: "moviecut-cli", targets: ["moviecut-cli"]),
    ],
    dependencies: withSparkle ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")] : [],
    targets: [
        .target(name: "MovieCutCore"),
        .executableTarget(
            name: "MovieCut",
            dependencies: withSparkle ? ["MovieCutCore", .product(name: "Sparkle", package: "Sparkle")] : ["MovieCutCore"],
            swiftSettings: withSparkle ? [.define("SPARKLE")] : []
        ),
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
