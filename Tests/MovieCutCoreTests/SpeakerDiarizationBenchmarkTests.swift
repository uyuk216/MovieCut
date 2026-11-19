import XCTest
@testable import MovieCutCore

/// 話者分離の精度ベンチマーク(R6-1)。
/// 特徴と正解ラベルが既知の合成シナリオで、クラスタリングの正しさを数値で測る。
/// 指標: ペアワイズF1(同じ話者のペアを同じクラスタに入れられたか)、
/// 最適対応づけ後の区間誤り率、話者数の誤差。決定的であることも確認する。
private extension AcousticFeatures {
    func withBands(_ bands: [Double]) -> AcousticFeatures {
        var f = self; f.spectralBands = bands; return f
    }
}

final class SpeakerDiarizationBenchmarkTests: XCTestCase {

    private func f(_ f0: Double, _ centroid: Double, spread: Double = 10, zcr: Double = 0.05,
                   rms: Double = 0.3, dur: Double = 1.0) -> AcousticFeatures {
        AcousticFeatures(meanF0: f0, f0Spread: spread, rms: rms, spectralCentroid: centroid,
                         zeroCrossingRate: zcr, duration: dur)
    }

    struct Scenario { let name: String; let feats: [AcousticFeatures]; let truth: [Int] }

    private func scenarios() -> [Scenario] {
        [
            Scenario(name: "basic", feats: [
                f(120, 800), f(124, 820), f(240, 1500), f(236, 1480), f(118, 790), f(242, 1520),
            ], truth: [0, 0, 1, 1, 0, 1]),
            Scenario(name: "volume", feats: [
                f(120, 800, rms: 0.45), f(121, 810, rms: 0.04), f(119, 795, rms: 0.5),
                f(122, 805, rms: 0.035), f(240, 1500, rms: 0.3), f(238, 1490, rms: 0.28),
            ], truth: [0, 0, 0, 0, 1, 1]),
            Scenario(name: "silence", feats: [
                f(120, 800), f(0, 0, spread: 0, zcr: 0.01, rms: 0.001), f(123, 815),
                f(240, 1500), f(0, 0, spread: 0, zcr: 0.01, rms: 0.001), f(237, 1495),
            ], truth: [0, 0, 0, 1, 1, 1]),
            Scenario(name: "shortBlip", feats: [
                f(120, 800), f(122, 810), f(205, 1350, spread: 30, dur: 0.15),
                f(121, 805), f(119, 798), f(240, 1500), f(238, 1490),
            ], truth: [0, 0, 0, 0, 0, 1, 1]),
            Scenario(name: "spread", feats: [
                f(150, 900, spread: 8), f(152, 910, spread: 9), f(148, 895, spread: 7),
                f(150, 1000, spread: 45), f(149, 990, spread: 50), f(151, 1010, spread: 42),
            ], truth: [0, 0, 0, 1, 1, 1]),
            Scenario(name: "bands", feats: [
                // 声の高さ・重心・抑揚が同じで、帯域配分(声質の形)だけが違う 2 人。
                // 旧特徴空間には帯域配分が無く、距離 0 で同一話者に統合されていた。
                f(150, 1000, spread: 15).withBands([0.72, 0.18, 0.07, 0.03]),
                f(152, 1010, spread: 16).withBands([0.70, 0.19, 0.08, 0.03]),
                f(150, 1000, spread: 15).withBands([0.28, 0.34, 0.24, 0.14]),
                f(148, 990, spread: 14).withBands([0.26, 0.35, 0.25, 0.14]),
            ], truth: [0, 0, 1, 1]),
            Scenario(name: "drift", feats: [
                f(120, 800), f(128, 830), f(136, 860), f(145, 890), f(154, 920), f(164, 950),
                f(260, 1600), f(258, 1590),
            ], truth: [0, 0, 0, 0, 0, 0, 1, 1]),
        ]
    }

    /// ペアワイズF1: 同じ話者のペア / 同じクラスタのペアの一致度。
    private func pairwiseF1(cluster: [Int], truth: [Int]) -> Double {
        var tp = 0, fp = 0, fn = 0
        for i in truth.indices { for j in truth.indices where j > i {
            let sameT = truth[i] == truth[j], sameC = cluster[i] == cluster[j]
            if sameT && sameC { tp += 1 } else if !sameT && sameC { fp += 1 } else if sameT && !sameC { fn += 1 }
        } }
        if tp == 0 { return (fp == 0 && fn == 0) ? 1 : 0 }
        return 2 * Double(tp) / Double(2 * tp + fp + fn)
    }

    /// クラスタ→話者の最適対応づけ(総当たり)後の区間正解率。
    private func bestAccuracy(cluster: [Int], truth: [Int]) -> Double {
        let clusters = Array(Set(cluster)).sorted()
        let labels = Array(Set(truth)).sorted()
        var best = 0
        func rec(_ ci: Int, _ map: [Int: Int]) {
            if ci == clusters.count {
                let ok = zip(cluster, truth).filter { map[$0.0] == $0.1 }.count
                best = max(best, ok); return
            }
            for l in labels { var m = map; m[clusters[ci]] = l; rec(ci + 1, m) }
        }
        rec(0, [:])
        return truth.isEmpty ? 1 : Double(best) / Double(truth.count)
    }

    private func run(_ s: Scenario) -> [Int] {
        let segments = s.feats.indices.map { TranscriptSegment(text: "文\($0)", start: Double($0), end: Double($0) + 1) }
        return AcousticClusterDiarizer().diarize(segments: segments, features: s.feats,
                                                 options: DiarizationOptions()).map(\.speaker)
    }

    func testBenchmarkReport() {
        var f1s: [Double] = []
        for s in scenarios() {
            let got = run(s)
            let f1 = pairwiseF1(cluster: got, truth: s.truth)
            let acc = bestAccuracy(cluster: got, truth: s.truth)
            let countErr = abs(Set(got).count - Set(s.truth).count)
            f1s.append(f1)
            print("BENCH \(s.name): F1=\(String(format: "%.3f", f1)) acc=\(String(format: "%.3f", acc)) countErr=\(countErr) got=\(got) truth=\(s.truth)")
        }
        let mean = f1s.reduce(0, +) / Double(f1s.count)
        print("BENCH MEAN F1=\(String(format: "%.3f", mean))")
    }

    func testBenchmarkCoreScenariosArePerfect() {
        // 改善の対象シナリオ(基本・音量変化・無音・短い区間・抑揚差)は完全分離を目標にする
        for s in scenarios() where ["basic", "volume", "silence", "shortBlip", "spread", "bands"].contains(s.name) {
            let got = run(s)
            XCTAssertEqual(pairwiseF1(cluster: got, truth: s.truth), 1.0, accuracy: 1e-9,
                           "\(s.name): got=\(got) truth=\(s.truth)")
            XCTAssertEqual(Set(got).count, Set(s.truth).count, "\(s.name) の話者数")
        }
    }

    func testBenchmarkDeterministic() {
        for s in scenarios() {
            XCTAssertEqual(run(s), run(s), "\(s.name) は決定的でなければならない")
        }
    }
}
