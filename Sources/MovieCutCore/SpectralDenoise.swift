import Foundation
import Accelerate

// MARK: - ノイズ除去(強): スペクトルゲート
//
// 簡易のノイズ除去(`DenoiseProcessor`: 静かな所を下げるだけ)では、声の最中のノイズは消えない。
// こちらは周波数ごとに「ノイズより十分大きい成分だけを通す」。
//   1. クリップのいちばん静かな 0.5 秒(連続した区間)の平均パワースペクトルを、ノイズの型(プロファイル)とする。
//   2. STFT(窓 2048 点・Hann・ホップ 512 = 75% 重ね)で周波数ごとのゲインを決める:
//        mask = clamp(1 − α·ノイズ / パワー, 床, 1)(パワーは隣の 3 bin で平滑化)、ゲイン = √mask
//      パワー減算に床を付けた「やわらかいマスク」。時間方向は上がるのは即時・下がるのはゆっくり(ぶつぶつ切れないように)。
//   3. 逆 FFT して窓を掛け、重ねて足す(overlap-add)。
// 強さ s(0〜1)で α = 1 + 3s、床 = −(12 + 28s) dB。乱数を使わないので、同じ入力なら必ず同じ出力になる。
// 注意: 最も静かな 0.5 秒にも音(声)が入っているクリップでは、その音をノイズとみなして弱める。

enum SpectralDenoise {
    static let fftSize = 2048
    static let hop = 512
    static let log2n = 11
    static let profileSeconds = 0.5
    static let releasePerFrame: Float = 0.75

    struct Profile {
        /// bin 0..<fftSize/2 のノイズのパワー(`Transform.power` と同じ尺度)
        var power: [Float]
    }

