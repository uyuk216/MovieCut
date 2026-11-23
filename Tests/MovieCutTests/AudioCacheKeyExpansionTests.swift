import XCTest
import MovieCutCore
@testable import MovieCut

/// A01: 再生ミックスのキャッシュ鍵は、ミキサーと同じ展開(入れ子・トラックミキサー・
/// チャンネル選択・無効化)を反映しなければならない。
final class AudioCacheKeyExpansionTests: XCTestCase {
    private let dates: (String) -> Date? = { _ in nil }

    private func audioClip(_ id: String, src: String = "/a.wav") -> Clip {
        var c = Clip(); c.id = id; c.type = .audio; c.src = src; c.start = 0; c.duration = 3
        return c
    }

    func testKeyChangesWhenNestedClipMoves() {
        var inner = Track(); inner.clips = [audioClip("n")]
        var comp = Clip(); comp.type = .compound; comp.start = 0; comp.duration = 3; comp.tracks = [inner]
        var top = Track(); top.clips = [comp]
        var p = Project(); p.tracks = [top]
        let k1 = AudioCacheKey.make(for: p, fileDate: dates)
        var inner2 = Track(); var moved = audioClip("n"); moved.start = 1; inner2.clips = [moved]
        var comp2 = comp; comp2.tracks = [inner2]
        var top2 = Track(); top2.clips = [comp2]
        var p2 = Project(); p2.tracks = [top2]
        XCTAssertNotEqual(k1, AudioCacheKey.make(for: p2, fileDate: dates), "複合内の音の移動で鍵が変わる")
    }

    func testKeyChangesWithTrackVolumeAndChannelModeAndDisable() {
        var t = Track(); t.clips = [audioClip("a")]
        var p = Project(); p.tracks = [t]
        let k0 = AudioCacheKey.make(for: p, fileDate: dates)

        var pVol = p; pVol.tracks[0].volume = 0.5
        XCTAssertNotEqual(k0, AudioCacheKey.make(for: pVol, fileDate: dates), "トラック音量で鍵が変わる")

        var pCh = p; pCh.tracks[0].clips[0].channelMode = .center
        XCTAssertNotEqual(k0, AudioCacheKey.make(for: pCh, fileDate: dates), "チャンネル選択で鍵が変わる")

        var pOff = p; pOff.tracks[0].clips[0].disabled = true
        XCTAssertNotEqual(k0, AudioCacheKey.make(for: pOff, fileDate: dates), "無効化で鍵が変わる")
    }
}
