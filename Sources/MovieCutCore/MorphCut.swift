import Foundation
import CoreGraphics

// モーフカット: クリップの境界(前のクリップの終わり ↔ 後ろのクリップの頭)を、
// 境界フレーム間のオプティカルフローと顔の位置合わせで変形・補間してつなぐ。
// 判定・位置合わせ・隣接の探索は純粋関数で、UI にも Renderer にも依存しない。
// 描画は Renderer.morphAdjustedFrame から呼ぶ(プレビューと書き出しで同じ経路)。

/// トランジションの計算結果のうち、モーフ用の視覚状態。
public struct MorphCutVisualState: Equatable, Sendable {
    /// true = transitionIn 側(A = 前のクリップ, B = 自分)、false = transitionOut 側(A = 自分, B = 次のクリップ)
    public var isIn: Bool
    /// 0 = A のコマそのまま、1 = B のコマそのまま
    public var weight: Double

    public init(isIn: Bool, weight: Double) {
        self.isIn = isIn; self.weight = weight
    }
}

/// モーフカットの設定(params の "morphStrength" / "morphFace")。
public struct MorphCutParameters: Equatable, Sendable {
    /// 0〜1。モーフ結果とクロスディゾルブの配合(1 = モーフのみ、0 = ディゾルブのみ)
    public var strength: Double
    /// 顔の位置合わせを優先するか
    public var facePriority: Bool

    public static let defaultStrength = 1.0

    public init(strength: Double = MorphCutParameters.defaultStrength, facePriority: Bool = true) {
        self.strength = Self.clampedStrength(strength)
        self.facePriority = facePriority
    }

    /// 有限でなければ既定、0〜1 に収める。
    public static func clampedStrength(_ v: Double) -> Double {
        guard v.isFinite else { return defaultStrength }
        return min(max(v, 0), 1)
    }
}

extension Transition {
    /// params の "morphStrength"(number)/ "morphFace"(bool、number の 0/1 も受ける)。無ければ既定。
    public var morphParameters: MorphCutParameters {
        var p = MorphCutParameters()
        guard case .object(let o) = params else { return p }
        if case .number(let v) = o["morphStrength"] { p.strength = MorphCutParameters.clampedStrength(v) }
        switch o["morphFace"] {
        case .bool(let b): p.facePriority = b
        case .number(let n): p.facePriority = n != 0
        default: break
        }
        return p
    }
}

/// 境界の処理の選び方。
public enum MorphCutStrategy: Equatable, Sendable { case morph, crossDissolve, none }

public enum MorphCut {
    /// フローの平均量(グリッド短辺に対する比)がこれを超えたらクロスディゾルブへ
    public static let maxMeanMotionFraction = 0.30
    /// 顔中心の位置合わせで動かす上限(フレーム寸法に対する比、正規化座標)
    public static let maxFaceShiftFraction = 0.20
    /// 両方に顔があるのに中心がこれ以上ずれたら別場面とみなしてクロスディゾルブへ
    public static let faceDissolveShiftFraction = 0.5
    /// 境界とみなす隣接クリップとの間隔の上限(秒)
    public static let maxNeighborGap = 0.5

    // MARK: フォールバック判定

    /// 境界の処理を決める(純粋関数)。
    public static func strategy(hasNeighbor: Bool, sizeMatches: Bool, flowAvailable: Bool,
                                lumaDifference: Double?, meanMotionFraction: Double?) -> MorphCutStrategy {
        guard hasNeighbor, sizeMatches else { return .none }
        guard flowAvailable, let m = meanMotionFraction, m <= maxMeanMotionFraction else { return .crossDissolve }
        if let l = lumaDifference, l > OpticalFlowInterpolator.sceneCutThreshold { return .crossDissolve }
        return .morph
    }

    /// フローの平均量 ÷ グリッドの短辺。空フローは nil。
    public static func meanMotionFraction(_ flow: FlowField) -> Double? {
        let n = flow.width * flow.height
        guard n > 0, flow.data.count >= n * 2 else { return nil }
        var sum = 0.0
        for i in 0..<n {
            let dx = Double(flow.data[2 * i]), dy = Double(flow.data[2 * i + 1])
            sum += (dx * dx + dy * dy).squareRoot()
        }
        return sum / Double(n) / Double(min(flow.width, flow.height))
    }

    // MARK: 顔の位置合わせ

    /// 面積最大の顔の中心(正規化・左上原点)。
    private static func largestFaceCenter(_ faces: [CGRect]) -> (x: Double, y: Double)? {
        guard let f = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return (Double(f.midX), Double(f.midY))
    }

    /// 顔の位置合わせ量(正規化・左上原点の中心差 B−A)。facePriority が false・どちらか顔なし・ずれ過大(別場面)は nil。
    /// 通常のずれは各軸 ±maxFaceShiftFraction に収める。
    public static func faceAlignment(facesA: [CGRect], facesB: [CGRect], facePriority: Bool) -> (dx: Double, dy: Double)? {
        guard facePriority, let a = largestFaceCenter(facesA), let b = largestFaceCenter(facesB) else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y
        guard dx.isFinite, dy.isFinite, hypot(dx, dy) <= faceDissolveShiftFraction else { return nil }
        let m = maxFaceShiftFraction
        return (min(max(dx, -m), m), min(max(dy, -m), m))
    }

