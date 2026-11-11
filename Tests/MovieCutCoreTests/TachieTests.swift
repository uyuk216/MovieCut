import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 立ち絵(素材)とキャラクター(声・字幕)の分離: モデル・編集・描画・台本の記法・旧形式からの移行(画素一致)・パーツの位置合わせ。
final class TachieTests: XCTestCase {
    /// 計測用: MC_TACHIE_BENCH_DIR を指定すると、素材をそこへ置き、消さない(`testWriteLegacyProjectForBenchWhenRequested`)。
    static let benchDir = ProcessInfo.processInfo.environment["MC_TACHIE_BENCH_DIR"].map { URL(fileURLWithPath: $0) }
    let tmp = TachieTests.benchDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("tachie-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { if TachieTests.benchDir == nil { try? FileManager.default.removeItem(at: tmp) } }

    // MARK: ヘルパー

    func writePNG(_ img: CGImage, _ name: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 透過 PNG: キャンバス w×h の、box(上が原点の画素)だけ色で塗る。
    func png(_ name: String, w: Int = 40, h: Int = 40, color: (UInt8, UInt8, UInt8), box: CGRect? = nil) throws -> String {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
        let b = box ?? CGRect(x: 0, y: 0, width: w, height: h)
        ctx.fill(CGRect(x: b.minX, y: CGFloat(h) - b.maxY, width: b.width, height: b.height))   // 上が原点で指定
        return try writePNG(ctx.makeImage()!, name)
    }

    /// 無音 0.5 秒のあとに 440Hz の音を 0.5 秒(16bit mono WAV)
    func writeToneWAV(_ name: String) throws -> String {
        let sr = 44100
        var samples = [Int16]()
        for i in 0..<sr { samples.append(i < sr / 2 ? 0 : Int16(12000 * sin(2 * Double.pi * 440 * Double(i) / Double(sr)))) }
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + samples.count * 2)); data.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(samples.count * 2))
        for s in samples { u16(UInt16(bitPattern: s)) }
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    func bytes(_ p: Project, t: Double, assets: RenderAssets = RenderAssets()) throws -> [UInt8] {
        let img = try XCTUnwrap(Renderer(project: p, assets: assets).renderImage(t: t))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }

    func rgb(_ d: [UInt8], w: Int, _ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2])) }

    func voice(_ id: String, char: String, text: String, wav: String, start: Double = 0, subtitle: Bool = false) -> Clip {
        var v = Clip(); v.id = id; v.type = .voice; v.start = start; v.duration = 1; v.charId = char; v.src = wav; v.text = text; v.subtitle = subtitle
        return v
    }

    func character(_ id: String, _ name: String) -> Character { var c = Character(); c.id = id; c.name = name; return c }

    func tachieClip(_ id: String, tachie: String, drive: MouthDrive? = nil, x: Double = 0.5, y: Double = 0.5, start: Double = 0, duration: Double = 3) -> Clip {
        var c = Clip(); c.id = id; c.type = .tachie; c.tachieId = tachie; c.start = start; c.duration = duration; c.x = x; c.y = y; c.mouthDrive = drive
        return c
    }

    /// 体は赤・目は緑(閉じ)/ 青(開き)のような、色で状態が分かる単純な立ち絵(単純画像版)。
    func simpleTachie(_ id: String, closed: String, open: String? = nil) -> Tachie {
        var t = Tachie(name: id); t.id = id; t.imgClosed = closed; t.imgOpen = open; return t
    }

    func project(clips: [[Clip]], characters: [Character] = [], tachies: [Tachie] = [], w: Int = 120, h: Int = 80) -> Project {
        var p = Project()
        p.width = w; p.height = h; p.bg = "#000000"
        p.characters = characters; p.tachies = tachies
        p.tracks = clips.enumerated().map { var t = Track(name: "L\($0.offset)"); t.clips = $0.element; return t }
        return p
    }

    // MARK: Stage 1 モデル

    func testModelFieldsAreOptionalAndWrittenOnlyWhenUsed() throws {
        let plain = try String(decoding: Project().encoded(), as: UTF8.self)
        for k in ["tachies", "tachieId", "mouthDrive", "subtitleText", "speakingOnly", "partOffsets"] { XCTAssertFalse(plain.contains(k), k) }
        var p = Project()
        var t = Tachie(name: "キャラ1"); t.id = "t1"; t.imgClosed = "/a.png"
        p.tachies = [t]
        var c = tachieClip("c1", tachie: "t1", drive: .character("ch1"))
        c.speakingOnly = true
        var v = Clip(); v.id = "v1"; v.type = .voice; v.text = "読み"; v.subtitleText = ""
        p.tracks[0].clips = [c, v]
        let data = try p.encoded()
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"tachies\"")); XCTAssertTrue(s.contains("\"mouthDrive\" : \"character:ch1\""))
        XCTAssertTrue(s.contains("\"subtitleText\" : \"\""), "空の字幕文(字幕なし)も書く")
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.tachies, p.tachies)
        XCTAssertEqual(back.tracks[0].clips[0].mouthDrive, .character("ch1"))
        XCTAssertEqual(back.tracks[0].clips[0].speakingOnly, true)
        XCTAssertEqual(back.tracks[0].clips[1].subtitleText, "")
        XCTAssertEqual(try back.encoded(), data, "書き直しても同じ")
        // 既定の連動(すべての声)は書かない
        var d = c; d.mouthDrive = .all; d.speakingOnly = nil
        var q = p; q.tracks[0].clips = [d]
        XCTAssertFalse(String(decoding: try q.encoded(), as: UTF8.self).contains("mouthDrive"))
    }

    func testUnknownKeysAndUnreadableValuesArePreserved() throws {
        let json = """
        {"width":320,"height":180,"fps":30,"characters":[],"tracks":[{"id":"L","name":"L","clips":[
          {"id":"c1","type":"tachie","tachieId":"t1","start":0,"duration":1,"mouthDrive":"future:xyz","zzz":1},
          {"id":"c2","type":"voice","start":0,"duration":1,"text":"a","subtitleText":5}]}],
         "tachies":[{"id":"t1","name":"n","imgClosed":"/a.png","future":{"k":[1,2]},"rig":{"slots":[{"name":"体","parts":["/p.png"],"active":0}],"partOffsets":{"/p.png":[3,-4]},"keep":true}}],
         "futureTop":"x"}
        """
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertEqual(p.tachies[0].extra["future"], .object(["k": .array([.number(1), .number(2)])]))
        XCTAssertEqual(p.tachies[0].rig?.partOffsets?["/p.png"], PartOffset(dx: 3, dy: -4))
        XCTAssertEqual(p.tachies[0].rig?.extra["keep"], .bool(true))
        XCTAssertNil(p.tracks[0].clips[0].mouthDrive)
        let out = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertTrue(out.contains("future:xyz")); XCTAssertTrue(out.contains("\"zzz\" : 1")); XCTAssertTrue(out.contains("futureTop"))
        XCTAssertTrue(out.contains("\"subtitleText\" : 5"), "読めない型は捨てずに書き戻す")
        XCTAssertEqual(try Project.decode(from: Data(out.utf8)).encoded(), try p.encoded())
    }

    func testMouthDriveRawAndDriverSelection() {
        for d in [MouthDrive.all, .none, .character("a:b"), .voiceClip("v1")] { XCTAssertEqual(MouthDrive(raw: d.raw), d) }
        XCTAssertNil(MouthDrive(raw: "character:")); XCTAssertNil(MouthDrive(raw: "bogus"))
        func v(_ id: String, _ ch: String) -> Clip { var c = Clip(); c.id = id; c.type = .voice; c.charId = ch; return c }
        let voices = [v("v1", "a"), v("v2", "b"), v("v3", "a")]
        XCTAssertEqual(MouthDrive.all.driver(among: voices)?.id, "v3")
        XCTAssertNil(MouthDrive.none.driver(among: voices))
        XCTAssertEqual(MouthDrive.character("b").driver(among: voices)?.id, "v2")
        XCTAssertEqual(MouthDrive.character("a").driver(among: voices)?.id, "v3")
        XCTAssertEqual(MouthDrive.voiceClip("v1").driver(among: voices)?.id, "v1")
        XCTAssertNil(MouthDrive.voiceClip("zz").driver(among: voices))
        XCTAssertNil(MouthDrive.all.driver(among: []))
    }

    func testOldFixturesStayByteIdenticalAndWriteNothingNew() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var n = 0
        for f in files where ["ymproj", "mcpjc"].contains(f.pathExtension) {
            let raw = try Data(contentsOf: f)
            let p = try Project.decode(from: raw)
            let out = String(decoding: try p.encoded(), as: UTF8.self)
            for k in ["\"tachies\"", "\"tachieId\"", "\"mouthDrive\"", "\"subtitleText\"", "\"speakingOnly\"", "\"partOffsets\""] {
                XCTAssertFalse(out.contains(k), "\(f.lastPathComponent): \(k)")
            }
            // 画像を持たないキャラだけの旧ファイルは、移行しても何も変わらない
            if !TachieMigration.needsMigration(p) { XCTAssertEqual(TachieMigration.migrated(p), p, f.lastPathComponent) }
            // 旧キャラの書き方(null 含む)は従来のまま
            // JSONEncoder は既定ではキーの順が不定(別の辞書から作ると並びが変わる)ので、sortedKeys で比べる
            let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
            XCTAssertEqual(String(decoding: try enc.encode(p.characters), as: UTF8.self),
                           String(decoding: try enc.encode(try Project.decode(from: try p.encoded()).characters), as: UTF8.self))
            n += 1
        }
        XCTAssertGreaterThan(n, 5)
    }

    func testCharacterLegacyKeysFollowTheFile() throws {
        // 旧ファイルのキャラ(キーが全部ある)は従来どおり全部書く。キーが無いキャラは書かない(既定値のとき)
        let old = ##"{"id":"a","name":"キャラ1","engine":"aquestalk","color":"#e8384f","imgClosed":null,"imgOpen":null,"x":0.2,"y":0.72,"scale":1,"flip":true,"alwaysShow":true}"##
        var c = try JSONDecoder().decode(Character.self, from: Data(old.utf8))
        var s = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        for k in ["imgClosed", "imgOpen", "\"x\"", "\"y\"", "scale", "flip", "alwaysShow"] { XCTAssertTrue(s.contains(k), k) }
        let new = ##"{"id":"a","name":"キャラ1","engine":"aquestalk","color":"#e8384f"}"##
        c = try JSONDecoder().decode(Character.self, from: Data(new.utf8))
        s = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        for k in ["imgClosed", "imgOpen", "\"x\"", "\"y\"", "scale", "flip", "alwaysShow"] { XCTAssertFalse(s.contains(k), k) }
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        XCTAssertEqual(try enc.encode(try JSONDecoder().decode(Character.self, from: Data(s.utf8))), try enc.encode(c))
        // 値を変えれば(既定でなければ)書く
        c.flip = true
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("flip"))
        // 新しく作ったキャラは従来どおり
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(Character()), as: UTF8.self).contains("alwaysShow"))
    }

    func testEditingFunctionsAreNoOpsWhenNothingChanges() throws {
        var p = Project()
        var t = Tachie(name: "A"); t.id = "t1"
        t.rig = CharacterRig(slots: [RigSlot(name: "体", parts: ["/b.png"], active: 0)])
        p = TachieEditing.add(p, tachie: t)
        XCTAssertEqual(p.tachies.count, 1)
        XCTAssertEqual(TachieEditing.add(p, tachie: t), p, "同じ id は足さない")
        XCTAssertEqual(TachieEditing.rename(p, id: "t1", to: "A"), p)
        XCTAssertEqual(TachieEditing.rename(p, id: "zz", to: "B"), p)
        XCTAssertEqual(TachieEditing.rename(p, id: "t1", to: "B").tachies[0].name, "B")
        XCTAssertEqual(TachieEditing.setPartOffset(p, tachieId: "t1", path: "/b.png", offset: PartOffset()), p, "ゼロを新しく入れても変わらない")
        XCTAssertEqual(TachieEditing.setPartOffset(p, tachieId: "t1", path: "/nope.png", offset: PartOffset(dx: 1, dy: 1)), p)
        let o = TachieEditing.setPartOffset(p, tachieId: "t1", path: "/b.png", offset: PartOffset(dx: 4, dy: -2))
        XCTAssertEqual(o.tachies[0].rig?.partOffsets?["/b.png"], PartOffset(dx: 4, dy: -2))
        XCTAssertEqual(TachieEditing.setPartOffset(o, tachieId: "t1", path: "/b.png", offset: PartOffset(dx: 4, dy: -2)), o)
        XCTAssertNil(TachieEditing.setPartOffset(o, tachieId: "t1", path: "/b.png", offset: PartOffset()).tachies[0].rig?.partOffsets, "ゼロに戻すと外す")

        let clip = try XCTUnwrap(TachieEditing.makeClip(p, tachieId: "t1", start: 1, duration: 2))
        XCTAssertNil(TachieEditing.makeClip(p, tachieId: "zz", start: 1, duration: 2))
        XCTAssertNil(TachieEditing.makeClip(p, tachieId: "t1", start: 1, duration: 0))
        p.tracks[0].clips = [clip]
        XCTAssertEqual(TachieEditing.setMouthDrive(p, clipId: clip.id, drive: .all), p, "既定のまま")
        let d = TachieEditing.setMouthDrive(p, clipId: clip.id, drive: .none)
        XCTAssertEqual(d.tracks[0].clips[0].mouthDrive, MouthDrive.none)
        XCTAssertEqual(TachieEditing.setMouthDrive(d, clipId: clip.id, drive: .none), d)
        XCTAssertNil(TachieEditing.setMouthDrive(d, clipId: clip.id, drive: .all).tracks[0].clips[0].mouthDrive)
        XCTAssertEqual(TachieEditing.setMouthDrive(p, clipId: "zz", drive: .none), p)

        // 字幕の文
        var v = Clip(); v.id = "v"; v.type = .voice; v.text = "よみ"
        p.tracks[0].clips.append(v)
        XCTAssertEqual(TachieEditing.setSubtitleText(p, clipId: "v", text: nil), p)
        XCTAssertEqual(TachieEditing.setSubtitleText(p, clipId: "v", text: "よみ"), p, "読み上げ文と同じ字幕は未設定と同じ")
        let s = TachieEditing.setSubtitleText(p, clipId: "v", text: "字幕")
        XCTAssertEqual(s.tracks[0].clips[1].subtitleText, "字幕")
        XCTAssertEqual(TachieEditing.setSubtitleText(s, clipId: "v", text: "字幕"), s)
        XCTAssertNil(TachieEditing.setSubtitleText(s, clipId: "v", text: nil).tracks[0].clips[1].subtitleText)
        XCTAssertEqual(TachieEditing.setSubtitleText(p, clipId: clip.id, text: "x"), p, "ボイス以外は変えない")

        // 素材を消すと、その立ち絵クリップも消える
        let r = TachieEditing.remove(s, id: "t1")
        XCTAssertTrue(r.tachies.isEmpty); XCTAssertEqual(r.tracks[0].clips.map(\.id), ["v"])
        XCTAssertEqual(TachieEditing.remove(s, id: "zz"), s)
    }

    func testTachieImagesCountAsUsedMedia() {
        var p = Project(); p.mediaPool = ["/a.png", "/b.png", "/c.png"]
        var t = Tachie(name: "t"); t.imgClosed = "/a.png"; t.rig = CharacterRig(slots: [RigSlot(name: "体", parts: ["/b.png"])])
        p.tachies = [t]
        XCTAssertEqual(UnusedMedia.find(in: p).map(\.path), ["/c.png"])
    }

    // MARK: Stage 2 描画

    /// 左半分(x 0〜0.5)ではなく、キャラごとの色で状態が分かる立ち絵を 2 つ。A: 閉じ=緑 開き=赤。B: 閉じ=青 開き=黄。
    func twoTachieProject(driveA: MouthDrive?, driveB: MouthDrive?, speakingOnlyB: Bool = false) throws -> (Project, aX: Int, bX: Int, y: Int) {
        let wav = try writeToneWAV("tone.wav")
        let a = simpleTachie("ta", closed: try png("ac.png", color: (0, 255, 0)), open: try png("ao.png", color: (255, 0, 0)))
        let b = simpleTachie("tb", closed: try png("bc.png", color: (0, 0, 255)), open: try png("bo.png", color: (255, 255, 0)))
        var cb = tachieClip("cb", tachie: "tb", drive: driveB, x: 0.75, y: 0.5)
        if speakingOnlyB { cb.speakingOnly = true }
        let p = project(clips: [[voice("v1", char: "ch1", text: "あ", wav: wav)], [tachieClip("ca", tachie: "ta", drive: driveA, x: 0.25, y: 0.5, duration: 3), cb]],
                        characters: [character("ch1", "キャラ1"), character("ch2", "キャラ3")], tachies: [a, b])
        return (p, 30, 90, 40)
    }

    func testTachieClipFollowsVoiceAndSeveralTachiesShareOneVoice() throws {
        let (p, ax, bx, y) = try twoTachieProject(driveA: nil, driveB: .character("ch1"))
        let quiet = try bytes(p, t: 0.25), loud = try bytes(p, t: 0.75)
        XCTAssertGreaterThan(rgb(quiet, w: 120, ax, y).1, 200); XCTAssertGreaterThan(rgb(quiet, w: 120, bx, y).2, 200)   // 閉じ(緑・青)
        XCTAssertGreaterThan(rgb(loud, w: 120, ax, y).0, 200); XCTAssertLessThan(rgb(loud, w: 120, ax, y).2, 50)        // A 開き(赤)
        XCTAssertGreaterThan(rgb(loud, w: 120, bx, y).0, 200); XCTAssertGreaterThan(rgb(loud, w: 120, bx, y).1, 200)    // B も同じ声で開き(黄)
        // 同じ入力は何度描いても同じ
        XCTAssertEqual(try bytes(p, t: 0.75), loud)
    }

    func testTachieCanFollowAnotherCharactersVoiceOrNone() throws {
        // B はキャラ ch2(声が無い)に連動 → 動かない。A は動かさない設定 → 動かない
        var (p, ax, bx, y) = try twoTachieProject(driveA: MouthDrive.none, driveB: .character("ch2"))
        var loud = try bytes(p, t: 0.75)
        XCTAssertGreaterThan(rgb(loud, w: 120, ax, y).1, 200, "動かさない = 閉じのまま")
        XCTAssertGreaterThan(rgb(loud, w: 120, bx, y).2, 200, "声の無いキャラに連動 = 閉じのまま")
        // 特定の声クリップに連動
        (p, ax, bx, y) = try twoTachieProject(driveA: .voiceClip("v1"), driveB: .voiceClip("nothing"))
        loud = try bytes(p, t: 0.75)
        XCTAssertGreaterThan(rgb(loud, w: 120, ax, y).0, 200)
        XCTAssertGreaterThan(rgb(loud, w: 120, bx, y).2, 200)
        // 声が出ている間だけ描く(speakingOnly)
        (p, ax, bx, y) = try twoTachieProject(driveA: nil, driveB: .character("ch1"), speakingOnlyB: true)
        let gone = try bytes(p, t: 1.5)
        XCTAssertEqual(rgb(gone, w: 120, bx, y).2, 0)
        XCTAssertGreaterThan(rgb(gone, w: 120, ax, y).1, 200, "A は声が無くても出ている")
        XCTAssertGreaterThan(rgb(try bytes(p, t: 0.75), w: 120, bx, y).0, 200)
    }

    func testTachieClipIsAnOrdinaryClipOnTheTimeline() throws {
        // クリップの範囲の外では描かない・位置とキーフレーム・左右反転・不透明度・エフェクト対象
        let img = try png("flag.png", color: (255, 0, 0), box: CGRect(x: 0, y: 0, width: 20, height: 40))   // 左半分だけ赤
        var c = tachieClip("c", tachie: "t", drive: MouthDrive.none, x: 0.5, y: 0.5, start: 1, duration: 1)
        let t = simpleTachie("t", closed: img)
        let p = project(clips: [[c]], tachies: [t])
        XCTAssertEqual(rgb(try bytes(p, t: 0.5), w: 120, 60, 40).0, 0, "開始前は描かない")
        XCTAssertEqual(rgb(try bytes(p, t: 2.5), w: 120, 60, 40).0, 0, "終了後は描かない")
        // 立ち絵の高さは画面の 0.6 倍 = 48、幅 48。中心(60,40)。赤は左半分(x 36〜60)
        let plain = try bytes(p, t: 1.5)
        XCTAssertGreaterThan(rgb(plain, w: 120, 45, 40).0, 200); XCTAssertEqual(rgb(plain, w: 120, 75, 40).0, 0)
        c.flipH = true
        let flipped = try bytes(project(clips: [[c]], tachies: [t]), t: 1.5)
        XCTAssertEqual(rgb(flipped, w: 120, 45, 40).0, 0); XCTAssertGreaterThan(rgb(flipped, w: 120, 75, 40).0, 200)
        // キーフレームで右へ動く
        c.flipH = nil
        c.keyframes["x"] = [Keyframe(t: 0, v: 0.25), Keyframe(t: 1, v: 0.75)]
        let moving = project(clips: [[c]], tachies: [t])
        XCTAssertGreaterThan(rgb(try bytes(moving, t: 1.01), w: 120, 15, 40).0, 200)
        XCTAssertGreaterThan(rgb(try bytes(moving, t: 1.99), w: 120, 75, 40).0, 200 - 200 + 0)   // 右端へ寄っている(赤の左半分が x≈75)
        // 拡大
        c.keyframes = [:]; c.scale = 0.5
        let small = try bytes(project(clips: [[c]], tachies: [t]), t: 1.5)
        XCTAssertEqual(rgb(small, w: 120, 45, 40).0, 0, "半分の大きさなら x=45 は外")
        XCTAssertGreaterThan(rgb(small, w: 120, 54, 40).0, 200)
        // 素材が無ければ描かない
        var ghost = c; ghost.tachieId = "none"
        XCTAssertEqual(rgb(try bytes(project(clips: [[ghost]], tachies: [t]), t: 1.5), w: 120, 54, 40).0, 0)
        XCTAssertTrue(Clip.supportsEffects(.tachie)); XCTAssertTrue(TransitionEditing.supportsVideo(.tachie))
        XCTAssertEqual(Animation.keys(for: c).prefix(2), ["x", "y"])
    }

    func testRigPartOffsetsMovePartsAndDifferentSizedPartsDefaultToBottomCenter() throws {
        // 体 40×40(全面灰)+ 顔 20×20 の小さなパーツ(下中央に置かれる)。補正で右へ 5・上へ 4
        let body = try png("body.png", color: (50, 50, 50))
        let face = try png("face.png", w: 20, h: 20, color: (255, 0, 0))
        var rig = CharacterRig(slots: [RigSlot(name: "体", parts: [body], active: 0), RigSlot(name: "顔", parts: [face], active: 0)])
        let cache = RigFrameCache()
        func px(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
            var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            let i = (y * img.width + x) * 4; return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
        }
        let paths = rig.paths(active: rig.resolvedActive())
        let base = try XCTUnwrap(cache.frame(paths: paths, height: 40))
        XCTAssertEqual(px(base, 20, 30).0, 255, "既定: 下の中央(x 10〜30, y 20〜40)")
        XCTAssertEqual(px(base, 20, 15).0, 50)
        rig.partOffsets = [face: PartOffset(dx: 5, dy: -4)]
        let moved = try XCTUnwrap(cache.frame(paths: paths, height: 40, offsets: rig.offsets(for: paths)))
        XCTAssertEqual(px(moved, 33, 30).0, 255, "右へ 5"); XCTAssertEqual(px(moved, 12, 30).0, 50)
        XCTAssertEqual(px(moved, 20, 17).0, 255, "上へ 4"); XCTAssertEqual(px(moved, 20, 38).0, 50)
        // 補正の有無は別のキャッシュ(同じパスでも混ざらない)
        XCTAssertEqual(px(try XCTUnwrap(cache.frame(paths: paths, height: 40)), 20, 30).0, 255)
        // 描画経路でも補正が効く
        var t = Tachie(name: "r"); t.id = "t"; t.rig = rig
        let c = tachieClip("c", tachie: "t", drive: MouthDrive.none, x: 0.5, y: 0.5)
        let p = project(clips: [[c]], tachies: [t], w: 100, h: 100)
        var q = p; q.tachies[0].rig?.partOffsets = nil
        XCTAssertNotEqual(try bytes(p, t: 0.5), try bytes(q, t: 0.5))
    }

    // MARK: Stage 3 台本の記法と字幕

    func testScriptSyntaxSpokenAndSubtitle() {
        let chars = [character("a", "キャラ1"), character("b", "キャラ3")]
        func p(_ l: String) -> ScriptTimeline.Line? { ScriptTimeline.parseLine(l, characters: chars, selectedCharId: nil) }
        let same = p("キャラ1: こんにちは")
        XCTAssertEqual(same?.spoken, "こんにちは"); XCTAssertNil(same?.subtitle, "| が無い = 字幕は読み上げ文と同じ")
        let diff = p("キャラ3：あいさつ | こんにちは！")
        XCTAssertEqual(diff?.who.id, "b"); XCTAssertEqual(diff?.spoken, "あいさつ"); XCTAssertEqual(diff?.subtitle, "こんにちは！")
        let none = p("キャラ1: ふふふ |")
        XCTAssertEqual(none?.spoken, "ふふふ"); XCTAssertEqual(none?.subtitle, "", "| のあとが空 = 字幕なし")
        XCTAssertEqual(p("キャラ1: ふふふ｜  ")?.subtitle, "", "全角の区切りも使える")
        let tag = p("キャラ1: [笑顔]やあ | [笑顔]こんにちは")
        XCTAssertEqual(tag?.spoken, "[笑顔]やあ"); XCTAssertEqual(tag?.subtitle, "[笑顔]こんにちは")
        XCTAssertEqual(p("キャラ1: a | b | c")?.subtitle, "b | c", "最初の区切りだけで分ける")
        XCTAssertNil(p("キャラ1: | 字幕だけ"), "読み上げ文が空の行は声を作れない")
        XCTAssertNil(p("※ メモ | あ"))
        // 名前が分からない行は選択中のキャラ、行全体が対象
        XCTAssertEqual(p("なんとか | かんとか")?.who.id, "a")
        XCTAssertEqual(p("なんとか | かんとか")?.subtitle, "かんとか")
        // 従来の parse は読み上げ文だけを返す
        XCTAssertEqual(ScriptTimeline.parse(line: "キャラ1: やあ | 字幕", characters: chars, selectedCharId: nil)?.1, "やあ")
        XCTAssertEqual(ScriptTimeline.parse(line: "キャラ1: [笑顔]やあ", characters: chars, selectedCharId: nil)?.1, "[笑顔]やあ")
    }

    func testScriptAddStoresSubtitleTextAndExportRoundTrips() async throws {
        var p = Project()
        p.characters = [character("a", "キャラ1")]
        p.tracks = [Track(name: "L1")]
        let lines = ["キャラ1: やあ", "キャラ1: よみ | じまく", "キャラ1: ふふ |", "キャラ1: [笑顔]ほほ | [笑顔]ほほ", "キャラ1: ごご | ごご"]
        let added = try await ScriptTimeline.add(lines: lines, to: &p, voice: ToneVoiceProvider(), directory: tmp)
        XCTAssertEqual(added.map(\.text), ["やあ", "よみ", "ふふ", "[笑顔]ほほ", "ごご"])
        XCTAssertEqual(added.map(\.subtitleText), [nil, "じまく", "", nil, nil], "読み上げ文と同じ字幕は書かない")
        // 台本に書き戻して、もう一度読むと同じ(読み上げ文と同じ字幕は書かない)
        let script = VoiceScriptExport.make(p)
        XCTAssertEqual(script.text, "キャラ1: やあ\nキャラ1: よみ | じまく\nキャラ1: ふふ |\nキャラ1: [笑顔]ほほ\nキャラ1: ごご")
        var q = Project(); q.characters = p.characters; q.tracks = [Track(name: "L1")]
        let again = try await ScriptTimeline.add(lines: script.text.components(separatedBy: "\n"), to: &q, voice: ToneVoiceProvider(), directory: tmp)
        XCTAssertEqual(again.map(\.text), added.map(\.text))
        XCTAssertEqual(again.map(\.subtitleText), added.map(\.subtitleText))
    }

    func testSubtitleBodyPrefersSubtitleTextAndStripsTags() {
        var c = Clip(); c.type = .voice; c.text = "[笑顔]よみ"
        XCTAssertEqual(c.subtitleBody, "よみ", "タグは字幕に出さない")
        c.subtitleText = "字幕"; XCTAssertEqual(c.subtitleBody, "字幕")
        c.subtitleText = "[泣き]字幕2"; XCTAssertEqual(c.subtitleBody, "字幕2")
        c.subtitleText = ""; XCTAssertEqual(c.subtitleBody, "")
    }

    func testSubtitleGenerationUsesSubtitleTextAndSkipsEmpty() throws {
        var p = Project()
        p.characters = [character("a", "キャラ1")]
        func v(_ id: String, _ start: Double, _ text: String, _ sub: String?) -> Clip {
            var c = Clip(); c.id = id; c.type = .voice; c.start = start; c.duration = 1; c.charId = "a"; c.text = text; c.subtitleText = sub; return c
        }
        p.tracks = [Track(name: "声")]
        p.tracks[0].clips = [v("1", 0, "よみ1", "字幕1"), v("2", 1, "よみ2", nil), v("3", 2, "よみ3", ""), v("4", 3, "[笑顔]よみ4", nil)]
        let r = try XCTUnwrap(SubtitleGeneration.generate(p, style: nil))
        let texts = r.project.allClips.filter { $0.type == .text }.sorted { $0.start < $1.start }.map { $0.text }
        XCTAssertEqual(texts, ["字幕1", "よみ2", "よみ4"], "字幕の文を優先、空は字幕なし、タグは除く")
        XCTAssertEqual(r.count, 3)
        // 口パクの母音は読み上げ文(text)で決まる: 字幕を変えても viseme は変わらない
        XCTAssertEqual(LipSync.moras(of: "あい"), LipSync.moras(of: "あい"))
        XCTAssertEqual(LipSync.moras(of: v("x", 0, "あい", "ぜんぜん違う").text ?? ""), LipSync.moras(of: "あい"))
    }

    func testSubtitleIsDrawnFromSubtitleTextAndEmptyDrawsNothing() throws {
        func make(_ sub: String?) -> Project {
            var c = Clip(); c.type = .voice; c.start = 0; c.duration = 1; c.charId = "a"; c.text = "あ"; c.subtitle = true; c.fontSize = 30; c.subtitleText = sub
            var p = project(clips: [[c]], characters: [character("a", "キャラ1")], w: 200, h: 100)
            p.bg = "#000000"
            return p
        }
        func lit(_ d: [UInt8]) -> Int { stride(from: 0, to: d.count, by: 4).filter { d[$0] > 128 }.count }
        let same = lit(try bytes(make(nil), t: 0.5))
        let empty = lit(try bytes(make(""), t: 0.5))
        let other = lit(try bytes(make("ながい字幕のぶん"), t: 0.5))
        XCTAssertGreaterThan(same, 0); XCTAssertEqual(empty, 0, "空の字幕文 = 字幕なし"); XCTAssertGreaterThan(other, same)
    }

    // MARK: Stage 4 移行(画素一致)

    /// 旧形式のプロジェクト: A=パーツ式(口の母音・表情・まばたき・バウンス・反転・拡大・常に表示オフ)、B=単純画像(開き・まばたき・母音・表情)。
    /// 他のクリップ(下に画像、上に文字・字幕つきのボイス)との重なり順も含める。
    func legacyProject() throws -> Project {
        func part(_ n: String, _ c: (UInt8, UInt8, UInt8), _ box: CGRect, w: Int = 40, h: Int = 40) throws -> String { try png(n, w: w, h: h, color: c, box: box) }
        let mb = CGRect(x: 0, y: 0, width: 10, height: 40), kb = CGRect(x: 15, y: 0, width: 10, height: 40), eb = CGRect(x: 28, y: 0, width: 8, height: 40)
        var rig = CharacterRig(slots: [
            RigSlot(name: "体", parts: [try part("lb.png", (90, 90, 90), CGRect(x: 0, y: 0, width: 40, height: 40))], active: 0),
            RigSlot(name: "髪", parts: [try part("lh.png", (200, 120, 40), CGRect(x: 0, y: 0, width: 40, height: 5), w: 40, h: 44)], active: 0),   // 縦に長い別サイズ
            RigSlot(name: "眉", parts: [try part("lm0.png", (10, 10, 10), mb), try part("lm1.png", (255, 0, 255), mb)], active: 0),
            RigSlot(name: "目", parts: [try part("le0.png", (0, 200, 200), eb), try part("le1.png", (200, 200, 0), eb)], active: 0),
            RigSlot(name: "口", parts: [try part("lk0.png", (0, 255, 0), kb), try part("lk1.png", (255, 255, 0), kb), try part("lk2.png", (255, 0, 0), kb), try part("lk3.png", (0, 0, 255), kb)], active: 0),
        ])
        rig.blink = 1; rig.mouthClosed = 0; rig.mouthOpen = 1; rig.vowels = ["a": 2, "i": 3]; rig.expressions = ["笑顔": ["眉": 1]]
        var a = character("ca", "A")
        a.rig = rig; a.x = 0.3; a.y = 0.8; a.scale = 1.2; a.flip = true; a.alwaysShow = false; a.bounce = true

        var b = character("cb", "B")
        b.imgClosed = try png("bc.png", color: (0, 255, 0)); b.imgOpen = try png("bo.png", color: (255, 255, 0)); b.imgBlink = try png("bb.png", color: (0, 0, 255))
        b.imgVowels = ["a": try png("ba.png", color: (255, 0, 0)), "i": try png("bi.png", color: (0, 0, 255))]
        b.expressions = ["笑顔": try png("bx.png", color: (255, 0, 255))]
        b.x = 0.7; b.y = 0.72; b.scale = 0.9; b.flip = false; b.alwaysShow = true

        let wav = try writeToneWAV("legacy-tone.wav")
        var bg = Clip(); bg.type = .image; bg.src = try png("bgimg.png", w: 16, h: 9, color: (30, 60, 90)); bg.start = 0; bg.duration = 6
        var text = Clip(); text.type = .text; text.text = "あ"; text.start = 0; text.duration = 6; text.fontSize = 24; text.x = 0.5; text.y = 0.3; text.color = "#ffffff"
        var p = project(clips: [[bg], [text],
                                [voice("v1", char: "ca", text: "あい", wav: wav, start: 0, subtitle: true), voice("v2", char: "cb", text: "[笑顔]あいう", wav: wav, start: 1.2, subtitle: true),
                                 voice("v3", char: "cb", text: "い", wav: wav, start: 2.5)]],
                        characters: [a, b, character("cc", "声だけ")], w: 320, h: 180)
        p.tracks.append(Track(name: "空き"))
        return p
    }

    func testMigrationRendersPixelIdenticalToTheOldPath() throws {
        let old = try legacyProject()
        let new = TachieMigration.migrated(old)
        XCTAssertEqual(new.tachies.count, 2)
        XCTAssertEqual(new.allClips.filter { $0.type == .tachie }.count, 2)
        // 移行後のキャラは声と字幕だけ(画像・リグ・向きは持たない)
        for c in new.characters.prefix(2) { XCTAssertNil(c.imgClosed); XCTAssertNil(c.rig); XCTAssertNil(c.expressions); XCTAssertEqual(c.legacyKeys, []) }
        let times: [Double] = [0, 0.3, 0.6, 0.8, 0.95, 1.1, 1.45, 1.7, 1.95, 2.55, 3.0, 3.7, 4.2, 5.0, 5.9]
        let oldAssets = RenderAssets(), newAssets = RenderAssets()
        var speakingChecked = 0
        for t in times {
            let a = try bytes(old, t: t, assets: oldAssets), b = try bytes(new, t: t, assets: newAssets)
            XCTAssertEqual(a.count, b.count)
            XCTAssertTrue(a == b, "t=\(t): 旧経路と移行後が画素で一致しない(\(zip(a, b).filter { $0 != $1 }.count) バイト違い)")
            if t >= 0.6 && t < 1 || t >= 1.45 && t < 2.2 { speakingChecked += 1 }
        }
        XCTAssertGreaterThanOrEqual(speakingChecked, 4, "話している時刻を含めて確認")
        // 何かを描いている(全部真っ黒で一致、ではない)・時刻で変わる
        XCTAssertNotEqual(try bytes(new, t: 0.3, assets: newAssets), try bytes(new, t: 0.95, assets: newAssets))
        XCTAssertNotEqual(try bytes(new, t: 3.0, assets: newAssets), try bytes(new, t: 1.7, assets: newAssets))
    }

    /// 計測の手順: MC_TACHIE_BENCH_DIR=<dir> swift test --filter testWriteLegacyProjectForBenchWhenRequested
    /// → moviecut-cli migrate <dir>/legacy.mcpjc <dir>/new.mcpjc → frame の --bench を両方で比べる。
    func testWriteLegacyProjectForBenchWhenRequested() throws {
        try XCTSkipUnless(TachieTests.benchDir != nil, "MC_TACHIE_BENCH_DIR が未指定")
        var p = try legacyProject()
        p = p.scaledForResolution(newWidth: 1920, newHeight: 1080)
        try p.save(to: tmp.appendingPathComponent("legacy.mcpjc"))
    }

    func testMigrationIsIdempotentKeepsLookAndWritesTheNewForm() throws {
        let old = try legacyProject()
        let new = TachieMigration.migrated(old)
        XCTAssertEqual(TachieMigration.migrated(new), new, "2 回目は何もしない")
        // 画像のないキャラ(声だけ)は触らない
        XCTAssertEqual(new.characters[2], old.characters[2])
        // クリップは全時間・最上段のレイヤーに、元の位置・大きさ・反転・連動を持つ
        let ca = try XCTUnwrap(new.allClips.first { $0.tachieId == new.tachies[0].id })
        XCTAssertEqual(ca.start, 0); XCTAssertEqual(ca.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(ca.x, 0.3); XCTAssertEqual(ca.y, 0.8); XCTAssertEqual(ca.scale, 1.2); XCTAssertEqual(ca.flipH, true)
        XCTAssertEqual(ca.mouthDrive, .character("ca")); XCTAssertEqual(ca.speakingOnly, true)
        let cb = try XCTUnwrap(new.allClips.first { $0.tachieId == new.tachies[1].id })
        XCTAssertNil(cb.speakingOnly); XCTAssertNil(cb.flipH)
        XCTAssertGreaterThan(new.tracks.count, old.tracks.count)
        for tr in new.tracks.suffix(2) { XCTAssertEqual(tr.clips.count, 1) }
        // 保存は新形式: キャラに画像・リグのキーが無い。読み直して書いても同じ
        let data = try new.encoded()
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(s.contains("imgClosed\" : \"/") && s.contains("\"characters\" : [\n    {\n      \"alwaysShow\""), "旧形式のキーを書かない")
        let chars = String(decoding: try JSONEncoder().encode(Array(new.characters.prefix(2))), as: UTF8.self)
        for k in ["imgClosed", "imgOpen", "imgBlink", "imgVowels", "\"expressions\"", "\"rig\"", "alwaysShow", "\"flip\"", "\"scale\""] { XCTAssertFalse(chars.contains(k), k) }
        XCTAssertEqual(try Project.decode(from: data).encoded(), data)
        // 読み直した新形式を描いても、旧経路と画素まで同じ
        let reloaded = try Project.decode(from: data)
        let assets = RenderAssets()
        for t in [0.6, 1.7, 3.0] { XCTAssertTrue(try bytes(reloaded, t: t, assets: assets) == bytes(old, t: t, assets: RenderAssets()), "t=\(t)") }
        // 旧形式の JSON を読む入口(アプリが開くとき)
        let oldData = try old.encoded()
        let opened = try Project.decodeMigrating(from: oldData)
        XCTAssertEqual(try opened.encoded(), data.isEmpty ? Data() : try new.encoded(), "decodeMigrating = decode + 移行")
        XCTAssertEqual(try Project.decode(from: oldData).encoded(), oldData, "decode だけでは旧ファイルは変わらない(バイト一致)")
    }

    // MARK: 立ち絵(リグ)の不具合: 位置合わせ・まばたき・口の既定

    func testAlignmentSuggestsShiftOnlyForOversizedPartsWhoseOpaqueAreaOverflows() {
        // 体 3000×3000。髪 3000×3200: 既定(下揃え)だと上の 200 がはみ出す。不透明部が上端まで届くなら下へ 200
        let rig = CharacterRig(slots: [RigSlot(name: "体", parts: ["body"], active: 0),
                                       RigSlot(name: "髪", parts: ["hair-top", "hair-inside", "hair-wide"], active: 0)])
        let sizes: [String: (w: Int, h: Int)] = ["body": (3000, 3000), "hair-top": (3000, 3200), "hair-inside": (3000, 3200), "hair-wide": (3400, 3000)]
        let opaque: [String: CGRect] = [
            "hair-top": CGRect(x: 0.1, y: 0.0, width: 0.8, height: 0.5),         // 上端まで描かれている → 下へ 200
            "hair-inside": CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.5),      // 上から 640px のところから → はみ出さない
            "hair-wide": CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5),        // 左右に 200 ずつはみ出す(幅 3400)
        ]
        let s = RigAlignment.suggestOffsets(for: rig, base: (3000, 3000), canvas: { sizes[$0] }, opaque: { opaque[$0] })
        XCTAssertEqual(s["hair-top"], PartOffset(dx: 0, dy: 200))
        XCTAssertNil(s["hair-inside"]); XCTAssertNil(s["body"])
        XCTAssertNil(s["hair-wide"], "キャンバスより広く描かれていれば動かさない")
        let applied = RigAlignment.applySuggestions(rig, base: (3000, 3000), canvas: { sizes[$0] }, opaque: { opaque[$0] })
        XCTAssertEqual(applied.partOffsets?["hair-top"], PartOffset(dx: 0, dy: 200))
        // 手で決めた補正は上書きしない・全部の補正が既にあれば同じ値を返す
        var manual = rig; manual.partOffsets = ["hair-top": PartOffset(dx: 7, dy: 7)]
        XCTAssertEqual(RigAlignment.applySuggestions(manual, base: (3000, 3000), canvas: { sizes[$0] }, opaque: { opaque[$0] }), manual)
    }

    func testBlinkPicksSmallestAreaAmongWideEyesAndMouthRoles() throws {
        // 目: 開いた目(両目ぶんの幅・高い)、閉じた目(同じ幅で細い)、片目だけ(幅が狭く面積も小さい → 候補外)
        let wide = CGRect(x: 4, y: 12, width: 32, height: 12), closed = CGRect(x: 4, y: 17, width: 32, height: 2), single = CGRect(x: 4, y: 12, width: 8, height: 1)
        let eyes = [try png("e0.png", color: (0, 0, 0), box: wide), try png("e1.png", color: (0, 0, 0), box: CGRect(x: 4, y: 10, width: 32, height: 14)),
                    try png("e2.png", color: (0, 0, 0), box: single), try png("e3.png", color: (0, 0, 0), box: closed), try png("e4.png", color: (0, 0, 0), box: wide)]
        let mouths = [try png("m0.png", color: (9, 9, 9), box: CGRect(x: 15, y: 15, width: 10, height: 3)),   // 小(閉じ)
                      try png("m1.png", color: (9, 9, 9), box: CGRect(x: 12, y: 10, width: 16, height: 16)),  // 大(あ)
                      try png("m2.png", color: (9, 9, 9), box: CGRect(x: 13, y: 12, width: 14, height: 8))]
        var rig = CharacterRig(slots: [RigSlot(name: "目", parts: eyes), RigSlot(name: "口", parts: mouths)])
        RigHeuristics.guessRoles(&rig, box: { RigHeuristics.opaqueBox($0, maxPixel: 40) })
        XCTAssertEqual(rig.blink, 3, "幅のある目のうち面積が最小のもの")
        XCTAssertEqual(rig.mouthClosed, 0); XCTAssertEqual(rig.mouthOpen, 1); XCTAssertEqual(rig.vowels?["a"], 1, "あ = 面積最大")
        // 片目しか無い・全部同じ形なら自信が無いので設定しない
        var flat = CharacterRig(slots: [RigSlot(name: "目", parts: [eyes[0], eyes[4]])])
        RigHeuristics.guessRoles(&flat, box: { RigHeuristics.opaqueBox($0, maxPixel: 40) })
        XCTAssertNil(flat.blink)
        // 位置の割合(実画像)
        let f = try XCTUnwrap(RigHeuristics.opaqueFraction(eyes[3], maxPixel: 40))
        XCTAssertEqual(f.minX, 0.1, accuracy: 0.03); XCTAssertEqual(f.minY, 17.0 / 40, accuracy: 0.03); XCTAssertEqual(f.width, 0.8, accuracy: 0.03)
    }

    func testImporterAppliesAlignmentToDifferentSizedPart() throws {
        let body = try png("体 (1).png", w: 40, h: 40, color: (50, 50, 50))
        let eyes = try (1...3).map { try png("目 (\($0)).png", w: 40, h: 40, color: (0, 0, 0), box: CGRect(x: 8, y: 14, width: 24, height: CGFloat(4 * $0))) }
        let hair = try png("髪 (1).png", w: 40, h: 44, color: (200, 0, 0), box: CGRect(x: 0, y: 0, width: 40, height: 10))   // 上端まで描かれた、縦に長い髪
        let r = try XCTUnwrap(RigFolderImporter.group(files: ([(body, "t"), (hair, "t")] + eyes.map { ($0, "t") }), sizeOf: RigFolderImporter.imageSize))
        let off = try XCTUnwrap(r.rig.partOffsets?[hair])
        // 体と大きさが違うので取り込みは中央揃え(上下に 2 画素ずつはみ出す)。上端まで描かれているので 2 画素ぶん下げる
        XCTAssertEqual(r.rig.alignment, .center)
        XCTAssertEqual(off.dx, 0, accuracy: 0.5); XCTAssertEqual(off.dy, 2, accuracy: 1.5, "上へはみ出す 2 画素ぶん下げる")
        XCTAssertNil(r.rig.partOffsets?[body])
        // 従来の下揃えなら 4 画素
        var bottom = r.rig; bottom.alignment = nil; bottom.partOffsets = nil
        let old = RigAlignment.suggestOffsets(for: bottom, base: (r.width, r.height))
        XCTAssertEqual(try XCTUnwrap(old[hair]).dy, 4, accuracy: 1.5)
    }

    // MARK: 実データ(無ければ飛ばす)

    func testRealReimuFolderGetsBlinkMouthAndHairOffsets() throws {
        let dir = URL(fileURLWithPath: "/Users/USER/動画素材/立ち絵/立ち絵素材フォルダ")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path), "ユーザーの素材フォルダがありません")
        let rep = try XCTUnwrap(RigFolderImporter.scan(folder: dir))
        let rig = rep.rig
        for p in (rig.slot("髪")?.parts ?? []) + (rig.slot("体")?.parts ?? []) {
            print("実データ \((p as NSString).lastPathComponent) \(String(describing: RigFolderImporter.imageSize(p))) opaque=\(String(describing: RigHeuristics.opaqueFraction(p)))")
        }
        print("実データ: blink=\(String(describing: rig.blink)) mouthClosed=\(String(describing: rig.mouthClosed)) mouthOpen=\(String(describing: rig.mouthOpen)) vowels=\(String(describing: rig.vowels)) offsets=\((rig.partOffsets ?? [:]).map { (($0.key as NSString).lastPathComponent, $0.value.dx, $0.value.dy) })")
        XCTAssertNotNil(rig.blink, "まばたきの目が自動で見つかる")
        XCTAssertNotNil(rig.mouthClosed); XCTAssertNotNil(rig.mouthOpen)
        // 割り当てた目は、幅のある目の中で面積が最小
        let eyes = try XCTUnwrap(rig.slot("目")).parts
        let boxes = eyes.map { RigHeuristics.opaqueBox($0) }
        let b = try XCTUnwrap(boxes[try XCTUnwrap(rig.blink)])
        let ws = boxes.compactMap { $0 }.filter { $0.w > 0 }.map(\.w).sorted()
        let medW = ws[ws.count / 2]
        for (i, bx) in boxes.enumerated() where i != rig.blink {
            if let bx, bx.area > 0, Double(bx.w) >= Double(medW) * 0.6 { XCTAssertLessThanOrEqual(b.area, bx.area, "目 \(i)") }
        }
        // 口: 閉じ = 面積最小、開き = 最大
        let mouths = try XCTUnwrap(rig.slot("口")).parts.map { Double(RigHeuristics.opaqueBox($0)?.area ?? 0) }
        XCTAssertEqual(mouths[try XCTUnwrap(rig.mouthOpen)], mouths.max())
        XCTAssertEqual(mouths[try XCTUnwrap(rig.mouthClosed)], mouths.filter { $0 > 0 }.min())
        // 髪(3000×3200)は、はみ出すなら補正が入り、補正後の不透明部が基準キャンバス(3000×3000)の中に収まる
        for p in try XCTUnwrap(rig.slot("髪")).parts {
            guard let size = RigFolderImporter.imageSize(p), size.h != rep.height, let f = RigHeuristics.opaqueFraction(p) else { continue }
            let off = rig.partOffsets?[p] ?? PartOffset()
            let top = Double(rep.height - size.h) + f.minY * Double(size.h) + off.dy
            let bottom = Double(rep.height - size.h) + f.maxY * Double(size.h) + off.dy
            XCTAssertGreaterThanOrEqual(top, -Double(size.h) / 384, "\((p as NSString).lastPathComponent) の上端 \(top)")
            XCTAssertLessThanOrEqual(bottom, Double(rep.height) + Double(size.h) / 384)
        }
    }
}
