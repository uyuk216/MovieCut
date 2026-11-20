import XCTest
@testable import MovieCutCore

/// YMM4 プロジェクトファイル(.ymmp / JSON 形式)インポーターのプロトタイプ検証。
/// フィクスチャは実ファイルの構造をもとに作った最小構成(内容はテスト用に創作)。
final class YmmpImportTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymmp", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func basicOutput() throws -> YmmpImporter.Output {
        try YmmpImporter.convert(data: fixtureData("ymmp-basic"))
    }

    // MARK: プロジェクトの基本情報

    func testProjectSettingsAndCharacters() throws {
        let out = try basicOutput()
        XCTAssertEqual(out.project.width, 1920)
        XCTAssertEqual(out.project.height, 1080)
        XCTAssertEqual(out.project.fps, 60)
        XCTAssertEqual(out.report.sourceFPS, 60)
        XCTAssertEqual(out.report.timelineName, "メイン")
        XCTAssertEqual(out.project.characters.count, 2)
        let reimu = try XCTUnwrap(out.project.characters.first { $0.name == "テストキャラ1" })
        XCTAssertEqual(reimu.engine, "voicevox")
        XCTAssertEqual(reimu.speaker, 8, "VOICEVOX の StyleID を speaker に引き継ぐ")
        XCTAssertEqual(reimu.color, "#8b0000", "#AARRGGBB からアルファを落とす")
        XCTAssertEqual(reimu.subtitleColor, "#ffffff")
        let marisa = try XCTUnwrap(out.project.characters.first { $0.name == "テストキャラ2" })
        XCTAssertEqual(marisa.engine, "aquestalk")
    }

    // MARK: ボイスアイテム

    func testVoiceItemsBecomeVoiceClipsWithSubtitleText() throws {
        let out = try basicOutput()
        let voices = out.project.allClips.filter { $0.type == .voice }
        XCTAssertEqual(voices.count, 2)
        let first = try XCTUnwrap(voices.min { $0.start < $1.start })
        XCTAssertEqual(first.start, 0)
        XCTAssertEqual(first.duration, 2.0, "120 フレーム / 60fps")
        XCTAssertEqual(first.text, "こんにちは、てすとです", "読み上げる文は Hatsuon")
        XCTAssertEqual(first.subtitleText, "こんにちは、テストです", "字幕に出す文は Serif")
        XCTAssertEqual(first.subtitle, true)
        XCTAssertEqual(first.fontSize, 64)
        XCTAssertEqual(first.font, "Yu Gothic")
        XCTAssertEqual(first.color, "#ffffff")
        let reimu = try XCTUnwrap(out.project.characters.first { $0.name == "テストキャラ1" })
        XCTAssertEqual(first.charId, reimu.id)
        let second = try XCTUnwrap(voices.max { $0.start < $1.start })
        XCTAssertEqual(second.start, 2.0)
        XCTAssertEqual(second.duration, 1.5)
        XCTAssertEqual(second.text, "二つ目のセリフだぜ")
        XCTAssertNil(second.subtitleText, "発音と字幕が同じなら subtitleText は付けない")
    }

    // MARK: テキスト / 画像 / 動画 / 音声

    func testTextImageVideoAudioItems() throws {
        let out = try basicOutput()
        let text = try XCTUnwrap(out.project.allClips.first { $0.type == .text })
        XCTAssertEqual(text.text, "タイトル文字")
        XCTAssertEqual(text.start, 0)
        XCTAssertEqual(text.duration, 3.0)
        XCTAssertEqual(text.fontSize, 80)
        XCTAssertEqual(text.color, "#ff0000")
        XCTAssertEqual(text.outline, "#000000")
        XCTAssertEqual(try XCTUnwrap(text.x), 0.5 + 100.0 / 1920, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(text.y), 0.5 + 50.0 / 1080, accuracy: 1e-9, "YMM4 の Y は上向き正なので反転する")

        let images = out.project.allClips.filter { $0.type == .image }
        XCTAssertEqual(images.count, 2)
        let slide = try XCTUnwrap(images.first { $0.src?.hasSuffix("slide.png") == true })
        XCTAssertEqual(slide.src, "C:/Users/test/img/slide.png", "パス区切りを / にそろえる")
        XCTAssertEqual(slide.duration, 10.0)
        XCTAssertEqual(slide.scale, 1.0)
        XCTAssertEqual(slide.opacity, 1.0)

        let video = try XCTUnwrap(out.project.allClips.first { $0.type == .video })
        XCTAssertEqual(video.src, "C:/Users/test/movie.mp4")
        XCTAssertEqual(video.start, 10.0)
        XCTAssertEqual(video.duration, 5.0)
        XCTAssertEqual(video.offset, 2.5, "ContentOffset(TimeSpan)を秒にする")
        XCTAssertNil(video.speed, "PlaybackRate 100 は等倍なので付けない")

        let audio = try XCTUnwrap(out.project.allClips.first { $0.type == .audio })
        XCTAssertEqual(audio.src, "C:/Users/test/bgm.mp3")
        XCTAssertEqual(audio.duration, 15.0)
        XCTAssertEqual(audio.locked, true, "IsLocked を引き継ぐ")
    }

    // MARK: レイヤー → トラック

    func testLayersBecomeTracksInAscendingOrder() throws {
        let out = try basicOutput()
        XCTAssertEqual(out.project.tracks.count, 5, "クリップのあるレイヤー(0,1,2,4,5)だけ")
        XCTAssertEqual(out.project.tracks.map(\.name), ["レイヤー1", "レイヤー2", "レイヤー3", "レイヤー5", "レイヤー6"])
        XCTAssertEqual(out.project.tracks[3].clips.count, 2, "レイヤー4 = ボイス 2 件")
        XCTAssertTrue(out.project.tracks[3].clips.allSatisfy { $0.type == .voice })
        XCTAssertEqual(out.project.mediaPool, [
            "C:/Users/test/img/slide.png",
            "C:/Users/test/movie.mp4",
            "C:/Users/test/bgm.mp3",
            "C:/Users/test/img/fx.png",
        ])
    }

    // MARK: 読み飛ばしとレポート

    func testSkippedItemsAndDroppedEffectsAreReported() throws {
        let out = try basicOutput()
        XCTAssertEqual(out.report.convertedCount, 7)
        XCTAssertEqual(out.report.skipped.count, 3)
        XCTAssertEqual(Set(out.report.skipped.map(\.typeName)), ["TachieItem", "ShapeItem", "VoiceItem"])
        XCTAssertTrue(out.report.skipped.contains { $0.typeName == "VoiceItem" && $0.reason.contains("Serif") })
        XCTAssertEqual(out.report.droppedEffectCount, 1, "VideoEffects の 1 件が落ちる")
        XCTAssertEqual(out.report.droppedKeyframeItemCount, 1, "KeyFrames のあるアイテム 1 件")
        XCTAssertTrue(out.report.notes.contains { $0.contains("音量") }, "音量を未引き継ぎである注記")
        XCTAssertTrue(out.report.notes.contains { $0.contains("Windows") }, "素材パスの注記")
    }

    // MARK: 変換結果が MovieCut のプロジェクトとして読み直せる

    func testConvertedProjectRoundTrips() throws {
        let out = try basicOutput()
        let data = try out.project.encoded()
        let loaded = try Project.decode(from: data)
        XCTAssertEqual(loaded.allClips.count, 7)
        XCTAssertEqual(loaded.characters.count, 2)
        let voice = try XCTUnwrap(loaded.allClips.first { $0.type == .voice })
        XCTAssertEqual(voice.subtitleText, "こんにちは、テストです")
    }

    // MARK: β 期形式(単数 Timeline + 先頭 "_")

    func testBetaFormatWithLeadingUnderscoreAndBOM() throws {
        let out = try YmmpImporter.convert(data: fixtureData("ymmp-beta"))
        XCTAssertEqual(out.project.fps, 30)
        XCTAssertEqual(out.project.width, 1280)
        XCTAssertEqual(out.project.height, 720)
        XCTAssertEqual(out.report.timelineName, "ベータ")
        let text = try XCTUnwrap(out.project.allClips.first { $0.type == .text })
        XCTAssertEqual(text.text, "ベータ形式の文字")
        XCTAssertEqual(text.start, 1.0, "30 フレーム / 30fps")
        XCTAssertEqual(text.duration, 2.0)
    }

    // MARK: エラー(部分変換でごまかさない)

    func testErrors() {
        XCTAssertThrowsError(try YmmpImporter.convert(data: Data("not json".utf8))) {
            XCTAssertEqual($0 as? YmmpImporter.Failure, .notJSON)
        }
        XCTAssertThrowsError(try YmmpImporter.convert(data: Data("<?xml version=\"1.0\"?><Project/>".utf8))) {
            XCTAssertEqual($0 as? YmmpImporter.Failure, .notJSON, "YMM3 の XML 形式は対象外")
        }
        XCTAssertThrowsError(try YmmpImporter.convert(data: Data("[]".utf8))) {
            XCTAssertEqual($0 as? YmmpImporter.Failure, .notProject)
        }
        XCTAssertThrowsError(try YmmpImporter.convert(data: Data("{}".utf8))) {
            XCTAssertEqual($0 as? YmmpImporter.Failure, .noTimeline)
        }
        let badFPS = #"{"Timelines":[{"VideoInfo":{"FPS":0},"Items":[]}]}"#
        XCTAssertThrowsError(try YmmpImporter.convert(data: Data(badFPS.utf8))) {
            XCTAssertEqual($0 as? YmmpImporter.Failure, .invalidFPS)
        }
        let badItems = #"{"Timelines":[{"VideoInfo":{"FPS":60},"Items":{}}]}"#
        XCTAssertThrowsError(try YmmpImporter.convert(data: Data(badItems.utf8))) {
            XCTAssertEqual($0 as? YmmpImporter.Failure, .malformedItems)
        }
    }

    // MARK: 拡張子の定数(1 箇所管理)

    func testOutputExtensionComesFromSingleConstant() {
        let dir = URL(fileURLWithPath: "/tmp/out")
        let url = YmmpImporter.outputURL(forSourceFile: URL(fileURLWithPath: "/tmp/movie.ymmp"), in: dir)
        XCTAssertEqual(url.lastPathComponent, "movie." + ProjectFileExtension.current)
        XCTAssertTrue(ProjectFileExtension.isReadableFile(URL(fileURLWithPath: "/tmp/a.ymproj")), "移行互換で旧拡張子も読める")
        XCTAssertTrue(ProjectFileExtension.isReadableFile(URL(fileURLWithPath: "/tmp/a." + ProjectFileExtension.current)))
        XCTAssertFalse(ProjectFileExtension.isReadableFile(URL(fileURLWithPath: "/tmp/a.txt")))
    }

    // MARK: 補助関数

    func testTimeSpanParsing() {
        XCTAssertEqual(YmmpImporter.timeSpanSeconds("00:00:02.5000000"), 2.5)
        XCTAssertEqual(YmmpImporter.timeSpanSeconds("00:00:00"), 0)
        let withDays: Double = 86400 + 7200 + 180 + 4
        XCTAssertEqual(YmmpImporter.timeSpanSeconds("1.02:03:04"), withDays)
        XCTAssertNil(YmmpImporter.timeSpanSeconds("abc"))
    }
}
