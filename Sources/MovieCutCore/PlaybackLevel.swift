import Foundation
import AVFoundation

// MARK: - 再生中のサウンドレベル(ピーク / ラウドネス)
//
// YMM4 のタイムライン脇のサウンドレベルメーター相当。再生経路(AVAudioEngine)には一切触らず、
// 再生用ミックス(書き出しと同じ AudioMixer の出力ファイル)が用意できた時点で、そのファイルを
// 背景で読みながら 100 ms ごとのピークと K 特性エネルギーを先に測っておく(PlaybackLevelEnvelope)。
// 再生中はコントローラが「いまの時刻の区切りを引く」だけなので、プレビューの描画・音声に負荷を足さない。
// - ピーク: 区切り内のサンプル絶対値の最大(dBFS)。
// - ラウドネス: LoudnessMeter と同じ K 特性フィルタ・同じ式のモーメンタリ(400 ms)とショートターム(3 s)。
//   区切りのエネルギーは「左右チャンネルの K 特性後の二乗平均の和」で、LoudnessMeter の hops と同じ定義。

/// メーターの表示モード(YMM4 のピーク/ラウドネス切替)。
public enum PlaybackLevelMode: String, CaseIterable {
    case peak
    case loudness

    public var label: String { self == .peak ? "ピーク" : "ラウドネス" }
}

/// 100 ms ごとの測定列。時刻から引くのは配列参照だけ(補間なし)。
public struct PlaybackLevelEnvelope: Equatable, Sendable {
    /// 区切りの長さ(秒)。
    public static let hopDuration = 0.1
    /// モーメンタリの窓(区切り数。400 ms)。
    static let momentaryHops = 4
    /// ショートタームの窓(区切り数。3 s)。
    static let shortTermHops = 30

    /// 区切りごとのピーク(線形 0〜。無音は 0)。
    public var peaks: [Float]
    /// 区切りごとの K 特性エネルギー(左右の二乗平均の和)。LUFS 換算は `Self.lufs(_:)`。
    public var energies: [Double]
    /// 測った長さ(秒)。
    public var duration: Double { Double(peaks.count) * Self.hopDuration }

    public init(peaks: [Float], energies: [Double]) {
        self.peaks = peaks
        self.energies = energies
    }

    /// 二乗平均(和)から LUFS へ(LoudnessMeter と同じ式)。
    static func lufs(_ energy: Double) -> Double { energy > 0 ? -0.691 + 10 * log10(energy) : -.infinity }

    /// 時刻 t の区切り番号。範囲外は nil。
    public func hopIndex(at t: Double) -> Int? {
        // peaks と energies の長さが食い違う作り方をされても、短い方に合わせる(ラウドネス計算が範囲外を読まない)
        let count = min(peaks.count, energies.count)
        guard t >= 0, t.isFinite, count > 0 else { return nil }
        let i = Int(t / Self.hopDuration)
        return i < count ? i : nil
    }

    /// 時刻 t のピーク(dBFS)。範囲外・無音は −∞。
    public func peakDb(at t: Double) -> Double {
        guard let i = hopIndex(at: t), peaks[i] > 0 else { return -.infinity }
        return 20 * log10(Double(peaks[i]))
    }

    /// 時刻 t のモーメンタリラウドネス(LUFS、400 ms 窓。頭では溜まった分だけで平均する)。
    public func momentaryLoudness(at t: Double) -> Double {
        guard let i = hopIndex(at: t) else { return -.infinity }
        let lo = max(0, i - Self.momentaryHops + 1)
        let slice = energies[lo...i]
        return Self.lufs(slice.reduce(0, +) / Double(slice.count))
    }

    /// 時刻 t のショートタームラウドネス(LUFS、3 s 窓。頭では溜まった分だけで平均する)。
    public func shortTermLoudness(at t: Double) -> Double {
        guard let i = hopIndex(at: t) else { return -.infinity }
        let lo = max(0, i - Self.shortTermHops + 1)
        let slice = energies[lo...i]
        return Self.lufs(slice.reduce(0, +) / Double(slice.count))
    }

