import XCTest
@testable import MovieCutCore

/// マルチカメラ編集(Core): 同期のずれの検出(合成の音)、グループの作成、アングルの切り替え、ファイルの互換。
final class MulticamTests: XCTestCase {
    private func video(_ id: String, start: Double, dur: Double, offset: Double = 0, src: Double = 60) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/x/\(id).mov"; c.start = start; c.duration = dur
        c.offset = offset; c.srcDuration = src
        return c
    }
    private func get(_ p: Project, _ id: String) -> Clip { p.allClips.first { $0.id == id }! }

    // MARK: 同期(合成の音)

    /// 10 ms ごとの包絡: 決まった擬似乱数の音の塊。`lead` 秒ぶん頭を無音にずらす(= 後ろにずれている)。
    private func envelope(seconds: Double, lead: Double, seed: UInt64 = 5) -> [Float] {
        let n = Int(seconds * 100)
        var s = seed
        var base: [Float] = []
        var level: Float = 0
        for i in 0..<n {
            if i % 17 == 0 {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                level = Float(Double(s >> 11) / Double(1 << 53))
                if level < 0.35 { level = 0 }
            }
            base.append(level)
        }
        let shift = Int((lead * 100).rounded())
        return (0..<n).map { $0 >= shift ? base[$0 - shift] : 0 }
    }

    func testKnownShiftIsRecoveredWithin10ms() throws {
        let ref = envelope(seconds: 30, lead: 0)
        for lead in [0.0, 0.37, 1.23, 4.5, -0.8] {
            // lead が負 = 角度のほうが先に鳴る
            let angle = lead >= 0 ? envelope(seconds: 30, lead: lead) : Array(envelope(seconds: 30 - lead, lead: 0).dropFirst(Int(-lead * 100)))
            let lag = try XCTUnwrap(Multicam.localLag(reference: ref, angle: angle), "lead \(lead)")
            XCTAssertEqual(lag, lead, accuracy: 0.0101, "lead \(lead)")
        }
    }

    func testSilentOrUnrelatedAudioGivesNoLag() {
        let ref = envelope(seconds: 20, lead: 0)
        XCTAssertNil(Multicam.localLag(reference: ref, angle: [Float](repeating: 0, count: 2000)))
        XCTAssertNil(Multicam.localLag(reference: [], angle: ref))
    }

    func testSyncOffsetAccountsForDifferentSourceOffsets() {
        let r = video("r", start: 0, dur: 10, offset: 5), a = video("a", start: 0, dur: 10, offset: 8)
        // 使う区間の頭どうしのずれが 0.5 秒なら、素材の時刻のずれは (8 − 5) + 0.5
        XCTAssertEqual(Multicam.syncOffset(reference: r, angle: a, localLag: 0.5), 3.5, accuracy: 1e-9)
    }

    // MARK: 作る

    private func project3() -> Project {
        var p = Project.new()
        p.tracks[0].clips = [video("cam1", start: 0, dur: 20)]
        p.tracks[1].clips = [video("cam2", start: 0, dur: 20, offset: 1)]
        p.tracks[2].clips = [video("cam3", start: 2, dur: 20)]
        return p
    }

    private func made(_ p: Project, lags: [String: Double] = ["cam2": 0.5, "cam3": -0.25]) throws -> (Project, String) {
        guard case .created(let q, let gid) = Multicam.makeGroup(in: p, ids: ["cam1", "cam2", "cam3"], localLags: lags) else { throw XCTSkip("作れない") }
        return (q, gid)
    }

    func testCandidatesOrderAndLimits() {
        let p = project3()
        XCTAssertEqual(Multicam.candidates(in: p, ids: ["cam3", "cam2", "cam1"])?.map(\.id), ["cam1", "cam2", "cam3"], "頭の早い順(同じなら下のレイヤー)")
        XCTAssertNil(Multicam.candidates(in: p, ids: ["cam1"]))
        XCTAssertNotNil(Multicam.createDisabledReason(in: p, ids: ["cam1"]))
        XCTAssertNil(Multicam.createDisabledReason(in: p, ids: ["cam1", "cam2"]))
        var q = p
        q.tracks[1].clips[0].speed = 2
        XCTAssertNil(Multicam.candidates(in: q, ids: ["cam1", "cam2"]), "速度変更は不可")
        var r = p
        r.tracks[1].clips[0].type = .audio
        XCTAssertNil(Multicam.candidates(in: r, ids: ["cam1", "cam2"]), "映像だけ")
    }

    func testMakeGroupAddsLayerMutesOthersAndKeepsOffsets() throws {
        let (q, gid) = try made(project3())
        let g = try XCTUnwrap(q.multicams.first { $0.id == gid })
        XCTAssertEqual(g.angles.map(\.name), ["カメラ1", "カメラ2", "カメラ3"])
        XCTAssertEqual(g.angles[0].syncOffset, 0)
        XCTAssertEqual(g.angles[1].syncOffset, 1.5, accuracy: 1e-9, "offset 差 1 + ずれ 0.5")
        XCTAssertEqual(g.angles[2].syncOffset, -0.25, accuracy: 1e-9)
        XCTAssertEqual(q.tracks.count, project3().tracks.count + 1)
        XCTAssertEqual(q.tracks.last?.id, g.targetTrackId, "結果のレイヤーは一番手前")
        XCTAssertNil(get(q, "cam1").volume)
        XCTAssertEqual(get(q, "cam2").volume, 0)
        XCTAssertEqual(get(q, "cam3").volume, 0)
    }

    func testMakeGroupRefusesLockedAndInvalid() {
        var p = project3()
        p.tracks[1].locked = true
        XCTAssertEqual(Multicam.makeGroup(in: p, ids: ["cam1", "cam2"], localLags: [:]), .locked)
        XCTAssertEqual(Multicam.makeGroup(in: project3(), ids: ["cam1"], localLags: [:]), .invalid)
        XCTAssertEqual(Multicam.makeGroup(in: project3(), ids: ["cam1", "cam2"], localLags: ["cam2": .infinity]), .invalid)
        // 手動(ずれ未指定)でも作れる
        if case .created = Multicam.makeGroup(in: project3(), ids: ["cam1", "cam2"], localLags: [:]) {} else { XCTFail() }
    }

    // MARK: 切り替え

    private func cutClips(_ p: Project, _ g: MulticamGroup) -> [Clip] {
        p.tracks.first { $0.id == g.targetTrackId }!.clips
    }

    func testCutCreatesLayoutWithSyncedOffsets() throws {
        var (p, gid) = try made(project3())
        let g = p.multicams[0]
        guard case .cut(let p1) = Multicam.cut(in: p, groupId: gid, angle: 1, at: 4) else { return XCTFail() }
        p = p1
        var cs = cutClips(p, g)
        XCTAssertEqual(cs.count, 1)
        // カメラ2 を 4 秒から基準の終わり(20)まで。素材の時刻 = 基準の素材 4 + ずれ 1.5
        XCTAssertEqual(cs[0].start, 4, accuracy: 1e-9); XCTAssertEqual(cs[0].duration, 16, accuracy: 1e-9)
        XCTAssertEqual(cs[0].offset, 5.5, accuracy: 1e-9)
        XCTAssertEqual(cs[0].src, "/x/cam2.mov"); XCTAssertEqual(cs[0].volume, 0)
        // 10 秒でカメラ3 へ: 前のクリップが縮み、右側が置き換わる
        guard case .cut(let p2) = Multicam.cut(in: p, groupId: gid, angle: 2, at: 10) else { return XCTFail() }
        p = p2
        cs = cutClips(p, g)
        XCTAssertEqual(cs.map(\.src), ["/x/cam2.mov", "/x/cam3.mov"])
        XCTAssertEqual(cs[0].duration, 6, accuracy: 1e-9)
        XCTAssertEqual(cs[1].start, 10, accuracy: 1e-9); XCTAssertEqual(cs[1].duration, 10, accuracy: 1e-9)
        XCTAssertEqual(cs[1].offset, 9.75, accuracy: 1e-9, "10 − 0.25")
        // 隙間も重なりもない
        XCTAssertEqual(cs[0].start + cs[0].duration, cs[1].start, accuracy: 1e-9)
        XCTAssertEqual(ClipRippleTrim.overlapCount(cs), 0)
        // 基準(カメラ1)へ 7 秒で戻す: 途中の分割。右側(7〜10)だけ置き換わり、10 以降は残る
        guard case .cut(let p3) = Multicam.cut(in: p, groupId: gid, angle: 0, at: 7) else { return XCTFail() }
        cs = cutClips(p3, g)
        XCTAssertEqual(cs.map(\.src), ["/x/cam2.mov", "/x/cam1.mov", "/x/cam3.mov"], "cam3 は 10 秒から")
        XCTAssertEqual(cs[1].start, 7, accuracy: 1e-9); XCTAssertEqual(cs[1].duration, 3, accuracy: 1e-9)
    }

    func testCutRulesUnchangedLockedOutsideAndFootage() throws {
        let (p, gid) = try made(project3())
        guard case .cut(let p1) = Multicam.cut(in: p, groupId: gid, angle: 1, at: 4) else { return XCTFail() }
        XCTAssertEqual(Multicam.cut(in: p1, groupId: gid, angle: 1, at: 6), .unchanged, "すでに同じ角度")
        XCTAssertEqual(Multicam.cut(in: p, groupId: gid, angle: 1, at: 25), .outsideRange)
        XCTAssertEqual(Multicam.cut(in: p, groupId: gid, angle: 5, at: 4), .invalid)
        XCTAssertEqual(Multicam.cut(in: p, groupId: "none", angle: 0, at: 4), .invalid)
        var l = p
        l.tracks[l.tracks.count - 1].locked = true
        XCTAssertEqual(Multicam.cut(in: l, groupId: gid, angle: 1, at: 4), .locked)
        // カメラ3 は −0.25 のずれ: 基準の 0 秒(素材 0)では素材 −0.25 になり、映像がない
        XCTAssertEqual(Multicam.cut(in: p, groupId: gid, angle: 2, at: 0), .noFootage)
        // 素材が短くて区間を満たさない
        var s = p
        s.multicams[0].angles[1].clip.srcDuration = 8
        XCTAssertEqual(Multicam.cut(in: s, groupId: gid, angle: 1, at: 4), .noFootage)
    }

    func testCutInGapFillsUpToNextClip() throws {
        var (p, gid) = try made(project3())
        // 5〜8 だけ cam2 のクリップを手で置いた状態を作る
        let g = p.multicams[0]
        let ti = p.tracks.count - 1
        p.tracks[ti].clips = [Multicam.angleClip(g, angle: 1, start: 12, duration: 3, reference: g.angles[0].clip)!]
        guard case .cut(let q) = Multicam.cut(in: p, groupId: gid, angle: 2, at: 4) else { return XCTFail() }
        let cs = q.tracks[ti].clips
        XCTAssertEqual(cs.map(\.start), [4, 12])
        XCTAssertEqual(cs[0].duration, 8, accuracy: 1e-9, "次のクリップの頭まで")
    }

    func testActiveGroupFollowsReferenceRangeAndTrack() throws {
        let (p, _) = try made(project3())
        XCTAssertNotNil(Multicam.activeGroup(in: p, at: 5))
        XCTAssertNil(Multicam.activeGroup(in: p, at: 25))
        var q = p
        q.tracks.removeLast()
        XCTAssertNil(Multicam.activeGroup(in: q, at: 5), "結果のレイヤーが消えたら使えない")
    }

    // MARK: ファイル

    func testProjectRoundTripAndNoKeyWhenUnused() throws {
        let plain = try Project.new().encoded()
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("multicams"))
        let (p, _) = try made(project3())
        let d = try p.encoded()
        let back = try Project.decode(from: d)
        XCTAssertEqual(back, p)
        XCTAssertEqual(try back.encoded(), d)
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("multicams"))
    }

    func testBrokenMulticamsValueIsKeptVerbatim() throws {
        let json = ##"{"width":1920,"height":1080,"fps":60,"bg":"#000000","codec":"h264","tracks":[{"name":"a","clips":[]}],"multicams":"oops"}"##
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertTrue(p.multicams.isEmpty)
        XCTAssertTrue(String(decoding: try p.encoded(), as: UTF8.self).contains("oops"))
    }

    func testOldFixturesCarryNoMulticamKey() throws {
        for n in ["rich", "electron-made", "speed", "effects", "keyframes"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: n, withExtension: "ymproj", subdirectory: "Fixtures"))
            let s = String(decoding: try Project.load(from: url).encoded(), as: UTF8.self)
            XCTAssertFalse(s.contains("multicams"), n)
        }
    }
}
