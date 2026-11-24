import XCTest
@testable import MovieCutCore

/// Remix(Core): 候補→フレーズ化→区間選定(目標尺への近似・ビート整列・順序保持・繰り返し)、
/// フォールバック候補、クロスフェード付きクリップ列、配置(元クリップ不変・Undo の土台)。
final class RemixTests: XCTestCase {

    func audioClip(id: String, start: Double, duration: Double, offset: Double = 0, src: String = "/x.wav") -> Clip {
        var c = Clip(); c.id = id; c.type = .audio; c.start = start; c.duration = duration; c.offset = offset; c.src = src
        return c
    }

    /// 0.5 秒間隔のビート候補(20 秒なら 1...39 本)。
    func beats(every step: Double, duration: Double) -> [Double] {
        var out: [Double] = []
        var t = step
        while t < duration { out.append(t); t += step }
        return out
    }

    func plan(_ r: Result<RemixPlan, RemixError>) -> RemixPlan {
        switch r { case .success(let p): return p; case .failure(let e): XCTFail("計画できなかった: \(e)"); fatalError() }
    }

    // MARK: 境界・フレーズ

    func testBoundariesSanitizeSortAndDedup() {
        let b = Remix.boundaries(duration: 10, candidates: [5, 2, 2 + 5e-7, -1, 10, 99, .nan, 7.5])
        XCTAssertEqual(b, [0, 2, 5, 7.5, 10], "範囲外・重複を除き、両端を付ける")
        XCTAssertEqual(Remix.boundaries(duration: 0, candidates: [1]), [])
        XCTAssertEqual(Remix.boundaries(duration: 10, candidates: []), [0, 10])
    }

    func testPhrasesGroupByNominalDuration() {
        // 0.5 秒間隔の候補、目安 2 秒 → 2 秒ずつのフレーズ
        let ph = Remix.phrases(duration: 10, candidates: beats(every: 0.5, duration: 10), nominalPhraseDuration: 2)
        XCTAssertEqual(ph.count, 5)
        XCTAssertEqual(ph.map(\.length), [2, 2, 2, 2, 2])
        XCTAssertEqual(ph.first?.sourceStart, 0)
        XCTAssertEqual(ph.last?.sourceEnd, 10)
        // 目安が大きいと最後に短いフレーズが残る
        let ph2 = Remix.phrases(duration: 10, candidates: beats(every: 0.5, duration: 10), nominalPhraseDuration: 4)
        XCTAssertEqual(ph2.map(\.length), [4, 4, 2])
    }

    func testNominalPhraseDurationUsesMedianBeatTimesPhraseBeats() {
        let n = Remix.nominalPhraseDuration(duration: 20, candidates: beats(every: 0.5, duration: 20),
                                            params: RemixParams(targetDuration: 10, phraseBeats: 4), usedFallback: false)
        XCTAssertEqual(n, 2.0, accuracy: 1e-9, "0.5 秒間隔 × 4 拍 = 2 秒")
        let f = Remix.nominalPhraseDuration(duration: 20, candidates: [3, 7],
                                            params: RemixParams(targetDuration: 10, fallbackPhraseSeconds: 3), usedFallback: true)
        XCTAssertEqual(f, 3.0, accuracy: 1e-9, "フォールバックは設定の秒数")
    }

    // MARK: 計画(短縮)

    func testPlanShortensKeepingOrderOnBeatBoundaries() {
        let r = Remix.plan(duration: 20, candidates: beats(every: 0.5, duration: 20),
                           params: RemixParams(targetDuration: 10), usedFallback: false)
        let p = plan(r)
        XCTAssertLessThanOrEqual(abs(p.totalDuration - 10), 0.5, "目標 10 秒に tolerance 内で近づく")
        XCTAssertEqual(p.totalDuration, p.segments.map(\.length).reduce(0, +), accuracy: 1e-9)
        XCTAssertEqual(p.segments.first?.sourceStart, 0, "曲の頭から始める")
        // 区間の端はすべて候補境界(0.5 の倍数)に整列
        for s in p.segments {
            XCTAssertEqual(s.sourceStart.truncatingRemainder(dividingBy: 0.5), 0, accuracy: 1e-9, "開始がビート境界")
            XCTAssertEqual(s.sourceEnd.truncatingRemainder(dividingBy: 0.5), 0, accuracy: 1e-9, "終了がビート境界")
            XCTAssertGreaterThan(s.length, 0)
        }
        // 短縮では繰り返しなし・順序保持(区間の開始が単調)
        let starts = p.segments.map(\.sourceStart)
        XCTAssertEqual(starts, starts.sorted(), "元の順序を保つ")
        XCTAssertEqual(Set(starts).count, starts.count, "同じ区間を繰り返さない")
        XCTAssertFalse(p.usedFallback)
    }

