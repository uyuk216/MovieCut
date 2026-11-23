import XCTest
@testable import MovieCutCore

/// 2026-11-24 のバグ確認で見つけた不具合の回帰テスト(小さなもの)。
final class BugHuntFollowupsTests: XCTestCase {
    /// CSV のセル判定が Windows 改行(\r\n)を見落とさないこと。Swift の Character では
    /// "\r\n" が1文字になり、"\n" とも "\r" とも一致しないため引用符が付かず行が壊れていた。
    func testCSVCellQuotesCRLF() {
        XCTAssertEqual(ClipListingExport.csvCell("a\r\nb"), "\"a\r\nb\"")
        XCTAssertEqual(ClipListingExport.csvCell("a\nb"), "\"a\nb\"")
        XCTAssertEqual(ClipListingExport.csvCell("a,b"), "\"a,b\"")
        XCTAssertEqual(ClipListingExport.csvCell("abc"), "abc")
    }

    /// 書き出し仕様の提案ファイル名はコーデックに従うこと(ProRes でも .mp4 になっていた)。
    func testExportSpecSuggestedFileNameFollowsCodec() {
        let prores = ExportSpec(name: "n", stem: "s", width: 320, height: 180, codec: "prores422")
        XCTAssertTrue(prores.suggestedFileName(documentName: "d").hasSuffix(".mov"))
        let h264 = ExportSpec(name: "n", stem: "s", width: 320, height: 180, codec: "h264")
        XCTAssertTrue(h264.suggestedFileName(documentName: "d").hasSuffix(".mp4"))
        let audio = ExportSpec(name: "n", stem: "s", width: 0, height: 0, codec: "h264", audioOnly: true)
        XCTAssertTrue(audio.suggestedFileName(documentName: "d").hasSuffix(".m4a"))
    }

    /// AquesTalk の合成が途中で失敗したとき、壊れた WAV がキャッシュに残らないこと
    /// (残ると次回に「当たった」として壊れた音声が使われ続けていた不具合の回帰)。
    /// 同じプレイヤーが「失敗 → 成功」と変わる形で確かめる(キーはプレイヤーのパスで決まるため)。
    func testAquesTalkFailedSynthesisDoesNotPoisonCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aqpoison-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flag = dir.appendingPathComponent("failflag")
        let player = dir.appendingPathComponent("player.sh")
        let script = "#!/bin/sh\n"
            + "while [ $# -gt 0 ]; do if [ \"$1\" = \"-W\" ]; then out=\"$2\"; fi; shift; done\n"
            + "if [ -f \"\(flag.path)\" ]; then printf 'PARTIAL' > \"$out\"; exit 1; fi\n"
            + "printf 'FULLWAV' > \"$out\"\nexit 0\n"
        try script.write(to: player, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: player.path)
        let cache = VoiceCache(directory: dir.appendingPathComponent("cache"))
        let synth = AquesTalkSynthesizer(cache: cache, playerPath: player.path)
        try Data().write(to: flag)
        do { _ = try await synth.synthesize(text: "テスト", voice: nil, speed: nil); XCTFail("失敗するはず") } catch {}
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasSuffix(".wav") }.isEmpty,
                      "失敗した合成の壊れた WAV がキャッシュに残っている: \(leftovers)")
        try FileManager.default.removeItem(at: flag)
        let url = try await synth.synthesize(text: "テスト", voice: nil, speed: nil)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "FULLWAV")
    }

    /// 口パク用タイミング(moraTimeline)がアクセントの手修正を反映すること
    /// (合成だけ手修正が効いて、タイミングは既定のままになっていた不具合の回帰)。
    func testMoraTimelineReflectsAccentEdits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mora-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = VoicevoxClient(baseURL: "http://fake.local:50021", cache: VoiceCache(directory: dir),
                                    session: AccentFakeVoicevox.session(),
                                    policy: VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"]))
        let base = try await client.moraTimeline(text: "こんにちは", speaker: 3)
        XCTAssertFalse(base.isEmpty)
        let q = try JSONSerialization.jsonObject(with: Data(sampleAudioQueryJSON.utf8)) as! [String: Any]
        var edited = try XCTUnwrap(VoicevoxAccent.phrases(fromQuery: q))
        for i in edited.indices {
            for j in edited[i].moras.indices { edited[i].moras[j].vowelLength = 2.0 }
        }
        let withEdits = try await client.moraTimeline(text: "こんにちは", speaker: 3, accentPhrases: edited)
        XCTAssertGreaterThan(withEdits.last!.end, base.last!.end + 1.0,
                             "手修正した母音の長さがタイミングに反映される")
    }

    /// 連番の取り込みキャッシュ鍵で fps を整数に切り捨てないこと(29 と 29.97 が同じ鍵になり、
    /// 古い APNG が再利用されていた)。
    func testImageSequenceCacheKeyDistinguishesFractionalFPS() {
        let seq = ImageSequence(directory: "/nonexistent", prefix: "f_", suffix: "", ext: "png", digits: 4,
                                frames: [.init(path: "/nonexistent/f_0001.png", number: 1),
                                         .init(path: "/nonexistent/f_0002.png", number: 2)],
                                missingNumbers: [])
        XCTAssertNotEqual(ImageSequenceImporter.cacheKey(sequence: seq, fps: 29),
                          ImageSequenceImporter.cacheKey(sequence: seq, fps: 29.97))
        XCTAssertEqual(ImageSequenceImporter.cacheKey(sequence: seq, fps: 29.97),
                       ImageSequenceImporter.cacheKey(sequence: seq, fps: 29.97))
    }
}
