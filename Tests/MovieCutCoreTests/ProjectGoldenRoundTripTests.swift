import XCTest
@testable import MovieCutCore

/// プロジェクト形式の「固定した期待値」のテスト(改善ラウンド6 キュー1 / docs/project-format-audit-r6.md)。
///
/// 目的: 仕様書 01 を実装に合わせて書き直す際の根拠(ゴールデン)を、テストとして固定する。
/// - ID は全て固定文字列(`newId()` のランダム値に依存しない)。Date・辞書順にも依存しない。
/// - JSON の比較は、キー順・数値表記の揺れを避けるため JSONSerialization 経由の正規化(NSDictionary 等価)で行う。
///   バイト一致を見るのは「同じ実装で encode→decode→encode した結果」だけ(冪等性)。
/// - 実装の挙動は変えない。懸念(N-1 など)に当たる「現状の挙動」を固定するテストは、名前に Characterization を付けた。
final class ProjectGoldenRoundTripTests: XCTestCase {
    // MARK: - ヘルパー

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func object(_ p: Project) throws -> [String: Any] { try object(p.encoded()) }

    private func text(_ p: Project) throws -> String { String(decoding: try p.encoded(), as: UTF8.self) }

    private func clip(_ id: String, _ type: ClipType, start: Double = 0, duration: Double = 1) -> Clip {
        var c = Clip()
        c.id = id; c.type = type; c.start = start; c.duration = duration
        return c
    }

    private func track(_ id: String, _ name: String, _ clips: [Clip] = []) -> Track {
        var t = Track(name: name)
        t.id = id; t.clips = clips
        return t
    }

    /// 代表構成のプロジェクト(複数トラック・主な種別・キャラクター・マーカー・素材まわり)。ID は固定。
    private func representativeProject() -> Project {
        var p = Project()
        p.width = 1280; p.height = 720; p.fps = 30; p.bg = "#112233"; p.codec = "hevc"

        var ch = Character()
        ch.id = "ch1"; ch.name = "A"; ch.engine = "voicevox"; ch.speaker = 3; ch.speed = 1.25; ch.color = "#e8384f"
        p.characters = [ch]

        var title = clip("c-text", .text, start: 0, duration: 2)
        title.text = "こんにちは"; title.fontSize = 72; title.color = "#ffffff"; title.outline = "#000000"
        var voice = clip("c-voice", .voice, start: 2, duration: 3)
        voice.text = "テスト"; voice.charId = "ch1"; voice.subtitle = true
        var img = clip("c-image", .image, start: 0, duration: 5)
        img.src = "/media/a.png"; img.x = 0.25; img.y = 0.75; img.scale = 1.5; img.opacity = 0.5
        var vid = clip("c-video", .video, start: 0, duration: 4)
        vid.src = "/media/b.mp4"; vid.srcDuration = 10; vid.offset = 1; vid.volume = 0.5; vid.locked = true
        var blur = clip("c-blur", .blur, start: 1, duration: 2)
        blur.w = 0.4; blur.h = 0.2; blur.strength = 30; blur.shape = "ellipse"
        p.tracks = [
            track("t1", "字幕", [title, voice]),
            track("t2", "映像", [img, vid]),
            track("t3", "ぼかし", [blur]),
        ]
        p.tracks[2].hidden = true
        p.tracks[1].muted = true

        var m = Marker(time: 1.5, name: "見出し"); m.id = "m1"
        p.markers = [m]
        p.rangeIn = 0.5; p.rangeOut = 4.5
        p.mediaPool = ["/media/a.png", "/media/b.mp4"]
        p.mediaHints = ["/media/a.png": MediaHint(relative: "media/a.png", size: 12)]
        p.mediaFingerprints = ["/media/a.png": MediaFingerprint(fileName: "a.png", size: 12, sha256: String(repeating: "ab", count: 32))]
        p.proxyLinks = ["/media/b.mp4": "/proxy/b.mp4"]
        p.targetTrackId = "t2"
        p.subtitleY = 0.8
        p.scriptText = "台本の1行目\n台本の2行目"
        p.readingDictionary = [ReadingEntry(word: "相棒", reading: "あいぼう")]
        return p
    }

    // MARK: - 冪等性