    func testPlanExactDurationIsSingleSegment() {
        let p = plan(Remix.plan(duration: 20, candidates: beats(every: 0.5, duration: 20),
                                params: RemixParams(targetDuration: 20), usedFallback: false))
        XCTAssertEqual(p.segments.count, 1)
        XCTAssertEqual(p.segments[0].sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(p.segments[0].sourceEnd, 20, accuracy: 1e-9)
        XCTAssertEqual(p.totalDuration, 20, accuracy: 1e-9)
    }

    // MARK: 計画(延長)

    func testPlanLengthensByRepeatingPhrases() {
        let p = plan(Remix.plan(duration: 10, candidates: beats(every: 0.5, duration: 10),
                                params: RemixParams(targetDuration: 24), usedFallback: false))
        XCTAssertLessThanOrEqual(abs(p.totalDuration - 24), 0.5, "目標 24 秒に tolerance 内で近づく")
        XCTAssertGreaterThan(p.selectedPhraseCount, 5, "元の 5 フレーズより多く選ぶ = 繰り返しが入る")
        XCTAssertGreaterThan(p.segments.count, 1, "周回をまたぐ接続は別区間になる")
        XCTAssertEqual(p.segments.first?.sourceStart, 0)
        for s in p.segments { XCTAssertTrue(s.sourceStart >= 0 && s.sourceEnd <= 10, "区間は素材の内側") }
    }

    // MARK: 計画(失敗)

    func testPlanFailures() {
        XCTAssertEqual(Remix.plan(duration: 20, candidates: [], params: RemixParams(targetDuration: 10), usedFallback: false),
                       .failure(.noCandidates), "候補が無ければ理由を返す")
        XCTAssertEqual(Remix.plan(duration: 20, candidates: beats(every: 0.5, duration: 20), params: RemixParams(targetDuration: 0), usedFallback: false),
                       .failure(.invalidTarget))
        XCTAssertEqual(Remix.plan(duration: 20, candidates: beats(every: 0.5, duration: 20), params: RemixParams(targetDuration: .nan), usedFallback: false),
                       .failure(.invalidTarget))
        // フレーズ 2 秒・tolerance 0.5 では 0.4 秒には近づけない
        XCTAssertEqual(Remix.plan(duration: 20, candidates: beats(every: 0.5, duration: 20), params: RemixParams(targetDuration: 0.4), usedFallback: false),
                       .failure(.cannotReachTarget), "大きく外れる計画は作らない")
    }

    func testPlanHugeTargetFailsWithoutHanging() {
        let r = Remix.plan(duration: 180, candidates: beats(every: 0.5, duration: 180), params: RemixParams(targetDuration: 1e9), usedFallback: false)
        guard case .failure = r else { return XCTFail("巨大な目標は失敗するはず") }
    }


    func testPlanRejectsUnsupportedClip() {
        var fast = audioClip(id: "a", start: 0, duration: 20)
        fast.speed = 2
        XCTAssertEqual(Remix.plan(source: fast, candidates: beats(every: 0.5, duration: 20),
                                  params: RemixParams(targetDuration: 10), usedFallback: false),
                       .failure(.unsupportedClip), "速度変更クリップは 1 対 1 でないので対象外")
        XCTAssertFalse(Remix.supports(fast))
        XCTAssertTrue(Remix.supports(audioClip(id: "a", start: 0, duration: 20)))
    }

    func testPlanIsDeterministic() {
        let args = (duration: 30.0, candidates: beats(every: 0.4, duration: 30), params: RemixParams(targetDuration: 17), usedFallback: false)
        XCTAssertEqual(Remix.plan(duration: args.duration, candidates: args.candidates, params: args.params, usedFallback: args.usedFallback),
                       Remix.plan(duration: args.duration, candidates: args.candidates, params: args.params, usedFallback: args.usedFallback))
    }

    // MARK: フォールバック候補

    static let sr = 48000.0

    /// 無音の中に 2 秒ごとに 0.3 秒のバースト(1 kHz)を置いた合成音。
    func burstTrack(seconds: Double, every: Double = 2) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * Self.sr))
        var t = 0.0
        while t < seconds {
            let s0 = Int((t * Self.sr).rounded())
            for j in 0..<Int(0.3 * Self.sr) where s0 + j < x.count {
                x[s0 + j] = Float(0.8 * sin(2 * Double.pi * 1000 * Double(j) / Self.sr))
            }
            t += every
        }
        return x
    }

    func testFallbackCandidatesFindSilenceBoundariesAndOnsets() {
        let prof = SilenceDetector.profile(left: burstTrack(seconds: 10), sampleRate: Self.sr)
        let cs = RemixFallback.candidates(profile: prof)
        XCTAssertFalse(cs.isEmpty)
        for truth in [2.0, 4.0, 6.0, 8.0] {
            let nearest = cs.map { abs($0 - truth) }.min() ?? .infinity
            XCTAssertLessThanOrEqual(nearest, 0.06, "バースト開始 \(truth) 秒の近くに候補がある (差 \(nearest))")
        }
        XCTAssertEqual(cs, cs.sorted())
        for c in cs { XCTAssertTrue(c > 0 && c < 10) }
    }

    func testFallbackCandidatesEmptyForSilenceAndConstantLevel() {
        let silence = SilenceDetector.profile(left: [Float](repeating: 0, count: Int(5 * Self.sr)), sampleRate: Self.sr)
        XCTAssertEqual(RemixFallback.candidates(profile: silence), [], "全て無音では候補なし")
        let constant = LevelProfile(levels: [Float](repeating: -20, count: 500), duration: 5)
        XCTAssertEqual(RemixFallback.candidates(profile: constant), [], "一定音量(変化なし)では候補なし")
    }

    func testPlanWithFallbackCandidates() {
        // 不規則な候補(無音の切り替わり想定)でも計画できる
        let candidates = [1.3, 3.1, 4.0, 6.2, 7.5, 9.9, 12.4, 14.0, 16.8, 18.2]
        let p = plan(Remix.plan(duration: 20, candidates: candidates,
                                params: RemixParams(targetDuration: 9, fallbackPhraseSeconds: 2), usedFallback: true))
        XCTAssertTrue(p.usedFallback)
        XCTAssertLessThanOrEqual(abs(p.totalDuration - 9), max(0.2, 2.0 * 0.25) + 1e-9)
        let bounds = Set(Remix.boundaries(duration: 20, candidates: candidates))
        for s in p.segments {
            XCTAssertTrue(bounds.contains(s.sourceStart), "区間の開始は候補境界")
            XCTAssertTrue(bounds.contains(s.sourceEnd), "区間の終了は候補境界")
        }
    }

    // MARK: クリップ列(クロスフェード)

    func testClipsApplyEqualPowerCrossfadePairsAndKeepSourceUntouched() {
        let src = audioClip(id: "a", start: 5, duration: 20, offset: 10)
        let before = src
        // 区間の長さが不揃いな素材で、連続した区間だけでは 7 秒にできない組み合わせにする
        // (フレーズ長 3,2,4,2,4,2,3。連続区間の合計は 5,6,8,9,10…で 7 にはならない)
        let p = plan(Remix.plan(duration: 20, candidates: [3, 5, 9, 11, 15, 17],
                                params: RemixParams(targetDuration: 7, crossfadeDuration: 0.1, fallbackPhraseSeconds: 0.5), usedFallback: true))
        XCTAssertGreaterThanOrEqual(p.segments.count, 2, "このテストは複数区間が前提")
        let made = try! XCTUnwrap(Remix.clips(source: src, plan: p, startAt: 100))
        XCTAssertEqual(made.count, p.segments.count)
        XCTAssertEqual(made.map(\.duration).reduce(0, +), p.totalDuration, accuracy: 1e-9)
        for (i, c) in made.enumerated() {
            XCTAssertEqual(c.offset, 10 + p.segments[i].sourceStart, accuracy: 1e-9, "素材位置 = 元 offset + 区間開始")
            XCTAssertEqual(c.start, i == 0 ? 100 : made[i - 1].start + made[i - 1].duration, accuracy: 1e-9, "隙間なく連続配置")
            XCTAssertNotEqual(c.id, "a")
        }
        XCTAssertEqual(Set(made.map(\.id)).count, made.count, "id は一意")
        // つなぎ目: 前の fadeOut と次の fadeIn が同じ長さ・等パワー
        for i in 1..<made.count {
            let cf = min(0.1, 0.5 * min(made[i - 1].duration, made[i].duration))
            XCTAssertEqual(made[i - 1].fadeOut ?? 0, cf, accuracy: 1e-9)
            XCTAssertEqual(made[i].fadeIn ?? 0, cf, accuracy: 1e-9)
            XCTAssertEqual(made[i - 1].fadeCurve, "equalPower")
            XCTAssertEqual(made[i].fadeCurve, "equalPower")
        }
        XCTAssertEqual(src, before, "元クリップは変更しない")
    }

    func testClipsWithZeroCrossfadeAddNoFades() {
        let src = audioClip(id: "a", start: 0, duration: 20)
        let p = plan(Remix.plan(duration: 20, candidates: beats(every: 0.5, duration: 20),
                                params: RemixParams(targetDuration: 6, crossfadeDuration: 0), usedFallback: false))
        let made = try! XCTUnwrap(Remix.clips(source: src, plan: p, startAt: 0))
        for c in made { XCTAssertFalse(c.hasAudioFade, "クロスフェード 0 ではフェードを付けない") }
    }

    // MARK: 組み立て(配置)

    func projectWithSource() -> Project {
        var p = Project.new()
        var tr = Track(name: "音")
        tr.clips = [audioClip(id: "a", start: 0, duration: 20, offset: 0),
                    audioClip(id: "b", start: 30, duration: 5)]
        p.tracks = [tr]
        return p
    }

    func testAssembleAppendsToSourceTrackEndAndKeepsOriginal() throws {
        let p = projectWithSource()
        let r = try XCTUnwrap({ () -> (Project, [String], RemixPlan)? in
            switch Remix.assemble(in: p, sourceClipId: "a", candidates: beats(every: 0.5, duration: 20),
                                  params: RemixParams(targetDuration: 10), usedFallback: false) {
            case .success(let v): return v
            case .failure(let e): XCTFail("組み立て失敗: \(e)"); return nil
            }
        }())
        let clips = r.0.tracks[0].clips.sorted { $0.start < $1.start }
        let original = try XCTUnwrap(clips.first { $0.id == "a" })
        XCTAssertEqual(original, p.tracks[0].clips[0], "元クリップはそのまま")
        let made = clips.filter { r.1.contains($0.id) }
        XCTAssertEqual(try XCTUnwrap(made.first).start, 35, accuracy: 1e-9, "レイヤーの末尾 (b の終わり 35 秒) から配置")
        XCTAssertEqual(made.map(\.duration).reduce(0, +), r.2.totalDuration, accuracy: 1e-9)
        // 同じレイヤーで重ならない
        for i in 1..<clips.count {
            XCTAssertGreaterThanOrEqual(clips[i].start, clips[i - 1].start + clips[i - 1].duration - 1e-9, "重なりなし")
        }
    }

    func testAssembleFailsOnLockedTrack() {
        var p = projectWithSource()
        p.tracks[0].locked = true
        switch Remix.assemble(in: p, sourceClipId: "a", candidates: beats(every: 0.5, duration: 20),
                              params: RemixParams(targetDuration: 10), usedFallback: false) {
        case .success: XCTFail("ロックされたレイヤーには置けない")
        case .failure(let e): XCTAssertEqual(e, .lockedOrBlocked)
        }
    }

    func testParamsClamped() {
        let p = RemixParams(targetDuration: 10, crossfadeDuration: 99, phraseBeats: 0, fallbackPhraseSeconds: -1).clamped
        XCTAssertEqual(p.crossfadeDuration, 0.5)
        XCTAssertEqual(p.phraseBeats, 1)
        XCTAssertEqual(p.fallbackPhraseSeconds, 0.5)
        XCTAssertEqual(RemixParams(targetDuration: 10, crossfadeDuration: .nan).clamped.crossfadeDuration, 0.1)
    }
}