    /// モードに応じた時刻 t のレベル(dBFS または LUFS)。
    public func levelDb(at t: Double, mode: PlaybackLevelMode) -> Double {
        mode == .peak ? peakDb(at: t) : momentaryLoudness(at: t)
    }

    /// メーターのバー用の 0〜1。ピークは −60 dB を床、ラウドネスは −50 LUFS を床にする。−∞ は 0。
    public static func normalized(_ db: Double, mode: PlaybackLevelMode) -> Double {
        guard db.isFinite else { return 0 }
        let floorDb = mode == .peak ? -60.0 : -50.0
        return min(1, max(0, (db - floorDb) / (0 - floorDb)))
    }

    // MARK: 測定

    /// 左右サンプル列(同長・48 kHz 前提でなくてもよい)から測る。テストと小さい入力用。
    public init(left: [Float], right: [Float], sampleRate: Double) {
        var calc = PlaybackLevelCalculator(sampleRate: sampleRate)
        calc.add(left: left, right: right)
        self = calc.finish()
    }

    /// 音声ファイル(再生用ミックス等)を少しずつ読みながら測る。読めなければ nil。
    /// 長いプロジェクトでも全体をメモリに置かない(読みは 1 秒分ずつ)。
    public static func compute(fromFileAt url: URL) -> PlaybackLevelEnvelope? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let ch = Int(file.processingFormat.channelCount)
        guard ch >= 1 else { return nil }
        let fmt = file.processingFormat
        var calc = PlaybackLevelCalculator(sampleRate: fmt.sampleRate)
        let capacity = AVAudioFrameCount(fmt.sampleRate)   // 1 秒分
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return nil }
        while file.framePosition < file.length {
            let want = AVAudioFrameCount(min(Int64(capacity), file.length - file.framePosition))
            do { try file.read(into: buf, frameCount: want) } catch { return nil }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { return nil }
            let l = Array(UnsafeBufferPointer(start: data[0], count: n))
            let r = ch >= 2 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : l
            calc.add(left: l, right: r)
        }
        let env = calc.finish()
        return env.peaks.isEmpty ? nil : env
    }
}

/// サンプルを流し込んで PlaybackLevelEnvelope を作る計算器。K 特性フィルタの係数は LevelMeter と同じ。
public struct PlaybackLevelCalculator {
    private let hopSamples: Int
    private var preL = BiquadState(), preR = BiquadState()
    private var rlbL = BiquadState(), rlbR = BiquadState()
    private var hopPeak: Float = 0
    private var hopSum = 0.0
    private var hopCount = 0
    private var peaks: [Float] = []
    private var energies: [Double] = []

    public init(sampleRate: Double) {
        hopSamples = max(1, Int((PlaybackLevelEnvelope.hopDuration * sampleRate).rounded()))
    }

    public mutating func add(left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        for i in 0..<n {
            let xl = left[i], xr = right[i]
            hopPeak = max(hopPeak, abs(xl), abs(xr))
            let yl = rlbL.run(LevelMeter.rlbFilter, preL.run(LevelMeter.preFilter, Double(xl)))
            let yr = rlbR.run(LevelMeter.rlbFilter, preR.run(LevelMeter.preFilter, Double(xr)))
            hopSum += yl * yl + yr * yr
            hopCount += 1
            if hopCount == hopSamples {
                peaks.append(hopPeak)
                energies.append(hopSum / Double(hopCount))
                hopPeak = 0; hopSum = 0; hopCount = 0
            }
        }
    }

    /// 末尾の端数区切りも 1 区切りとして出す(平均は溜まった分で割る)。
    public func finish() -> PlaybackLevelEnvelope {
        var p = peaks, e = energies
        if hopCount > 0 {
            p.append(hopPeak)
            e.append(hopSum / Double(hopCount))
        }
        return PlaybackLevelEnvelope(peaks: p, energies: e)
    }
}
