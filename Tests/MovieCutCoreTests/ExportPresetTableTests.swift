import XCTest
import AVFoundation
@testable import MovieCutCore

/// 書き出しプリセットの仕様表(縦型・X・YouTube の値)、ビットレートの検査、保存したプリセットの JSON(寛容な読み込み・書き出し)。
final class ExportPresetTableTests: XCTestCase {
    private func sample(w: Int = 1280, h: Int = 720, fps: Double = 60, codec: String = "h264") -> Project {
        var p = Project.new()
        p.width = w; p.height = h; p.fps = fps; p.codec = codec
        return p
    }

    func testVerticalPresetsAreFixedTo30fpsAt8Mbps() {
        for preset in [ExportPreset.tiktok, .shorts, .reels] {
            let s = preset.spec
            XCTAssertEqual([s.width, s.height], [1080, 1920], "\(preset)")
            XCTAssertEqual(s.codec, "h264", "\(preset)")
            XCTAssertEqual(s.bitrateMbps, 8, "\(preset)")
            let q = preset.apply(to: sample(w: 1920, h: 1080, fps: 60))
            XCTAssertEqual(q.fps, 30, "\(preset): 60 のプロジェクトでも 30 fps")
            XCTAssertEqual([q.width, q.height], [1080, 1920])
        }
    }

    func testXPresetsAndYouTube60() {
        XCTAssertEqual([ExportPreset.x720.spec.width, ExportPreset.x720.spec.height], [1280, 720])
        XCTAssertEqual(ExportPreset.x720.apply(to: sample(fps: 60)).fps, 30)
        XCTAssertEqual(ExportPreset.x720.spec.bitrateMbps, 8)
        XCTAssertEqual([ExportPreset.x1080.spec.width, ExportPreset.x1080.spec.height], [1920, 1080])
        XCTAssertEqual(ExportPreset.x1080.apply(to: sample(fps: 24)).fps, 60, "固定 60 fps")
        XCTAssertEqual(ExportPreset.youtube1080p60.apply(to: sample(fps: 30)).fps, 60)
        XCTAssertNil(ExportPreset.youtube1080.spec.bitrateMbps, "従来どおり既定のビットレート")
        XCTAssertNil(ExportPreset.youtube4k.spec.bitrateMbps)
        XCTAssertEqual(ExportPreset.youtube4k.spec.codec, "hevc")
    }

    func testExistingPresetsKeepTheirOldValues() {
        // 既存の 5 つは従来の値のまま(ショート縦・YouTube 1080p は fps を変えない)
        XCTAssertEqual(ExportPreset.short.apply(to: sample(fps: 24)).fps, 24)
        XCTAssertEqual(ExportPreset.youtube1080.apply(to: sample(fps: 24)).fps, 24)
        XCTAssertEqual(ExportPreset.light.apply(to: sample(fps: 60)).fps, 30)
        XCTAssertEqual(ExportPreset.light.apply(to: sample(fps: 24)).fps, 24)
        XCTAssertEqual(ExportPreset.audio.spec.audioOnly, true)
    }

    func testSuggestedNamesFollowTheStem() {
        XCTAssertEqual(ExportPreset.tiktok.suggestedFileName(documentName: "旅"), "旅-tiktok.mp4")
        XCTAssertEqual(ExportSpec(name: "縦", stem: "縦", width: 1080, height: 1920, codec: "h264").suggestedFileName(documentName: "旅"), "旅-縦.mp4")
    }

    // MARK: ビットレートの検査

    func testBitrateValidation() {
        XCTAssertEqual(ExportSpec.validBitrate(8), 8)
        XCTAssertEqual(ExportSpec.validBitrate(1), 1)
        XCTAssertEqual(ExportSpec.validBitrate(100), 100)
        XCTAssertNil(ExportSpec.validBitrate(0.5))
        XCTAssertNil(ExportSpec.validBitrate(101))
        XCTAssertNil(ExportSpec.validBitrate(.nan))
        XCTAssertNil(ExportSpec.validBitrate(.infinity))
        XCTAssertNil(ExportSpec.validBitrate(nil))
    }

    // MARK: 保存したプリセットの JSON

