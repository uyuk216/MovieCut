import Foundation
import AVFoundation

// MARK: - 話者分離(W3-27 / YMM4監査 #75)
//
// 文字起こし(Whisper / 音声認識)の区間結果に、話者ラベル(話者1・話者2…)を付ける土台。
//
// 方式と限界(正直な明示):
// - 実用的な話者埋め込みモデル(学習型)は同梱できないため、ここでの分離は
//   音響特徴(基本周波数・そのばらつき・スペクトル重心・帯域ごとの配分・
//   ゼロ交差率)の区間ごとの変化に基づくクラスタリングによる「簡易判定」
//   である。学習型の本格分離ではない。
// - R6-1 の精度改善: 音量は同一話者でも大きく変わるため同一性の判定からは
//   外し(無音の判定だけに使う)、F0 のばらつきと帯域配分を判定に加えた。
//   無音区間と短すぎる区間は新しい話者を作らず直前の話者に寄せ、重心の
//   計算にも混ぜない。重心は区間の長さで重み付けし、最後に再割り当てと
//   近いクラスタの統合で貪欲法の初期の誤りを正す。すべて決定的。
// - そのため、同じ話者の声色の変化(叫ぶ・ささやく等)や、似た声の別人を
//   取り違えることがある。ラベルは手動で直せる(UI / `SpeakerLabels`)。
// - 本格的な埋め込み型分離は未達。将来差し替えられるよう、判定は
//   `DiarizationEngine` プロトコルの境界の後ろに置いてある
//   (初期実装は `AcousticClusterDiarizer`)。
//
// 画面にも Undo にも依存しない。字幕・台本への反映も純粋関数として用意する。

/// 話者分離についての利用者向けの注意文(UI とドキュメントで共用する)。
public enum SpeakerDiarizationInfo {
    public static let limitationNotice = "話者分離は、声の高さ・音色の目安などの音響特徴による簡易判定です。学習型の話者分離ではないため、同じ人の声色の変化や、似た声の別人を取り違えることがあります。ラベルは手で直せます。"
}

/// 区間 1 件の音響特徴。純粋な値で、クラスタリングとテストの入力になる。
public struct AcousticFeatures: Equatable, Sendable {
    /// 平均の基本周波数(Hz)。無声・無音と判定した区間は 0。
    public var meanF0: Double
    /// 基本周波数のばらつき(標準偏差 Hz)。
    public var f0Spread: Double
    /// 音量(RMS。0〜1 目安)。
    public var rms: Double
    /// スペクトル重心(Hz)。音色の明るさの目安。
    public var spectralCentroid: Double
    /// ゼロ交差率(1 サンプルあたり。0〜1)。
    public var zeroCrossingRate: Double
    /// 区間の長さ(秒)。
    public var duration: Double
    /// スペクトルの帯域ごとのエネルギー配分(0〜1、合計おおよそ 1)。
    /// 帯域は `AcousticFeatureExtractor.spectralBandEdges` の区切りで 4 つ。
    /// 重心だけでは分からない「声質の形」の目安。測れなかった区間は空。
    public var spectralBands: [Double]

    public init(meanF0: Double, f0Spread: Double, rms: Double, spectralCentroid: Double, zeroCrossingRate: Double, duration: Double, spectralBands: [Double] = []) {
        self.meanF0 = meanF0; self.f0Spread = f0Spread; self.rms = rms
        self.spectralCentroid = spectralCentroid; self.zeroCrossingRate = zeroCrossingRate; self.duration = duration
        self.spectralBands = spectralBands
    }

    /// 声らしい区間か(基本周波数が取れている)。
    public var isVoiced: Bool { meanF0 > 0 }

    /// 無音とみなす区間か(音量が小さく、基本周波数も取れていない)。
    /// 話者の手がかりが無いので、分離では直前の話者に寄せる対象。
    public var isSilent: Bool { !isVoiced && rms < AcousticFeatureExtractor.voicedRMSThreshold }

