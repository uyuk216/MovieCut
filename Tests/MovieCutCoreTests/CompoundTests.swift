import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 複合クリップ: まとめ・解除(往復で値が変わらない)、循環と深さの拒否、描画が「まとめる前と同じ画素」になること、
/// 音声が「まとめる前と同じサンプル」になること、古いファイルの書き方が変わらないこと。
final class CompoundTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("compound-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: 共通

    struct Px {
        let w: Int
        var d: [UInt8]
    }

    func pixels(_ img: CGImage) -> Px {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Px(w: img.width, d: d)
    }

    /// 単色の PNG(不透明)。
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

    func image(_ id: String, _ path: String, start: Double, duration: Double, x: Double, y: Double, scale: Double = 1,
               opacity: Double? = nil, rotation: Double? = nil, effects: [Effect] = []) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.src = path; c.start = start; c.duration = duration
        c.x = x; c.y = y; c.scale = scale; c.opacity = opacity; c.rotation = rotation; c.effects = effects
        return c
    }

    func layer(_ name: String, _ clips: [Clip], id: String? = nil) -> Track {
        var t = Track(name: name); if let id { t.id = id }; t.clips = clips
        return t
    }

    func render(_ p: Project, t: Double) throws -> Px {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    /// 2 枚の画素の最大の差(チャンネルごと)。
    func maxDiff(_ a: Px, _ b: Px) -> Int {
        XCTAssertEqual(a.d.count, b.d.count)
        var m = 0
        for i in 0..<min(a.d.count, b.d.count) { m = max(m, abs(Int(a.d[i]) - Int(b.d[i]))) }
        return m
    }

    /// 200×200・背景は黒。3 レイヤーに、位置・大きさ・不透明度・回転・効果の違う画像を置いたプロジェクト。
    /// 開始時刻はどれも 0 より後ろにして、まとめたときの頭の付け替えを確かめる。
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

    // MARK: まとめ・解除

    /// まとめて解除すると、元のプロジェクトとまったく同じになる(子の時刻は 1e-9 秒の格子で往復する)。
    func testGroupThenUngroupRestoresProjectExactly() throws {
        var p = try sampleProject()
        // 小数の多い時刻も入れる(往復で誤差が残らないか)
        p.tracks[1].clips[0].start = 1.2345
        p.tracks[0].clips[0].start = 0.3
        p.tracks[2].clips[0].start = 0.7001
        let grouped = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2", "c3"]))
        XCTAssertEqual(grouped.project.allClips.filter { $0.type == .compound }.count, 1)
        XCTAssertTrue(grouped.project.allClips.allSatisfy { $0.type != .image }, "3 つの画像は複合の中へ入った")
        let back = try XCTUnwrap(CompoundEditing.ungroup(grouped.project, clipId: grouped.compoundId))
        XCTAssertEqual(back.project, p, "まとめて解除すると元と同じ")
        XCTAssertEqual(Set(back.clipIds), ["c1", "c2", "c3"])
    }

    func testGroupStoresChildTimesRelativeToCompoundStart() throws {
        let p = try sampleProject()
        let r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2", "c3"]))
        let comp = try XCTUnwrap(r.project.allClips.first { $0.type == .compound })
        XCTAssertEqual(comp.start, 0.25, "最も早い子の開始が複合の頭")
        XCTAssertEqual(comp.duration, 3.75, accuracy: 1e-9, "頭から、いちばん遅く終わる子(c2 の 4 秒)まで")
        let kids = try XCTUnwrap(comp.tracks)
        XCTAssertEqual(kids.map(\.id), ["trackA", "trackB", "trackC"], "子のレイヤーは元のレイヤーの id を保つ")
        XCTAssertEqual(kids[0].clips[0].start, 0, accuracy: 1e-12)
        XCTAssertEqual(kids[1].clips[0].start, 0.75, accuracy: 1e-12)
        XCTAssertEqual(kids[2].clips[0].start, 0.25, accuracy: 1e-12)
        XCTAssertEqual(kids[1].clips[0].duration, 3, "長さ・素材の位置はそのまま")
    }

    /// 同じレイヤーの一部だけをまとめても、残りのクリップは動かず、解除すると元の並びに戻る。
    func testGroupingPartOfALayerLeavesTheRestInPlace() throws {
        var p = try sampleProject()
        p.tracks[0].clips = [
            image("a1", p.tracks[0].clips[0].src!, start: 0, duration: 1, x: 0.5, y: 0.5),
            image("a2", p.tracks[0].clips[0].src!, start: 1, duration: 1, x: 0.5, y: 0.5),
            image("a3", p.tracks[0].clips[0].src!, start: 2, duration: 1, x: 0.5, y: 0.5),
        ]
        let before = p
        let r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["a1", "a3"]))
        XCTAssertEqual(r.project.tracks[0].clips.map(\.id), [r.compoundId, "a2"], "残る a2 は同じ場所・同じ値")
        XCTAssertEqual(r.project.tracks[0].clips[1], before.tracks[0].clips[1])
        let back = try XCTUnwrap(CompoundEditing.ungroup(r.project, clipId: r.compoundId))
        XCTAssertEqual(back.project, before)
    }

    func testGroupRejectsFewerThanTwoLockedAndUnknown() throws {
        var p = try sampleProject()
        XCTAssertNil(CompoundEditing.group(p, clipIds: ["c1"]), "1 つだけはまとめない")
        XCTAssertNil(CompoundEditing.group(p, clipIds: ["c1", "nope"]), "見つからない id があれば全体を拒否")
        p.tracks[1].locked = true
        XCTAssertNil(CompoundEditing.group(p, clipIds: ["c1", "c2"]), "ロックされたレイヤーのクリップは動かさない")
        XCTAssertNil(CompoundEditing.ungroup(try sampleProject(), clipId: "c1"), "複合でないクリップは解除しない")
    }

    func testNestingIsLimitedToMaxDepth() throws {
        var p = try sampleProject()
        // 1 クリップずつ足して入れ子を深くする。上限(8 段)を超えるまとめは拒否される
        var extra = image("x0", p.tracks[0].clips[0].src!, start: 0, duration: 1, x: 0.5, y: 0.5)
        p.tracks[0].clips.append(extra)
        var groups = 0
        var currentId = "c1"
        var current = p
        while true {
            extra.id = "x\(groups + 1)"
            current.tracks[0].clips.append(extra)
            guard let r = CompoundEditing.group(current, clipIds: [currentId, extra.id]) else { break }
            current = r.project
            currentId = r.compoundId
            groups += 1
            if groups > 20 { XCTFail("上限がない"); break }
        }
        XCTAssertEqual(groups, CompoundEditing.maxDepth - 1, "深さは 8 段まで(クリップ 1 段 + まとめ 7 回)")
        let deepest = try XCTUnwrap(current.allClips.first { $0.id == currentId })
        XCTAssertEqual(CompoundEditing.depth(of: deepest), CompoundEditing.maxDepth)
    }

    func testCycleIsDetected() throws {
        // JSON の木では循環は作れない。同じ id の複合が中にあると循環とみなす
        var inner = Clip(); inner.id = "same"; inner.type = .compound; inner.start = 0; inner.duration = 1
        inner.tracks = [Track(name: "x")]
        var outer = Clip(); outer.id = "same"; outer.type = .compound; outer.start = 0; outer.duration = 1
        var t = Track(name: "中"); t.clips = [inner]
        outer.tracks = [t]
        XCTAssertTrue(CompoundEditing.hasCycle(outer))
        var ok = outer; ok.tracks = [Track(name: "空")]
        XCTAssertFalse(CompoundEditing.hasCycle(ok))
    }

    /// 循環のある複合は描かない(無限に入れ子にならない)。循環の部分を除いたプロジェクトと同じ画素になる。
    func testCyclicCompoundDrawsNothingForTheCycle() throws {
        var base = Project()
        base.width = 200; base.height = 200; base.bg = "#202020"
        base.tracks = [layer("赤", [image("red", try solidPNG("r.png", r: 1, g: 0, b: 0), start: 0, duration: 4, x: 0.3, y: 0.3, scale: 0.5)])]
        let white = try solidPNG("w.png", r: 1, g: 1, b: 1)
        // 外の複合と中の複合が同じ id(循環)。中の白い画像は描かれてはいけない
        var inner = Clip(); inner.id = "loop"; inner.type = .compound; inner.start = 0; inner.duration = 4
        inner.tracks = [layer("中", [image("hidden", white, start: 0, duration: 4, x: 0.5, y: 0.5)])]
        var outer = Clip(); outer.id = "loop"; outer.type = .compound; outer.start = 0; outer.duration = 4
        outer.tracks = [layer("外", [inner])]
        var withCycle = base
        withCycle.tracks.append(layer("循環", [outer]))
        var expected = base
        expected.tracks.append(layer("循環", []))
        XCTAssertEqual(maxDiff(try render(withCycle, t: 1), try render(expected, t: 1)), 0)
    }

    // MARK: 描画: まとめる前と同じ画素

    /// 複合クリップを描いた画素は、まとめる前のクリップを直接描いた画素と一致する(位置・回転・不透明度・効果・時刻の頭の付け替えを含む)。
    func testRenderingCompoundMatchesUngroupedClipsPixelForPixel() throws {
        let p = try sampleProject()
        let r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2", "c3"]))
        for t in [0.3, 0.8, 1.2, 1.9, 2.4] {
            let a = try render(p, t: t)
            let b = try render(r.project, t: t)
            XCTAssertEqual(maxDiff(a, b), 0, "t=\(t) で画素が一致しない")
        }
    }

    /// 複合クリップ自身の位置・大きさを変えると、中身もまとめて動く(子を個別に直さなくても効く)。
    func testCompoundTransformMovesChildrenAsAUnit() throws {
        let p = try sampleProject()
        var r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2"]))
        let i = try XCTUnwrap(r.project.tracks.firstIndex { $0.clips.contains { $0.type == .compound } })
        let j = try XCTUnwrap(r.project.tracks[i].clips.firstIndex { $0.type == .compound })
        r.project.tracks[i].clips[j].x = 0.2
        r.project.tracks[i].clips[j].scale = 0.5
        let shifted = try render(r.project, t: 1.5)
        let plain = try render(try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2"])).project, t: 1.5)
        XCTAssertGreaterThan(maxDiff(shifted, plain), 0, "動かすと画素が変わる")
    }

    /// 複合クリップの中にも、トランジションが効く(中身の子のトランジションは中身の時刻で決まる)。
    func testChildTransitionIsHonouredInsideCompound() throws {
        var p = try sampleProject()
        p.tracks[1].clips[0].transitionIn = Transition(.fade, duration: 1)
        let r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2"]))
        for t in [1.1, 1.6, 2.0] {
            XCTAssertEqual(maxDiff(try render(p, t: t), try render(r.project, t: t)), 0, "t=\(t)")
        }
    }

    // MARK: 音声: まとめる前と同じサンプル

    /// 複合の中の音声は、まとめる前と同じサンプルになる(平らにして同じ列で混ぜる)。
    func testAudioSamplesMatchUngroupedClips() throws {
        let wav1 = tmp.appendingPathComponent("a.wav"), wav2 = tmp.appendingPathComponent("b.wav")
        try AudioFixture.writeSine(wav1, frequency: 330, segments: [(2, 0.3)])
        try AudioFixture.writeSine(wav2, frequency: 660, segments: [(2, 0.2)])
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = wav1.path; a.start = 0.4; a.duration = 1.5
        var b = Clip(); b.id = "b"; b.type = .audio; b.src = wav2.path; b.start = 1.1; b.duration = 1.5; b.volume = 0.5
        var p = Project()
        p.tracks = [layer("音1", [a]), layer("音2", [b])]
        let r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["a", "b"]))
        let x = tmp.appendingPathComponent("plain.caf"), y = tmp.appendingPathComponent("group.caf")
        _ = try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: x)
        _ = try AudioMixer.mixdown(project: r.project, assets: RenderAssets(), to: y)
        let sx = try samples(x), sy = try samples(y)
        XCTAssertEqual(sx.count, sy.count, "長さが同じ")
        var m: Float = 0
        for i in 0..<min(sx.count, sy.count) { m = max(m, abs(sx[i] - sy[i])) }
        XCTAssertLessThan(m, 1e-6, "サンプルの差")
        XCTAssertGreaterThan(sx.map { abs($0) }.max() ?? 0, 0.1, "音が実際に入っている")
    }

    /// 中の音声レイヤーを消音にすると、その複合の中の音だけが消える(外のレイヤーは変わらない)。
    func testMutedChildLayerIsSilentInsideCompound() throws {
        let wav = tmp.appendingPathComponent("m.wav")
        try AudioFixture.writeSine(wav, segments: [(2, 0.3)])
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = wav.path; a.start = 0; a.duration = 2
        var b = Clip(); b.id = "b"; b.type = .audio; b.src = wav.path; b.start = 0; b.duration = 2
        var p = Project(); p.tracks = [layer("1", [a]), layer("2", [b])]
        var r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["a", "b"])).project
        let i = try XCTUnwrap(r.tracks.firstIndex { $0.clips.contains { $0.type == .compound } })
        let j = try XCTUnwrap(r.tracks[i].clips.firstIndex { $0.type == .compound })
        r.tracks[i].clips[j].tracks?[1].muted = true
        let flat = CompoundEditing.audibleClips(in: r)
        XCTAssertEqual(flat.map(\.id), ["a"], "消音の子は混ぜない")
    }

    // MARK: 読み書き

    /// 複合でないプロジェクトは、`tracks` の項目を書かない(古いファイルの書き方は変わらない)。
    func testNonCompoundProjectWritesNoTracksKey() throws {
        let p = try sampleProject()
        let data = try JSONEncoder().encode(p)
        XCTAssertFalse(data.isEmpty)
        let clipJSON = String(data: try JSONEncoder().encode(p.tracks[0].clips[0]), encoding: .utf8)!
        XCTAssertFalse(clipJSON.contains("\"tracks\""), "複合でないクリップは tracks を書かない")
    }

    /// 複合クリップは、中身ごと書いて読み直すと同じになる(入れ子を含む)。
    func testCompoundRoundTripsThroughJSON() throws {
        let p = try sampleProject()
        let r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2", "c3"]))
        // 保存と同じ書き方(キーの順を固定)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(r.project)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back, r.project)
        let again = try enc.encode(back)
        XCTAssertEqual(again, data, "書き直しても同じバイト列")
    }

    // MARK: ヘルパー

    /// 音声ファイルの全サンプル(左右をまとめて平らに)。
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

    /// 計測(合否は見ない): 1920×1080 で、まとめる前と後の 1 コマの描画時間。環境差があるので数字は参考。
    func testPrintsRenderTimingBeforeAndAfterGrouping() throws {
        var p = try sampleProject()
        p.width = 1920; p.height = 1080
        let r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2", "c3"])).project
        func time(_ q: Project) throws -> Double {
            let renderer = Renderer(project: q, assets: RenderAssets())
            _ = renderer.renderImage(t: 1.0)   // 素材の読み込み
            let runs = 20
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<runs { _ = renderer.renderImage(t: 1.0) }
            return (CFAbsoluteTimeGetCurrent() - t0) / Double(runs) * 1000
        }
        let before = try time(p), after = try time(r)
        print("[CompoundTests] 1920x1080 1コマ: まとめる前 \(String(format: "%.2f", before)) ms, まとめた後 \(String(format: "%.2f", after)) ms")
    }
}
