import Foundation
import CoreGraphics
import CoreImage
import Metal

// MARK: - 描画バックエンド(#77 Metal レンダリング・段階導入)
//
// 従来の描画は `CIContext(options:)`(デバイス未指定)で Core Image を使っていた。
// 既定の CIContext は内部で Metal を使うこともあるが、デバイス・コマンドキューは
// フレームワーク任せで、共有も保証されない。本モジュールは:
//
//   - Metal デバイスとコマンドキューを明示した CIContext を 1 つ共有する経路(.metal)
//   - 従来と全く同じオブジェクトを返す経路(.legacy = グローバルの `ciContext` そのもの)
//   - 利用可能なら Metal、無ければ従来へ自動で戻る経路(.auto、Renderer の既定)
//
// を用意し、呼び出し側が選べるようにする。最終合成は従来どおり CGContext で行うため、
// エフェクト・ぼかし等の Core Image 段だけが GPU 経路に載る。Metal が使えない環境
// (デバイスが無い・コマンドキューが作れない)では `.metal` を指定しても `.legacy` に
// フォールバックするので、従来経路で必ず描ける。
//
// 画素の同一性: 作業色空間・出力色空間・出力形式(BGRA8・sRGB)は従来と同一にそろえる。
// 検証は `PixelComparison` と RenderBackendTests(従来経路との画素比較)で行う。

/// 描画バックエンドの選択。
public enum RenderBackend: String, CaseIterable, Equatable, Sendable {
    /// 従来経路: デバイス未指定の共有 `CIContext`(従来と同一オブジェクト)。
    case legacy
    /// Metal 経路: `MTLDevice` / `MTLCommandQueue` を明示した共有 `CIContext`。
    case metal
    /// 自動: Metal が利用可能なら Metal、無ければ従来経路。
    case auto

    /// 表示・ログ用の名前。
    public var title: String {
        switch self {
        case .legacy: return "従来 (Core Image)"
        case .metal: return "Metal"
        case .auto: return "自動"
        }
    }
}

/// バックエンドごとの `CIContext` を作って共有する窓口。スレッドセーフ(生成はロック内で一度だけ)。
public final class RenderContextProvider: @unchecked Sendable {
    public static let shared = RenderContextProvider()

    private let lock = NSLock()
    private var cachedMetalContext: CIContext?
    private var metalProbed = false
    private var cachedDevice: MTLDevice?
    private var cachedQueue: MTLCommandQueue?

    public init() {}

    /// Metal デバイス(作れなければ nil)。結果はキャッシュする。
    public var metalDevice: MTLDevice? {
        lock.lock(); defer { lock.unlock() }
        probeMetalLocked()
        return cachedDevice
    }

    /// Metal デバイス名(診断用。無ければ nil)。
    public var metalDeviceName: String? { metalDevice?.name }

    /// Metal 経路が使えるか(デバイスとコマンドキューと CIContext が用意できるか)。
    public var isMetalAvailable: Bool { metalContext != nil }

    /// Metal 用 CIContext(従来と同じ作業・出力色空間)。作れなければ nil。
    public var metalContext: CIContext? {
        lock.lock(); defer { lock.unlock() }
        probeMetalLocked()
        return cachedMetalContext
    }

    /// ロック保持中に呼ぶこと。デバイス・キュー・コンテキストを一度だけ作る。
    private func probeMetalLocked() {
        guard !metalProbed else { return }
        metalProbed = true
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        cachedDevice = device
        cachedQueue = queue
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        cachedMetalContext = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: sRGB,
            .outputColorSpace: sRGB,
        ])
    }

    /// 従来経路の CIContext(Renderer のグローバル `ciContext` そのもの)。
    public var legacyContext: CIContext { ciContext }

    /// バックエンドを実際に使う経路へ解決する(`.legacy` か `.metal` のどちらか)。
    /// `.metal` を選んでも Metal が使えない環境では `.legacy` に戻る(フォールバック)。
    public func resolvedBackend(for backend: RenderBackend) -> RenderBackend {
        switch backend {
        case .legacy: return .legacy
        case .metal: return isMetalAvailable ? .metal : .legacy
        case .auto: return isMetalAvailable ? .metal : .legacy
        }
    }

    /// バックエンドに対応する CIContext。`.metal` / `.auto` で Metal が使えないときは従来のもの。
    public func context(for backend: RenderBackend) -> CIContext {
        switch resolvedBackend(for: backend) {
        case .metal: return metalContext ?? ciContext
        case .legacy, .auto: return ciContext
        }
    }
}

// MARK: - 画素比較(描画の同一性検証)

/// 2 枚の画像の画素差分の要約(同一性検証・テスト・診断用)。
public struct PixelDifference: Equatable, Sendable {
    /// 総画素数。
    public var totalPixels: Int
    /// 1 チャンネルでも異なる画素の数。
    public var differingPixels: Int
    /// チャンネル値の差の最大(0〜255)。
    public var maxChannelDifference: Int
    /// チャンネル値の差の絶対値の平均(0〜255、全チャンネル平均)。
    public var meanAbsoluteDifference: Double

    /// 異なる画素の割合(0〜1)。
    public var differingFraction: Double {
        totalPixels > 0 ? Double(differingPixels) / Double(totalPixels) : 0
    }
    /// 完全に一致するか。
    public var isIdentical: Bool { differingPixels == 0 }

    public init(totalPixels: Int, differingPixels: Int, maxChannelDifference: Int, meanAbsoluteDifference: Double) {
        self.totalPixels = totalPixels
        self.differingPixels = differingPixels
        self.maxChannelDifference = maxChannelDifference
        self.meanAbsoluteDifference = meanAbsoluteDifference
    }
}

/// CGImage 同士を画素単位で比べる。大きさが違うときは nil(比べられない)。
public enum PixelComparison {
    /// RGBA(premultipliedLast・sRGB・4 バイト/画素)に展開した生データ。作れなければ nil。
    static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &data, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    public static func compare(_ a: CGImage, _ b: CGImage) -> PixelDifference? {
        guard a.width == b.width, a.height == b.height,
              let da = rgbaBytes(a), let db = rgbaBytes(b), da.count == db.count else { return nil }
        var differing = 0
        var maxDiff = 0
        var sum: Int64 = 0
        let pixels = a.width * a.height
        for p in 0..<pixels {
            var pixelDiffers = false
            for ch in 0..<4 {
                let d = abs(Int(da[p * 4 + ch]) - Int(db[p * 4 + ch]))
                if d > 0 { pixelDiffers = true }
                if d > maxDiff { maxDiff = d }
                sum += Int64(d)
            }
            if pixelDiffers { differing += 1 }
        }
        let mean = pixels > 0 ? Double(sum) / Double(pixels * 4) : 0
        return PixelDifference(totalPixels: pixels, differingPixels: differing,
                               maxChannelDifference: maxDiff, meanAbsoluteDifference: mean)
    }
}
