import XCTest
@testable import MovieCutCore

/// 2026-11-02 候補表 18・20・21 の純粋な計算。
final class PartBRound4Tests: XCTestCase {
    // MARK: 18 ハイライト圧縮

    func testRolloffIsIdentityBelowKnee() {
        for v in stride(from: 0.0, through: 0.8, by: 0.05) {
            XCTAssertEqual(HighlightRolloff.apply(v, knee: 0.8), v, accuracy: 1e-12)
        }
    }

    func testRolloffIsMonotonicAndStaysBelowOne() {
        var prev = -1.0
        for i in 0...1000 {
            let out = HighlightRolloff.apply(Double(i) / 1000, knee: 0.8)
            XCTAssertGreaterThanOrEqual(out, prev)
            XCTAssertLessThan(out, 1.0 + 1e-12)
            prev = out
        }
        XCTAssertLessThan(HighlightRolloff.apply(1, knee: 0.8), 1)
    }

    func testRolloffIsContinuousAtKnee() {
        let k = 0.7
        let just = HighlightRolloff.apply(k + 1e-9, knee: k)
        XCTAssertEqual(just, k, accuracy: 1e-6)
    }

    func testRolloffHandlesBadInputs() {
        XCTAssertEqual(HighlightRolloff.apply(.nan), 0)
        XCTAssertEqual(HighlightRolloff.apply(-0.5), 0)
        XCTAssertEqual(HighlightRolloff.apply(2), HighlightRolloff.apply(1))
        XCTAssertEqual(HighlightRolloff.clampKnee(.infinity), HighlightRolloff.defaultKnee)
        XCTAssertEqual(HighlightRolloff.clampKnee(1.5), 0.99)
    }

    func testRolloffTableHasEndpointsAndSize() {
        let t = HighlightRolloff.table(size: 256)
        XCTAssertEqual(t.count, 256)
        XCTAssertEqual(t.first ?? -1, 0, accuracy: 1e-12)
        XCTAssertLessThan(t.last ?? 2, 1)
        XCTAssertEqual(HighlightRolloff.table(size: 0).count, 2)
    }

    // MARK: 20 立ち絵の欠落

    func testMissingExpressionTagsListsAbsentAndEmptyPaths() {
        let exp = ["笑顔": "/c/smile.png", "怒り": "/c/angry.png", "泣き": "/c/cry.png", "無": ""]
        let present: Set<String> = ["/c/smile.png", "/c/cry.png"]
        let missing = CharacterPartCheck.missingExpressionTags(exp) { present.contains($0) }
        XCTAssertEqual(missing, ["怒り", "無"])
    }

    func testMissingExpressionTagsEmptyWhenAllPresent() {
        let exp = ["笑顔": "/c/smile.png"]
        XCTAssertEqual(CharacterPartCheck.missingExpressionTags(exp) { _ in true }, [])
        XCTAssertEqual(CharacterPartCheck.missingExpressionTags([:]) { _ in false }, [])
    }

    // MARK: 21 元素材上の使用区間

    private func media(offset: Double, duration: Double, speed: Double? = nil, srcDuration: Double? = 20, type: ClipType = .video) -> Clip {
        var c = Clip()
        c.type = type
        c.offset = offset
        c.duration = duration
        c.speed = speed
        c.srcDuration = srcDuration
        return c
    }

    func testSourceUsageIsOffsetToOffsetPlusSpan() {
        let r = SourceUsage.range(of: media(offset: 2, duration: 4, speed: 2))
        XCTAssertEqual(r?.start ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(r?.end ?? -1, 10, accuracy: 1e-9)
    }

    func testSourceUsageClampsToSourceDuration() {
        let r = SourceUsage.range(of: media(offset: 2, duration: 10, srcDuration: 6))
        XCTAssertEqual(r?.end ?? -1, 6, accuracy: 1e-9)
    }

    func testSourceUsageNilForFreezeImageAndEmpty() {
        var freeze = media(offset: 1, duration: 3)
        freeze.freeze = true
        XCTAssertNil(SourceUsage.range(of: freeze))
        XCTAssertNil(SourceUsage.range(of: media(offset: 0, duration: 0)))
        XCTAssertNil(SourceUsage.range(of: media(offset: 0, duration: 3, type: .image)))
    }
}
