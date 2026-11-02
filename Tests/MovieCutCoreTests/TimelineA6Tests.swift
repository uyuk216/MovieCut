import XCTest
import AVFoundation
@testable import MovieCutCore

/// A6: タイムライン(複数選択・コピー&ペースト・レイヤー・波形/サムネイルの純粋な部分)。
final class TimelineA6Tests: XCTestCase {
    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
    }

    private func clip(_ id: String, _ type: ClipType = .image, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        return c
    }

    /// T0: a(0-2) b(2-4) c(5-6) / T1: d(1-3) e(3-5) / T2: f(0-1)
    private func sample() -> Project {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", start: 0, dur: 2), clip("b", start: 2, dur: 2), clip("c", start: 5, dur: 1)]
        p.tracks[1].clips = [clip("d", start: 1, dur: 2), clip("e", start: 3, dur: 2)]
        p.tracks[2].clips = [clip("f", start: 0, dur: 1)]
        return p
    }

    // MARK: 選択

    func testClickModifiers() {
        let p = sample()
        var s = TimelineSelection.click(.empty, on: "a", modifier: .none, in: p)
        XCTAssertEqual(s, .only("a"))
        s = TimelineSelection.click(s, on: "d", modifier: .command, in: p)
        XCTAssertEqual(s.ids, ["a", "d"]); XCTAssertEqual(s.primary, "d")
        s = TimelineSelection.click(s, on: "a", modifier: .command, in: p)       // トグルで外す
        XCTAssertEqual(s.ids, ["d"]); XCTAssertEqual(s.primary, "d")
        s = TimelineSelection.click(s, on: "d", modifier: .command, in: p)       // 最後の 1 つを外すと空
        XCTAssertEqual(s, .empty)
        // 主を外したら、残りの開始の一番早いものが主
        s = ClipSelection(ids: ["b", "c", "e"], primary: "e")
        s = TimelineSelection.click(s, on: "e", modifier: .command, in: p)
        XCTAssertEqual(s.ids, ["b", "c"]); XCTAssertEqual(s.primary, "b")
        // 何もない所: 修飾なしは空、修飾つきは変えない
        XCTAssertEqual(TimelineSelection.click(s, on: nil, modifier: .none, in: p), .empty)
        XCTAssertEqual(TimelineSelection.click(s, on: nil, modifier: .shift, in: p), s)
        XCTAssertEqual(TimelineSelection.click(s, on: nil, modifier: .command, in: p), s)
    }

    func testShiftExtendsAlongSameLayerOtherwiseAddsOne() {
        let p = sample()
        var s = TimelineSelection.click(.only("a"), on: "c", modifier: .shift, in: p)
        XCTAssertEqual(s.ids, ["a", "b", "c"]); XCTAssertEqual(s.primary, "c")
        s = TimelineSelection.click(.only("b"), on: "e", modifier: .shift, in: p)    // 別のレイヤー: そのクリップだけ
        XCTAssertEqual(s.ids, ["b", "e"])
        s = TimelineSelection.click(.empty, on: "f", modifier: .shift, in: p)
        XCTAssertEqual(s, .only("f"))
    }

    func testSelectAllAndPrune() {
        var p = sample()
        let all = TimelineSelection.selectAll(in: p)
        XCTAssertEqual(all.ids, ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(all.primary, "a", "開始が最も早い(同じなら上のレイヤー)")
        p = ClipEditing.delete(in: p, clipId: "a")!
        let pr = TimelineSelection.pruned(all, in: p)
        XCTAssertEqual(pr.ids, ["b", "c", "d", "e", "f"])
        XCTAssertEqual(pr.primary, "f", "a が消えたので、開始 0 の f")
        XCTAssertEqual(TimelineSelection.pruned(pr, in: p), pr)
        XCTAssertEqual(TimelineSelection.selectAll(in: Project.new()), .empty)
    }

    func testRectHitTesting() {
        let p = sample()
        // 時間 2.5〜3.5・行 0...1 → b(2-4), d(1-3), e(3-5)
        XCTAssertEqual(Set(TimelineSelection.clips(in: p, timeRange: 2.5...3.5, rows: 0...1)), ["b", "d", "e"])
        // 端が接するだけでも当たり(クリップの終わり = 範囲の頭)
        XCTAssertEqual(Set(TimelineSelection.clips(in: p, timeRange: 4...4.5, rows: 0...0)), ["b"])
        XCTAssertEqual(TimelineSelection.clips(in: p, timeRange: 4.1...4.9, rows: 0...0), [])
        // 行の範囲が外にはみ出しても落ちない
        XCTAssertEqual(Set(TimelineSelection.clips(in: p, timeRange: 0...0.5, rows: 2...9)), ["f"])
        // 長さ 0 のクリップ
        var q = p; q.tracks[0].clips.append(clip("z", start: 7, dur: 0))
        XCTAssertEqual(TimelineSelection.clips(in: q, timeRange: 6.5...7.5, rows: 0...0), ["z"])
    }

    func testRubberBandAdditiveKeepsPrimary() {
        let p = sample()
        let base = ClipSelection(ids: ["c"], primary: "c")
        let plain = TimelineSelection.rubberBand(base: base, hits: ["d", "e"], additive: false, in: p)
        XCTAssertEqual(plain.ids, ["d", "e"]); XCTAssertEqual(plain.primary, "d")
        let add = TimelineSelection.rubberBand(base: base, hits: ["d", "e"], additive: true, in: p)
        XCTAssertEqual(add.ids, ["c", "d", "e"]); XCTAssertEqual(add.primary, "c")
        XCTAssertEqual(TimelineSelection.rubberBand(base: base, hits: [], additive: false, in: p), .empty)
        XCTAssertEqual(TimelineSelection.rubberBand(base: base, hits: [], additive: true, in: p), base)
    }

    // MARK: 複数削除・詰めて削除・移動・複製

    func testDeleteMany() {
        let p = sample()
        let r = ClipEditing.delete(in: p, clipIds: ["a", "e", "zzz"])!
        XCTAssertEqual(Set(r.allClips.map(\.id)), ["b", "c", "d", "f"])
        XCTAssertNil(ClipEditing.delete(in: p, clipIds: ["zzz"]))
        XCTAssertNil(ClipEditing.delete(in: p, clipIds: []))
    }

    func testRippleDeleteManyClosesGapsPerLayer() {
        var p = sample()
        p.tracks[0].clips = [clip("a", start: 0, dur: 2), clip("b", start: 2, dur: 2), clip("c", start: 4, dur: 1), clip("g", start: 5, dur: 1)]
        let r = ClipEditing.rippleDelete(in: p, clipIds: ["a", "b", "e"])!
        let t0 = r.tracks[0].clips
        XCTAssertEqual(t0.map(\.id), ["c", "g"])
        XCTAssertEqual(t0[0].start, 0, accuracy: 1e-9); XCTAssertEqual(t0[1].start, 1, accuracy: 1e-9)
        XCTAssertEqual(r.tracks[1].clips.map(\.id), ["d"])   // e は最後なので詰める対象なし
        XCTAssertEqual(r.tracks[2].clips[0].start, 0)
        XCTAssertNil(ClipEditing.rippleDelete(in: p, clipIds: ["nope"]))
    }

    func testMoveManyKeepsRelativeOffsetsAndLayers() {
        let p = sample()
        let r = ClipEditing.moveMany(in: p, clipIds: ["b", "d"], primaryId: "b", deltaT: 1.5, targetTrackIndex: 1, playhead: 0, pps: 40, snapEnabled: false)
        func find(_ id: String) -> (Clip, Int) {
            for (ti, tr) in r.project.tracks.enumerated() { if let c = tr.clips.first(where: { $0.id == id }) { return (c, ti) } }
            fatalError()
        }
        XCTAssertEqual(find("b").0.start, 3.5, accuracy: 1e-9); XCTAssertEqual(find("b").1, 1)
        XCTAssertEqual(find("d").0.start, 2.5, accuracy: 1e-9); XCTAssertEqual(find("d").1, 2)   // 1 段下へ
        XCTAssertEqual(find("d").0.start - find("b").0.start, -1, accuracy: 1e-9, "相対位置は保たれる")
        XCTAssertEqual(find("a").0.start, 0)             // 選択外は動かない
        XCTAssertEqual(r.project.allClips.count, p.allClips.count)
    }

    func testMoveManyStopsAtZeroAndAtLayerEdges() {
        let p = sample()
        // 左へ −10: 一番早い選択(a: 0)が 0 で止まる → 全体が動かない
        let r1 = ClipEditing.moveMany(in: p, clipIds: ["a", "b"], primaryId: "b", deltaT: -10, targetTrackIndex: nil, playhead: 0, pps: 40, snapEnabled: false)
        XCTAssertEqual(r1.project.allClips.first { $0.id == "a" }!.start, 0)
        XCTAssertEqual(r1.project.allClips.first { $0.id == "b" }!.start, 2, accuracy: 1e-9)
        // 主は最下段のレイヤー、もう 1 つは最下段の手前: 下の端で止まる(クラッシュしない)
        let r2 = ClipEditing.moveMany(in: p, clipIds: ["f", "e"], primaryId: "f", deltaT: 0, targetTrackIndex: 4, playhead: 0, pps: 40, snapEnabled: false)
        XCTAssertEqual(r2.project.allClips.count, p.allClips.count)
        XCTAssertEqual(ClipEditing.locate("f", in: r2.project)!.track, 4)
        XCTAssertEqual(ClipEditing.locate("e", in: r2.project)!.track, 3, "同じ段差(2 段下)")
    }

    func testMoveManySkipsLockedLayersAndLockedDestination() {
        var p = sample()
        p.tracks[2].locked = true            // f はロック
        let r = ClipEditing.moveMany(in: p, clipIds: ["a", "f"], primaryId: "a", deltaT: 1, targetTrackIndex: 1, playhead: 0, pps: 40, snapEnabled: false)
        XCTAssertEqual(r.project.allClips.first { $0.id == "f" }!.start, 0, "ロックされたレイヤーのクリップは動かない")
        XCTAssertEqual(ClipEditing.locate("a", in: r.project)!.track, 1)
        // 行き先がロック: 時刻だけ動いて、レイヤーは元のまま
        var q = sample(); q.tracks[1].locked = true
        let r2 = ClipEditing.moveMany(in: q, clipIds: ["a", "b"], primaryId: "a", deltaT: 1, targetTrackIndex: 1, playhead: 0, pps: 40, snapEnabled: false)
        XCTAssertEqual(ClipEditing.locate("a", in: r2.project)!.track, 0)
        XCTAssertEqual(r2.project.allClips.first { $0.id == "a" }!.start, 1, accuracy: 1e-9)
        // 主がロックされているなら何もしない
        let r3 = ClipEditing.moveMany(in: p, clipIds: ["a", "f"], primaryId: "f", deltaT: 1, targetTrackIndex: nil, playhead: 0, pps: 40, snapEnabled: false)
        XCTAssertEqual(r3.project, p)
    }

    func testMoveManySnapsOnlyToNonSelectedClips() {
        let p = sample()
        // b(2-4) を +0.99 動かすと頭 2.99 / 終わり 4.99 → c の頭 5 に終わりが吸着(8pt = 0.2 秒以内)。仲間 d の終わり 3 には吸着しない
        let r = ClipEditing.moveMany(in: p, clipIds: ["b", "d"], primaryId: "b", deltaT: 0.99, targetTrackIndex: nil, playhead: 0, pps: 40, snapEnabled: true)
        XCTAssertEqual(r.project.allClips.first { $0.id == "b" }!.start, 3, accuracy: 1e-9)
        XCTAssertEqual(r.project.allClips.first { $0.id == "d" }!.start, 2, accuracy: 1e-9)
    }

    func testDuplicateManyPlacesGroupAfterItsEndKeepingLayers() {
        let p = sample()
        let r = ClipEditing.duplicate(in: p, clipIds: ["b", "d"])!
        XCTAssertEqual(r.newIds.count, 2)
        let nb = r.project.allClips.first { $0.id == r.newIds[0] }!, nd = r.project.allClips.first { $0.id == r.newIds[1] }!
        // 全体の終わりは b の 4。一番早い d(1)が 4 に来るので b は +3 → 5、d → 4
        XCTAssertEqual(nb.start, 5, accuracy: 1e-9); XCTAssertEqual(nd.start, 4, accuracy: 1e-9)
        // 元の層に置くと c(5〜6)・e(3〜5)・互いに重なるので、重なる分は次の空き層へ送る(2026-11-02: 層内の重なり禁止)
        XCTAssertGreaterThanOrEqual(ClipEditing.locate(nb.id, in: r.project)!.track, 0)
        XCTAssertGreaterThanOrEqual(ClipEditing.locate(nd.id, in: r.project)!.track, 1)
        assertNoLayerOverlaps(r.project)
        XCTAssertEqual(r.project.allClips.count, p.allClips.count + 2)
        XCTAssertNil(ClipEditing.duplicate(in: p, clipIds: ["none"]))
    }

    // MARK: クリップボード

    func testClipboardRoundTripAndPasteKeepsRelativeOffsets() throws {
        let p = sample()
        let cb = try XCTUnwrap(ClipClipboard.make(from: p, clipIds: ["b", "d", "f"]))
        XCTAssertEqual(cb.items.map(\.clip.id), ["b", "d", "f"], "レイヤー番号順")
        let back = try XCTUnwrap(ClipClipboard.decode(try XCTUnwrap(cb.encoded())))
        XCTAssertEqual(back, cb)
        // 元のレイヤーのまま、再生位置 10 へ(一番早い頭は f の 0)
        let r = try XCTUnwrap(ClipEditing.paste(back, in: p, at: 10, targetTrack: nil))
        XCTAssertEqual(r.newIds.count, 3); XCTAssertEqual(r.skipped, 0)
        let starts = r.newIds.map { id in r.project.allClips.first { $0.id == id }!.start }
        XCTAssertEqual(starts[0], 12, accuracy: 1e-9)   // b: 2 + 10
        XCTAssertEqual(starts[1], 11, accuracy: 1e-9)   // d: 1 + 10
        XCTAssertEqual(starts[2], 10, accuracy: 1e-9)   // f: 0 + 10
        XCTAssertTrue(Set(r.newIds).isDisjoint(with: Set(p.allClips.map(\.id))), "新しい id")
        XCTAssertEqual(ClipEditing.locate(r.newIds[1], in: r.project)!.track, 1)
    }

    func testPasteOnSelectedLayerKeepsStepsAndAddsLayersWhenNeeded() throws {
        let p = sample()
        let cb = try XCTUnwrap(ClipClipboard.make(from: p, clipIds: ["a", "d", "f"]))   // 層 0,1,2
        let r = try XCTUnwrap(ClipEditing.paste(cb, in: p, at: 3, targetTrack: 3))
        XCTAssertEqual(r.project.tracks.count, 6, "3,4,5 に置くので 5 層 → 6 層(+1)")
        XCTAssertEqual(r.project.tracks[5].name, "レイヤー6")
        XCTAssertEqual(ClipEditing.locate(r.newIds[0], in: r.project)!.track, 3)
        XCTAssertEqual(ClipEditing.locate(r.newIds[1], in: r.project)!.track, 4)
        XCTAssertEqual(ClipEditing.locate(r.newIds[2], in: r.project)!.track, 5)
        // 元のレイヤーに番号が無い(別のドキュメントから)ときも、足して置く
        let small = Project.new()
        var far = cb; far.items[2].track = 8
        let r2 = try XCTUnwrap(ClipEditing.paste(far, in: small, at: 0, targetTrack: nil))
        XCTAssertEqual(r2.project.tracks.count, 9)
    }

    func testPasteSkipsLockedLayersAndChangesNothingWhenAllSkipped() throws {
        var p = sample()
        p.tracks[3].locked = true
        let cb = try XCTUnwrap(ClipClipboard.make(from: p, clipIds: ["a", "d"]))
        let r = try XCTUnwrap(ClipEditing.paste(cb, in: p, at: 0, targetTrack: 2))   // a → 2, d → 3(ロック)
        XCTAssertEqual(r.skipped, 1); XCTAssertEqual(r.newIds.count, 1)
        XCTAssertEqual(r.project.tracks[3].clips.count, 0)
        // 全部ロックなら nil(足したレイヤーも残さない)
        p.tracks[2].locked = true
        XCTAssertNil(ClipEditing.paste(cb, in: p, at: 0, targetTrack: 2))
        XCTAssertNil(ClipEditing.paste(ClipClipboard(items: []), in: p, at: 0, targetTrack: nil))
        XCTAssertNil(ClipClipboard.decode(Data("not json".utf8)))
        XCTAssertNil(ClipClipboard.make(from: p, clipIds: ["none"]))
    }

    func testPastedClipKeepsUnknownKeysAndAudioFields() throws {
        let p = try Project.load(from: fixtureURL("speed"))
        let id = try XCTUnwrap(p.allClips.first { $0.extra["futureClipKey"] != nil }).id
        let cb = try XCTUnwrap(ClipClipboard.make(from: p, clipIds: [id]))
        let back = try XCTUnwrap(ClipClipboard.decode(try XCTUnwrap(cb.encoded())))
        XCTAssertEqual(back.items[0].clip.extra["futureClipKey"], p.allClips.first { $0.id == id }!.extra["futureClipKey"])
        XCTAssertEqual(back.items[0].clip.speed, 2)
    }

    // MARK: レイヤー

    func testLayerEditingNoOpsReturnNilAndOffValuesAreNotStored() throws {
        let p = Project.new()
        XCTAssertNil(LayerEditing.rename(in: p, index: 0, to: "  "))
        XCTAssertNil(LayerEditing.rename(in: p, index: 0, to: p.tracks[0].name))
        XCTAssertNil(LayerEditing.rename(in: p, index: 99, to: "x"))
        XCTAssertEqual(LayerEditing.rename(in: p, index: 0, to: " セリフ ")?.tracks[0].name, "セリフ")
        XCTAssertNil(LayerEditing.setLocked(in: p, index: 0, false))
        XCTAssertNil(LayerEditing.setSolo(in: p, index: 0, false))
        XCTAssertNil(LayerEditing.setHeight(in: p, index: 0, .normal))
        var q = try XCTUnwrap(LayerEditing.setLocked(in: p, index: 0, true))
        q = try XCTUnwrap(LayerEditing.setSolo(in: q, index: 0, true))
        q = try XCTUnwrap(LayerEditing.setHeight(in: q, index: 0, .large))
        let on = String(decoding: try q.encoded(), as: UTF8.self)
        for k in ["\"locked\"", "\"solo\"", "\"height\""] { XCTAssertTrue(on.contains(k), k) }
        q = try XCTUnwrap(LayerEditing.setLocked(in: q, index: 0, false))
        q = try XCTUnwrap(LayerEditing.setSolo(in: q, index: 0, false))
        q = try XCTUnwrap(LayerEditing.setHeight(in: q, index: 0, .normal))
        XCTAssertEqual(try q.encoded(), try p.encoded(), "全部戻せば、ファイルは元と同じ")
        XCTAssertEqual(LayerEditing.rowHeights(LayerEditing.setHeight(in: p, index: 1, .small).map { $0 }!).prefix(3).map { $0 }, [40, 36, 40])
    }

    func testLockViolationDetection() {
        var p = sample()
        p.tracks[0].locked = true
        var edited = p
        edited.tracks[0].clips[0].start = 9
        XCTAssertTrue(LayerEditing.violatesLock(old: p, new: edited))
        var moved = p; moved.tracks[1].clips.append(moved.tracks[0].clips.removeFirst())
        XCTAssertTrue(LayerEditing.violatesLock(old: p, new: moved))
        var other = p; other.tracks[1].clips[0].start = 9; other.tracks[0].name = "x"; other.tracks[0].muted = true; other.tracks[0].hidden = true
        XCTAssertFalse(LayerEditing.violatesLock(old: p, new: other), "ほかのレイヤーと、名前・消音・隠すは対象外")
        var unlock = p; unlock.tracks[0].locked = nil
        XCTAssertFalse(LayerEditing.violatesLock(old: p, new: unlock), "ロックの切り替え自体は許す")
        XCTAssertEqual(LayerEditing.editableIds(["a", "d"], in: p), ["d"])
        XCTAssertTrue(LayerEditing.isLockedClip("a", in: p)); XCTAssertFalse(LayerEditing.isLockedClip("d", in: p))
    }

    func testSoloAudibility() {
        var p = sample()
        XCTAssertTrue(p.tracks.allSatisfy { p.isAudible($0) })
        p.tracks[1].solo = true
        XCTAssertFalse(p.isAudible(p.tracks[0])); XCTAssertTrue(p.isAudible(p.tracks[1]))
        p.tracks[1].muted = true
        XCTAssertFalse(p.isAudible(p.tracks[1]), "消音はソロより強い")
        p.tracks[1].muted = nil; p.tracks[2].solo = true
        XCTAssertTrue(p.isAudible(p.tracks[1]) && p.isAudible(p.tracks[2]) && !p.isAudible(p.tracks[0]))
    }

    // MARK: ファイルの互換

    func testTimelineFixtureRoundTripsAndKeepsUnknowns() throws {
        let p1 = try Project.load(from: fixtureURL("timeline"))
        XCTAssertTrue(p1.tracks[0].isLocked); XCTAssertEqual(LayerHeight.of(p1.tracks[0]), .large)
        XCTAssertEqual(p1.tracks[0].extra["layerFutureKey"], .object(["keep": .bool(true)]))
        XCTAssertTrue(p1.tracks[1].isSolo); XCTAssertEqual(LayerHeight.of(p1.tracks[1]), .small)
        XCTAssertEqual(p1.tracks[1].muted, false)
        // 型違い・知らない値は捨てずに書き戻し、既定として扱う
        XCTAssertFalse(p1.tracks[2].isLocked); XCTAssertEqual(p1.tracks[2].extra["locked"], .string("yes"))
        XCTAssertEqual(p1.tracks[2].height, "huge"); XCTAssertEqual(LayerHeight.of(p1.tracks[2]), .normal)
        XCTAssertEqual(LayerHeight.of(p1.tracks[3]), .normal)
        XCTAssertTrue(p1.hasSolo)
        let data = try p1.encoded()
        let p2 = try Project.decode(from: data)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(try p2.encoded(), data)
    }

    func testOldFixturesGainNoLayerKeys() throws {
        for n in ["rich", "electron-made", "keyframes", "transitions", "effects", "speed", "audiofx"] {
            let p = try Project.load(from: fixtureURL(n))
            XCTAssertTrue(p.tracks.allSatisfy { $0.locked == nil && $0.solo == nil && $0.height == nil }, n)
            let s = String(decoding: try p.encoded(), as: UTF8.self)
            for k in ["\"locked\"", "\"solo\"", "\"height\""] {
                // キャラクターなどに "height" を持つ項目があるかもしれないので、tracks の中だけ調べる
                for t in p.tracks {
                    let ts = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
                    XCTAssertFalse(ts.contains(k), "\(n) \(k)")
                }
                _ = s
            }
        }
    }

    // MARK: 波形

    func testPeakAccumulationMatchesBucketing() {
        // 8000 Hz で 0.5 秒: 前半 0.5 の振幅、後半 0.25 の振幅 → 1/100 秒(80 サンプル)ごとに 50 本
        var s = [Float](repeating: 0.5, count: 2000) + [Float](repeating: -0.25, count: 2000)
        s[10] = -0.9
        let w = WaveformPeaks.compute(samples: s, sampleRate: 8000)
        XCTAssertEqual(w.peaks.count, 50)
        XCTAssertEqual(w.peaks[0], 0.9, accuracy: 1e-6)
        XCTAssertEqual(w.peaks[10], 0.5, accuracy: 1e-6)
        XCTAssertEqual(w.peaks[40], 0.25, accuracy: 1e-6)
        XCTAssertEqual(w.duration, 0.5, accuracy: 1e-9)
        // 分けて流し込んでも同じ
        var acc = WaveformPeaks.Accumulator(sampleRate: 8000)
        acc.append(Array(s[0..<777])); acc.append(Array(s[777...]))
        XCTAssertEqual(acc.finish(), w)
        XCTAssertEqual(WaveformPeaks.compute(samples: [], sampleRate: 8000).peaks, [])
        // 1 を超える値は 1 に収める
        XCTAssertEqual(WaveformPeaks.compute(samples: [3, 0], sampleRate: 100).peaks[0], 1)
    }

    func testColumnsMapSourceRangeAndReverse() {
        // 1 秒 = 100 本。前半 0.2・後半 0.8
        let w = WaveformPeaks(peaks: [Float](repeating: 0.2, count: 50) + [Float](repeating: 0.8, count: 50))
        let c = w.columns(from: 0, to: 1, count: 4)
        XCTAssertEqual(c, [0.2, 0.2, 0.8, 0.8])
        XCTAssertEqual(w.columns(from: 1, to: 0, count: 4), [0.8, 0.8, 0.2, 0.2], "逆順")
        XCTAssertEqual(w.columns(from: 0.9, to: 3, count: 2), [0.8, 0.0], "素材の外は 0")
        XCTAssertEqual(w.columns(from: 0.25, to: 0.5, count: 5), [Float](repeating: 0.2, count: 5))
        XCTAssertEqual(w.columns(from: 0, to: 1, count: 0), [])
        XCTAssertEqual(w.columns(from: 0.5, to: 0.5, count: 3), [0, 0, 0])
        // クリップ: offset 0.5・長さ 0.25・速度 2 → 素材 0.5〜1.0 は全部 0.8
        var clip = Clip(); clip.type = .audio; clip.offset = 0.5; clip.duration = 0.25; clip.speed = 2
        XCTAssertEqual(WaveformPeaks.sourceRange(for: clip).to, 1.0, accuracy: 1e-9)
        XCTAssertEqual(w.columns(for: clip, count: 3), [0.8, 0.8, 0.8])
        clip.reverse = true; clip.offset = 0.25; clip.duration = 1; clip.speed = 0.5   // 素材 0.25〜0.75 が逆順
        let r = WaveformPeaks.sourceRange(for: clip)
        XCTAssertEqual(r.from, 0.75, accuracy: 1e-9); XCTAssertEqual(r.to, 0.25, accuracy: 1e-9)
        XCTAssertEqual(w.columns(for: clip, count: 2), [0.8, 0.2])
        var freeze = Clip(); freeze.type = .video; freeze.freeze = true; freeze.duration = 2
        XCTAssertEqual(w.columns(for: freeze, count: 2), [0, 0])
    }

    /// 合成した WAV(1 秒の 440 Hz 正弦波 0.5 → 1 秒の無音 → 1 秒の 0.25)を AVAssetReader で読んで、ピークが合うこと。
    func testLoadPeaksFromSyntheticWavMonoAndStereo() async throws {
        for channels in [1, 2] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("a6-wave-\(channels)-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try Self.writeWav(url: url, channels: channels, rate: 44100) { t in
                if t < 1 { return 0.5 * sin(2 * .pi * 440 * t) }
                if t < 2 { return 0 }
                return 0.25 * sin(2 * .pi * 440 * t)
            }
            let loaded = await WaveformPeaks.load(url: url)
            let w = try XCTUnwrap(loaded, "channels \(channels)")
            XCTAssertEqual(w.duration, 3, accuracy: 0.05)
            let cols = w.columns(from: 0, to: 3, count: 3)
            XCTAssertEqual(cols[0], 0.5, accuracy: 0.06, "channels \(channels)")
            XCTAssertEqual(cols[1], 0, accuracy: 0.02)
            XCTAssertEqual(cols[2], 0.25, accuracy: 0.05)
        }
        let missing = URL(fileURLWithPath: "/nonexistent/none.wav")
        let none = await WaveformPeaks.load(url: missing)
        XCTAssertNil(none)
    }

    static func writeWav(url: URL, channels: Int, rate: Int, seconds: Double = 3, _ f: (Double) -> Double) throws {
        let frames = Int(Double(rate) * seconds)
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let dataBytes = frames * channels * 2
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataBytes)); data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(dataBytes))
        for i in 0..<frames {
            let v = Int16((max(-1, min(1, f(Double(i) / Double(rate)))) * 32767).rounded())
            for _ in 0..<channels { u16(UInt16(bitPattern: v)) }
        }
        try data.write(to: url)
    }

    // MARK: サムネイル

    func testThumbnailTimesAndQuantisation() {
        var c = Clip(); c.type = .video; c.offset = 10; c.duration = 8; c.srcDuration = 100
        XCTAssertEqual(ThumbnailPlan.tileCount(width: 320, tileWidth: 60), 6)
        XCTAssertEqual(ThumbnailPlan.tileCount(width: 10, tileWidth: 60), 1)
        XCTAssertEqual(ThumbnailPlan.tileCount(width: 0, tileWidth: 60), 0)
        XCTAssertEqual(ThumbnailPlan.tileCount(width: 100000, tileWidth: 10), ThumbnailPlan.maxTiles)
        let t = ThumbnailPlan.times(for: c, tiles: 4)      // 1 枚 2 秒 → 刻み 2 秒、中心 11, 13, 15, 17 を切り下げ
        XCTAssertEqual(t, [10, 12, 14, 16])
        for v in t { XCTAssertTrue(v >= 10 && v <= 18) }
        // 速度 2 → 素材は 16 秒ぶん
        c.speed = 2
        XCTAssertEqual(ThumbnailPlan.times(for: c, tiles: 2), [10, 20])   // 1 枚 8 秒 → 刻み 5 秒、中心 14, 22
        // 逆再生: 右のタイルほど素材の頭に近い
        c.speed = nil; c.reverse = true
        XCTAssertEqual(ThumbnailPlan.times(for: c, tiles: 4), [16, 14, 12, 10])
        // 近い時刻は同じ値に丸まる(キャッシュの使い回し)
        var d = c; d.reverse = nil; d.offset = 10.03
        // 頭のタイルだけは素材の範囲の下限(10.03)で止まる。残りは同じ値に丸まる
        XCTAssertEqual(Array(ThumbnailPlan.times(for: d, tiles: 4).dropFirst()), Array(ThumbnailPlan.times(for: Clip.with(offset: 10, type: .video, duration: 8), tiles: 4).dropFirst()))
        // フリーズは 1 コマだけ
        var f = c; f.reverse = nil; f.type = .video; f.freeze = true; f.offset = 3.25
        XCTAssertEqual(ThumbnailPlan.times(for: f, tiles: 3), [3.25, 3.25, 3.25])
        XCTAssertEqual(ThumbnailPlan.times(for: c, tiles: 0), [])
    }
}

private extension Clip {
    static func with(offset: Double, type: ClipType, duration: Double) -> Clip {
        var c = Clip(); c.type = type; c.offset = offset; c.duration = duration; return c
    }
}