    /// 短すぎる区間か。特徴が 1〜2 フレーム分しかなく不安定なので、
    /// 新しい話者の根拠にはせず、重心の計算にも混ぜない。
    public var isShort: Bool { duration > 0 && duration < 0.25 }
}

// MARK: - 音響特徴の抽出(サンプル列に対する純粋計算)

public enum AcousticFeatureExtractor {
    /// F0 探索の範囲(Hz)。
    public static let f0Range = 60.0...400.0
    /// これより小さい音量のフレームは無声として F0 を数えない。
    public static let voicedRMSThreshold = 0.02

    /// モノラルサンプルの [start, end)(秒)の区間の特徴を出す。区間が空・範囲外なら無音の特徴を返す。
    public static func features(samples: [Float], sampleRate: Double, start: Double, end: Double) -> AcousticFeatures {
        let rawDuration = end - start
        let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
        guard sampleRate > 0, sampleRate.isFinite, !samples.isEmpty, duration > 0 else {
            return AcousticFeatures(meanF0: 0, f0Spread: 0, rms: 0, spectralCentroid: 0, zeroCrossingRate: 0, duration: duration)
        }
        // 時刻→フレームの変換は、非有限・巨大な時刻でも整数変換で落とさず、範囲へ丸める。
        func frame(_ t: Double) -> Int {
            let v = (t * sampleRate).rounded()
            guard v.isFinite else { return v > 0 ? samples.count : 0 }
            if v <= 0 { return 0 }
            if v >= Double(samples.count) { return samples.count }
            return Int(v)
        }
        let a = frame(start)
        let b = min(max(a, frame(end)), samples.count)
        guard b > a else {
            return AcousticFeatures(meanF0: 0, f0Spread: 0, rms: 0, spectralCentroid: 0, zeroCrossingRate: 0, duration: duration)
        }
        let slice = Array(samples[a..<b])

        // 音量(RMS)
        var sumSq = 0.0
        for v in slice { sumSq += Double(v) * Double(v) }
        let rms = (sumSq / Double(slice.count)).squareRoot()

        // ゼロ交差率
        var crossings = 0
        for i in 1..<slice.count where (slice[i - 1] < 0) != (slice[i] < 0) { crossings += 1 }
        let zcr = Double(crossings) / Double(slice.count)

        // フレーム単位(約 128ms まで)に分けて F0 とスペクトル重心を集める
        let frameLen = min(slice.count, max(512, Int(min(sampleRate, 1e9) * 0.128)))
        let hop = max(1, frameLen / 2)
        var f0s: [Double] = []
        var centroids: [Double] = []
        var bandSets: [[Double]] = []
        var pos = 0
        while pos + frameLen <= slice.count {
            let frame = Array(slice[pos..<(pos + frameLen)])
            let frms = frameRMS(frame)
            if frms >= voicedRMSThreshold, let f0 = estimateF0(frame, sampleRate: sampleRate) {
                f0s.append(f0)
            }
            if frms >= voicedRMSThreshold, let s = spectrum(frame, sampleRate: sampleRate) {
                centroids.append(s.centroid)
                bandSets.append(s.bands)
            }
            pos += hop
        }
        // 区間が 1 フレームに満たないときは全体で 1 回だけ測る
        if f0s.isEmpty, centroids.isEmpty, rms >= voicedRMSThreshold {
            if let f0 = estimateF0(slice, sampleRate: sampleRate) { f0s.append(f0) }
            if let s = spectrum(slice, sampleRate: sampleRate) { centroids.append(s.centroid); bandSets.append(s.bands) }
        }

        let meanF0 = f0s.isEmpty ? 0 : f0s.reduce(0, +) / Double(f0s.count)
        let spread = f0s.count > 1 ? (f0s.reduce(0) { $0 + ($1 - meanF0) * ($1 - meanF0) } / Double(f0s.count)).squareRoot() : 0
        let centroid = centroids.isEmpty ? 0 : centroids.reduce(0, +) / Double(centroids.count)
        var bands: [Double] = []
        if let first = bandSets.first {
            bands = [Double](repeating: 0, count: first.count)
            for set in bandSets where set.count == bands.count {
                for i in bands.indices { bands[i] += set[i] }
            }
            for i in bands.indices { bands[i] /= Double(bandSets.count) }
        }
        return AcousticFeatures(meanF0: meanF0, f0Spread: spread, rms: rms,
                                spectralCentroid: centroid, zeroCrossingRate: zcr, duration: duration,
                                spectralBands: bands)
    }

