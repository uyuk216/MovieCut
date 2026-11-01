import XCTest
import AVFoundation
@testable import MovieCutCore

/// 速度ランプの音声: 出力の各コマが、積分で決まる素材の位置の値を読んでいること。
/// 素材の値を「その時刻(秒)」にしておくと、出力のコマ k の値は ∫₀^(k/sr) speed の値になる(直線補間なので誤差は小さい)。
final class SpeedRampAudioTests: XCTestCase {
    /// 値が「素材の時刻(秒)」の合成音源。位置は読むたびに進む。
    final class TimeSource: PCMSource {
        var pos = 0
        let total: Int
        let offsetSec: Double
        init(total: Int, offsetSec: Double) { self.total = total; self.offsetSec = offsetSec }
        func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
            let n = max(0, min(frames, total - pos))
            for i in 0..<n {
                let v = Float(offsetSec + Double(pos + i) / 48000)
                left[i] = v; right[i] = v
            }
            pos += n
            return n
        }
    }

    func testRampOutputFollowsIntegralOfSpeed() throws {
        var c = Clip(); c.id = "a"; c.type = .audio; c.src = "/tmp/none.wav"; c.start = 0; c.duration = 1; c.offset = 0.5
        c.srcDuration = 10
        c.speedRamp = [SpeedKey(t: 0, v: 1), SpeedKey(t: 1, v: 0.25)]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ramp-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try AudioRemap.render(clip: c, open: { _, off, span in
            // 素材の範囲 [offset, offset + span] を読む。値は素材の絶対時刻(秒)
            TimeSource(total: Int((span + 0.1) * 48000), offsetSec: off)
        }, in: dir)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 48000, "出力の長さはタイムラインの長さ(1 秒)")
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000))
        try file.read(into: buf)
        let ch = try XCTUnwrap(buf.floatChannelData)
        // 出力のコマ k(時刻 k/sr)の値 = offset + ∫₀^t speed。どのコマも 1e-3 秒以内
        for k in stride(from: 0, to: 48000, by: 997) {
            let t = Double(k) / 48000
            let want = 0.5 + SpeedRamp.integral(c.speedRamp!, upTo: t)
            XCTAssertEqual(Double(ch[0][k]), want, accuracy: 1e-3, "コマ \(k)")
        }
        XCTAssertEqual(Double(ch[0][47999]), 0.5 + SpeedRamp.integral(c.speedRamp!, upTo: 47999.0 / 48000), accuracy: 1e-3)
    }
}
