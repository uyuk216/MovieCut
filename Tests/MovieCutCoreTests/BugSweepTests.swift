import XCTest
@testable import MovieCutCore

/// 機能追加後の不具合の掃除(2026-11-02): 複合クリップの編集・複製の id・テンプレート名・ロックされたレイヤーへの配置。
final class BugSweepTests: XCTestCase {
    private func audio(_ id: String, start: Double, duration: Double, offset: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .audio; c.src = "/tmp/a.wav"
        c.start = start; c.duration = duration; c.offset = offset; c.srcDuration = 60
        return c
    }

    private func compound(_ id: String, start: Double, duration: Double, kids: [Clip]) -> Clip {
        var c = Clip(); c.id = id; c.type = .compound; c.start = start; c.duration = duration
        var kt = Track(name: "中")
        kt.clips = kids
        c.tracks = [kt]
        return c
    }

    private func project(_ clips: [Clip]) -> Project {
        var t = Track(name: "レイヤー1")
        t.clips = clips
        var p = Project()
        p.tracks = [t]
        return p
    }

    /// 複合の中を含む、すべての clip id(重複を数えるため配列で返す)。
    private func allIds(_ clips: [Clip]) -> [String] {
        clips.flatMap { c -> [String] in [c.id] + (c.tracks ?? []).flatMap { allIds($0.clips) } }
    }

    // 候補 1: 複合の分割で、右側の中身が切り目から続かない(頭から流れ直す)
    func testSplitCompoundRightPieceContinuesContent() throws {
        let comp = compound("c", start: 0, duration: 4, kids: [audio("k", start: 0, duration: 4)])
        let (_, right) = try XCTUnwrap(ClipEditing.split(comp, at: 2))
        let c = try XCTUnwrap(CompoundEditing.audibleClips(in: project([right])).first)
        XCTAssertEqual(c.start, 2, accuracy: 1e-9)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 0), 2, accuracy: 1e-9, "切り目の時刻に出る素材は 2 秒")
    }

    // 候補 1: 複合の左端を詰めると、同じ時刻に出る中身がずれる
    func testTrimLeftCompoundKeepsContentAligned() throws {
        let comp = compound("c", start: 0, duration: 4, kids: [audio("k", start: 0, duration: 4)])
        let r = ClipEditing.trimLeft(in: project([comp]), clipId: "c", deltaT: 1, playhead: 0, pps: 0, snapEnabled: false)
        let trimmed = try XCTUnwrap(r.project.tracks[0].clips.first)
        XCTAssertEqual(trimmed.start, 1, accuracy: 1e-9)
        let c = try XCTUnwrap(CompoundEditing.audibleClips(in: project([trimmed])).first)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 0), 1, accuracy: 1e-9, "タイムライン 1 秒に出る素材は 1 秒")
    }

    // 候補 2: 複合の終わりの後まで、中の音声が鳴る
    func testCompoundAudioDoesNotPlayPastCompoundEnd() throws {
        let comp = compound("c", start: 0, duration: 2, kids: [audio("k", start: 0, duration: 5)])
        let c = try XCTUnwrap(CompoundEditing.audibleClips(in: project([comp])).first)
        XCTAssertLessThanOrEqual(c.start + c.duration, 2 + 1e-9, "複合の終わり(2 秒)より後まで鳴らない")
    }

    // 候補 3: 貼り付けた複合の中の子の id が元と重複する
    func testPastedCompoundGetsFreshChildIds() throws {
        let comp = compound("c", start: 0, duration: 2, kids: [audio("k", start: 0, duration: 1)])
        let p = project([comp])
        let clip = try XCTUnwrap(ClipClipboard.make(from: p, clipIds: ["c"]))
        let r = try XCTUnwrap(ClipEditing.paste(clip, in: p, at: 5, targetTrack: nil))
        let ids = allIds(r.project.allClips)
        XCTAssertEqual(ids.count, Set(ids).count, "貼り付け後の id は全部一意(\(ids))")
    }

    // 候補 3: 複製した複合の中の子の id が元と重複する
    func testDuplicatedCompoundGetsFreshChildIds() throws {
        let comp = compound("c", start: 0, duration: 2, kids: [audio("k", start: 0, duration: 1)])
        let r = try XCTUnwrap(ClipEditing.duplicate(in: project([comp]), clipId: "c"))
        let ids = allIds(r.project.allClips)
        XCTAssertEqual(ids.count, Set(ids).count, "複製後の id は全部一意(\(ids))")
    }

    // 候補 4: 大文字小文字だけ違う名前で上書きが起きる(macOS は大文字小文字を区別しないことが多い)
    func testTemplateUniqueNameIgnoresCase() {
        XCTAssertEqual(ProjectTemplate.uniqueName(base: "Foo", existing: ["foo"]), "Foo 2")
    }

    // 候補 5: ロックされたレイヤーに自動配置される
    func testPlacementSkipsLockedLayer() {
        var locked = Track(name: "ロック")
        locked.locked = true
        var p = Project()
        p.tracks = [locked]
        let ids = ClipEditing.place(media: [("/tmp/x.png", .image, 5)], at: 0, in: &p)
        let id = try? XCTUnwrap(ids.first)
        XCTAssertEqual(p.tracks[0].clips.count, 0, "ロックされたレイヤーには置かない")
        XCTAssertEqual(p.allClips.filter { $0.id == id }.count, 1, "別のレイヤーに 1 つ置く")
        assertNoLayerOverlaps(p)
    }
}

final class BugSweepProxyTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bugsweep-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // 候補 6: 存在しない素材や映像のない素材で、後ろの素材のプロキシ作成が止まる
    func testBatchContinuesPastMissingAndFailedSources() async throws {
        let good1 = dir.appendingPathComponent("g1.mp4"), good2 = dir.appendingPathComponent("g2.mp4")
        try TestVideo.write(to: good1, size: (640, 360), frames: 5, rgb: (0, 255, 0))
        try TestVideo.write(to: good2, size: (640, 360), frames: 5, rgb: (0, 0, 255))
        let missing = dir.appendingPathComponent("nope.mp4")
        let result = try await ProxyStore.makeAll(sources: [missing, good1, good2], directory: dir)
        XCTAssertEqual(result.made.count, 2, "存在する 2 件は作る")
        XCTAssertEqual(result.failed.count, 1, "存在しない 1 件は失敗として数える")
        XCTAssertNotNil(ProxyStore.existingProxy(for: good2, directory: dir), "最後の素材まで作る")
    }
}