    /// 実数 FFT(vDSP_fft_zrip)。1 つのスレッドで使う前提(作業用の配列を持つ)。
    final class Transform {
        let n = SpectralDenoise.fftSize
        let half = SpectralDenoise.fftSize / 2
        let setup: FFTSetup
        let window: [Float]
        var re: [Float], im: [Float]
        init() {
            setup = vDSP_create_fftsetup(vDSP_Length(SpectralDenoise.log2n), FFTRadix(FFT_RADIX2))!
            window = (0..<SpectralDenoise.fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(SpectralDenoise.fftSize))) }
            re = [Float](repeating: 0, count: SpectralDenoise.fftSize / 2)
            im = [Float](repeating: 0, count: SpectralDenoise.fftSize / 2)
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        /// frame(n 点)に窓を掛けて FFT。結果は re / im に入る(bin k = 1..<half、bin 0 の re は DC、im は Nyquist。値は DFT の 2 倍)。
        func forward(_ frame: UnsafePointer<Float>) {
            var w = [Float](repeating: 0, count: n)
            vDSP_vmul(frame, 1, window, 1, &w, 1, vDSP_Length(n))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    w.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(SpectralDenoise.log2n), FFTDirection(FFT_FORWARD))
                }
            }
        }

        /// re / im を逆 FFT して、n 点の時間信号を out に書く(forward のあと直接 inverse すると元の信号に戻る尺度)。
        func inverse(into out: UnsafeMutablePointer<Float>) {
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(SpectralDenoise.log2n), FFTDirection(FFT_INVERSE))
                    out.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(half))
                    }
                }
            }
            var scale = Float(1) / Float(2 * n)   // zrip の往復は 2n 倍
            vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(n))
        }

        /// bin k のパワー(0..<half。bin 0 は DC)。
        func power(into p: inout [Float]) {
            for k in 0..<half { p[k] = re[k] * re[k] + im[k] * im[k] }
            p[0] = re[0] * re[0]
        }
    }

    // MARK: プロファイル

    /// いちばん静かな 0.5 秒のノイズの型。`open` は先頭から読める入力を新しく開く(2 回呼ぶ)。短すぎる(窓 1 つ未満)・読めなければ nil。
    static func estimateProfile(open: () -> PCMSource?, sampleRate sr: Double) -> Profile? {
        let n = fftSize, h = hop
        let block = 8192
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block), r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { l.deallocate(); r.deallocate() }
        // 1 回目: ホップごとのエネルギー(モノ)
        guard let s1 = open() else { return nil }
        var energies: [Double] = []
        var acc = 0.0, inBlock = 0
        var total = 0
        while true {
            let got = s1.read(left: l, right: r, frames: block)
            if got <= 0 { break }
            for i in 0..<got {
                let m = Double(l[i] + r[i]) * 0.5
                acc += m * m; inBlock += 1
                if inBlock == h { energies.append(acc); acc = 0; inBlock = 0 }
            }
            total += got
            if got < block { break }
        }
        guard total >= n else { return nil }
        let w = min(energies.count, max(n / h, Int((profileSeconds * sr / Double(h)).rounded())))
        guard w >= n / h else { return nil }
        // 連続 w ホップの合計が最小の窓
        var sum = energies[0..<w].reduce(0, +)
        var best = sum, bestStart = 0
        if energies.count > w {
            for k in 1...(energies.count - w) {
                sum += energies[k + w - 1] - energies[k - 1]
                if sum < best { best = sum; bestStart = k }
            }
        }
        // 2 回目: その区間の平均パワースペクトル
        guard let s2 = open() else { return nil }
        var skip = bestStart * h
        while skip > 0 {
            let got = s2.read(left: l, right: r, frames: min(block, skip))
            if got <= 0 { return nil }
            skip -= got
        }
        let region = w * h
        var mono = [Float](repeating: 0, count: region)
        var filled = 0
        while filled < region {
            let got = s2.read(left: l, right: r, frames: min(block, region - filled))
            if got <= 0 { break }
            for i in 0..<got { mono[filled + i] = (l[i] + r[i]) * 0.5 }
            filled += got
        }
        guard filled >= n else { return nil }
        let tr = Transform()
        var p = [Float](repeating: 0, count: n / 2)
        var sumP = [Double](repeating: 0, count: n / 2)
        var frames = 0
        var pos = 0
        while pos + n <= filled {
            mono.withUnsafeBufferPointer { tr.forward($0.baseAddress! + pos) }
            tr.power(into: &p)
            for k in 0..<(n / 2) { sumP[k] += Double(p[k]) }
            frames += 1; pos += h
        }
        guard frames > 0 else { return nil }
        return Profile(power: sumP.map { Float($0 / Double(frames)) })
    }

    // MARK: ゲイン

    struct Params {
        let alpha: Float
        let floorMask: Float   // パワーの床(振幅の床の 2 乗)
        init(strength: Double) {
            let s = Float(AudioFx.clampDenoise(strength))
            alpha = 1 + 3 * s
            let floorDb = -(12 + 28 * s)
            floorMask = powf(10, floorDb / 10)
        }
    }

    /// 1 チャンネルぶんの STFT 処理器。フレームごとに `process` を呼ぶ。前のゲインを覚える(時間方向の平滑化)。
    final class ChannelProcessor {
        let tr = Transform()
        let profile: [Float]
        let p: Params
        var power: [Float]
        var smoothed: [Float]
        var gain: [Float]
        var prevGain: [Float]
        var out: [Float]
        init(profile: Profile, params: Params) {
            self.profile = profile.power; p = params
            let half = SpectralDenoise.fftSize / 2
            power = [Float](repeating: 0, count: half)
            smoothed = power; gain = power
            prevGain = [Float](repeating: 1, count: half)
            out = [Float](repeating: 0, count: SpectralDenoise.fftSize)
        }

        /// frame(fftSize 点)を処理して、窓を掛けた逆 FFT の結果(重ねて足す前)を `out` に作る。
        func process(_ frame: UnsafePointer<Float>) {
            let half = SpectralDenoise.fftSize / 2
            tr.forward(frame)
            tr.power(into: &power)
            for k in 0..<half {
                let a = power[max(0, k - 1)], c = power[min(half - 1, k + 1)]
                smoothed[k] = 0.25 * a + 0.5 * power[k] + 0.25 * c
            }
            for k in 0..<half {
                let nz = profile[k] * p.alpha
                var m = smoothed[k] > 0 ? 1 - nz / smoothed[k] : 0
                m = min(1, max(p.floorMask, m))
                var g = m.squareRoot()
                g = max(g, prevGain[k] * SpectralDenoise.releasePerFrame)   // 下がるのはゆっくり
                gain[k] = g
            }
            for k in 0..<half { tr.re[k] *= gain[k]; tr.im[k] *= gain[k] }
            tr.im[0] *= gain[half - 1] / max(gain[0], 1e-9)   // 実際は Nyquist: 最後の bin のゲインで
            swap(&prevGain, &gain)
            out.withUnsafeMutableBufferPointer { tr.inverse(into: $0.baseAddress!) }
            for i in 0..<SpectralDenoise.fftSize { out[i] *= tr.window[i] }
        }
    }

    /// 重ね合わせの正規化(Hann²を 75% 重ねた和)。
    static let overlapNorm: Float = 1 / 1.5

    // MARK: 配列をまとめて処理(テスト・CLI 用)

    /// 左右の配列をまとめて処理する。プロファイルは自分自身のいちばん静かな 0.5 秒から作る。作れなければ(短すぎる)そのまま返す。
    static func process(left: [Float], right: [Float], sampleRate sr: Double, strength: Double) -> (left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        let make = { () -> PCMSource? in ArraySource(Array(left[0..<n]), Array(right[0..<n])) }
        guard let prof = estimateProfile(open: make, sampleRate: sr), let src = make() else { return (left, right) }
        let d = SpectralDenoiseSource(inner: src, profile: prof, strength: strength)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        var done = 0
        while done < n {
            let want = min(4096, n - done)
            let got = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                d.read(left: lp.baseAddress! + done, right: rp.baseAddress! + done, frames: want) } }
            if got <= 0 { break }
            done += got
        }
        return (l, r)
    }

    /// 配列から読む PCMSource(テスト・プロファイルの入力用)。
    final class ArraySource: PCMSource {
        let l: [Float], r: [Float]
        var pos = 0
        init(_ l: [Float], _ r: [Float]) { self.l = l; self.r = r }
        func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
            let n = min(frames, l.count - pos)
            if n <= 0 { return 0 }
            for i in 0..<n { left[i] = l[pos + i]; right[i] = r[pos + i] }
            pos += n
            return n
        }
    }
}