    /// 代表構成: encode → decode → 再 encode がバイト一致し、decode した値も元と等しい。
    func testRepresentativeProjectEncodeDecodeEncodeIsByteStable() throws {
        let p = representativeProject()
        let d1 = try p.encoded()
        let back = try Project.decode(from: d1)
        XCTAssertEqual(back, p)
        let d2 = try back.encoded()
        XCTAssertEqual(d1, d2, "encode→decode→encode でバイトが変わらない")
        let d3 = try Project.decode(from: d2).encoded()
        XCTAssertEqual(d2, d3)
    }

    /// encoded() の出力形式: キー昇順・整形・"/" をエスケープしない。
    func testEncodedFormatIsSortedPrettyAndDoesNotEscapeSlashes() throws {
        let s = try text(representativeProject())
        XCTAssertTrue(s.contains("\n  \"aquestalkCommand\""), "整形(2 スペースの字下げ)で出る")
        XCTAssertTrue(s.contains("\"/media/a.png\""), "スラッシュを \\/ にしない")
        XCTAssertFalse(s.contains("\\/"))
        let bg = try XCTUnwrap(s.range(of: "\"bg\""))
        let codec = try XCTUnwrap(s.range(of: "\"codec\""))
        let height = try XCTUnwrap(s.range(of: "\"height\" :"))
        XCTAssertTrue(bg.lowerBound < codec.lowerBound && codec.lowerBound < height.lowerBound, "トップレベルのキーは昇順")
    }

    // MARK: - ゴールデン JSON(固定文字列)

