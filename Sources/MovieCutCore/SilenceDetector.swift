import Foundation

// MARK: - 無音の検出(無音カット用)

/// 無音カットの設定。
public struct SilenceParams: Equatable, Sendable {
    public static let thresholdRange: ClosedRange<Double> = -80 ... -10
    public static let minSilenceRange: ClosedRange<Double> = 0.05 ... 5
    public static let padRange: ClosedRange<Double> = 0 ... 1
    public static let `default` = SilenceParams()

    /// これより小さい音を無音とみなす(dBFS)
    public var thresholdDb: Double
    /// これより短い無音は切らない(秒)
    public var minSilence: Double
    /// 無音の両端に残す余白(秒)。声の語頭・語尾を削らないため。クリップの端側には付けない。
    public var pad: Double

    public init(thresholdDb: Double = -40, minSilence: Double = 0.4, pad: Double = 0.1) {
        self.thresholdDb = thresholdDb; self.minSilence = minSilence; self.pad = pad
    }

    /// 範囲に収めた値。
    public var clamped: SilenceParams {
        func c(_ v: Double, _ r: ClosedRange<Double>, _ d: Double) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d }
        return SilenceParams(thresholdDb: c(thresholdDb, Self.thresholdRange, -40),
                             minSilence: c(minSilence, Self.minSilenceRange, 0.4),
                             pad: c(pad, Self.padRange, 0.1))
    }
}

/// 時間の範囲(秒。クリップの頭からの時刻)。
public struct SilenceRange: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var length: Double { end - start }
}

/// 音の大きさの時間変化(10 ミリ秒ごとの RMS、dBFS)。一度測れば、しきい値などを動かしても作り直さずに無音を求められる。
public struct LevelProfile: Equatable, Sendable {
    public static let windowSeconds = 0.01
    /// 窓ごとの dBFS(無音は -120)
    public var levels: [Float]
    /// 測った長さ(秒)。最後の窓は短いことがある。
    public var duration: Double

    public init(levels: [Float], duration: Double) { self.levels = levels; self.duration = duration }

    /// 無音の区間(余白を引いた、実際に切る範囲)。音の大きさが `thresholdDb` 未満の窓が `minSilence` 以上続いたところ。
    /// 前後に `pad` を残す(クリップの頭・終わりに接する側は残さない)。余白を引くと残らないものは捨てる。
    public func silentRanges(_ params: SilenceParams) -> [SilenceRange] {
        let p = params.clamped
        let w = Self.windowSeconds
        var out: [SilenceRange] = []
        var i = 0
        let n = levels.count
        let thr = Float(p.thresholdDb)
        while i < n {
            guard levels[i] < thr else { i += 1; continue }
            var j = i
            while j < n && levels[j] < thr { j += 1 }
            let a = Double(i) * w
            let b = min(duration, Double(j) * w)
            if b - a >= p.minSilence - 1e-9 {
                let cutStart = i == 0 ? a : a + p.pad
                let cutEnd = j >= n ? b : b - p.pad
                if cutEnd - cutStart > 1e-3 { out.append(SilenceRange(start: cutStart, end: cutEnd)) }
            }
            i = j
        }
        return out
    }

    /// 無音を除いて残す範囲(`silent` の補集合、[0, duration])。
    public func keepRanges(_ params: SilenceParams) -> [SilenceRange] {
        SilenceDetector.keepRanges(silent: silentRanges(params), duration: duration)
    }
}

public enum SilenceDetector {
    /// 窓ごとの RMS の dBFS を求める(左右別々に測って大きい方)。`sampleRate` は 1 秒あたりのフレーム数。
    /// 最後の窓が短いときは、その長さの RMS。
    public static func profile(left: [Float], right: [Float]? = nil, sampleRate: Double, duration: Double? = nil) -> LevelProfile {
        let win = max(1, Int((sampleRate * LevelProfile.windowSeconds).rounded()))
        let n = left.count
        var levels: [Float] = []
        levels.reserveCapacity(n / win + 1)
        var i = 0
        while i < n {
            let e = min(n, i + win)
            levels.append(windowDb(left, right, i, e))
            i = e
        }
        return LevelProfile(levels: levels, duration: duration ?? Double(n) / sampleRate)
    }

    static func windowDb(_ l: [Float], _ r: [Float]?, _ a: Int, _ b: Int) -> Float {
        func rms(_ x: [Float]) -> Double {
            var s = 0.0
            for k in a..<b { s += Double(x[k]) * Double(x[k]) }
            return (s / Double(max(1, b - a))).squareRoot()
        }
        let v = max(rms(l), r.map { rms($0) } ?? 0)
        return v <= 1e-6 ? -120 : Float(20 * log10(v))
    }

    /// 無音の補集合。
    public static func keepRanges(silent: [SilenceRange], duration: Double) -> [SilenceRange] {
        var out: [SilenceRange] = []
        var pos = 0.0
        for s in silent.sorted(by: { $0.start < $1.start }) {
            if s.start > pos + 1e-9 { out.append(SilenceRange(start: pos, end: s.start)) }
            pos = max(pos, s.end)
        }
        if duration > pos + 1e-9 { out.append(SilenceRange(start: pos, end: duration)) }
        return out
    }

    /// 無音カットできるクリップか: 音の出る素材(audio / voice / video)で、速度・逆再生・フリーズが無い。
    /// 速度や逆再生のあるクリップは、素材の時間とタイムラインの時間が 1 対 1 にならないので対象にしない。
    public static func supports(_ c: Clip) -> Bool {
        Clip.supportsAudioFx(c) && !c.hasAudioRemap && (c.src.map { !$0.isEmpty } ?? false) && c.duration > 0
    }

    /// クリップが使う範囲([offset, offset + 長さ])の音を読んで、音の大きさの変化を測る。音が読めない・無いときは nil。
    /// ミキサーと同じ経路(AVAudioFile / AVAssetReader、48 kHz ステレオ)で読む。
    public static func analyze(clip c: Clip) -> LevelProfile? {
        guard supports(c), let src = try? AudioMixer.openSource(c, offset: c.offset, span: c.duration) else { return nil }
        let sr = AudioMixer.sampleRate
        let total = Int((c.duration * sr).rounded())
        let win = Int((sr * LevelProfile.windowSeconds).rounded())      // 480
        let chunk = win * 100                                           // 1 秒(窓の整数倍)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: chunk), r = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { l.deallocate(); r.deallocate() }
        var levels: [Float] = []
        levels.reserveCapacity(total / win + 1)
        var done = 0
        while done < total {
            let want = min(chunk, total - done)
            let got = src.read(left: l, right: r, frames: want)
            if got <= 0 { break }
            var i = 0
            while i < got {
                let e = min(got, i + win)
                var sl = 0.0, sr2 = 0.0
                for k in i..<e { sl += Double(l[k]) * Double(l[k]); sr2 += Double(r[k]) * Double(r[k]) }
                let v = (max(sl, sr2) / Double(e - i)).squareRoot()
                levels.append(v <= 1e-6 ? -120 : Float(20 * log10(v)))
                i = e
            }
            done += got
        }
        // 素材が短くて読めなかったぶんは無音として扱う
        let windows = Int((Double(total) / Double(win)).rounded(.up))
        while levels.count < windows { levels.append(-120) }
        return LevelProfile(levels: levels, duration: c.duration)
    }
}
