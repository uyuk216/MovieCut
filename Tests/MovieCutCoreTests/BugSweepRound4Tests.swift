import XCTest
@testable import MovieCutCore

/// 2026-11-02 バッチ 4 の不具合掃除。先に失敗するテストを書いてから直した。
final class BugSweepRound4Tests: XCTestCase {
    private func fiveLayers() -> Project {
        var p = Project()
        p.tracks = (1...5).map { Track(name: "レイヤー\($0)") }
        return p
    }

    private func clip(_ id: String, start: Double, duration: Double) -> Clip {
        var c = Clip()
        c.id = id
        c.type = .text
        c.start = start
        c.duration = duration
        return c
    }

    /// 一番上のレイヤーに重なる区間で追加すると、同じレイヤーで重なっていた(以前は末尾に足すだけ)。
    func testAppendToTopLayerNeverOverlapsOnTopLayer() {
        var p = fiveLayers()
        let top = p.tracks.count - 1
        p.tracks[top].clips.append(clip("old", start: 0, duration: 10))
        ClipEditing.appendToTopLayer(clip("new", start: 2, duration: 3), in: &p)
        assertNoLayerOverlaps(p)
        XCTAssertNotNil(p.allClips.first { $0.id == "new" })
    }

    /// 一番上が空いていれば、以前どおり一番上へ入る(古い書類の見た目を変えない)。
    func testAppendToTopLayerStillUsesTopWhenFree() {
        var p = fiveLayers()
        ClipEditing.appendToTopLayer(clip("n", start: 2, duration: 3), in: &p)
        XCTAssertEqual(p.tracks[p.tracks.count - 1].clips.map(\.id), ["n"])
    }

    /// 全レイヤーが塞がっているなら、新しいレイヤーを足して、そこへ置く。
    func testAppendToTopLayerAddsLayerWhenAllBusy() {
        var p = fiveLayers()
        for i in p.tracks.indices { p.tracks[i].clips.append(clip("b\(i)", start: 0, duration: 10)) }
        ClipEditing.appendToTopLayer(clip("n", start: 2, duration: 3), in: &p)
        XCTAssertEqual(p.tracks.count, 6)
        assertNoLayerOverlaps(p)
        XCTAssertEqual(p.tracks[5].clips.map(\.id), ["n"])
    }

    /// 一番上がロックされていれば、ロックされていない新しいレイヤーを一番上に足して、そこへ置く(ロックには足さない)。
    func testAppendToTopLayerSkipsLockedTopByAddingLayer() {
        var p = fiveLayers()
        p.tracks[4].locked = true
        ClipEditing.appendToTopLayer(clip("n", start: 2, duration: 3), in: &p)
        XCTAssertTrue(p.tracks[4].clips.isEmpty)
        XCTAssertEqual(p.tracks.count, 6)
        XCTAssertEqual(p.tracks[5].clips.map(\.id), ["n"])
        assertNoLayerOverlaps(p)
    }
}

extension BugSweepRound4Tests {
    /// 背景を抜く: 書いた PNG がどのクリップからも使われていなければ「残骸」として返す(差し替えに失敗したときに消す)。
    func testCutoutOrphanDetectedWhenNoClipUsesIt() {
        var p = Project()
        var c = Clip(); c.id = "img"; c.type = .image; c.src = "/cache/img-1.png"
        p.tracks = [Track(name: "レイヤー1")]
        p.tracks[0].clips = [c]
        let orphans = CutoutCache.unreferenced(["/cache/img-1.png", "/cache/img-2.png"], in: p)
        XCTAssertEqual(orphans, ["/cache/img-2.png"])
    }
}
