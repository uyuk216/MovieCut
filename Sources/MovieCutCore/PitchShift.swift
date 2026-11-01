import Foundation
import Accelerate
import AVFoundation

/// 音程変更(半音単位)。長さは変えない。外部ライブラリを使わない、決定的な時間領域の処理。
///
/// 手順: (1) WSOLA(Hann 窓・75% 重なり・位相のそろう位置を探す)で、長さを `p` 倍に伸ばす(音程は変わらない)
/// (2) 伸ばした音を、位置 i × p で直線補間して元の長さに縮める(音程が p 倍になり、長さは元どおり)。
/// p = 2^(半音 / 12)。+12 でちょうど 2 倍の周波数になる。
///
/// 制約: 粒の位置は相互相関で決めるだけなので、声や楽器では位相の揺れ(ややこもった・ざらついた音)が出ることがある。
/// 音程だけを聴き比べて使う用途の簡易版。フォルマントは動かさない(声が高く・低くなるだけ)。
public enum PitchShift {
    static let grain = 2048
    static let hop = 512
    /// 次の粒を探す幅(入力のサンプル、±)。
    static let searchRadius = 128

    /// 半音数から周波数の倍率。
    public static func ratio(semitones: Double) -> Double { pow(2, semitones / 12) }

    /// 1 チャンネルを処理する。`semitones` が 0 なら入力をそのまま返す(ビット単位で同じ)。出力の長さは入力と同じ。
    public static func shift(_ x: [Float], semitones: Double) -> [Float] {
        shiftChannels([x], semitones: semitones)[0]
    }

    /// 複数チャンネル(同じ長さ)を処理する。粒の位置はチャンネル 0 で決めて、全チャンネルで同じにする(左右がずれない)。
    public static func shiftChannels(_ chans: [[Float]], semitones: Double) -> [[Float]] {
        let s = AudioFx.clampPitch(semitones)
        guard s != 0, let first = chans.first, !first.isEmpty else { return chans }
        let p = ratio(semitones: s)
        let stretched = stretch(chans, alpha: p)
        return stretched.map { resample($0, count: first.count, rate: p) }
    }

    /// 時間を `alpha` 倍に伸ばす(WSOLA)。粒を Hann 窓で重ね、次の粒は「前の粒の続き」と最もよく合う位置を、
    /// 目標の位置の近く(±searchRadius)から選ぶ。位相がそろうので、音程は変わらない。
    static func stretch(_ chans: [[Float]], alpha: Double) -> [[Float]] {
        let n = chans[0].count
        let outLen = Int((Double(n) * alpha).rounded(.up)) + grain
        let win = (0..<grain).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(grain))) }
        let ov = grain - hop
        var outs = chans.map { _ in [Float](repeating: 0, count: outLen) }
        var weight = [Float](repeating: 0, count: outLen)
        let inHop = Double(hop) / alpha
        var prev = 0
        var k = 0
        var target = [Float](repeating: 0, count: ov)
        while k * hop < outLen {
            let outStart = k * hop
            var s = 0
            if k > 0 {
                let nominal = prev + Int(inHop.rounded())
                // 目標: 前の粒の、出力で重なる部分に対応する入力(prev + hop ..< prev + grain)
                for j in 0..<ov { let i = prev + hop + j; target[j] = i < n ? chans[0][i] : 0 }
                s = bestStart(chans[0], nominal: nominal, target: target)
            }
            for (c, x) in chans.enumerated() {
                for j in 0..<grain {
                    let o = outStart + j
                    if o >= outLen { break }
                    let i = s + j
                    let v: Float = (i >= 0 && i < n) ? x[i] : 0
                    outs[c][o] += v * win[j]
                }
            }
            for j in 0..<grain where outStart + j < outLen { weight[outStart + j] += win[j] }
            prev = s
            k += 1
        }
        for c in outs.indices {
            for i in 0..<outLen where weight[i] > 1e-6 { outs[c][i] /= weight[i] }
        }
        return outs
    }

    /// 目標(長さ ov)に最もよく合う入力の位置を、nominal ± searchRadius から選ぶ(正規化した相互相関)。
    static func bestStart(_ x: [Float], nominal: Int, target: [Float]) -> Int {
        let n = x.count, ov = target.count
        var best = max(0, min(nominal, n - ov))
        var bestScore = -Float.greatestFiniteMagnitude
        let lo = max(0, nominal - searchRadius), hi = min(n - ov, nominal + searchRadius)
        guard lo <= hi else { return best }
        for c in lo...hi {
            var dot: Float = 0, energy: Float = 0
            x.withUnsafeBufferPointer { xp in
                target.withUnsafeBufferPointer { tp in
                    vDSP_dotpr(xp.baseAddress! + c, 1, tp.baseAddress!, 1, &dot, vDSP_Length(ov))
                    vDSP_svesq(xp.baseAddress! + c, 1, &energy, vDSP_Length(ov))
                }
            }
            let score = energy > 1e-9 ? dot / energy.squareRoot() : 0
            if score > bestScore { bestScore = score; best = c }
        }
        return best
    }

    /// 位置 i × rate を直線補間で読み、`count` 個の出力を作る。
    static func resample(_ y: [Float], count: Int, rate: Double) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let pos = Double(i) * rate
            let k = Int(pos)
            let f = Float(pos - Double(k))
            let a: Float = k < y.count ? y[k] : 0
            let b: Float = k + 1 < y.count ? y[k + 1] : 0
            out[i] = a * (1 - f) + b * f
        }
        return out
    }

    /// 音声ファイル(48 kHz ステレオ Float32 CAF、AudioRemap の出力と同じ形式)を、音程を変えた同じ長さのファイルに作る。
    static func renderFile(from src: URL, semitones: Double, in dir: URL) throws -> URL {
        let input = try AVAudioFile(forReading: src)
        let fmt = input.processingFormat
        let total = Int(input.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, total))) else {
            throw AudioRemap.Failure.engine("buffer")
        }
        try input.read(into: buf)
        let got = Int(buf.frameLength)
        guard let ch = buf.floatChannelData, got > 0 else { throw AudioRemap.Failure.engine("empty") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = dir.appendingPathComponent("\(UUID().uuidString)-pitch.caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: Int(fmt.channelCount),
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let out = try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let ob = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(got)),
              let oc = ob.floatChannelData else { throw AudioRemap.Failure.engine("buffer") }
        let chans = (0..<Int(fmt.channelCount)).map { Array(UnsafeBufferPointer(start: ch[$0], count: got)) }
        let outs = shiftChannels(chans, semitones: semitones)
        for c in 0..<outs.count { outs[c].withUnsafeBufferPointer { p in oc[c].update(from: p.baseAddress!, count: got) } }
        ob.frameLength = AVAudioFrameCount(got)
        try out.write(from: ob)
        return outURL
    }
}