    /// 全ての値が明示されていて、読み書きで変わらない JSON。decode → encode の結果が正規化比較で一致する。
    /// (未知キー `futureTop` / `futureChar` / 未知の type `hologram` も保持される)
    func testGoldenJSONDecodeEncodeKeepsEverything() throws {
        let sha = String(repeating: "a", count: 64)
        let golden = """
        {
          "formatVersion": 2,
          "width": 1280, "height": 720, "fps": 30,
          "bg": "#112233", "codec": "hevc",
          "voicevoxUrl": "http://127.0.0.1:50021",
          "aquestalkCommand": "say {text}",
          "characters": [
            {"id": "ch1", "name": "A", "engine": "voicevox", "color": "#e8384f", "speaker": 3, "speed": 1.5, "futureChar": 1}
          ],
          "tracks": [
            {"id": "t1", "name": "L1", "hidden": true, "clips": [
              {"id": "c1", "type": "text", "start": 0, "duration": 2, "offset": 0, "text": "こんにちは", "fontSize": 80, "color": "#ffffff"},
              {"id": "c2", "type": "hologram", "start": 2, "duration": 1, "offset": 0, "weird": true}
            ]}
          ],
          "markers": [{"id": "m1", "time": 1.5, "name": "A"}],
          "rangeIn": 0.5, "rangeOut": 9,
          "mediaPool": ["/a/x.mp4"],
          "mediaHints": {"/a/x.mp4": {"relative": "media/x.mp4", "size": 3}},
          "mediaFingerprints": {"/a/x.mp4": {"fileName": "x.mp4", "size": 3, "sha256": "\(sha)"}},
          "proxyLinks": {"/a/x.mp4": "/p/x.mp4"},
          "targetTrackId": "t1",
          "subtitleY": 0.8,
          "scriptText": "台本",
          "futureTop": {"a": [1, null, "s"]}
        }
        """
        let p = try Project.decode(from: Data(golden.utf8))
        let expected = try object(Data(golden.utf8))
        let actual = try object(p)
        XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected))
        XCTAssertEqual(p.tracks[0].clips[1].type.rawValue, "hologram")
        XCTAssertEqual(p.mediaFingerprints["/a/x.mp4"]?.sha256, sha)
    }

    /// 空のオブジェクトは既定のプロジェクトと同じ(欠落 = 既定値)。書くと必須キーが補われる。
    func testEmptyObjectDecodesToDefaultsAndWritesRequiredKeys() throws {
        let p = try Project.decode(from: Data("{}".utf8))
        XCTAssertEqual(p, Project.new().withoutRandomIds(of: p))
        let o = try object(p)
        XCTAssertEqual(Set(o.keys), Self.alwaysWrittenTopLevelKeys)
    }

    // MARK: - 常に書く / 書かない

    static let alwaysWrittenTopLevelKeys: Set<String> = ["formatVersion", "width", "height", "fps", "bg", "codec", "voicevoxUrl", "aquestalkCommand", "characters", "tracks"]

    /// 既定のプロジェクトで「空なら書かない / 設定時のみ書く」キーが書かれていないこと。
    func testDefaultProjectOmitsOptionalTopLevelKeys() throws {
        let o = try object(Project.new())
        XCTAssertEqual(Set(o.keys), Self.alwaysWrittenTopLevelKeys)
        XCTAssertEqual(o["formatVersion"] as? Int, 2)
        XCTAssertEqual(o["width"] as? Int, 1920)
        XCTAssertEqual(o["height"] as? Int, 1080)
        XCTAssertEqual(o["fps"] as? Int, 60)
        XCTAssertEqual(o["bg"] as? String, "#000000")
        XCTAssertEqual(o["codec"] as? String, "h264")
        XCTAssertEqual(o["voicevoxUrl"] as? String, "http://127.0.0.1:50021")
        XCTAssertEqual((o["characters"] as? [Any])?.count, 3)
        XCTAssertEqual((o["tracks"] as? [Any])?.count, 5)
    }

    /// 逆に、設定すると該当キーが書かれる(オプションのトップレベルキー)。
    func testSettingOptionalTopLevelFieldsWritesTheirKeys() throws {
        var p = Project.new()
        var m = Marker(time: 1, name: "m"); m.id = "m1"
        p.markers = [m]
        var rc = ReviewComment(time: 1, body: "b"); rc.id = "r1"
        p.reviewComments = [rc]
        p.rangeIn = 1; p.rangeOut = 2
        p.mediaHints = ["a": MediaHint(relative: "media/a", size: 1)]
        p.mediaFingerprints = ["a": MediaFingerprint(fileName: "a", size: 1, sha256: String(repeating: "0", count: 64))]
        p.proxyLinks = ["a": "b"]
        p.mediaPool = ["a"]
        var md = MediaMetadata(); md.rating = 3
        p.mediaMetadata = ["a": md]
        p.smartCollections = [SmartCollection(id: "s1", name: "n", criteria: MediaFilterCriteria(minRating: 3))]
        p.targetTrackId = "t"
        p.readingDictionary = [ReadingEntry(word: "a", reading: "b")]
        p.scenes = [SceneDefinition(id: "sc1", name: "S", tracks: [])]
        p.subtitleY = 0.5
        p.camera = CameraSettings(x: 0.6, y: 0.5, targetX: 0.5, targetY: 0.5, orbit: 0, fov: 60)
        p.scriptText = "x"
        let o = try object(p)
        let optional: Set<String> = ["markers", "reviewComments", "rangeIn", "rangeOut", "mediaHints", "mediaFingerprints", "proxyLinks", "mediaPool",
                                     "mediaMetadata", "smartCollections", "targetTrackId", "readingDictionary", "scenes", "subtitleY", "camera", "scriptText"]
        XCTAssertEqual(Set(o.keys), Self.alwaysWrittenTopLevelKeys.union(optional))
    }

    /// カメラが既定値のときは書かない。メディアメタデータは中身が空なら書かない。
    func testDefaultCameraAndEmptyMediaMetadataAreNotWritten() throws {
        var p = Project.new()
        p.camera = CameraSettings()
        p.mediaMetadata = ["a": MediaMetadata()]
        let o = try object(p)
        XCTAssertNil(o["camera"])
        XCTAssertNil(o["mediaMetadata"])
    }

    /// クリップ: 既定のクリップは id/type/start/duration/offset だけ。true のときだけ書くフラグ・既定値は書かない項目の確認。
    func testClipDefaultsAreOmittedAndFlagsAreWrittenOnlyWhenTrue() throws {
        var c = clip("k", .image)
        func keys(_ c: Clip) throws -> Set<String> {
            var p = Project.new()
            p.tracks = [track("t", "L", [c])]
            let t = try XCTUnwrap((try object(p)["tracks"] as? [[String: Any]])?.first)
            return Set(try XCTUnwrap((t["clips"] as? [[String: Any]])?.first).keys)
        }
        let base: Set<String> = ["id", "type", "start", "duration", "offset"]
        XCTAssertEqual(try keys(c), base)

        // 既定値・false は書かない
        c.locked = false; c.muted = false; c.disabled = false; c.treatAsVoice = false
        c.speakingOnly = false; c.followsProjectEnd = false; c.playsAnimation = false
        c.frameBlend = false; c.frameFlow = false; c.stabilize = 0; c.stabilizeRoll = false
        c.channelMode = .downmix; c.mouthDrive = MouthDrive.all
        c.note = ""
        XCTAssertEqual(try keys(c), base)

        // true なら書く
        c.locked = true; c.muted = true; c.disabled = true; c.treatAsVoice = true
        c.speakingOnly = true; c.followsProjectEnd = true; c.playsAnimation = true
        c.frameBlend = true; c.frameFlow = true; c.stabilize = 0.5; c.stabilizeRoll = true
        XCTAssertEqual(try keys(c), base.union(["locked", "muted", "disabled", "treatAsVoice", "speakingOnly", "followsProjectEnd",
                                               "playsAnimation", "frameBlend", "frameFlow", "stabilize", "stabilizeRoll"]))
    }

    /// 既定値のアクセサ(OrDefault)が仕様書に載せる値と一致する。
    func testClipOrDefaultValuesMatchTheDocumentedTable() {
        let c = clip("k", .image)
        XCTAssertEqual([c.xOrDefault, c.yOrDefault], [0.5, 0.5])
        XCTAssertEqual([c.scaleOrDefault, c.opacityOrDefault, c.volumeOrDefault, c.blurOrDefault], [1, 1, 1, 0])
        XCTAssertEqual([c.wOrDefault, c.hOrDefault, c.strengthOrDefault], [0.3, 0.3, 24])
        XCTAssertEqual(c.shapeOrDefault, "rect")
        XCTAssertEqual(c.blurModeOrDefault, "blur")
        XCTAssertEqual(c.mosaicSizeOrDefault, 12)
        XCTAssertEqual(c.colorOrDefault, "#ffffff")
        XCTAssertEqual(c.outlineOrDefault, "#000000")
        XCTAssertEqual(c.fontSizeOrDefault, 80)
        XCTAssertEqual(clip("v", .voice).fontSizeOrDefault, 64)
        XCTAssertEqual(c.rotationOrDefault, 0)
    }

    /// キャラクター: 新規は旧立ち絵の 7 キーを全部書く。未設定の任意項目は書かない。移行後(legacyKeys 空)は既定でない値だけ。
    func testCharacterWritesLegacyPoseKeysOnlyWhenPresentOrNonDefault() throws {
        var c = Character()
        c.id = "c"; c.name = "n"
        func keys(_ c: Character) throws -> Set<String> {
            var p = Project.new()
            p.characters = [c]
            return Set(try XCTUnwrap((try object(p)["characters"] as? [[String: Any]])?.first).keys)
        }
        XCTAssertEqual(try keys(c), ["id", "name", "engine", "color", "imgClosed", "imgOpen", "x", "y", "scale", "flip", "alwaysShow"], "新規は旧立ち絵の項目を全部書く")
        c.legacyKeys = []
        XCTAssertEqual(try keys(c), ["id", "name", "engine", "color"], "移行後は既定値の立ち絵項目を書かない")
        c.x = 0.18; c.flip = true; c.alwaysShow = false
        XCTAssertEqual(try keys(c), ["id", "name", "engine", "color", "x", "flip", "alwaysShow"])
        // 3 キャラの既定
        let d = Character.defaults()
        XCTAssertEqual(d.map(\.name), ["キャラ1", "キャラ2", "キャラ3"])
        XCTAssertEqual(d.map(\.color), ["#e8384f", "#f2c53d", "#7ac943"])
        XCTAssertEqual(d.map(\.x), [0.18, 0.82, 0.82])
        XCTAssertEqual(d.map(\.flip), [true, false, false])
    }

    /// トラック: 標準値は書かない(hidden/muted は設定した値をそのまま書く)。
    func testTrackWritesOptionalFlagsOnlyWhenSet() throws {
        func keys(_ t: Track) throws -> Set<String> {
            var p = Project.new()
            p.tracks = [t]
            return Set(try XCTUnwrap((try object(p)["tracks"] as? [[String: Any]])?.first).keys)
        }
        var t = track("t", "L")
        XCTAssertEqual(try keys(t), ["id", "name", "clips"])
        t.hidden = true; t.muted = true; t.locked = true; t.solo = true; t.height = "large"; t.volume = 0.5; t.pan = -0.5
        XCTAssertEqual(try keys(t), ["id", "name", "clips", "hidden", "muted", "locked", "solo", "height", "volume", "pan"])
        XCTAssertEqual(Track.defaultLayers().map(\.name), (1...5).map { "レイヤー\($0)" })
    }

    // MARK: - クリップ種別

    /// 既知の 12 種 + 未知の type が、往復で文字列のまま保たれる。
    func testAllClipTypesRoundTripKeepingTypeStrings() throws {
        let expected = ["image", "video", "audio", "text", "voice", "blur", "adjustment", "visualizer", "compound", "scene", "shape", "tachie"]
        XCTAssertEqual(ClipType.known.map(\.rawValue), expected)
        XCTAssertTrue(ClipType.known.allSatisfy(\.isKnown))
        let all = expected + ["hologram"]
        var p = Project.new()
        p.tracks = [track("t", "L", all.enumerated().map { clip("k\($0.offset)", ClipType(rawValue: $0.element)) })]
        let back = try Project.decode(from: p.encoded())
        XCTAssertEqual(back.tracks[0].clips.map { $0.type.rawValue }, all)
        XCTAssertFalse(ClipType(rawValue: "hologram").isKnown)
        let clips = try XCTUnwrap((try object(back)["tracks"] as? [[String: Any]])?.first?["clips"] as? [[String: Any]])
        XCTAssertEqual(clips.compactMap { $0["type"] as? String }, all)
    }

    /// type が文字列でない・欠けているとき: 欠落は image、型違いは "unknown"(現状の挙動)。
    func testMissingOrNonStringClipTypeFallsBack() throws {
        let src = #"{"tracks":[{"id":"t","name":"L","clips":[{"id":"a"},{"id":"b","type":5}]}]}"#
        let p = try Project.decode(from: Data(src.utf8))
        XCTAssertEqual(p.tracks[0].clips[0].type, .image)
        XCTAssertEqual(p.tracks[0].clips[1].type.rawValue, "unknown")
    }

    // MARK: - fps / formatVersion

    func testFpsIsWrittenAsIntegerWhenWholeAndDecimalOtherwise() throws {
        var p = Project.new()
        p.fps = 30
        XCTAssertTrue(try text(p).contains("\"fps\" : 30,"))
        p.fps = 24.0
        XCTAssertTrue(try text(p).contains("\"fps\" : 24,"))
        p.fps = 29.97
        XCTAssertTrue(try text(p).contains("\"fps\" : 29.97,"))
        p.fps = 23.976
        XCTAssertTrue(try text(p).contains("\"fps\" : 23.976,"))
        p.fps = 12.5
        XCTAssertTrue(try text(p).contains("\"fps\" : 12.5,"))
    }

    func testFpsInputFormsAndClamping() throws {
        func fps(_ raw: String) throws -> Double {
            try Project.decode(from: Data("{\"fps\":\(raw)}".utf8)).fps
        }
        XCTAssertEqual(try fps("30"), 30)
        XCTAssertEqual(try fps("30.0"), 30)
        XCTAssertEqual(try fps("29.97"), 29.97, accuracy: 1e-9)
        XCTAssertEqual(try fps("\"29.97\""), 29.97, accuracy: 1e-9)
        XCTAssertEqual(try fps("\"30000/1001\""), 30000.0 / 1001.0, accuracy: 1e-9)
        XCTAssertEqual(try fps("1000"), 240)
        XCTAssertEqual(try fps("0"), 1)
        XCTAssertEqual(try fps("-5"), 1)
        XCTAssertEqual(try fps("\"abc\""), 60, "読めない文字列は既定の 60")
        XCTAssertEqual(try fps("null"), 60)
        XCTAssertEqual(try fps("true"), 60)
        // 分数で読んだものを書くと、放送用の表示値 29.97 になる
        var p = try Project.decode(from: Data(#"{"fps":"30000/1001"}"#.utf8))
        XCTAssertTrue(try text(p).contains("\"fps\" : 29.97,"))
        p.fps = 60
        XCTAssertTrue(try text(p).contains("\"fps\" : 60,"))
    }

    func testFormatVersionRoundTrip() throws {
        func written(_ src: String) throws -> Int? {
            try object(Project.decode(from: Data(src.utf8)))["formatVersion"] as? Int
        }
        XCTAssertEqual(try written("{}"), 2, "無し(0)は現在の版で書く")
        XCTAssertEqual(try written(#"{"formatVersion":0}"#), 2)
        XCTAssertEqual(try written(#"{"formatVersion":1}"#), 2)
        XCTAssertEqual(try written(#"{"formatVersion":2}"#), 2)
        XCTAssertEqual(try written(#"{"formatVersion":9}"#), 9, "新しい版は下げない")
        XCTAssertEqual(try written(#"{"formatVersion":"3"}"#), 2, "文字列は無効(0 扱い)")
        XCTAssertEqual(try written(#"{"formatVersion":-4}"#), 2)
        // formatVersion は extra に回らない
        XCTAssertNil(try Project.decode(from: Data(#"{"formatVersion":9}"#.utf8)).extra["formatVersion"])
        XCTAssertEqual(try Project.decode(from: Data(#"{"formatVersion":9}"#.utf8)).sourceFormat.value, 9)
    }

    // MARK: - 型違いの既知キー(保持される範囲 / 捨てられる範囲)

    /// 型が違って読めなかった既知キーを extra に退避して書き戻す型(トラックのロック等・クリップの各項目・トップレベルの一部)。
    func testWrongTypedKnownKeysAreSalvagedWhereDocumented() throws {
        let src = """
        {"targetTrackId":5,"scenes":"x","tracks":[{"id":"t","name":"L","locked":"yes","volume":"loud","clips":[
          {"id":"k","type":"image","speed":"fast","locked":false,"blendMode":"futureBlend","textStyle":7,"group":9}]}]}
        """
        let o = try object(Project.decode(from: Data(src.utf8)))
        XCTAssertEqual(o["targetTrackId"] as? Int, 5)
        XCTAssertEqual(o["scenes"] as? String, "x")
        let t = try XCTUnwrap((o["tracks"] as? [[String: Any]])?.first)
        XCTAssertEqual(t["locked"] as? String, "yes")
        XCTAssertEqual(t["volume"] as? String, "loud")
        let c = try XCTUnwrap((t["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(c["speed"] as? String, "fast")
        XCTAssertEqual(c["locked"] as? Bool, false, "true 以外のロックも捨てずに書き戻す")
        XCTAssertEqual(c["blendMode"] as? String, "futureBlend")
        XCTAssertEqual(c["textStyle"] as? Int, 7)
        XCTAssertEqual(c["group"] as? Int, 9)
    }

    /// 現状の挙動の固定(懸念 N-1): 退避の仕組みを持たない既知キー(クリップの text など)の型違いは、読み込みで値が失われる。
    /// 将来 extra への退避を足したら、このテストを更新する。
    func testCharacterizationWrongTypedKeysWithoutSalvageAreDropped() throws {
        let src = #"{"rangeIn":"x","mediaPool":5,"tracks":[{"id":"t","name":"L","hidden":"yes","clips":[{"id":"k","type":"text","text":5}]}]}"#
        let o = try object(Project.decode(from: Data(src.utf8)))
        XCTAssertNil(o["rangeIn"])
        XCTAssertNil(o["mediaPool"])
        let t = try XCTUnwrap((o["tracks"] as? [[String: Any]])?.first)
        XCTAssertNil(t["hidden"])
        XCTAssertNil((t["clips"] as? [[String: Any]])?.first?["text"])
    }

    /// 現状の挙動の固定(懸念 N-2): mediaFingerprints は 1 件でも壊れていると、辞書ごと読まれない(extra にも残らない)。
    func testCharacterizationBrokenFingerprintEntryDropsWholeDictionary() throws {
        let good = String(repeating: "a", count: 64)
        let src = "{\"mediaFingerprints\":{\"/a\":{\"fileName\":\"a\",\"size\":1,\"sha256\":\"\(good)\"},\"/b\":{\"fileName\":\"b\"}}}"
        let p = try Project.decode(from: Data(src.utf8))
        XCTAssertTrue(p.mediaFingerprints.isEmpty)
        XCTAssertNil(p.extra["mediaFingerprints"])
    }

    /// 保持の範囲(型ごと): extra を持つ型は未知キーを保持し、持たない型(Crop・Bubble・MediaHint の値・Keyframe)は捨てる。
    func testUnknownKeyPreservationBoundary() throws {
        let src = """
        {"formatVersion":9,
         "reviewComments":[{"id":"r","time":1,"body":"b","futureRc":1}],
         "scenes":[{"id":"s","name":"S","futureScene":1,"tracks":[]}],
         "tachies":[{"id":"ta","name":"T","futureTachie":1}],
         "camera":{"x":0.6,"futureCamera":1},
         "mediaHints":{"a":{"relative":"media/a","size":1,"futureHint":1}},
         "tracks":[{"id":"t","name":"L","clips":[{"id":"k","type":"image","crop":{"l":0.1,"futureCrop":1},
            "keyframes":{"x":[{"t":0,"v":1,"futureKey":1}]}}]}]}
        """
        let s = try text(Project.decode(from: Data(src.utf8)))
        for kept in ["futureRc", "futureScene", "futureTachie", "futureCamera"] { XCTAssertTrue(s.contains(kept), kept) }
        for dropped in ["futureHint", "futureCrop", "futureKey"] { XCTAssertFalse(s.contains(dropped), dropped) }
    }

    // MARK: - 壊れたファイル

    func testBrokenFilesThrowAndFieldLevelMismatchesDoNot() throws {
        XCTAssertThrowsError(try Project.decode(from: Data()))
        XCTAssertThrowsError(try Project.decode(from: Data("{broken".utf8)))
        XCTAssertThrowsError(try Project.decode(from: Data("[]".utf8)))
        XCTAssertThrowsError(try Project.decode(from: Data("\"str\"".utf8)))
        // フィールド単位の型違いは throw しない(既定値に落ちる)
        let p = try Project.decode(from: Data(#"{"width":"wide","height":null,"bg":3,"characters":"x","tracks":{}}"#.utf8))
        XCTAssertEqual([p.width, p.height], [1920, 1080])
        XCTAssertEqual(p.bg, "#000000")
        XCTAssertEqual(p.characters.count, 3)
        XCTAssertEqual(p.tracks.count, 5)
    }

    func testDeepNestingIsRejected() {
        let deep = String(repeating: "[", count: InputLimits.maxJSONDepth + 1) + String(repeating: "]", count: InputLimits.maxJSONDepth + 1)
        XCTAssertThrowsError(try Project.decode(from: Data(deep.utf8))) { XCTAssertEqual($0 as? InputLimits.Failure, .tooDeep) }
    }

    /// 読み込み時のクランプ: 常識外れの数値は安全な範囲に収める(正常値は変えない)。
    func testSanitizeClampsAbsurdValuesOnly() throws {
        let src = #"{"width":999999,"height":0,"rangeIn":1e30,"tracks":[{"id":"t","name":"L","clips":[{"id":"k","type":"image","start":1e30,"duration":2.5,"x":0.25}]}]}"#
        let p = try Project.decode(from: Data(src.utf8))
        XCTAssertEqual(p.width, InputLimits.maxPixelSide)
        XCTAssertEqual(p.height, 1)
        XCTAssertEqual(p.rangeIn, InputLimits.maxSeconds)
        XCTAssertEqual(p.tracks[0].clips[0].start, InputLimits.maxSeconds)
        XCTAssertEqual(p.tracks[0].clips[0].duration, 2.5)
        XCTAssertEqual(p.tracks[0].clips[0].x, 0.25)
    }

    // MARK: - 拡張子・保存・パッケージ・素材識別

    func testProjectFileExtensionConstants() {
        XCTAssertEqual(ProjectFileExtension.current, "mcpjc")
        XCTAssertEqual(ProjectFileExtension.readable, ["mcpjc", "ymproj"])
        XCTAssertTrue(ProjectFileExtension.isReadableFile(URL(fileURLWithPath: "/tmp/a.mcpjc")))
        XCTAssertTrue(ProjectFileExtension.isReadableFile(URL(fileURLWithPath: "/tmp/A.YMPROJ")))
        XCTAssertFalse(ProjectFileExtension.isReadableFile(URL(fileURLWithPath: "/tmp/a.json")))
        XCTAssertEqual(ProjectFileExtension.fileName(replacingExtensionOf: "a.ymproj"), "a.mcpjc")
        XCTAssertEqual(ProjectFileExtension.fileName(replacingExtensionOf: "noext"), "noext.mcpjc")
    }

    /// 単一の JSON ファイルとして保存・読み込みでき、保存は一時ファイル経由(.atomic)。往復で内容が変わらない。
    func testSaveAndLoadSingleJSONFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.mcpjc")
        let p = representativeProject()
        try p.save(to: url)
        XCTAssertEqual(try Project.load(from: url), p)
        XCTAssertEqual(try Data(contentsOf: url), try p.encoded())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["doc.mcpjc"], "保存後に一時ファイルが残らない")
        // JSON としてそのまま読める
        XCTAssertNotNil(try object(Data(contentsOf: url))["tracks"])
    }

    /// パッケージ化の命名: 同名は 2 つ目から -2, -3…。大文字小文字は同名とみなす。同じ元パスは 1 回だけ。
    func testMediaPackageNamingRule() {
        var p = Project.new()
        var a = clip("a", .video); a.src = "/a/x.mp4"
        var b = clip("b", .video); b.src = "/b/x.mp4"
        var c = clip("c", .video); c.src = "/c/X.MP4"
        var d = clip("d", .video); d.src = "/a/x.mp4"
        var e = clip("e", .video); e.src = "/gone/y.mp4"
        var f = clip("f", .audio); f.src = "/a/noext"
        var g = clip("g", .audio); g.src = "/b/noext"
        p.tracks = [track("t", "L", [a, b, c, d, e, f, g])]
        let plan = MediaPackage.plan(p, exists: { !$0.hasPrefix("/gone") }, size: { _ in 7 })
        XCTAssertEqual(plan.project.tracks[0].clips.map { $0.src }, ["media/x.mp4", "media/x-2.mp4", "media/X-3.MP4", "media/x.mp4", "/gone/y.mp4", "media/noext", "media/noext-2"])
        XCTAssertEqual(plan.copies.map(\.to), ["media/x.mp4", "media/x-2.mp4", "media/X-3.MP4", "media/noext", "media/noext-2"])
        XCTAssertEqual(plan.skipped, ["/gone/y.mp4"])
        XCTAssertEqual(plan.project.mediaHints["/a/x.mp4"], MediaHint(relative: "media/x.mp4", size: 7))
        XCTAssertNil(plan.project.mediaHints["/gone/y.mp4"])
    }

    /// 素材識別は SHA-256(小文字 hex 64 文字)。"abc" の既知ベクタ。
    func testFingerprintIsSHA256LowercaseHex() throws {
        let fp = MediaFingerprint.compute(data: Data("abc".utf8), fileName: "abc.txt")
        XCTAssertEqual(fp.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(fp.size, 3)
        XCTAssertEqual(fp.fileName, "abc.txt")
        XCTAssertEqual(MediaFingerprint(fileName: "x", size: 1, sha256: "ABCDEF").sha256, "abcdef", "init は小文字にそろえる")
        let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fp)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(o).keys), ["fileName", "size", "sha256"])
    }

    /// 素材参照: 相対パスはプロジェクトフォルダ基準で解決、フォルダ外へ出る相対パスは拒否。
    func testResolverRelativeAndEscapingPaths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("golden-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("media/a.bin"))
        let resolved = MediaResolver.resolve(src: "media/a.bin", projectDir: dir.path)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved?.hasSuffix("/media/a.bin") == true)
        XCTAssertNil(MediaResolver.resolve(src: "../escape.bin", projectDir: dir.path))
        XCTAssertNil(MediaResolver.resolve(src: "media/missing.bin", projectDir: dir.path))
        XCTAssertNil(MediaResolver.resolve(src: "", projectDir: dir.path))
    }
}

private extension Project {
    /// 既定のプロジェクトは `Character.defaults()` / `Track.defaultLayers()` が毎回ランダムな id を作るので、
    /// 比較用に id だけ `other` に合わせたコピーを返す。
    func withoutRandomIds(of other: Project) -> Project {
        var p = self
        for i in p.characters.indices where other.characters.indices.contains(i) { p.characters[i].id = other.characters[i].id }
        for i in p.tracks.indices where other.tracks.indices.contains(i) { p.tracks[i].id = other.tracks[i].id }
        return p
    }
}
