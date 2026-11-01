import XCTest
@testable import MovieCutCore

/// ラウドネス計測(BS.1770)。合成信号の理論値と比べる。公式の適合音源(EBU 3341 など)ではまだ確かめていない。
///
/// 理論値の出し方: 1 kHz の正弦波(振幅 A)の二乗平均は A²/2。K 特性の 1 kHz のゲインは +0.698 dB(係数から計算)。
/// LUFS = −0.691 + 10·log10(Σ チャンネルの G·二乗平均)。G は左右とも 1。
/// - 片側だけ(モノラル 1 ch)、ピーク −20 dBFS(A = 0.1): −0.691 + 10·log10(0.005 × 1.1745) ≈ −23.00 LUFS
/// - 左右が同じ(ステレオ 2 ch): 同じ値に +3.01 dB → ≈ −19.99 LUFS
/// 「−20 dBFS の 1 kHz 正弦波 ≒ −23 LUFS」は、片側(モノラル)として測ったときの値。
/// 本アプリのミックスはステレオなので、モノラル素材を左右に複製すると 3 dB 大きく出る。
final class LoudnessTests: XCTestCase {
    private func sine(hz: Double, amplitude: Double, seconds: Double, phase: Double = 0) -> [Float] {
        let n = Int(seconds * 48_000)
        return (0..<n).map { i in Float(amplitude * sin(2 * Double.pi * hz * Double(i) / 48_000 + phase)) }
    }

    /// 左右の信号を流して測る。
    private func measure(left: [Float], right: [Float]) -> LoudnessReport {
        let meter = LoudnessMeter()
        left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
            var i = 0
            while i < l.count {
                let n = min(4096, l.count - i)
                meter.add(l.baseAddress! + i, r.baseAddress! + i, n)
                i += n
            }
        } }
        return meter.finish()
    }

    private let mono = -23.00      // 片側だけ・−20 dBFS の 1 kHz 正弦波
    private let stereo = -19.99    // 左右同じ

    func testOneChannelSineAtMinus20dBFSIsAboutMinus23LUFS() {
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 10)
        let r = measure(left: x, right: [Float](repeating: 0, count: x.count))
        XCTAssertEqual(r.integrated, mono, accuracy: 0.3, "片側だけ(モノラル相当)")
        XCTAssertEqual(r.shortTermMax, mono, accuracy: 0.3)
        XCTAssertEqual(r.samplePeakDb, -20.0, accuracy: 0.05)
        XCTAssertEqual(r.duration, 10, accuracy: 0.01)
    }

    func testStereoSameSignalIsThreeDBLouder() {
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 10)
        let r = measure(left: x, right: x)
        XCTAssertEqual(r.integrated, stereo, accuracy: 0.3, "左右同相は 2 ch ぶん(+3.01 dB)")
        XCTAssertEqual(r.integrated - measure(left: x, right: [Float](repeating: 0, count: x.count)).integrated, 3.01, accuracy: 0.1)
    }

    func testFullScaleStereoIsAboutZeroLUFS() {
        // 振幅 1.0 の両チャンネル: −0.691 + 10·log10(2 × 0.5 × 1.1745) ≈ 0.0 LUFS
        let x = sine(hz: 1000, amplitude: 1.0, seconds: 6)
        XCTAssertEqual(measure(left: x, right: x).integrated, 0.0, accuracy: 0.3)
    }

    func testSilenceIsMinusInfinity() {
        let z = [Float](repeating: 0, count: 48_000 * 5)
        let r = measure(left: z, right: z)
        XCTAssertEqual(r.integrated, -.infinity)
        XCTAssertEqual(r.shortTermMax, -.infinity)
        XCTAssertEqual(r.truePeakDb, -.infinity)
        XCTAssertNil(r.differenceToYouTube())
    }

    func testAbsoluteGateIgnoresVeryQuietPart() {
        // 前 8 秒は −20 dBFS、後の 8 秒は −90 LUFS 付近(絶対ゲート −70 LUFS より下)。統合は前半だけで決まる。
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 8) + sine(hz: 1000, amplitude: 0.1 * pow(10, -70.0 / 20), seconds: 8)
        let r = measure(left: x, right: x)
        XCTAssertEqual(r.integrated, stereo, accuracy: 0.3, "絶対ゲートで静かな後半が除かれる(境目の数区間は少しだけ影響)")
    }

    func testRelativeGateRemovesSectionTenLUQuieter() {
        // 前 8 秒 −20 dBFS、後 8 秒は −35 dBFS 付近(相対ゲート −10 LU より下 → 除かれる)
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 8) + sine(hz: 1000, amplitude: 0.1 * pow(10, -15.0 / 20), seconds: 8)
        let r = measure(left: x, right: x)
        XCTAssertEqual(r.integrated, stereo, accuracy: 0.3, "相対ゲートで −10 LU 以下の区間が除かれる")
    }

    func testTruePeakExceedsSamplePeakForQuarterRateSine() {
        // fs/4(12 kHz)・位相 45°: 標本は ±0.707 しか取らないが、真のピークは 1.0(0 dBTP)
        let x = sine(hz: 12_000, amplitude: 1.0, seconds: 1, phase: .pi / 4)
        let r = measure(left: x, right: x)
        XCTAssertEqual(r.samplePeakDb, -3.01, accuracy: 0.05)
        XCTAssertEqual(r.truePeakDb, 0.0, accuracy: 0.3, "4 倍オーバーサンプリングで山の間を拾う")
        XCTAssertGreaterThan(r.truePeakDb, r.samplePeakDb + 2.5)
    }

    func testTruePeakOfOneKHzSine() {
        let x = sine(hz: 1000, amplitude: 0.5, seconds: 1)
        XCTAssertEqual(measure(left: x, right: x).truePeakDb, -6.02, accuracy: 0.1)
    }

    func testDifferenceToYouTubeIsOnlyAHint() {
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 6)
        let r = measure(left: x, right: x)
        XCTAssertEqual(r.differenceToYouTube() ?? .nan, stereo + 14, accuracy: 0.3)
    }

    func testShortTermNeedsThreeSeconds() {
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 2)
        XCTAssertEqual(measure(left: x, right: x).shortTermMax, -.infinity)
    }

    func testReportIsDeterministic() {
        let x = sine(hz: 440, amplitude: 0.3, seconds: 3)
        XCTAssertEqual(measure(left: x, right: x), measure(left: x, right: x))
    }
}