    static func frameRMS(_ frame: [Float]) -> Double {
        guard !frame.isEmpty else { return 0 }
        var s = 0.0
        for v in frame { s += Double(v) * Double(v) }
        return (s / Double(frame.count)).squareRoot()
    }

    /// 自己相関による基本周波数の推定。有声らしいピークが無ければ nil。
    static func estimateF0(_ frame: [Float], sampleRate: Double) -> Double? {
        let n = frame.count
        guard n >= 64 else { return nil }
        let minLag = max(2, Int(sampleRate / f0Range.upperBound))
        let maxLag = min(n / 2, Int(sampleRate / f0Range.lowerBound))
        guard maxLag > minLag else { return nil }
        // 平均を引いてから自己相関(直流成分でピークが埋もれないように)
        let mean = frame.reduce(0, +) / Float(n)
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[i] = Double(frame[i] - mean) }
        var r0 = 0.0
        for v in x { r0 += v * v }
        guard r0 > 1e-9 else { return nil }
        var bestLag = -1
        var best = 0.0
        for lag in minLag...maxLag {
            var r = 0.0
            for i in 0..<(n - lag) { r += x[i] * x[i + lag] }
            let normalized = r / r0
            if normalized > best { best = normalized; bestLag = lag }
        }
        guard bestLag > 0, best > 0.35 else { return nil }
        return sampleRate / Double(bestLag)
    }

    /// 帯域の区切り(Hz)。この区切りで分けた 4 帯域のエネルギー配分を測る。
    public static let spectralBandEdges = [500.0, 1500.0, 3000.0]

    /// スペクトル重心(Hz)。Hann 窓 + DFT の大きさの重み付き平均。測れなければ nil。
    static func spectralCentroid(_ frame: [Float], sampleRate: Double) -> Double? {
        spectrum(frame, sampleRate: sampleRate)?.centroid
    }

    /// スペクトル重心と帯域ごとのエネルギー配分を 1 回の FFT で測る。測れなければ nil。
    static func spectrum(_ frame: [Float], sampleRate: Double) -> (centroid: Double, bands: [Double])? {
        let n = 1024   // 先頭 1024 サンプルで測る(区間の音色の目安として十分)
        guard frame.count >= 256 else { return nil }
        let m = min(n, frame.count)
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        for i in 0..<m {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(1, m - 1)))
            re[i] = Double(frame[i]) * w
        }
        fft(&re, &im)
        var weighted = 0.0, total = 0.0
        var bandTotals = [Double](repeating: 0, count: spectralBandEdges.count + 1)
        for k in 1..<(n / 2) {
            let mag = (re[k] * re[k] + im[k] * im[k]).squareRoot()
            let freq = Double(k) * sampleRate / Double(n)
            weighted += freq * mag
            total += mag
            var band = 0
            while band < spectralBandEdges.count, freq >= spectralBandEdges[band] { band += 1 }
            bandTotals[band] += mag
        }
        guard total > 1e-9 else { return nil }
        return (weighted / total, bandTotals.map { $0 / total })
    }

    /// 2 の冪サイズの反復 FFT(実部・虚部の配列を書き換える)。
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        guard n > 1, n & (n - 1) == 0 else { return }
        // ビット反転の並べ替え
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2 * Double.pi / Double(len)
            let wr = cos(ang), wi = sin(ang)
            for i in stride(from: 0, to: n, by: len) {
                var cwr = 1.0, cwi = 0.0
                for k in 0..<(len / 2) {
                    let ur = re[i + k], ui = im[i + k]
                    let vr = re[i + k + len / 2] * cwr - im[i + k + len / 2] * cwi
                    let vi = re[i + k + len / 2] * cwi + im[i + k + len / 2] * cwr
                    re[i + k] = ur + vr; im[i + k] = ui + vi
                    re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi
                    let nextWr = cwr * wr - cwi * wi
                    cwi = cwr * wi + cwi * wr
                    cwr = nextWr
                }
            }
            len <<= 1
        }
    }
}

