import Foundation
import CoreMedia

/// フレームレートを分数(num/den)で持つ。放送用の 29.97 などは 30000/1001 のように正確に扱い、
/// 時刻とコマ番号の変換はすべてここを通す(Double の 1/fps を足し込むとずれるため)。
public struct FrameRate: Equatable, Hashable, Sendable {
    public let num: Int
    public let den: Int

    public init(num: Int, den: Int) {
        let g = Self.gcd(abs(num), abs(den))
        let d = max(1, g)
        self.num = max(1, num / d)
        self.den = max(1, den / d)
    }

    /// 1 秒あたりのコマ数(分数どおりの値)。
    public var value: Double { Double(num) / Double(den) }

    /// 1 コマの長さ(秒)。
    public var frameDuration: Double { Double(den) / Double(num) }

    // MARK: 範囲・定数

    public static let minValue = 1.0
    public static let maxValue = 240.0
    public static let defaultValue = 60.0

    /// 放送用の分数レート(表示用の値 → 正確な分数)。許容差は ±0.01。
    static let broadcast: [(label: Double, num: Int, den: Int)] = [
        (23.976, 24000, 1001), (29.97, 30000, 1001), (47.952, 48000, 1001), (59.94, 60000, 1001), (119.88, 120000, 1001),
    ]
    static let broadcastTolerance = 0.01

    /// メニューやシートに並べる定番のレート。
    public static let presets: [Double] = [24, 30, 48, 60, 120, 240]
    /// 放送用の小数レート(プリセットには並べず、シートの「放送用」の行にだけ出す)。
    public static let broadcastPresets: [Double] = [23.976, 29.97, 59.94]

    // MARK: 変換

    /// Double から分数へ。放送用レートに近ければその分数、それ以外は分母 1000 を約分した分数(12.5 → 25/2)。
    /// 範囲外は 1…240 に収める。
    public static func from(_ v: Double) -> FrameRate {
        let v = clamp(v)
        for b in broadcast where abs(v - b.label) <= broadcastTolerance { return FrameRate(num: b.num, den: b.den) }
        return FrameRate(num: Int((v * 1000).rounded()), den: 1000)
    }

    /// 1…240 に収める(NaN / 無限大は既定の 60)。
    public static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return defaultValue }
        return min(maxValue, max(minValue, v))
    }

    /// ファイルに書く・メニューで比べるための値。放送用は 29.97 のような表示値、それ以外は小数 3 桁に丸めた値。
    public static func canonical(_ v: Double) -> Double {
        let v = clamp(v)
        for b in broadcast where abs(v - b.label) <= broadcastTolerance { return b.label }
        return (v * 1000).rounded() / 1000
    }

    /// 同じレートとみなせるか(メニューの ✓ 用)。
    public static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0005 }

    /// 短い表記。整数は小数なし("60")、そのほかは小数 3 桁まで・末尾の 0 なし("29.97" "23.976" "12.5")。
    public static func label(_ v: Double) -> String {
        let c = canonical(v)
        if c == c.rounded() { return String(Int(c)) }
        var s = String(format: "%.3f", c)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: 時刻とコマ

    /// コマ番号 → 時刻(秒)。
    public func time(ofFrame i: Int) -> Double { Double(i) * Double(den) / Double(num) }

    /// コマ番号 → CMTime(value = i × den、timescale = num で誤差なし)。
    public func cmTime(frame i: Int) -> CMTime {
        CMTime(value: CMTimeValue(i) * CMTimeValue(den), timescale: CMTimeScale(num))
    }

    /// 長さ(秒)に必要なコマ数 = ceil(長さ × fps)。3.7×60=222.00000000000003 で 1 コマ増えないよう少し引く。
    public func frameCount(duration: Double) -> Int {
        guard duration > 0, duration.isFinite else { return 0 }
        return Int(ceil(duration * value - 1e-6))
    }

    /// 時刻 t を含むコマの番号(コマの先頭に丸める。誤差を見込んで少し足す)。
    public func frameIndex(at t: Double) -> Int { Int(floor(max(0, t) * value + 1e-6)) }

    /// 時刻 t をコマの境目にそろえた時刻(floor)。
    public func snapped(_ t: Double) -> Double { time(ofFrame: frameIndex(at: t)) }

    /// コマ送り: frames コマ動かした時刻(0 未満にはならない)。コマの途中にいるときは、進むなら次の境目、戻るなら今の境目から数える。
    public func stepped(from t: Double, frames: Int) -> Double {
        let pos = max(0, t) * value
        let base = frames < 0 ? Int(ceil(pos - 1e-6)) : Int(floor(pos + 1e-6))
        return time(ofFrame: max(0, base + frames))
    }

    /// 1 コマの長さ(ミリ秒)の表記。
    public func frameMilliseconds() -> String { String(format: "%.3f", frameDuration * 1000) }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

// MARK: - 画面に出す文字

public enum VideoText {
    /// プレビュー左上の表示: "1920×1080 · 29.97fps"(整数は小数なし)。
    public static func chip(width: Int, height: Int, fps: Double) -> String {
        "\(width)×\(height) · \(FrameRate.label(fps))fps"
    }
}
