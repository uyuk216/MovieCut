import Foundation
import CoreGraphics
import ImageIO

/// アニメーション画像(GIF / APNG / アニメーション WebP)のコマの表示タイミング。純粋な値型。
/// 動く立ち絵(単体・リグのパーツ)がクリップ内時刻から「いま出すコマ」を決めるのに使う。
public struct AnimatedImageTiming: Equatable {
    /// コマ数。
    public var frameCount: Int
    /// 各コマの表示秒(`frameCount` と同じ長さ)。
    public var delays: [Double]
    /// ループ回数。0 = 無限。
    public var loopCount: Int

    /// 遅延の下限(秒)。GIF の 0 遅延(ブラウザは 0.1 秒に直すが、ここでは時刻を進めるため最小値に丸める)対策。
    public static let minimumDelay = 0.02
    /// 遅延が取れない形式の既定(秒)。
    public static let defaultDelay = 0.1

    public init(frameCount: Int, delays: [Double], loopCount: Int = 0) {
        self.frameCount = frameCount
        self.delays = delays
        self.loopCount = loopCount
    }

    /// 下限を適用した各コマの表示秒。
    var clampedDelays: [Double] {
        (0..<max(0, frameCount)).map { i in
            let d = i < delays.count ? delays[i] : Self.defaultDelay
            return d.isFinite ? max(Self.minimumDelay, d) : Self.defaultDelay
        }
    }

    /// 1 周の長さ(下限適用前の遅延の合計)。0 以下なら nil(静止画扱い)。
    public var totalDuration: Double? {
        let s = delays.reduce(0, +)
        return s.isFinite && s > 0 ? s : nil
    }

    /// アニメーションとして動かすか(2 コマ以上で、1 周の長さがある)。
    public var isAnimated: Bool { frameCount > 1 && totalDuration != nil }

    /// 経過秒 `elapsed` に出すコマの番号(0 始まり)。
    /// - elapsed ≦ 0・静止画・コマ 1 つは 0。
    /// - 無限ループは 1 周の長さで剰余、有限ループは回数を使い切ったら最後のコマで止まる。
    /// - コマの境界は「そのコマの開始 ≦ elapsed < 次のコマの開始」。
    public func frameIndex(at elapsed: Double) -> Int {
        guard isAnimated, elapsed.isFinite, elapsed > 0 else { return 0 }
        let ds = clampedDelays
        let total = ds.reduce(0, +)
        guard total > 0 else { return 0 }
        // 0.1 + 0.2 のような 2 進小数の誤差でコマの境界・1 周の境目がずれないよう、ごく小さな許容(1ns)を持たせる
        let eps = 1e-9
        var t = elapsed
        if loopCount > 0, t >= total * Double(loopCount) - eps { return ds.count - 1 }
        t = t.truncatingRemainder(dividingBy: total)
        if total - t < eps { t = 0 }
        var start = 0.0
        for (i, d) in ds.enumerated() {
            if t < start + d - eps { return i }
            start += d
        }
        return ds.count - 1
    }
}

public enum AnimatedImage {
    /// ファイルのアニメーションのタイミング。静止画(1 コマ)・読めない・壊れているファイルは nil。
    public static func timing(atPath path: String) -> AnimatedImageTiming? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return timing(of: src)
    }

    /// `CGImageSource` のアニメーションのタイミング。1 コマ以下は nil。
    public static func timing(of src: CGImageSource) -> AnimatedImageTiming? {
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return nil }
        let delays = (0..<n).map { delay(src, index: $0) }
        return AnimatedImageTiming(frameCount: n, delays: delays, loopCount: loopCount(src))
    }

    /// 1 コマの表示秒。GIF / APNG / WebP の辞書から(未クランプ値があればそれを優先)。取れなければ既定の 0.1 秒。
    static func delay(_ src: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else { return AnimatedImageTiming.defaultDelay }
        let sets: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictKey, unclamped, clamped) in sets {
            guard let dict = props[dictKey] as? [CFString: Any] else { continue }
            if let v = (dict[unclamped] as? NSNumber)?.doubleValue, v > 0 { return v }
            if let v = (dict[clamped] as? NSNumber)?.doubleValue { return v }
        }
        return AnimatedImageTiming.defaultDelay
    }

    /// ループ回数(GIF / APNG / WebP の LoopCount)。取れなければ 0(無限)。
    static func loopCount(_ src: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] else { return 0 }
        let sets: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
        ]
        for (dictKey, key) in sets {
            if let dict = props[dictKey] as? [CFString: Any], let v = (dict[key] as? NSNumber)?.intValue { return max(0, v) }
        }
        return 0
    }
}