// MARK: - 話者ラベルつき区間

/// 文字起こし区間に話者ラベルを付けたもの。`speaker` は 0 始まり(表示は「話者1」から)。
public struct DiarizedSegment: Equatable, Sendable {
    public var segment: TranscriptSegment
    public var speaker: Int
    public var feature: AcousticFeatures?
    public init(segment: TranscriptSegment, speaker: Int, feature: AcousticFeatures? = nil) {
        self.segment = segment; self.speaker = speaker; self.feature = feature
    }
    /// 表示用ラベル(「話者1」)。
    public var speakerLabel: String { SpeakerLabels.label(for: speaker) }
    /// 字幕に出す文(「話者1：本文」)。
    public var labeledText: String { DiarizationText.prefixed(segment.text, speaker: speaker) }
}

/// 話者ラベルの名前づけ・付け替え(手動修正の純粋計算)。
public enum SpeakerLabels {
    public static func label(for speaker: Int) -> String { "話者\(max(0, speaker) + 1)" }

    /// 1 件のラベルを付け替える。範囲外の添字ならそのまま返す。
    public static func relabeled(_ diarized: [DiarizedSegment], at index: Int, toSpeaker speaker: Int) -> [DiarizedSegment] {
        guard diarized.indices.contains(index), speaker >= 0 else { return diarized }
        var out = diarized
        out[index].speaker = speaker
        return out
    }

    /// `from` の話者を `into` にまとめる(同じ人だと分かったときの手動修正)。
    public static func merged(_ diarized: [DiarizedSegment], from: Int, into: Int) -> [DiarizedSegment] {
        diarized.map { d in
            var d = d
            if d.speaker == from { d.speaker = into }
            return d
        }
    }

    /// ラベルの番号を、最初に現れた順に 0,1,2… へ振り直す(付け替え後の番号の穴を詰める)。
    public static func compacted(_ diarized: [DiarizedSegment]) -> [DiarizedSegment] {
        var order: [Int] = []
        for d in diarized where !order.contains(d.speaker) { order.append(d.speaker) }
        let remap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return diarized.map { d in var d = d; d.speaker = remap[d.speaker] ?? d.speaker; return d }
    }

    /// いま使われている話者の数。
    public static func speakerCount(_ diarized: [DiarizedSegment]) -> Int {
        Set(diarized.map(\.speaker)).count
    }
}

/// 字幕文への話者ラベルの付け外し。
public enum DiarizationText {
    /// 既存の「話者N：」があれば付け替えて、無ければ先頭に付ける。
    public static func prefixed(_ text: String, speaker: Int) -> String {
        "\(SpeakerLabels.label(for: speaker))：\(stripPrefix(text))"
    }