    /// 両方に顔があり、中心の差が faceDissolveShiftFraction を超えるか(別場面とみなす)。
    public static func faceShiftTooLarge(facesA: [CGRect], facesB: [CGRect]) -> Bool {
        guard let a = largestFaceCenter(facesA), let b = largestFaceCenter(facesB) else { return false }
        return hypot(b.x - a.x, b.y - a.y) > faceDissolveShiftFraction
    }

    // MARK: 境界の相手

    /// 同じトラックのクリップ列から、境界の相手の index を探す(純粋関数)。対象は .video / .image のみ。
    /// .in: 自分より前で end <= 自分の start + 1e-9、間隔が maxNeighborGap 以下、end が最大のもの。
    /// .out: 自分より後で start >= 自分の end − 1e-9、間隔が maxNeighborGap 以下、start が最小のもの。
    public static func neighborIndex(clips: [Clip], for clipId: String, edge: TransitionEdge) -> Int? {
        guard let me = clips.first(where: { $0.id == clipId }) else { return nil }
        let eps = 1e-9
        var best: Int?
        for (i, o) in clips.enumerated() where o.id != clipId && (o.type == .video || o.type == .image) {
            if edge == .in {
                let end = o.start + o.duration
                guard end <= me.start + eps, me.start - end <= maxNeighborGap else { continue }
                if best == nil || end > clips[best!].start + clips[best!].duration { best = i }
            } else {
                let myEnd = me.start + me.duration
                guard o.start >= myEnd - eps, o.start - myEnd <= maxNeighborGap else { continue }
                if best == nil || o.start < clips[best!].start { best = i }
            }
        }
        return best
    }

    // MARK: コマを作る

    /// A と B の間の重み weight のコマ。weight <= 0 → a、>= 1 → b(同一インスタンス)。
    /// 寸法不一致・作れないときは nil(呼び出し側は素のコマのまま)。
    public static func morphImage(_ a: CGImage, _ b: CGImage, weight: Double, flow: FlowField?,
                                  facesA: [CGRect], facesB: [CGRect], params: MorphCutParameters) -> CGImage? {
        if weight <= 0 { return a }
        if weight >= 1 { return b }
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else { return nil }
        // 輝度差(縮小画像どうし)
        let (fw, fh) = OpticalFlowInterpolator.flowSize(width: a.width, height: a.height)
        var luma: Double?
        if let ba = OpticalFlowInterpolator.bitmap(of: a, width: fw, height: fh),
           let bb = OpticalFlowInterpolator.bitmap(of: b, width: fw, height: fh) {
            luma = OpticalFlowInterpolator.meanLumaDifference(ba, bb)
        }
        var s = strategy(hasNeighbor: true, sizeMatches: true, flowAvailable: flow != nil,
                         lumaDifference: luma, meanMotionFraction: flow.flatMap { meanMotionFraction($0) })
        if s == .morph, params.facePriority, faceShiftTooLarge(facesA: facesA, facesB: facesB) { s = .crossDissolve }
        switch s {
        case .none: return nil
        case .crossDissolve: return FrameBlend.mix(a, b, weight: weight)
        case .morph: break
        }
        guard let flow else { return FrameBlend.mix(a, b, weight: weight) }
        // 顔の位置合わせ: 中間位置で顔が一致するよう A と B を平行移動する(faces は左上原点、CGContext は左下原点)
        var alignedA = a, alignedB = b
        if let d = faceAlignment(facesA: facesA, facesB: facesB, facePriority: params.facePriority) {
            let W = Double(a.width), H = Double(a.height)
            alignedA = translated(a, dx: d.dx * W * weight, dy: -d.dy * H * weight) ?? a
            alignedB = translated(b, dx: -d.dx * W * (1 - weight), dy: d.dy * H * (1 - weight)) ?? b
        }
        guard let morph = OpticalFlowInterpolator.interpolate(alignedA, alignedB, weight: weight, flow: flow) else {
            return FrameBlend.mix(a, b, weight: weight)
        }
        if params.strength >= 1 { return morph }
        guard let dissolve = FrameBlend.mix(a, b, weight: weight) else { return morph }
        return FrameBlend.mix(dissolve, morph, weight: params.strength) ?? morph
    }

    /// 画像を (dx, dy)(CGContext 空間の画素、左下原点)だけずらして描く。背景は透明。0 のときは元の画像のまま。
    static func translated(_ img: CGImage, dx: Double, dy: Double) -> CGImage? {
        if dx == 0 && dy == 0 { return img }
        let cs = img.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
        ctx.draw(img, in: CGRect(x: dx, y: dy, width: Double(img.width), height: Double(img.height)))
        return ctx.makeImage()
    }
}