    func testRoundTripWritesOnlyNonDefaultOptionalFields() throws {
        let list = [
            CustomExportPreset(name: "縦 8M", width: 1080, height: 1920, codec: "h264", fps: 30, bitrateMbps: 8),
            CustomExportPreset(name: "素のまま", width: 1280, height: 720, codec: "hevc"),
        ]
        let data = CustomExportPresetStore.encode(list)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("bitrateMbps"))
        let second = try XCTUnwrap(text.components(separatedBy: "\"name\"").last)
        XCTAssertFalse(second.contains("fps"), "fps が無いものは書かない")
        XCTAssertFalse(second.contains("bitrateMbps"), "ビットレートが無いものは書かない")
        XCTAssertEqual(CustomExportPresetStore.decode(data), list)
        XCTAssertEqual(CustomExportPresetStore.encode(CustomExportPresetStore.decode(data)), data, "書き直しても同じ")
    }

    func testGarbageIsIgnoredNotFatal() {
        XCTAssertEqual(CustomExportPresetStore.decode(Data("not json".utf8)), [])
        XCTAssertEqual(CustomExportPresetStore.decode(Data("42".utf8)), [])
        XCTAssertEqual(CustomExportPresetStore.decode(Data(#"{"presets": "x"}"#.utf8)), [])
        XCTAssertEqual(CustomExportPresetStore.decode(Data("[]".utf8)), [])
        XCTAssertEqual(CustomExportPresetStore.decode(Data("".utf8)), [])
    }

    func testBadEntriesAreDroppedAndGoodOnesKept() {
        let json = """
        {"version":1,"presets":[
          "文字列",
          {"name":"","width":1080,"height":1920,"codec":"h264"},
          {"name":"a/b","width":1080,"height":1920,"codec":"h264"},
          {"name":"youtube1080","width":1920,"height":1080,"codec":"h264"},
          {"name":"奇数","width":1081,"height":1920,"codec":"h264"},
          {"name":"小さい","width":8,"height":1920,"codec":"h264"},
          {"name":"ヘン","width":1080,"height":1920,"codec":"vp9"},
          {"name":"欠け","width":1080,"codec":"h264"},
          {"name":"良い","width":1080,"height":1920,"codec":"HEVC","fps":30,"bitrateMbps":12},
          {"name":"良い","width":640,"height":360,"codec":"h264"},
          {"name":"範囲外","width":1280,"height":720,"codec":"h264","fps":9999,"bitrateMbps":500},
          {"name":"文字の型","width":"1280","height":720,"codec":"h264"}
        ]}
        """
        let got = CustomExportPresetStore.decode(Data(json.utf8))
        XCTAssertEqual(got.map(\.name), ["良い", "範囲外"])
        XCTAssertEqual(got[0], CustomExportPreset(name: "良い", width: 1080, height: 1920, codec: "hevc", fps: 30, bitrateMbps: 12))
        XCTAssertEqual(got[1], CustomExportPreset(name: "範囲外", width: 1280, height: 720, codec: "h264", fps: nil, bitrateMbps: nil), "範囲外の値は既定に戻す")
    }

    func testTooManyEntriesAreCapped() {
        let items = (0..<80).map { #"{"name":"p\#($0)","width":1280,"height":720,"codec":"h264"}"# }.joined(separator: ",")
        let got = CustomExportPresetStore.decode(Data(#"{"presets":[\#(items)]}"#.utf8))
        XCTAssertEqual(got.count, CustomExportPreset.maxCount)
    }

    func testUpsertReplacesSameNameIgnoringCase() {
        let a = CustomExportPreset(name: "Mine", width: 1280, height: 720, codec: "h264")
        let b = CustomExportPreset(name: "mine", width: 1920, height: 1080, codec: "hevc")
        let list = CustomExportPresetStore.upserting(a, into: [])!
        let replaced = CustomExportPresetStore.upserting(b, into: list)!
        XCTAssertEqual(replaced, [b])
        XCTAssertNil(CustomExportPresetStore.upserting(CustomExportPreset(name: "x", width: 16, height: 16, codec: "h264"),
                                                      into: (0..<CustomExportPreset.maxCount).map { CustomExportPreset(name: "n\($0)", width: 16, height: 16, codec: "h264") }))
    }

    func testNameRules() {
        XCTAssertTrue(CustomExportPreset.isValidName("縦動画 8M"))
        XCTAssertFalse(CustomExportPreset.isValidName("   "))
        XCTAssertFalse(CustomExportPreset.isValidName("a:b"))
        XCTAssertFalse(CustomExportPreset.isValidName("a/b"))
        XCTAssertFalse(CustomExportPreset.isValidName("TikTok"), "組み込みと同じ名前は不可")
        XCTAssertFalse(CustomExportPreset.isValidName(String(repeating: "あ", count: 41)))
    }

    func testStoreFileRoundTripAndMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-preset-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/export-presets.json")
        XCTAssertEqual(CustomExportPresetStore.load(from: url), [], "無いファイルは空")
        let list = [CustomExportPreset(name: "保存", width: 1080, height: 1920, codec: "h264", fps: 30, bitrateMbps: 8)]
        try CustomExportPresetStore.save(list, to: url)
        XCTAssertEqual(CustomExportPresetStore.load(from: url), list)
        try Data("壊れた".utf8).write(to: url)
        XCTAssertEqual(CustomExportPresetStore.load(from: url), [], "壊れたファイルは空として扱う")
    }

    func testCustomSpecAppliesLikeABuiltIn() {
        let c = CustomExportPreset(name: "縦", width: 1080, height: 1920, codec: "h264", fps: 30, bitrateMbps: 6)
        let q = c.spec.apply(to: sample(fps: 60))
        XCTAssertEqual([q.width, q.height], [1080, 1920])
        XCTAssertEqual(q.codec, "h264")
        XCTAssertEqual(q.fps, 30)
        XCTAssertEqual(c.spec.bitrateMbps, 6)
    }
}