// MARK: - ストリーム版(ミキサーが読む)

/// 入力を先読みしながら STFT をかけ、遅れなしの位置(入力と同じ長さ・同じ位置)で返す PCMSource。
/// フレームの始まりは −(N−H) から H ずつ。フレーム s を処理し終えると、s + H より前のサンプルが確定する。
final class SpectralDenoiseSource: PCMSource {
    private let inner: PCMSource
    private let n = SpectralDenoise.fftSize, h = SpectralDenoise.hop
    private let chL: SpectralDenoise.ChannelProcessor, chR: SpectralDenoise.ChannelProcessor
    // 入力: 絶対位置 inBase から
    private var inL: [Float] = [], inR: [Float] = []
    private var inBase = 0
    private var innerEOF = false
    // 出力の足し込み: 絶対位置 outBase から
    private var accL: [Float] = [], accR: [Float] = []
    private var outBase: Int
    private var nextStart: Int
    private var emitted = 0
    private var scratchL: [Float], scratchR: [Float]
    private let tmpL: UnsafeMutablePointer<Float>, tmpR: UnsafeMutablePointer<Float>
    private static let block = 4096

    init(inner: PCMSource, profile: SpectralDenoise.Profile, strength: Double) {
        self.inner = inner
        let params = SpectralDenoise.Params(strength: strength)
        chL = SpectralDenoise.ChannelProcessor(profile: profile, params: params)
        chR = SpectralDenoise.ChannelProcessor(profile: profile, params: params)
        nextStart = -(SpectralDenoise.fftSize - SpectralDenoise.hop)
        outBase = nextStart
        scratchL = [Float](repeating: 0, count: SpectralDenoise.fftSize)
        scratchR = scratchL
        tmpL = .allocate(capacity: Self.block); tmpR = .allocate(capacity: Self.block)
    }
    deinit { tmpL.deallocate(); tmpR.deallocate() }

    private var inEnd: Int { inBase + inL.count }
    /// 確定している位置(これより前は出力できる)。
    private var finalBound: Int { innerEOF && nextStart >= inEnd ? inEnd : min(nextStart, inEnd) }
    private var isFinished: Bool { innerEOF && nextStart >= inEnd }

    private func fillInput() {
        let got = inner.read(left: tmpL, right: tmpR, frames: Self.block)
        if got > 0 {
            inL.append(contentsOf: UnsafeBufferPointer(start: tmpL, count: got))
            inR.append(contentsOf: UnsafeBufferPointer(start: tmpR, count: got))
        }
        if got < Self.block { innerEOF = true }
    }

    private func processFrame() {
        // 入力 [nextStart, nextStart + n) を取り出す(範囲外は 0)
        for i in 0..<n {
            let a = nextStart + i - inBase
            if a >= 0 && a < inL.count { scratchL[i] = inL[a]; scratchR[i] = inR[a] } else { scratchL[i] = 0; scratchR[i] = 0 }
        }
        scratchL.withUnsafeBufferPointer { chL.process($0.baseAddress!) }
        scratchR.withUnsafeBufferPointer { chR.process($0.baseAddress!) }
        // 足し込み先を確保
        let need = nextStart + n - outBase
        if accL.count < need {
            accL.append(contentsOf: [Float](repeating: 0, count: need - accL.count))
            accR.append(contentsOf: [Float](repeating: 0, count: need - accR.count))
        }
        let o = nextStart - outBase
        let norm = SpectralDenoise.overlapNorm
        for i in 0..<n { accL[o + i] += chL.out[i] * norm; accR[o + i] += chR.out[i] * norm }
        nextStart += h
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        if frames <= 0 { return 0 }
        while finalBound - emitted < frames && !isFinished {
            if !innerEOF && inEnd < nextStart + n { fillInput(); continue }
            processFrame()
        }
        let count = min(frames, finalBound - emitted)
        if count <= 0 { return 0 }
        let base = emitted - outBase
        for i in 0..<count { left[i] = accL[base + i]; right[i] = accR[base + i] }
        emitted += count
        // 使い終わった所を捨てる
        let dropOut = min(accL.count, emitted - outBase)
        if dropOut > 1 << 16 {
            accL.removeFirst(dropOut); accR.removeFirst(dropOut); outBase += dropOut
        }
        let dropIn = min(inL.count, nextStart - inBase)
        if dropIn > 1 << 16 {
            inL.removeFirst(dropIn); inR.removeFirst(dropIn); inBase += dropIn
        }
        return count
    }
}
