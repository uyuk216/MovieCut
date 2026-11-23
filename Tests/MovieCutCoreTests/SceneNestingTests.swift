import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// シーン／ネスト(W3-01): 定義と参照の分離、描画・音声が直接置いた場合と一致すること、時刻の窓と尺の切り取り、
/// 循環・深さの防止、削除ポリシー(参照中は削除不可)、シーン無しプロジェクトの完全互換(バイト一致)。
final class SceneNestingTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scene-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: 共通(CompoundTests と同じ流儀)

    struct Px { let w: Int; var d: [UInt8] }
    func pixels(_ img: CGImage) -> Px {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Px(w: img.width, d: d)
    }
    func solidPNG(_ name: String, r: CGFloat, g: CGFloat, b: CGFloat, size: Int = 80) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(c.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }
    func image(_ id: String, _ path: String, start: Double, duration: Double, x: Double = 0.5, y: Double = 0.5, scale: Double = 1) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.src = path; c.start = start; c.duration = duration
        c.x = x; c.y = y; c.scale = scale
        return c
    }
    func layer(_ name: String, _ clips: [Clip]) -> Track { var t = Track(name: name); t.clips = clips; return t }
    func render(_ p: Project, t: Double) throws -> Px { pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t))) }
    func maxDiff(_ a: Px, _ b: Px) -> Int {
        XCTAssertEqual(a.d.count, b.d.count)
        var m = 0
        for i in 0..<min(a.d.count, b.d.count) { m = max(m, abs(Int(a.d[i]) - Int(b.d[i]))) }
        return m
    }
    func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]; return e }

    /// 赤い画像 1 枚(0〜3 秒)を持つシーン「導入」を定義したプロジェクトと、直接置き版。
    func projectWithScene() throws -> (withScene: Project, direct: Project, sceneId: String) {
        let red = try solidPNG("red.png", r: 1, g: 0, b: 0)
        var scene = SceneDefinition(); scene.name = "導入"
        scene.tracks = [layer("中身", [image("in1", red, start: 0, duration: 3, x: 0.4, y: 0.5, scale: 0.6)])]
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#202020"
        p.scenes = [scene]
        p.tracks = [layer("メイン", [])]
        let placed = try XCTUnwrap(SceneEditing.place(in: p, sceneId: scene.id, host: .main, trackIndex: 0, at: 1))
        var d = Project(); d.width = 200; d.height = 200; d.bg = "#202020"
        d.tracks = [layer("メイン", [image("in1", red, start: 1, duration: 3, x: 0.4, y: 0.5, scale: 0.6)])]
        return (placed.project, d, scene.id)
    }

    // MARK: 後方互換(シーン無しは完全一致)

    func testProjectWithoutScenesWritesNoScenesKeyAndRoundTripsByteIdentical() throws {
        var p = Project(); p.width = 320; p.height = 240
        p.tracks = [layer("A", [image("c1", "/tmp/x.png", start: 0, duration: 2)])]
        let data = try encoder().encode(p)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("\"scenes\""), "シーン無しは scenes キーを書かない")
        let clipText = String(data: try encoder().encode(p.tracks[0].clips[0]), encoding: .utf8)!
        XCTAssertFalse(clipText.contains("\"sceneId\""), "通常クリップは sceneId を書かない")
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back, p)
        XCTAssertEqual(try encoder().encode(back), data, "読み直して書いても同じバイト列")
    }

    func testLegacyJSONWithoutScenesDecodesAndReencodesIdentically() throws {
        // シーン導入前の形式(scenes キー無し)を、手書き JSON で読む
        let legacy = ##"{"formatVersion":1,"width":200,"height":200,"fps":60,"bg":"#000000","codec":"h264","voicevoxUrl":"http://127.0.0.1:50021","aquestalkCommand":"x","characters":[],"tracks":[{"id":"t1","name":"A","clips":[{"id":"c1","type":"text","start":0,"duration":1,"offset":0,"text":"あ"}]}]}"##
        let p = try JSONDecoder().decode(Project.self, from: Data(legacy.utf8))
        XCTAssertTrue(p.scenes.isEmpty)
        let out = String(data: try encoder().encode(p), encoding: .utf8)!
        XCTAssertFalse(out.contains("\"scenes\""))
    }

    func testSceneProjectRoundTripsThroughJSON() throws {
        let (p, _, _) = try projectWithScene()
        let data = try encoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back, p)
        XCTAssertEqual(try encoder().encode(back), data, "シーンありでも往復でバイト列が変わらない")
        XCTAssertEqual(back.scenes.count, 1)
        XCTAssertEqual(back.allClips.first?.type, .scene)
        XCTAssertEqual(back.allClips.first?.sceneId, back.scenes[0].id)
    }

    // MARK: 定義・一覧の編集

    func testCreateRenameDuplicateDeleteBasics() throws {
        var p = Project()
        XCTAssertNil(SceneEditing.create(in: p, name: "  "), "空の名前は作らない")
        let made = try XCTUnwrap(SceneEditing.create(in: p, name: "OP"))
        p = made.project
        XCTAssertEqual(p.scenes.count, 1)
        XCTAssertFalse(p.scenes[0].tracks.isEmpty, "新規シーンは編集できるレイヤーを持つ")
        XCTAssertEqual(SceneEditing.duration(of: p.scenes[0]), 0, "空のシーンの尺は 0")
        XCTAssertNil(SceneEditing.place(in: p, sceneId: made.sceneId, host: .main, trackIndex: 0, at: 0), "空のシーンは置けない")
        let renamed = try XCTUnwrap(SceneEditing.rename(in: p, sceneId: made.sceneId, to: "本編"))
        XCTAssertEqual(renamed.scenes[0].name, "本編")
        XCTAssertNil(SceneEditing.rename(in: p, sceneId: made.sceneId, to: "OP"), "同じ名前は nil")
        let dup = try XCTUnwrap(SceneEditing.duplicate(in: renamed, sceneId: made.sceneId))
        XCTAssertEqual(dup.project.scenes.count, 2)
        XCTAssertNotEqual(dup.sceneId, made.sceneId)
        XCTAssertEqual(dup.project.scenes[1].name, "本編 のコピー")
        let deleted = try XCTUnwrap(SceneEditing.delete(in: dup.project, sceneId: dup.sceneId))
        XCTAssertEqual(deleted.scenes.count, 1)
    }

    func testDuplicateGivesInnerClipsFreshIds() throws {
        let (_, _, _) = try projectWithScene() // 流儀の確認だけ(下で自前のを使う)
        let red = try solidPNG("r2.png", r: 1, g: 0, b: 0)
        var scene = SceneDefinition(); scene.name = "S"
        scene.tracks = [layer("L", [image("orig", red, start: 0, duration: 1)])]
        var p = Project(); p.scenes = [scene]
        let dup = try XCTUnwrap(SceneEditing.duplicate(in: p, sceneId: scene.id))
        let copied = try XCTUnwrap(dup.project.scene(withId: dup.sceneId))
        XCTAssertEqual(copied.tracks[0].clips[0].id != "orig", true, "中身のクリップ id は振り直す")
        XCTAssertEqual(copied.tracks[0].clips[0].src, red, "中身そのものは同じ")
    }

    /// 削除ポリシー: 参照されているシーンは削除できない(メインからも、他のシーンからも)。
    func testDeleteIsRefusedWhileReferenced() throws {
        let (p, _, sid) = try projectWithScene()
        XCTAssertEqual(SceneEditing.referenceCount(in: p, sceneId: sid), 1)
        XCTAssertNil(SceneEditing.delete(in: p, sceneId: sid), "メインから参照中は削除不可")
        // 参照クリップを消せば削除できる
        var q = p; q.tracks[0].clips = []
        XCTAssertNotNil(SceneEditing.delete(in: q, sceneId: sid))
        // 他のシーンの中からの参照でも削除不可
        var host = SceneDefinition(); host.name = "ホスト"
        host.tracks = [layer("L", [])]
        var p2 = p; p2.scenes.append(host)
        let inner = try XCTUnwrap(SceneEditing.place(in: p2, sceneId: sid, host: .scene(host.id), trackIndex: 0, at: 0))
        XCTAssertNil(SceneEditing.delete(in: inner.project, sceneId: sid), "シーン内から参照中も削除不可")
    }

    // MARK: 描画

    /// シーンを置いた描画は、中身を直接置いた描画と画素一致する(再利用の意味論)。
    func testSceneRenderingMatchesDirectPlacementPixelForPixel() throws {
        let (p, direct, _) = try projectWithScene()
        for t in [1.0, 1.5, 2.9, 3.9] {
            XCTAssertEqual(maxDiff(try render(p, t: t), try render(direct, t: t)), 0, "t=\(t)")
        }
        // クリップの外(開始前)は背景だけ
        XCTAssertEqual(maxDiff(try render(p, t: 0.5), try render(direct, t: 0.5)), 0)
    }

    /// 同じシーンを 2 箇所に置くと、両方に同じ内容が出る(定義を直せば両方変わる)。
    func testSameScenePlacedTwiceRendersInBothPlaces() throws {
        let (p, _, sid) = try projectWithScene()
        let again = try XCTUnwrap(SceneEditing.place(in: p, sceneId: sid, host: .main, trackIndex: 0, at: 5))
        let atFirst = try render(again.project, t: 1.5)
        let atSecond = try render(again.project, t: 5.5)
        XCTAssertEqual(maxDiff(atFirst, atSecond), 0, "同じシーンは同じ絵を出す")
    }

    /// 尺の扱い: クリップの duration をシーン尺より短くすると、超えた分は切り取られる。
    func testClipDurationClipsSceneContent() throws {
        let (p, direct, _) = try projectWithScene()
        var q = p
        q.tracks[0].clips[0].duration = 1 // シーン尺 3 のうち 1 秒だけ
        // t=2.5(シーン内 1.5 秒)は、クリップが終わっているので背景のみ = 直接版の「何も無い」絵
        var empty = direct; empty.tracks[0].clips = []
        XCTAssertEqual(maxDiff(try render(q, t: 2.5), try render(empty, t: 2.5)), 0)
        // t=1.5(シーン内 0.5 秒)は中身が見える
        XCTAssertEqual(maxDiff(try render(q, t: 1.5), try render(direct, t: 1.5)), 0)
    }

    /// offset はシーン内時刻の窓の頭: 窓をずらすと、その分だけ進んだ内容が見える。
    func testOffsetShiftsTheSceneWindow() throws {
        let blue = try solidPNG("blue.png", r: 0, g: 0, b: 1)
        let red = try solidPNG("red2.png", r: 1, g: 0, b: 0)
        var scene = SceneDefinition(); scene.name = "切替"
        scene.tracks = [layer("L", [image("r", red, start: 0, duration: 2), image("b", blue, start: 2, duration: 2)])]
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#202020"; p.scenes = [scene]; p.tracks = [layer("M", [])]
        var placed = try XCTUnwrap(SceneEditing.place(in: p, sceneId: scene.id, host: .main, trackIndex: 0, at: 0)).project
        placed.tracks[0].clips[0].offset = 2 // 窓の頭を 2 秒へ(青から始まる)
        placed.tracks[0].clips[0].duration = 2
        var expect = Project(); expect.width = 200; expect.height = 200; expect.bg = "#202020"
        expect.tracks = [layer("M", [image("b", blue, start: 0, duration: 2)])]
        XCTAssertEqual(maxDiff(try render(placed, t: 0.5), try render(expect, t: 0.5)), 0)
    }

    /// シーンクリップ自身の位置・拡大も効く(中身を 1 枚として扱う)。
    func testSceneClipTransformApplies() throws {
        let (p, direct, _) = try projectWithScene()
        var moved = p; moved.tracks[0].clips[0].x = 0.9; moved.tracks[0].clips[0].scale = 0.4
        XCTAssertGreaterThan(maxDiff(try render(moved, t: 1.5), try render(direct, t: 1.5)), 0, "動かすと画素が変わる")
    }

    /// 参照先が無いシーンクリップは黙って何も描かない(壊れた参照で落ちない)。
    func testDanglingSceneReferenceDrawsNothing() throws {
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#202020"; p.tracks = [layer("M", [])]
        var c = Clip(); c.type = .scene; c.sceneId = "missing"; c.start = 0; c.duration = 2
        p.tracks[0].clips = [c]
        var empty = p; empty.tracks[0].clips = []
        XCTAssertEqual(maxDiff(try render(p, t: 1), try render(empty, t: 1)), 0)
        XCTAssertTrue(CompoundEditing.audibleClips(in: p).isEmpty)
    }

    // MARK: 循環・深さ

    /// 循環するシーン(A→B→A)は描画も音声も無限ループせず、循環の先は出ない。
    func testCyclicScenesTerminateAndDrawNothingBeyondCycle() throws {
        let red = try solidPNG("cyc.png", r: 1, g: 0, b: 0)
        var a = SceneDefinition(); a.name = "A"; var b = SceneDefinition(); b.name = "B"
        var refB = Clip(); refB.type = .scene; refB.sceneId = b.id; refB.start = 0; refB.duration = 2
        var refA = Clip(); refA.type = .scene; refA.sceneId = a.id; refA.start = 0; refA.duration = 2
        a.tracks = [layer("L", [refB])]
        b.tracks = [layer("L", [image("r", red, start: 0, duration: 2), refA])]
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#202020"; p.scenes = [a, b]; p.tracks = [layer("M", [])]
        XCTAssertTrue(SceneEditing.hasCycle(in: p))
        // 配置検証: 循環を作る配置は拒否される(既にある循環とは別に、新規の自己参照も拒否)
        XCTAssertFalse(SceneEditing.canPlace(in: p, sceneId: a.id, hostSceneId: a.id), "自分自身への配置は拒否")
        XCTAssertFalse(SceneEditing.canPlace(in: p, sceneId: a.id, hostSceneId: b.id), "循環になる配置は拒否")
        // 描画: B の絵(赤)は A 経由で 1 回だけ出て、循環の先では止まる(落ちない・無限ループしない)。
        // 配置検証は循環シーンを拒否するので、ここではファイルから読んだ状態を再現して手で置く
        XCTAssertNil(SceneEditing.place(in: p, sceneId: a.id, host: .main, trackIndex: 0, at: 0), "循環シーンは配置も拒否")
        var head = Clip(); head.type = .scene; head.sceneId = a.id; head.start = 0; head.duration = 2
        var placed = p; placed.tracks[0].clips = [head]
        let px = try render(placed, t: 1)
        var expect = Project(); expect.width = 200; expect.height = 200; expect.bg = "#202020"
        expect.tracks = [layer("M", [image("r", red, start: 0, duration: 2)])]
        XCTAssertEqual(maxDiff(px, try render(expect, t: 1)), 0)
        XCTAssertEqual(CompoundEditing.audibleClips(in: placed).map(\.id), ["r"], "音声側の平坦化も循環の先では止まる(B の中身が 1 回だけ出る)")
    }

    /// 深さ上限: 長い参照チェーンでも、上限を超えた先は描かれない(が、落ちない)。
    func testDeepChainIsCapped() throws {
        let red = try solidPNG("deep.png", r: 1, g: 0, b: 0)
        var scenes: [SceneDefinition] = []
        let n = SceneEditing.maxDepth + 4
        for i in 0..<n { var s = SceneDefinition(); s.name = "S\(i)"; scenes.append(s) }
        for i in 0..<n {
            if i == n - 1 { scenes[i].tracks = [layer("L", [image("r", red, start: 0, duration: 2)])] }
            else { var ref = Clip(); ref.type = .scene; ref.sceneId = scenes[i + 1].id; ref.start = 0; ref.duration = 2; scenes[i].tracks = [layer("L", [ref])] }
        }
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#202020"; p.scenes = scenes; p.tracks = [layer("M", [])]
        XCTAssertEqual(SceneEditing.nestingDepth(in: p, sceneId: scenes[0].id), n - 1)
        XCTAssertFalse(SceneEditing.canPlace(in: p, sceneId: scenes[0].id, hostSceneId: nil), "深すぎるシーンは配置を拒否")
        // ファイルから読んだ深すぎる参照でも描画は止まらない(上限の先は描かない)
        var head = Clip(); head.type = .scene; head.sceneId = scenes[0].id; head.start = 0; head.duration = 2
        p.tracks[0].clips = [head]
        var empty = Project(); empty.width = 200; empty.height = 200; empty.bg = "#202020"; empty.tracks = [layer("M", [])]
        XCTAssertEqual(maxDiff(try render(p, t: 1), try render(empty, t: 1)), 0, "上限より深い先の絵は出ない")
    }

    // MARK: 音声

    /// シーンの中の音声は、直接置いた場合と同じサンプルになる(書き出しとプレビューの共通経路)。
    func testSceneAudioSamplesMatchDirectPlacement() throws {
        let wav = tmp.appendingPathComponent("s.wav")
        try AudioFixture.writeSine(wav, frequency: 440, segments: [(2, 0.3)])
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = wav.path; a.start = 0.2; a.duration = 1.5
        var scene = SceneDefinition(); scene.name = "音シーン"; scene.tracks = [layer("音", [a])]
        var p = Project(); p.scenes = [scene]; p.tracks = [layer("M", [])]
        let placed = try XCTUnwrap(SceneEditing.place(in: p, sceneId: scene.id, host: .main, trackIndex: 0, at: 0.5)).project
        // 平坦化: 絶対時刻 = 配置 0.5 + シーン内 0.2 = 0.7
        let flat = CompoundEditing.audibleClips(in: placed)
        XCTAssertEqual(flat.map(\.id), ["a"])
        XCTAssertEqual(flat[0].start, 0.7, accuracy: 1e-9)
        var direct = Project()
        var a2 = a; a2.start = 0.7
        direct.tracks = [layer("M", [a2])]
        let x = tmp.appendingPathComponent("via-scene.caf"), y = tmp.appendingPathComponent("direct.caf")
        _ = try AudioMixer.mixdown(project: placed, assets: RenderAssets(), to: x)
        _ = try AudioMixer.mixdown(project: direct, assets: RenderAssets(), to: y)
        let sx = try samples(x), sy = try samples(y)
        XCTAssertEqual(sx.count, sy.count)
        var m: Float = 0
        for i in 0..<min(sx.count, sy.count) { m = max(m, abs(sx[i] - sy[i])) }
        XCTAssertLessThan(m, 1e-6)
        XCTAssertGreaterThan(sx.map { abs($0) }.max() ?? 0, 0.1, "音が実際に入っている")
    }

    /// シーンの中のレイヤー消音・クリップ消音は、メイン側と同じ意味で効く。
    func testMutedInsideSceneIsRespected() throws {
        let wav = tmp.appendingPathComponent("m2.wav")
        try AudioFixture.writeSine(wav, segments: [(1, 0.3)])
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = wav.path; a.start = 0; a.duration = 1
        var scene = SceneDefinition(); scene.name = "S"; var t = layer("音", [a]); t.muted = true; scene.tracks = [t]
        var p = Project(); p.scenes = [scene]; p.tracks = [layer("M", [])]
        let placed = try XCTUnwrap(SceneEditing.place(in: p, sceneId: scene.id, host: .main, trackIndex: 0, at: 0)).project
        XCTAssertTrue(CompoundEditing.audibleClips(in: placed).isEmpty, "シーン内の消音レイヤーは混ぜない")
    }

    // MARK: スコープ(開いて編集)

    func testSceneScopeViewAndEmbedRoundTrip() throws {
        let (p, _, sid) = try projectWithScene()
        let view = try XCTUnwrap(SceneScope.view(of: p, sceneId: sid))
        XCTAssertEqual(view.tracks.count, 1)
        XCTAssertEqual(view.allClips.map(\.id), ["in1"], "見え方はシーンの中身")
        XCTAssertEqual(view.scenes.count, 1, "シーン一覧は見え方にも残る")
        var edited = view
        edited.tracks[0].clips[0].start = 0.5
        let back = try XCTUnwrap(SceneScope.embed(view: edited, into: p, sceneId: sid))
        XCTAssertEqual(back.scene(withId: sid)?.tracks[0].clips[0].start, 0.5, "編集は定義へ戻る")
        XCTAssertEqual(back.tracks, p.tracks, "メインのレイヤーは根のまま")
        XCTAssertEqual(SceneScope.breadcrumb(p, sceneId: sid), ["プロジェクト", "導入"])
        XCTAssertNil(SceneScope.view(of: p, sceneId: "missing"))
    }

    // MARK: ヘルパー

    func samples(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let n = AVAudioFrameCount(f.length)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: buf, frameCount: n)
        var out: [Float] = []
        for c in 0..<Int(f.processingFormat.channelCount) {
            out.append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![c], count: Int(buf.frameLength)))
        }
        return out
    }
}


