import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 大きさの違う画像のグループごとに別のリグを作る(顔A系 2344×2500 と 体 3000×3000)。
final class RigSizeGroupTests: XCTestCase {
    func files(_ sizes: [String: (w: Int, h: Int)], parent: [String: String] = [:]) -> [(path: String, parent: String)] {
        sizes.keys.sorted().map { (path: "/r/\(parent[$0] ?? "r")/\($0)", parent: parent[$0] ?? "r") }
    }
    func sizeOf(_ sizes: [String: (w: Int, h: Int)]) -> (String) -> (w: Int, h: Int)? { { sizes[($0 as NSString).lastPathComponent] } }

    func testSeparateGroupsPerCanvasSize() {
        var sz: [String: (w: Int, h: Int)] = [:]
        for n in ["体 (1).png", "眉 (1).png", "眉 (2).png", "目 (1).png", "口 (1).png"] { sz[n] = (3000, 3000) }
        sz["髪 (1).png"] = (3000, 3200)   // 体と同じグループ(高さが 1/6 以内)
        for n in ["顔A：眉 (1).png", "顔A：眉 (2).png", "顔A：目 (1).png", "顔A：口 (1).png"] { sz[n] = (2344, 2500) }
        sz["顔A体A (1).png"] = (2344, 2500)
        let g = RigFolderImporter.groups(files: files(sz), rootName: "r", sizeOf: sizeOf(sz))
        XCTAssertEqual(g.count, 2)
        let big = g.first { $0.width == 3000 }!, small = g.first { $0.width == 2344 }!
        XCTAssertEqual(big.report.rig.slots.map(\.name), ["体", "髪", "眉", "目", "口"])
        XCTAssertEqual(big.imageCount, 6)
        XCTAssertEqual(small.report.rig.slot("眉")?.parts.count, 2)
        XCTAssertNil(small.report.rig.slot("体"), "完成した立ち絵(顔A体A)は体として扱わない")
        XCTAssertNotEqual(big.name, small.name)
        XCTAssertTrue(big.name.contains("3000×3000") && small.name.contains("2344×2500"), "\(big.name) / \(small.name)")
        XCTAssertTrue(small.name.hasPrefix("r "))
        XCTAssertEqual(big.report.rig.alignment, .center, "髪(3200)があるグループは中央揃え")
        XCTAssertNil(small.report.rig.alignment)
        // 最初のグループ = 眉・目・口が多い方(scan と同じ基準)
        XCTAssertEqual(g[0].width, 3000)
    }

    func testSingleSizeKeepsFolderNameAndMatchesScan() {
        var sz: [String: (w: Int, h: Int)] = [:]
        for n in ["体.png", "眉 (1).png", "眉 (2).png", "目 (1).png", "口 (1).png"] { sz[n] = (100, 100) }
        let g = RigFolderImporter.groups(files: files(sz), rootName: "れいむ", sizeOf: sizeOf(sz))
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].name, "れいむ")
        let single = RigFolderImporter.group(files: files(sz), sizeOf: sizeOf(sz))
        XCTAssertEqual(g[0].report.rig, single?.rig)
    }

    func testSubfolderNamesAGroupAndUnbuildableGroupsAreDropped() {
        var sz: [String: (w: Int, h: Int)] = [:]
        var par: [String: String] = [:]
        for n in ["体.png", "眉 (1).png", "目 (1).png", "口 (1).png"] { sz[n] = (100, 100) }
        for n in ["a.png"] { sz[n] = (50, 50) }   // どのスロットにもならず、同じ名前の仲間もいない → グループにならない
        for n in ["表情 (1).png", "表情 (2).png", "表情 (3).png"] { sz[n] = (80, 90); par[n] = "テンプレ" }   // 自由なスロットになる
        let g = RigFolderImporter.groups(files: files(sz, parent: par), rootName: "x", sizeOf: sizeOf(sz))
        XCTAssertEqual(g.count, 2)
        XCTAssertTrue(g.contains { $0.name == "テンプレ 80×90" }, g.map(\.name).description)
    }

    func testEmptyFolderHasNoGroups() {
        XCTAssertTrue(RigFolderImporter.groups(files: [], rootName: "x", sizeOf: { _ in nil }).isEmpty)
    }

    func testUserFolderGroupsIfPresent() throws {
        let dir = URL(fileURLWithPath: "/Users/USER/動画素材/立ち絵/立ち絵素材フォルダ")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path), "素材フォルダがありません")
        let g = RigFolderImporter.scanGroups(folder: dir)
        for x in g { print("group:", x.name, x.width, x.height, "images", x.imageCount, x.report.rig.slots.map { "\($0.name)=\($0.parts.count)" }.joined(separator: " ")) }
        XCTAssertGreaterThanOrEqual(g.count, 2, "3000×3000 系と 2344×2500 系は別のグループ")
        XCTAssertEqual(g[0].width, 3000)
        // 最初のグループは従来の scan と同じリグ
        let single = try XCTUnwrap(RigFolderImporter.scan(folder: dir))
        XCTAssertEqual(g[0].report.rig.slots.map { "\($0.name)=\($0.parts.count)" }, single.rig.slots.map { "\($0.name)=\($0.parts.count)" })
        XCTAssertTrue(g.contains { $0.width == 2344 && $0.height == 2500 })
        XCTAssertEqual(Set(g.map(\.name)).count, g.count)
    }
}