    /// 先頭の「話者N：」「話者N: 」を取り除く(無ければそのまま)。
    public static func stripPrefix(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("話者") else { return text }
        let rest = t.dropFirst(2)
        var digits = 0
        for ch in rest { if ch.isASCII, ch.isNumber { digits += 1 } else { break } }
        guard digits > 0 else { return text }
        let afterDigits = rest.dropFirst(digits)
        guard let first = afterDigits.first, first == "：" || first == ":" else { return text }
        return String(afterDigits.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    public static func hasSpeakerPrefix(_ text: String) -> Bool {
        stripPrefix(text) != text
    }
}

// MARK: - 分離エンジン(差し替え可能な境界)

public struct DiarizationOptions: Equatable, Sendable {
    /// 話者数の上限(1〜8)。これを超える割り当てはせず、最も近い話者に寄せる。
    public var maxSpeakers: Int
    /// 新しい話者と認める距離のしきい値(正規化した特徴の距離。これ以上離れたら別話者)。
    public var threshold: Double
    public init(maxSpeakers: Int = 4, threshold: Double = 0.6) {
        self.maxSpeakers = min(max(1, maxSpeakers), 8)
        self.threshold = threshold
    }
}

/// 話者分離の差し替え口。将来の埋め込み型モデルはこの境界の後ろに実装する。
public protocol DiarizationEngine: Sendable {
    func diarize(segments: [TranscriptSegment], features: [AcousticFeatures], options: DiarizationOptions) -> [DiarizedSegment]
}

/// 音響特徴のクラスタリングによる簡易分離。
/// 区間を時刻順に見て、既存の話者の重心に近ければ同じ話者、しきい値より遠く
/// 上限に達していなければ新しい話者とする決定的な貪欲法を土台に、
/// R6-1 で次の仕上げを足した(いずれも決定的・学習なし):
/// - 無音区間と短すぎる区間は新しい話者を作らず直前の話者に寄せ、重心にも混ぜない
/// - 重心は区間の長さで重み付けする(短い区間のノイズに引っ張られない)
/// - 最後に、頼れる区間だけで重心を作り直して 1 回だけ付け替え直し、
///   重心どうしがしきい値より近いクラスタは 1 つに統合する
public struct AcousticClusterDiarizer: DiarizationEngine {
    public init() {}

    /// 特徴どうしの距離(0 に近いほど似ている)。声の高さを最も重く見る。
    /// 音量(rms)は同一話者でもささやき〜大声で大きく変わり別人性の手がかりに
    /// ならないため、同一性の判定には使わない(無音の判定だけに使う)。
    public static func distance(_ a: AcousticFeatures, _ b: AcousticFeatures) -> Double {
        var parts: [(value: Double, weight: Double)] = []
        // 声の高さ: 両方とも有声ならオクターブ差。有声/無声の食い違いは中程度の差として数える。
        if a.isVoiced, b.isVoiced {
            parts.append((min(abs(log2(a.meanF0 / b.meanF0)) / 0.35, 2), 1.0))
            // 声の高さのばらつき(抑揚の目安)。両方とも測れているときだけ比べる。
            if a.f0Spread > 1, b.f0Spread > 1 {
                parts.append((min(abs(log2(a.f0Spread / b.f0Spread)) / 1.2, 2), 0.5))
            }
        } else if a.isVoiced != b.isVoiced {
            parts.append((0.7, 1.0))
        }
        // 音色(スペクトル重心)
        if a.spectralCentroid > 0, b.spectralCentroid > 0 {
            parts.append((min(abs(log2(a.spectralCentroid / b.spectralCentroid)) / 0.5, 2), 0.8))
        }
        // 音色の形(帯域ごとのエネルギー配分)。両方に同じ帯域数があれば比べる。
        if !a.spectralBands.isEmpty, a.spectralBands.count == b.spectralBands.count {
            var sq = 0.0
            for i in a.spectralBands.indices { let d = a.spectralBands[i] - b.spectralBands[i]; sq += d * d }
            parts.append((min(sq.squareRoot() / 0.35, 2), 0.8))
        }
        // ゼロ交差率(摩擦音の多さなどの目安)
        parts.append((min(abs(a.zeroCrossingRate - b.zeroCrossingRate) / 0.08, 2), 0.5))
        guard !parts.isEmpty else { return 0 }
        let num = parts.reduce(0) { $0 + $1.weight * $1.value * $1.value }
        let den = parts.reduce(0) { $0 + $1.weight }
        return (num / den).squareRoot()
    }

    /// 重心の累積。区間の長さで重み付けし(0.25〜4 秒で頭打ち)、
    /// 有声の平均(F0 と そのばらつき)は有声区間だけで取る。
    private struct Cluster {
        var totalWeight = 0.0
        var voicedWeight = 0.0
        var sumF0 = 0.0, sumSpread = 0.0, sumCentroid = 0.0, sumZCR = 0.0
        var bandSums: [Double] = []
        var bandWeight = 0.0

        mutating func add(_ f: AcousticFeatures) {
            let w = min(max(f.duration, 0.25), 4.0)
            totalWeight += w
            sumCentroid += f.spectralCentroid * w
            sumZCR += f.zeroCrossingRate * w
            if f.isVoiced {
                voicedWeight += w
                sumF0 += f.meanF0 * w
                sumSpread += f.f0Spread * w
            }
            if !f.spectralBands.isEmpty {
                if bandSums.isEmpty { bandSums = [Double](repeating: 0, count: f.spectralBands.count) }
                if bandSums.count == f.spectralBands.count {
                    for i in bandSums.indices { bandSums[i] += f.spectralBands[i] * w }
                    bandWeight += w
                }
            }
        }

        var centroid: AcousticFeatures {
            let n = max(totalWeight, 1e-9)
            return AcousticFeatures(
                meanF0: voicedWeight > 0 ? sumF0 / voicedWeight : 0,
                f0Spread: voicedWeight > 0 ? sumSpread / voicedWeight : 0,
                rms: 0,
                spectralCentroid: sumCentroid / n,
                zeroCrossingRate: sumZCR / n,
                duration: 1,
                spectralBands: bandWeight > 0 ? bandSums.map { $0 / bandWeight } : [])
        }
    }

    public func diarize(segments: [TranscriptSegment], features: [AcousticFeatures], options: DiarizationOptions) -> [DiarizedSegment] {
        precondition(features.count == segments.count || features.isEmpty, "features は segments と同じ件数か空")
        let feats: [AcousticFeatures?] = segments.indices.map { features.indices.contains($0) ? features[$0] : nil }

        // 第 1 段: 時刻順の貪欲割り当て
        var clusters: [Cluster] = []
        var assignment: [Int] = []
        assignment.reserveCapacity(segments.count)
        var lastSpeaker = 0
        for f in feats {
            guard let f else {
                // 特徴が無い区間は直前の話者に寄せる(無ければ話者1)
                assignment.append(lastSpeaker)
                continue
            }
            if f.isSilent {
                // 無音は話者の手がかりが無い: 新しい話者は作らず、重心にも混ぜない
                assignment.append(clusters.isEmpty ? 0 : lastSpeaker)
                continue
            }
            if clusters.isEmpty {
                clusters.append(Cluster())
                clusters[0].add(f)
                assignment.append(0)
                lastSpeaker = 0
                continue
            }
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (ci, cluster) in clusters.enumerated() {
                let d = Self.distance(f, cluster.centroid)
                if d < bestDistance { bestDistance = d; best = ci }
            }
            if f.isShort {
                // 短すぎる区間は特徴が不安定: 新しい話者は作らず直前に寄せ、重心にも混ぜない
                assignment.append(lastSpeaker)
                continue
            }
            let speaker: Int
            if bestDistance <= options.threshold {
                speaker = best
            } else if clusters.count < options.maxSpeakers {
                // しきい値より遠い = 新しい話者(上限に達していないときだけ増やす)
                speaker = clusters.count
                clusters.append(Cluster())
            } else {
                // 上限に達しているので、最も近い話者に寄せる
                speaker = best
            }
            clusters[speaker].add(f)
            assignment.append(speaker)
            lastSpeaker = speaker
        }

        // 第 2 段: 仕上げ(再割り当て 1 回 + 近いクラスタの統合)。どちらも決定的。
        if clusters.count > 1 {
            assignment = Self.refined(assignment: assignment, feats: feats, greedy: clusters, options: options)
        }

        // ラベルを最初に現れた順に 0,1,2… へ振り直して返す
        var order: [Int] = []
        for a in assignment where !order.contains(a) { order.append(a) }
        let remap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return segments.enumerated().map { i, segment in
            DiarizedSegment(segment: segment, speaker: remap[assignment[i]] ?? 0, feature: feats[i])
        }
    }

    /// 割り当てから、頼れる区間(無音でも短くもない)だけで重心を作り直す。
    /// 頼れる区間が無いクラスタは貪欲段の重心をそのまま使う。
    private static func reliableCentroids(assignment: [Int], feats: [AcousticFeatures?], greedy: [Cluster]) -> [AcousticFeatures] {
        var rebuilt = [Cluster](repeating: Cluster(), count: greedy.count)
        for (i, a) in assignment.enumerated() {
            guard let f = feats[i], !f.isSilent, !f.isShort, rebuilt.indices.contains(a) else { continue }
            rebuilt[a].add(f)
        }
        return greedy.enumerated().map { ci, g in
            rebuilt[ci].totalWeight > 0 ? rebuilt[ci].centroid : g.centroid
        }
    }

    /// 再割り当てと統合。重心は付け替えの間は固定するので結果は決定的。
    private static func refined(assignment: [Int], feats: [AcousticFeatures?], greedy: [Cluster], options: DiarizationOptions) -> [Int] {
        var assignment = assignment
        // 再割り当て: 頼れる区間を、作り直した重心のうち最も近く
        // しきい値以内にある話者へ付け替える(新しい話者は作らない)
        let centroids = reliableCentroids(assignment: assignment, feats: feats, greedy: greedy)
        for i in assignment.indices {
            guard let f = feats[i], !f.isSilent, !f.isShort else { continue }
            var best = assignment[i]
            var bestDistance = Double.greatestFiniteMagnitude
            for (ci, c) in centroids.enumerated() {
                let d = distance(f, c)
                if d < bestDistance { bestDistance = d; best = ci }
            }
            if best != assignment[i], bestDistance <= options.threshold {
                assignment[i] = best
            }
        }
        // 統合: 重心どうしがしきい値より近い組があれば、最も近い組から 1 つにまとめる
        while true {
            let cs = reliableCentroids(assignment: assignment, feats: feats, greedy: greedy)
            let used = Array(Set(assignment)).sorted()
            guard used.count > 1 else { break }
            var pair: (Int, Int)?
            var pairDistance = Double.greatestFiniteMagnitude
            for x in used.indices {
                for y in used.indices where y > x {
                    let d = distance(cs[used[x]], cs[used[y]])
                    if d < pairDistance { pairDistance = d; pair = (used[x], used[y]) }
                }
            }
            guard let pair, pairDistance < options.threshold else { break }
            for i in assignment.indices where assignment[i] == pair.1 { assignment[i] = pair.0 }
        }
        return assignment
    }
}

// MARK: - 字幕・台本への反映(純粋関数)

public enum DiarizationApply {
    /// 話者ラベルつきの字幕キュー(タイムライン時刻。本文に「話者N：」を付ける)。
    /// 時刻の収め方は `TranscriptSubtitles.cues` と同じ(クリップの範囲内に切り、空は捨てる)。
    public static func cues(from diarized: [DiarizedSegment], clip: Clip) -> [SubtitleCue] {
        let dur = clip.duration
        var out: [SubtitleCue] = []
        for d in diarized {
            let body = SubtitleFile.cleanBody(d.segment.text)
            guard !body.isEmpty, d.segment.start.isFinite, d.segment.end.isFinite, dur > 0 else { continue }
            let a = min(max(0, d.segment.start), dur)
            let b = min(max(a, d.segment.end), dur)
            guard b - a > 1e-3 else { continue }
            out.append(SubtitleCue(start: clip.start + a, end: clip.start + b,
                                   text: DiarizationText.prefixed(body, speaker: d.speaker)))
        }
        return out.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    /// 台本欄へ入れる行(「話者1: 本文」。台本の話者名としてそのまま読める形)。
    public static func scriptLines(from diarized: [DiarizedSegment]) -> [String] {
        diarized.compactMap { d in
            let body = d.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return "\(d.speakerLabel): \(body)"
        }
    }

    /// 既にある文字クリップ(字幕)に話者ラベルを付ける。対象は、開始時刻が
    /// `clipStart + 区間の開始` と `tolerance` 秒以内で一致し、本文(ラベルを除いた形)が
    /// 区間の文と一致する文字クリップ。当てた件数を返す(Undo は呼び出し側)。
    @discardableResult
    public static func applyToTextClips(_ diarized: [DiarizedSegment], clipStart: Double, to project: inout Project, tolerance: Double = 0.06) -> Int {
        var count = 0
        for d in diarized {
            let targetStart = clipStart + d.segment.start
            let body = d.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            outer: for ti in project.tracks.indices {
                for ci in project.tracks[ti].clips.indices {
                    let clip = project.tracks[ti].clips[ci]
                    guard clip.type == .text, let text = clip.text else { continue }
                    guard abs(clip.start - targetStart) <= tolerance else { continue }
                    guard DiarizationText.stripPrefix(text) == body || text == body else { continue }
                    let newText = DiarizationText.prefixed(body, speaker: d.speaker)
                    if newText != text {
                        project.tracks[ti].clips[ci].text = newText
                        count += 1
                    }
                    break outer
                }
            }
        }
        return count
    }
}

// MARK: - 実行(音を書き出す → 認識する → 特徴 → 分離)

public enum DiarizationPipeline {
    /// 分離の実行結果一式(シートでの手動修正と再クラスタリングに使う)。
    public struct Run: Equatable, Sendable {
        public var segments: [TranscriptSegment]
        public var features: [AcousticFeatures]
        public var diarized: [DiarizedSegment]
    }

    /// 選んだクリップを文字にし、区間ごとの音響特徴を測って話者ラベルを付ける。
    /// 認識の経路は文字起こしと同じ(`TranscriptionAudio` の WAV を使い回して特徴も測る)。
    /// キャンセルは `CancellationError`。一時ファイルは終わったら消す。
    public static func run(clip: Clip, transcriber: Transcriber, options: DiarizationOptions = DiarizationOptions(),
                           engine: DiarizationEngine = AcousticClusterDiarizer(),
                           tempDirectory: URL = FileManager.default.temporaryDirectory,
                           onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Run {
        guard TranscriptionSupport.supports(clip) else { throw TranscriptionError.noAudio }
        let url = tempDirectory.appendingPathComponent("moviecut-diarize-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Task.detached(priority: .userInitiated) { try TranscriptionAudio.writeWAV(clip: clip, to: url) }.value
        try Task.checkCancellation()
        let segments = try await transcriber.transcribe(audioURL: url, duration: clip.duration, onProgress: onProgress)
        try Task.checkCancellation()
        let (samples, sampleRate) = try readMonoSamples(url: url)
        let features = segments.map { AcousticFeatureExtractor.features(samples: samples, sampleRate: sampleRate, start: $0.start, end: $0.end) }
        let diarized = engine.diarize(segments: segments, features: features, options: options)
        return Run(segments: segments, features: features, diarized: diarized)
    }

    /// WAV(モノラル/ステレオどちらでも)をモノラルのサンプル列として読む。
    public static func readMonoSamples(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        // フレーム数が AVAudioFrameCount(UInt32)に収まらない音声は、変換で落とさずエラーにする。
        guard let frames = AVAudioFrameCount(exactly: file.length) else {
            throw TranscriptionError.failed("音声が長すぎて読み込めません。")
        }
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return ([], format.sampleRate) }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var sum: Float = 0
            for ch in 0..<channelCount { sum += channels[ch][i] }
            out[i] = sum / Float(max(1, channelCount))
        }
        return (out, format.sampleRate)
    }
}