// MARK: - バグ確認 第2部 C12: 配置の深さ判定は複合の段数も数える

final class SceneNestingCanPlaceDepthTests: XCTestCase {
    /// 動画クリップを複合で levels 段包んだクリップ。
    private func nest(_ levels: Int) -> Clip {
        var c = Clip(); c.type = .video; c.duration = 1
        for _ in 0..<levels {
            var tr = Track(name: "L"); tr.clips = [c]
            var w = Clip(); w.type = .compound; w.duration = 1; w.tracks = [tr]
            c = w
        }
        return c
    }
    private func project(sceneId: String, content: Clip) -> Project {
        var tr = Track(name: "L"); tr.clips = [content]
        var p = Project(); p.tracks = [Track(name: "main")]
        p.scenes = [SceneDefinition(id: sceneId, name: "S", tracks: [tr])]
        return p
    }
    func testCompoundLevelsCountTowardTheDepthLimit() {
        // 複合 8 段を中身に持つシーンは、シーン参照が無くても上限を超える(末端が描画・音声で落ちる)
        XCTAssertFalse(SceneEditing.canPlace(in: project(sceneId: "deep", content: nest(8)), sceneId: "deep", hostSceneId: nil))
        XCTAssertTrue(SceneEditing.canPlace(in: project(sceneId: "ok", content: nest(7)), sceneId: "ok", hostSceneId: nil))
    }
    func testPlacingIntoAHostRespectsTheHostsOwnLevel() {
        // 中身 7 段のシーン(クリップ自体で 8 段)は、別のシーンの中には置けない(置くと 9 段になる)
        var deep = project(sceneId: "deep", content: nest(7))
        deep.scenes.append(SceneDefinition(id: "host", name: "H", tracks: [Track(name: "L")]))
        XCTAssertFalse(SceneEditing.canPlace(in: deep, sceneId: "deep", hostSceneId: "host"))
        var ok = project(sceneId: "ok", content: nest(6))
        ok.scenes.append(SceneDefinition(id: "host", name: "H", tracks: [Track(name: "L")]))
        XCTAssertTrue(SceneEditing.canPlace(in: ok, sceneId: "ok", hostSceneId: "host"))
    }
}
