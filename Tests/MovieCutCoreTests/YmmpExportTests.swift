import XCTest
@testable import MovieCutCore

/// .ymmp 書き戻し(`YmmpExporter`)の検証。往復(import→export→import / export→import)と、
/// 対応できない要素がレポートに理由つきで残ること(黙って落ちないこと)を確かめる。
final class YmmpExportTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymmp", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func exportedItems(_ data: Data) throws -> [[String: Any]] {
        let root = try parseJSON(data)
        let timelines = try XCTUnwrap(root["Timelines"] as? [[String: Any]])
        return try XCTUnwrap(timelines.first?["Items"] as? [[String: Any]])
    }

    private func typeName(_ item: [String: Any]) -> String? {
        (item["$type"] as? String)?.split(separator: ",").first?.split(separator: ".").last.map(String.init)
    }

    // MARK: 構造(YMM4 形式としての妥当性)

    func testExportedStructureMatchesYmmpShape() throws {
        let project = try YmmpImporter.convert(data: fixtureData("ymmp-basic")).project
        let out = YmmpExporter.export(project: project)
        let root = try parseJSON(out.data)
        XCTAssertEqual(root["SelectedTimelineIndex"] as? Int, 0)
        let timelines = try XCTUnwrap(root["Timelines"] as? [[String: Any]])
        XCTAssertEqual(timelines.count, 1)
        let info = try XCTUnwrap(timelines[0]["VideoInfo"] as? [String: Any])
        XCTAssertEqual(info["Width"] as? Int, 1920)
        XCTAssertEqual(info["Height"] as? Int, 1080)
        XCTAssertEqual((info["FPS"] as? NSNumber)?.doubleValue, 60)
        let characters = try XCTUnwrap(root["Characters"] as? [[String: Any]])
        XCTAssertEqual(characters.count, 2)
        let reimu = try XCTUnwrap(characters.first { ($0["Name"] as? String) == "テストキャラ1" })
        XCTAssertEqual((reimu["Voice"] as? [String: Any])?["API"] as? String, "voicevox")
        let param = try XCTUnwrap(reimu["VoiceParameter"] as? [String: Any])
        XCTAssertTrue((param["$type"] as? String)?.contains("VOICEVOXVoiceParameter") == true)
        XCTAssertEqual(param["StyleID"] as? Int, 8)
        XCTAssertEqual(reimu["Color"] as? String, "#FF8B0000", "#rrggbb にアルファ FF を付けて #AARRGGBB に戻す")
        let items = try exportedItems(out.data)
        XCTAssertEqual(Set(items.compactMap(typeName)), ["VoiceItem", "TextItem", "ImageItem", "VideoItem", "AudioItem"])
        for item in items {
            XCTAssertNotNil(item["Frame"] as? Int)
            XCTAssertNotNil(item["Length"] as? Int)
            XCTAssertNotNil(item["Layer"] as? Int)
        }
    }

    // MARK: 往復(import → export → import)

    func testRoundTripPreservesClipsCharactersAndTiming() throws {
        let first = try YmmpImporter.convert(data: fixtureData("ymmp-basic"))
        let exported = YmmpExporter.export(project: first.project)
        // 書き出した .ymmp が、インポーターで再び変換できること(形式としての妥当性の検証を兼ねる)
        let second = try YmmpImporter.convert(data: exported.data)

        XCTAssertEqual(second.project.width, first.project.width)
        XCTAssertEqual(second.project.height, first.project.height)
        XCTAssertEqual(second.project.fps, first.project.fps)
        XCTAssertEqual(second.project.characters.count, first.project.characters.count)
        let reimu2 = try XCTUnwrap(second.project.characters.first { $0.name == "テストキャラ1" })
        XCTAssertEqual(reimu2.engine, "voicevox")
        XCTAssertEqual(reimu2.speaker, 8)
        XCTAssertEqual(reimu2.color, "#8b0000")

        XCTAssertEqual(second.project.allClips.count, first.project.allClips.count, "変換できたクリップは往復で減らない")
        XCTAssertEqual(second.report.convertedCount, first.report.convertedCount)
        func key(_ c: Clip) -> String { "\(c.type.rawValue)|\(c.start)|\(c.duration)|\(c.text ?? c.src ?? "")" }
        XCTAssertEqual(Set(second.project.allClips.map(key)), Set(first.project.allClips.map(key)))

        let voice = try XCTUnwrap(second.project.allClips.filter { $0.type == .voice }.min { $0.start < $1.start })
        XCTAssertEqual(voice.text, "こんにちは、てすとです", "Hatsuon が読み上げ文に戻る")
        XCTAssertEqual(voice.subtitleText, "こんにちは、テストです", "Serif が字幕文に戻る")
        let video = try XCTUnwrap(second.project.allClips.first { $0.type == .video })
        XCTAssertEqual(video.offset, 2.5, accuracy: 1e-6, "ContentOffset(TimeSpan)が往復する")
        XCTAssertEqual(video.src, "C:/Users/test/movie.mp4", "Windows パスは区切りを戻して往復する")
    }

    func testExportIsDeterministicInStructure() throws {
        let project = try YmmpImporter.convert(data: fixtureData("ymmp-basic")).project
        let a = try exportedItems(YmmpExporter.export(project: project).data)
        let b = try exportedItems(YmmpExporter.export(project: project).data)
        XCTAssertEqual(a.count, b.count)
        // ID(UUID)以外は同じになる
        let strip: ([String: Any]) -> String = { item in
            var d = item; d.removeValue(forKey: "ID")
            return (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        XCTAssertEqual(a.map(strip), b.map(strip))
    }

    // MARK: MovieCut で作ったプロジェクト → export → import

    func testMovieCutProjectRoundTrip() throws {
        var p = Project.new()
        p.width = 1280; p.height = 720; p.fps = 30
        var voice = Clip(); voice.type = .voice; voice.start = 0; voice.duration = 2
        voice.text = "読み上げます"; voice.subtitleText = "字幕です"; voice.subtitle = true
        voice.charId = p.characters[0].id; voice.fontSize = 64
        var text = Clip(); text.type = .text; text.start = 2; text.duration = 1.5
        text.text = "タイトル"; text.x = 0.75; text.y = 0.25; text.fontSize = 80
        var image = Clip(); image.type = .image; image.start = 0; image.duration = 3.5
        image.src = "/tmp/slide.png"; image.scale = 1.5; image.opacity = 0.5
        p.tracks[0].clips = [voice]
        p.tracks[1].clips = [text]
        p.tracks[2].clips = [image]

        let out = YmmpExporter.export(project: p)
        XCTAssertEqual(out.report.convertedCount, 3)
        XCTAssertTrue(out.report.unsupported.isEmpty)
        let back = try YmmpImporter.convert(data: out.data)
        XCTAssertEqual(back.project.allClips.count, 3)
        let v = try XCTUnwrap(back.project.allClips.first { $0.type == .voice })
        XCTAssertEqual(v.text, "読み上げます")
        XCTAssertEqual(v.subtitleText, "字幕です")
        let t = try XCTUnwrap(back.project.allClips.first { $0.type == .text })
        XCTAssertEqual(t.text, "タイトル")
        XCTAssertEqual(try XCTUnwrap(t.x), 0.75, accuracy: 1e-9, "位置が往復する")
        XCTAssertEqual(try XCTUnwrap(t.y), 0.25, accuracy: 1e-9)
        let i = try XCTUnwrap(back.project.allClips.first { $0.type == .image })
        XCTAssertEqual(i.scale, 1.5)
        XCTAssertEqual(i.opacity, 0.5)
    }

    // MARK: 対応できない要素はレポートに残る(黙って落とさない)

    func testUnsupportedClipsAndFeaturesAreReported() throws {
        var p = Project.new()
        var shape = Clip(); shape.type = .shape; shape.start = 0; shape.duration = 1
        var tachie = Clip(); tachie.type = .tachie; tachie.start = 0; tachie.duration = 1
        var voice = Clip(); voice.type = .voice; voice.start = 0; voice.duration = 1; voice.text = "声"
        voice.keyframes = ["x": [Keyframe(t: 0, v: 0.2), Keyframe(t: 1, v: 0.8)]]
        voice.effects = [Effect(kind: "blur", params: ["amount": 5])]
        p.tracks[0].clips = [shape, tachie, voice]
        p.markers = [Marker(time: 0.5, name: "印")]

        let out = YmmpExporter.export(project: p)
        XCTAssertEqual(out.report.convertedCount, 1, "ボイスだけが書き出せる")
        XCTAssertEqual(Set(out.report.unsupported.map(\.typeName)), ["shape", "tachie"])
        XCTAssertTrue(out.report.unsupported.allSatisfy { !$0.reason.isEmpty }, "理由が付いている")
        XCTAssertTrue(out.report.droppedFeatures.contains { $0.feature.contains("キーフレーム") })
        XCTAssertTrue(out.report.droppedFeatures.contains { $0.feature.contains("エフェクト") })
        XCTAssertTrue(out.report.droppedFeatures.contains { $0.feature.contains("マーカー") })
        XCTAssertTrue(out.report.hasLoss)
        // 書き出した先にも shape/tachie は入っていない
        let items = try exportedItems(out.data)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(typeName(items[0]), "VoiceItem")
    }

    func testEmptyVoiceAndMissingSourceAreReported() {
        var p = Project.new()
        var voice = Clip(); voice.type = .voice; voice.start = 0; voice.duration = 1; voice.text = ""
        var image = Clip(); image.type = .image; image.start = 0; image.duration = 1; image.src = nil
        p.tracks[0].clips = [voice, image]
        let out = YmmpExporter.export(project: p)
        XCTAssertEqual(out.report.convertedCount, 0)
        XCTAssertEqual(out.report.unsupported.count, 2)
    }

    // MARK: 補助関数

    func testTimeSpanStringRoundTripsThroughImporterParser() {
        for sec in [0.0, 2.5, 65.25, 3661.0000001] {
            let s = YmmpExporter.timeSpanString(sec)
            XCTAssertEqual(YmmpImporter.timeSpanSeconds(s) ?? -1, sec, accuracy: 0.000_001, "\(s)")
        }
    }

    func testARGBConversion() {
        XCTAssertEqual(YmmpExporter.argb("#8b0000"), "#FF8B0000")
        XCTAssertEqual(YmmpExporter.argb("#FF8B0000"), "#FF8B0000")
        XCTAssertNil(YmmpExporter.argb("red"))
        XCTAssertNil(YmmpExporter.argb(nil))
    }

    // MARK: ファイル書き出し

    func testWriteCreatesParseableFile() throws {
        let project = try YmmpImporter.convert(data: fixtureData("ymmp-basic")).project
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ymmp-export-\(UUID().uuidString).ymmp")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try YmmpExporter.write(project: project, to: url)
        XCTAssertEqual(report.convertedCount, 7)
        let reread = try YmmpImporter.load(fileAt: url)
        XCTAssertEqual(reread.project.allClips.count, 7)
    }
}
