import Foundation
import AVFoundation

// AquesTalk など「モーラ長を返さないエンジン」向けの口形タイミング推定(B-7 拡張)。
// 生成済み WAV のエネルギー包絡から発音区間を割り、読みのモーラ数で区間を等分して口形の区間列を作る。
// 純粋関数(同じ入力には同じ結果)。ファイル I/O は `writeSidecar` だけ。サイドカーは VOICEVOX と同じ形式。

public enum AudioMoraTiming {
    /// 包絡の窓(秒)。
    public static let window = 0.01
    /// 発音とみなす閾値 = 包絡ピークのこの割合。
    public static let thresholdRatio = 0.1
    /// これより短い無音は発音の途中(促音・語中の小さな谷)として埋める(秒)。
    public static let minGap = 0.12
    /// これより短い発音は雑音として捨てる(秒)。
    public static let minVoiced = 0.03

    /// 10ms 窓の RMS 包絡。
    public static func envelope(samples: [Float], sampleRate: Double) -> [Float] {
        let n = max(1, Int(sampleRate * window))
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        var i = 0
        while i < samples.count {
            let j = min(samples.count, i + n)
            var s: Float = 0
            for k in i..<j { let v = samples[k].isFinite ? samples[k] : 0; s += v * v }
            out.append((s / Float(j - i)).squareRoot())
            i = j
        }
        return out
    }

    /// 包絡から発音区間(秒)を割る。
    public static func voicedRanges(envelope env: [Float]) -> [(start: Double, end: Double)] {
        guard let peak = env.max(), peak > 0 else { return [] }
        let th = peak * Float(thresholdRatio)
        var runs: [(Int, Int)] = []
        var k = 0
        while k < env.count {
            if env[k] >= th {
                var e = k
                while e < env.count, env[e] >= th { e += 1 }
                runs.append((k, e)); k = e
            } else { k += 1 }
        }
        let gap = Int((minGap / window).rounded())
        var merged: [(Int, Int)] = []
        for r in runs {
            if let l = merged.last, r.0 - l.1 < gap { merged[merged.count - 1].1 = r.1 } else { merged.append(r) }
        }
        let minLen = Int((minVoiced / window).rounded())
        return merged.filter { $0.1 - $0.0 >= minLen }.map { (Double($0.0) * window, Double($0.1) * window) }
    }

    /// モーラ列(口形)を発音区間へ等分で割り当てる。無音は区間に含めない(発音時間だけを連結して等分し、実時間へ戻す)。
    /// 閉じた口のモーラも時間を持つ(ん・っ の長さ)が、出力の区間は母音のものだけ。モーラ無し・発音無しは空。
    public static func segments(moras: [Viseme], envelope env: [Float]) -> [TimedViseme] {
        let ranges = voicedRanges(envelope: env)
        guard !moras.isEmpty, !ranges.isEmpty else { return [] }
        let total = ranges.reduce(0) { $0 + ($1.end - $1.start) }
        let per = total / Double(moras.count)
        guard per > 0 else { return [] }
        var out: [TimedViseme] = []
        // 圧縮時間 t → 実時間への写像で、各モーラの [a, b) を発音区間にまたがって切り出す
        var offsets: [Double] = []   // 各発音区間の圧縮時間での開始
        var acc = 0.0
        for r in ranges { offsets.append(acc); acc += r.end - r.start }
        for (m, v) in moras.enumerated() where v != .closed {
            let a = Double(m) * per, b = Double(m + 1) * per
            for (ri, r) in ranges.enumerated() {
                let cs = offsets[ri], ce = cs + (r.end - r.start)
                let lo = max(a, cs), hi = min(b, ce)
                if hi - lo > 1e-9 { out.append(TimedViseme(vowel: v, start: r.start + (lo - cs), end: r.start + (hi - cs))) }
            }
        }
        return out
    }

    /// WAV を読んでモノラルの Float 列にする。
    public static func readMono(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0, f.length < 200_000_000,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), c = Int(buf.format.channelCount)
        guard n > 0, c > 0 else { return nil }
        var out = [Float](repeating: 0, count: n)
        for k in 0..<c { let p = ch[k]; for i in 0..<n { out[i] += p[i] / Float(c) } }
        return (out, f.processingFormat.sampleRate)
    }

    /// WAV と読みから区間列を作る。読み(モーラ)無し・WAV 読めない・発音無しは nil(呼び出し側は従来の推定へ)。
    public static func timeline(wav: URL, text: String) -> [TimedViseme]? {
        let moras = LipSync.moras(of: text)
        guard !moras.isEmpty, let (s, rate) = readMono(wav) else { return nil }
        let segs = segments(moras: moras, envelope: envelope(samples: s, sampleRate: rate))
        return segs.isEmpty ? nil : segs
    }

    /// サイドカー(`<wav>.visemes.json`)を書く。既に有効なものがあれば何もしない。書いたら true。
    @discardableResult
    public static func writeSidecar(wav: URL, text: String) -> Bool {
        let sidecar = VoicevoxMora.sidecarURL(forWav: wav.path)
        if let existing = try? Data(contentsOf: sidecar), VoicevoxMora.decodeSidecar(existing) != nil { return false }
        guard let segs = timeline(wav: wav, text: text), let data = VoicevoxMora.encodeSidecar(segs) else { return false }
        return (try? data.write(to: sidecar, options: .atomic)) != nil
    }
}
