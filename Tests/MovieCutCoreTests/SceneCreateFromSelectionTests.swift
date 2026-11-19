import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 選択からシーンを作成(R2-3): 選択したクリップ群を新しいシーン定義にまとめ、元の位置にシーンクリップを置く。
/// 複合クリップの `CompoundTests` と同じ流儀で、構造(相対時刻・レイヤーの写し)・拒否条件・深さ/循環の防止・
/// 作成前後で描画(画素)と音声(サンプル)が一致すること・保存の往復を確認する。
final class SceneCreateFromSelectionTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scene-create-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: 共通(SceneNestingTests / CompoundTests と同じ流儀)

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
    func image(_ id: String, _ path: String, start: Double, duration: Double, x: Double = 0.5, y: Double = 0.5, scale: Double = 1,
               opacity: Double? = nil, rotation: Double? = nil, effects: [Effect] = []) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.src = path; c.start = start; c.duration = duration
        c.x = x; c.y = y; c.scale = scale; c.opacity = opacity; c.rotation = rotation; c.effects = effects
        return c
    }
    func layer(_ name: String, _ clips: [Clip], id: String? = nil) -> Track {
        var t = Track(name: name); if let id { t.id = id }; t.clips = clips
        return t
    }
    func render(_ p: Project, t: Double) throws -> Px { pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t))) }
    func maxDiff(_ a: Px, _ b: Px) -> Int {
        XCTAssertEqual(a.d.count, b.d.count)
        var m = 0
        for i in 0..<min(a.d.count, b.d.count) { m = max(m, abs(Int(a.d[i]) - Int(b.d[i]))) }
        return m
    }
    func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]; return e }

    /// 200×200・3 レイヤーに、位置・大きさ・不透明度・回転・効果の違う画像を置いたプロジェクト(CompoundTests の標本と同じ形)。
    func sampleProject() throws -> Project {
        let red = try solidPNG("red.png", r: 1, g: 0, b: 0)
        let blue = try solidPNG("blue.png", r: 0, g: 0, b: 1)
        let green = try solidPNG("green.png", r: 0, g: 1, b: 0)
        var p = Project()
        p.width = 200; p.height = 200; p.bg = "#202020"
        p.tracks = [
            layer("A", [image("c1", red, start: 0.25, duration: 3, x: 0.3, y: 0.4, scale: 0.6, rotation: 20)], id: "trackA"),
            layer("B", [image("c2", blue, start: 1, duration: 3, x: 0.7, y: 0.6, scale: 0.5, opacity: 0.7)], id: "trackB"),
            layer("C", [image("c3", green, start: 0.5, duration: 2, x: 0.5, y: 0.2, scale: 0.4, effects: [Effect(.mono)])], id: "trackC"),
        ]
        return p
    }

    // MARK: 構造

    func testCreateBuildsSceneDefinitionAndReplacesSelection() throws {
        let p = try sampleProject()
        let r = try XCTUnwrap(SceneEditing.createFromSelection(in: p, name: "まとめ", clipIds: ["c1", "c2", "c3"]))
        XCTAssertEqual(r.project.scenes.count, 1)
        let scene = try XCTUnwrap(r.project.scene(withId: r.sceneId))
        XCTAssertEqual(scene.name, "まとめ")
        XCTAssertEqual(scene.tracks.map(\.id), ["trackA", "trackB", "trackC"], "中身のレイヤーは元のレイヤーの id を保つ")
        XCTAssertEqual(scene.tracks[0].clips[0].id, "c1")
        XCTAssertEqual(scene.tracks[0].clips[0].start, 0, accuracy: 1e-12, "時刻は先頭(0.25)からの相対")
        XCTAssertEqual(scene.tracks[1].clips[0].start, 0.75, accuracy: 1e-12)
        XCTAssertEqual(scene.tracks[2].clips[0].start, 0.25, accuracy: 1e-12)
        XCTAssertEqual(SceneEditing.duration(of: scene), 3.75, accuracy: 1e-9)
        // 元の位置にはシーンクリップ 1 本だけが残る(最も前のレイヤー・開始は選択の先頭・尺は選択全体)
        let clip = try XCTUnwrap(r.project.allClips.first { $0.id == r.clipId })
        XCTAssertEqual(clip.type, .scene)
        XCTAssertEqual(clip.sceneId, r.sceneId)
        XCTAssertEqual(clip.start, 0.25)
        XCTAssertEqual(clip.duration, 3.75, accuracy: 1e-9)
        XCTAssertEqual(clip.offset, 0)
        XCTAssertEqual(r.project.tracks[0].clips.map(\.id), [r.clipId])
        XCTAssertTrue(r.project.tracks[1].clips.isEmpty)
        XCTAssertTrue(r.project.tracks[2].clips.isEmpty)
        XCTAssertEqual(SceneEditing.referenceCount(in: r.project, sceneId: r.sceneId), 1)
    }

    /// 1 つだけの選択でも作れる(複合との意図的な違い: 定義化・再利用が目的なので 1 本でも意味がある)。
    func testCreateFromSingleClipIsAllowed() throws {
        let p = try sampleProject()
        let r = try XCTUnwrap(SceneEditing.createFromSelection(in: p, name: "単独", clipIds: ["c2"]))
        let scene = try XCTUnwrap(r.project.scene(withId: r.sceneId))
        XCTAssertEqual(scene.tracks.map(\.id), ["trackB"])
        XCTAssertEqual(scene.tracks[0].clips[0].start, 0, accuracy: 1e-12)
        let clip = try XCTUnwrap(r.project.allClips.first { $0.id == r.clipId })
        XCTAssertEqual(clip.start, 1)
        XCTAssertEqual(clip.duration, 3)
        XCTAssertEqual(r.project.tracks[1].clips.map(\.id), [r.clipId], "シーンクリップは元のレイヤーへ")
        XCTAssertEqual(r.project.tracks[0].clips.map(\.id), ["c1"], "選んでいないクリップはそのまま")
    }

    /// 同じレイヤーの一部だけを選んでも、残りは動かず、中身の相対位置も保たれる。
    func testCreateFromPartOfALayerLeavesTheRestInPlace() throws {
        let red = try solidPNG("p.png", r: 1, g: 0, b: 0)
        var p = Project(); p.width = 200; p.height = 200
        p.tracks = [layer("A", [
            image("a1", red, start: 0, duration: 1),
            image("a2", red, start: 1, duration: 1),
            image("a3", red, start: 2, duration: 1),
        ], id: "trackA")]
        let before = p
        let r = try XCTUnwrap(SceneEditing.createFromSelection(in: p, name: "部分", clipIds: ["a1", "a3"]))
        XCTAssertEqual(r.project.tracks[0].clips.count, 2)
        XCTAssertEqual(r.project.tracks[0].clips[1], before.tracks[0].clips[1], "残る a2 は同じ場所・同じ値")
        let scene = try XCTUnwrap(r.project.scene(withId: r.sceneId))
        XCTAssertEqual(scene.tracks.count, 1)
        XCTAssertEqual(scene.tracks[0].clips.map(\.id), ["a1", "a3"])
        XCTAssertEqual(scene.tracks[0].clips[1].start, 2, accuracy: 1e-12)
        let clip = try XCTUnwrap(r.project.allClips.first { $0.id == r.clipId })
        XCTAssertEqual(clip.start, 0)
        XCTAssertEqual(clip.duration, 3)
    }

    /// 複合クリップを含む選択も、そのままシーンの中身にできる(中身の構造は保たれる)。
    func testCreateCanIncludeCompoundClip() throws {
        let p = try sampleProject()
        let grouped = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2"]))
        let r = try XCTUnwrap(SceneEditing.createFromSelection(in: grouped.project, name: "複合入り", clipIds: [grouped.compoundId, "c3"]))
        let scene = try XCTUnwrap(r.project.scene(withId: r.sceneId))
        let inner = scene.tracks.flatMap { $0.clips }
        XCTAssertTrue(inner.contains { $0.id == grouped.compoundId && $0.type == .compound && $0.tracks != nil })
        XCTAssertTrue(inner.contains { $0.id == "c3" })
    }

    // MARK: 拒否条件

    func testCreateRejectsEmptyUnknownLockedAndEmptyName() throws {
        var p = try sampleProject()
        XCTAssertNil(SceneEditing.createFromSelection(in: p, name: "x", clipIds: []), "選択が空なら作らない")
        XCTAssertNil(SceneEditing.createFromSelection(in: p, name: "x", clipIds: ["c1", "nope"]), "見つからない id があれば全体を拒否")
        XCTAssertNil(SceneEditing.createFromSelection(in: p, name: "  ", clipIds: ["c1", "c2"]), "空の名前は作らない")
        p.tracks[1].locked = true
        XCTAssertNil(SceneEditing.createFromSelection(in: p, name: "x", clipIds: ["c1", "c2"]), "ロックされたレイヤーのクリップは動かさない")
        var q = try sampleProject()
        q.tracks[0].clips[0].locked = true
        XCTAssertNil(SceneEditing.createFromSelection(in: q, name: "x", clipIds: ["c1", "c2"]), "ロックされたクリップは動かさない")
    }

    /// 深さの境界: シーン参照の入れ子が上限(8 段)にちょうど収まる作成は通り、1 段超える作成は拒否する。
    func testCreateDepthBoundary() throws {
        // s0(葉)→ s1 → … → s7 の参照チェーン(nestingDepth は s_i で i)
        var scenes: [SceneDefinition] = []
        for i in 0...7 { var s = SceneDefinition(); s.name = "s\(i)"; scenes.append(s) }
        let red = try solidPNG("d.png", r: 1, g: 0, b: 0)
        scenes[0].tracks = [layer("L", [image("leaf", red, start: 0, duration: 2)])]
        for i in 1...7 {
            var ref = Clip(); ref.type = .scene; ref.sceneId = scenes[i - 1].id; ref.start = 0; ref.duration = 2
            scenes[i].tracks = [layer("L", [ref])]
        }
        func projectPicking(_ sid: String) -> Project {
            var p = Project(); p.width = 200; p.height = 200; p.scenes = scenes
            var head = Clip(); head.id = "head"; head.type = .scene; head.sceneId = sid; head.start = 0; head.duration = 2
            p.tracks = [layer("M", [head])]
            return p
        }
        XCTAssertEqual(SceneEditing.nestingDepth(in: projectPicking(scenes[7].id), sceneId: scenes[7].id), 7)
        // head の展開は 8 段(参照 1 + チェーン 7)。新しいシーンの 1 段を足すと 9 段 → 拒否
        XCTAssertNil(SceneEditing.createFromSelection(in: projectPicking(scenes[7].id), name: "深すぎ", clipIds: ["head"]))
        // head の展開が 7 段なら、新しいシーンを足して 8 段ちょうど → 可
        XCTAssertNotNil(SceneEditing.createFromSelection(in: projectPicking(scenes[6].id), name: "境界", clipIds: ["head"]))
    }

    /// 配置先のシーン(host)への参照を含む選択は、シーンの中で作ると循環になるので拒否する(メインでは作れる)。
    func testCreateRejectsHostReferenceCycle() throws {
        var host = SceneDefinition(); host.name = "ホスト"
        host.tracks = [layer("L", [image("h1", "/tmp/x.png", start: 0, duration: 1)])]
        var x = SceneDefinition(); x.name = "X"
        var refH = Clip(); refH.type = .scene; refH.sceneId = host.id; refH.start = 0; refH.duration = 1
        x.tracks = [layer("L", [refH])]
        var p = Project(); p.scenes = [host, x]
        var head = Clip(); head.id = "head"; head.type = .scene; head.sceneId = x.id; head.start = 0; head.duration = 1
        var direct = Clip(); direct.id = "direct"; direct.type = .scene; direct.sceneId = host.id; direct.start = 2; direct.duration = 1
        p.tracks = [layer("M", [head, direct])]
        XCTAssertNil(SceneEditing.createFromSelection(in: p, name: "循環", clipIds: ["head"], hostSceneId: host.id), "X はホストを参照するので、ホストの中では循環")
        XCTAssertNil(SceneEditing.createFromSelection(in: p, name: "循環", clipIds: ["direct"], hostSceneId: host.id), "ホスト自身への参照も循環")
        XCTAssertNotNil(SceneEditing.createFromSelection(in: p, name: "通常", clipIds: ["head"]), "メインへの配置なら循環にならない")
    }

    // MARK: 描画・音声の一致

    /// 作成後の描画は、作成前(直接置き)と画素一致する(位置・回転・不透明度・効果・相対時刻を含む)。
    func testCreateRenderingMatchesOriginalPixelForPixel() throws {
        let p = try sampleProject()
        let r = try XCTUnwrap(SceneEditing.createFromSelection(in: p, name: "絵", clipIds: ["c1", "c2", "c3"]))
        for t in [0.3, 0.8, 1.2, 1.9, 2.4, 3.5] {
            XCTAssertEqual(maxDiff(try render(p, t: t), try render(r.project, t: t)), 0, "t=\(t)")
        }
    }

    /// 作成後の音声は、作成前と同じクリップが同じ絶対時刻で平坦化され、ミックスのサンプルも一致する。
    func testCreateAudioMatchesOriginalSamples() throws {
        let wav = tmp.appendingPathComponent("a.wav")
        try AudioFixture.writeSine(wav, frequency: 440, segments: [(2, 0.3)])
        let red = try solidPNG("a.png", r: 1, g: 0, b: 0)
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = wav.path; a.start = 0.2; a.duration = 1.5
        var p = Project(); p.width = 200; p.height = 200
        p.tracks = [layer("音", [a]), layer("絵", [image("img", red, start: 0, duration: 2)])]
        let before = CompoundEditing.audibleClips(in: p)
        let r = try XCTUnwrap(SceneEditing.createFromSelection(in: p, name: "音シーン", clipIds: ["a", "img"]))
        let after = CompoundEditing.audibleClips(in: r.project)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.start), before.map(\.start))
        let x = tmp.appendingPathComponent("before.caf"), y = tmp.appendingPathComponent("after.caf")
        _ = try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: x)
        _ = try AudioMixer.mixdown(project: r.project, assets: RenderAssets(), to: y)
        let sx = try samples(x), sy = try samples(y)
        XCTAssertEqual(sx.count, sy.count)
        var m: Float = 0
        for i in 0..<min(sx.count, sy.count) { m = max(m, abs(sx[i] - sy[i])) }
        XCTAssertLessThan(m, 1e-6)
        XCTAssertGreaterThan(sx.map { abs($0) }.max() ?? 0, 0.1, "音が実際に入っている")
    }

    // MARK: 保存

    /// 作成したプロジェクトは JSON を往復してもバイト列が変わらない。
    func testCreatedProjectRoundTripsThroughJSON() throws {
        let p = try sampleProject()
        let r = try XCTUnwrap(SceneEditing.createFromSelection(in: p, name: "保存", clipIds: ["c1", "c3"]))
        let data = try encoder().encode(r.project)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back, r.project)
        XCTAssertEqual(try encoder().encode(back), data)
        XCTAssertEqual(back.scenes.count, 1)
        XCTAssertEqual(back.allClips.first { $0.type == .scene }?.sceneId, back.scenes[0].id)
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
