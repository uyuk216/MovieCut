import Foundation
import CoreGraphics
import CoreImage

// MARK: - 変形の座標の約束
//
// メッシュ変形(W3-04 / 監査 #55)とパペット変形(W3-05 / 監査 #56)のモデル・変位場・描画。
//
// 座標はすべて「クリップ自身の絵に対する割合(0〜1)・左上原点」(x は右へ、y は下へ)。
// マスク(`ClipMask`)と同じ約束で、ファイルにもこの形で書く。描画のときだけ、作業範囲の画素へ直す。
// どちらの変形も「変位場(出力の各点が、元の絵のどこから来るか)」に直してから、共通の
// サンプラ(`WarpRenderer`)で 1 回だけ画素を動かす。二重実装を避けるため、メッシュとパペットは
// 変位の作り方だけが違い、画素の移動は共有する。
//
// 後方互換: 変形が無い(nil)・制御点/ピンがすべて元の位置(identity)のクリップは、
// 描画の速い道の判定(`Clip.hasActiveWarp`)で従来経路のままになり、画素は従来と完全一致する。
// ファイルには、変形を設定したときだけ `meshWarp` / `puppetWarp` を書く(値があるときだけ保存)。

/// 変形の点(割合・左上原点)。範囲外(0 未満・1 超)も許す(絵の外へ引っ張る変形)。
public struct WarpPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    /// 変位として足し引きするための素の形。
    public static func + (a: WarpPoint, b: WarpPoint) -> WarpPoint { WarpPoint(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: WarpPoint, b: WarpPoint) -> WarpPoint { WarpPoint(x: a.x - b.x, y: a.y - b.y) }
}

// MARK: - メッシュ変形

/// メッシュ変形: 列×行の格子の各制御点を元の位置からずらす変形。
/// `points` は行優先(左上から右へ、上から下へ)の現在の位置で、数は cols × rows。
/// 元の位置は格子から決まる(列 i → x = i/(cols-1)、行 j → y = j/(rows-1))。
public struct MeshWarp: Equatable, Sendable {
    public static let minGrid = 2
    public static let maxGrid = 8
    public static let defaultCols = 3
    public static let defaultRows = 3
    /// 制御点の位置の許す範囲(割合)。絵の外へも引っ張れるが、破綻しないよう抑える。
    public static let positionRange = -1.0...2.0

    public var cols: Int
    public var rows: Int
    public var points: [WarpPoint]
    /// 知らないキー(保持して書き戻す)
    public var extra: [String: JSONValue] = [:]

    public init(cols: Int = MeshWarp.defaultCols, rows: Int = MeshWarp.defaultRows) {
        let c = Self.clampGrid(cols), r = Self.clampGrid(rows)
        self.cols = c
        self.rows = r
        self.points = (0..<(c * r)).map { Self.home(index: $0, cols: c, rows: r) }
    }

    public init(cols: Int, rows: Int, points: [WarpPoint]) {
        self.cols = Self.clampGrid(cols)
        self.rows = Self.clampGrid(rows)
        self.points = points
        self = normalized
    }

    static func clampGrid(_ v: Int) -> Int { min(max(v, minGrid), maxGrid) }
    static func clampPos(_ v: Double) -> Double { v.isFinite ? min(max(v, positionRange.lowerBound), positionRange.upperBound) : 0 }

    /// 格子点の元の位置(割合・左上原点)。
    public static func home(index: Int, cols: Int, rows: Int) -> WarpPoint {
        let c = cols > 1 ? Double(index % cols) / Double(cols - 1) : 0.5
        let r = rows > 1 ? Double(index / cols) / Double(rows - 1) : 0.5
        return WarpPoint(x: c, y: r)
    }
    public func home(index: Int) -> WarpPoint { Self.home(index: index, cols: cols, rows: rows) }

    /// 格子数・点の数・範囲を正す。点が足りなければ元の位置で埋め、多ければ切る。
    public var normalized: MeshWarp {
        var m = self
        m.cols = Self.clampGrid(m.cols); m.rows = Self.clampGrid(m.rows)
        var pts: [WarpPoint] = []
        pts.reserveCapacity(m.cols * m.rows)
        for i in 0..<(m.cols * m.rows) {
            let p = i < m.points.count ? m.points[i] : Self.home(index: i, cols: m.cols, rows: m.rows)
            pts.append(WarpPoint(x: Self.clampPos(p.x), y: Self.clampPos(p.y)))
        }
        m.points = pts
        return m
    }

    /// 変形なし(全点が元の位置)か。true のとき描画は従来と完全一致する。
    public var isIdentity: Bool {
        let m = normalized
        return m.points.enumerated().allSatisfy { i, p in
            let h = m.home(index: i)
            return abs(p.x - h.x) < 1e-9 && abs(p.y - h.y) < 1e-9
        }
    }

    /// 一番大きな変位(割合)。描画の作業範囲の余白の目安。
    public var maxDisplacement: Double {
        let m = normalized
        return m.points.enumerated().map { i, p in
            let h = m.home(index: i)
            return hypot(p.x - h.x, p.y - h.y)
        }.max() ?? 0
    }

    /// 割合の点 (u, v) での変位(割合)。格子の変位を双線形に補間する(セルの外は端のセルで抑える)。
    public func displacement(u: Double, v: Double) -> WarpPoint {
        let m = normalized
        let gx = min(max(u, 0), 1) * Double(m.cols - 1)
        let gy = min(max(v, 0), 1) * Double(m.rows - 1)
        let i0 = min(Int(gx.rounded(.down)), m.cols - 2), j0 = min(Int(gy.rounded(.down)), m.rows - 2)
        let fx = min(max(gx - Double(i0), 0), 1), fy = min(max(gy - Double(j0), 0), 1)
        func d(_ i: Int, _ j: Int) -> WarpPoint {
            let idx = j * m.cols + i
            return m.points[idx] - m.home(index: idx)
        }
        let d00 = d(i0, j0), d10 = d(i0 + 1, j0), d01 = d(i0, j0 + 1), d11 = d(i0 + 1, j0 + 1)
        return WarpPoint(
            x: (d00.x * (1 - fx) + d10.x * fx) * (1 - fy) + (d01.x * (1 - fx) + d11.x * fx) * fy,
            y: (d00.y * (1 - fx) + d10.y * fx) * (1 - fy) + (d01.y * (1 - fx) + d11.y * fx) * fy)
    }

    static let knownKeys: Set<String> = ["cols", "rows", "points"]
}

extension MeshWarp: Codable {
    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        self.init(cols: l.int("cols") ?? Self.defaultCols, rows: l.int("rows") ?? Self.defaultRows,
                  points: l.value("points") ?? [])
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        let m = normalized
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(m.cols, forKey: AnyKey("cols"))
        try c.encode(m.rows, forKey: AnyKey("rows"))
        try c.encode(m.points, forKey: AnyKey("points"))
    }
}

// MARK: - パペット変形

/// パペットのピン。`home` が元の位置、`x`/`y` が現在の位置(割合・左上原点)。
/// `fixed`(固定ピン)は動かず、周りの変位を 0 へ引き戻す錨になる。
public struct PuppetPin: Equatable, Sendable {
    public var hx: Double
    public var hy: Double
    public var x: Double
    public var y: Double
    public var fixed: Bool

    public init(hx: Double, hy: Double, x: Double? = nil, y: Double? = nil, fixed: Bool = false) {
        self.hx = MeshWarp.clampPos(hx); self.hy = MeshWarp.clampPos(hy)
        self.x = MeshWarp.clampPos(x ?? hx); self.y = MeshWarp.clampPos(y ?? hy)
        self.fixed = fixed
        if fixed { self.x = self.hx; self.y = self.hy }
    }

    public var home: WarpPoint { WarpPoint(x: hx, y: hy) }
    public var current: WarpPoint { WarpPoint(x: x, y: y) }
    /// このピンの変位(固定ピンは常に 0)。
    public var displacement: WarpPoint { fixed ? WarpPoint(x: 0, y: 0) : WarpPoint(x: x - hx, y: y - hy) }
    public var isIdentity: Bool { abs(displacement.x) < 1e-9 && abs(displacement.y) < 1e-9 }

    public var normalized: PuppetPin { PuppetPin(hx: hx, hy: hy, x: x, y: y, fixed: fixed) }

    static let knownKeys: Set<String> = ["hx", "hy", "x", "y", "fixed"]
}

extension PuppetPin: Codable {
    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        self.init(hx: l.double("hx") ?? 0.5, hy: l.double("hy") ?? 0.5,
                  x: l.double("x"), y: l.double("y"), fixed: l.bool("fixed") ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        let p = normalized
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(p.hx, forKey: AnyKey("hx"))
        try c.encode(p.hy, forKey: AnyKey("hy"))
        if p.x != p.hx { try c.encode(p.x, forKey: AnyKey("x")) }
        if p.y != p.hy { try c.encode(p.y, forKey: AnyKey("y")) }
        if p.fixed { try c.encode(true, forKey: AnyKey("fixed")) }
    }
}

/// パペット変形: ピンを打って、可動ピンの移動に周囲が滑らかに追従する変形(ボーンなし)。
/// 変位は「ピンまでの距離で重み付けした平均」で、重みは影響半径 `radius` の内側で
/// (1 − (d/R)²)² と落ちる(中心で 1、縁で 0、縁の外は 0)。固定ピンは変位 0 の重みとして
/// 分母にも入るので、固定ピンの周りは動かなくなる。
public struct PuppetWarp: Equatable, Sendable {
    public static let defaultRadius = 0.35
    public static let radiusRange = 0.05...1.0
    public static let maxPins = 32

    public var pins: [PuppetPin]
    /// 影響半径(割合)。既定のときはファイルに書かない。
    public var radius: Double
    /// 知らないキー(保持して書き戻す)
    public var extra: [String: JSONValue] = [:]

    public init(pins: [PuppetPin] = [], radius: Double = PuppetWarp.defaultRadius) {
        self.pins = pins
        self.radius = radius
        self = normalized
    }

    static func clampRadius(_ v: Double) -> Double { v.isFinite ? min(max(v, radiusRange.lowerBound), radiusRange.upperBound) : defaultRadius }

    public var normalized: PuppetWarp {
        var p = self
        p.pins = Array(p.pins.map { $0.normalized }.prefix(Self.maxPins))
        p.radius = Self.clampRadius(p.radius)
        return p
    }

    /// 変形なし(ピンが無い、または全ピンの変位が 0)か。
    public var isIdentity: Bool { normalized.pins.allSatisfy { $0.isIdentity } }

    public var maxDisplacement: Double { normalized.pins.map { hypot($0.displacement.x, $0.displacement.y) }.max() ?? 0 }

    /// 割合の点 (u, v) での変位(割合)。ピンの重み付き平均(重みが無ければ 0)。
    public func displacement(u: Double, v: Double) -> WarpPoint {
        let p = normalized
        guard !p.pins.isEmpty else { return WarpPoint(x: 0, y: 0) }
        let r2 = p.radius * p.radius
        var numX = 0.0, numY = 0.0, den = 0.0
        for pin in p.pins {
            let dx = u - pin.hx, dy = v - pin.hy
            let d2 = dx * dx + dy * dy
            guard d2 < r2 else { continue }
            let t = 1 - d2 / r2
            let w = t * t
            let d = pin.displacement
            numX += w * d.x; numY += w * d.y; den += w
        }
        guard den > 1e-12 else { return WarpPoint(x: 0, y: 0) }
        return WarpPoint(x: numX / den, y: numY / den)
    }

    static let knownKeys: Set<String> = ["pins", "radius"]
}

extension PuppetWarp: Codable {
    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        self.init(pins: l.value("pins") ?? [], radius: l.double("radius") ?? Self.defaultRadius)
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        let p = normalized
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(p.pins, forKey: AnyKey("pins"))
        if p.radius != Self.defaultRadius { try c.encode(p.radius, forKey: AnyKey("radius")) }
    }
}

// MARK: - クリップ側

extension Clip {
    /// 変形(メッシュ/パペット)を付けられる種類(エフェクトと同じ)。
    public static func supportsWarp(_ type: ClipType) -> Bool { supportsEffects(type) }

    /// 描く変形が 1 つでも効いているか(設定があり、変形なしでない)。描画の速い道の判定。
    /// これが false のクリップは、従来の描画経路のままで画素が完全一致する。
    public var hasActiveWarp: Bool {
        (meshWarp.map { !$0.isIdentity } ?? false) || (puppetWarp.map { !$0.isIdentity } ?? false)
    }

    /// 割合の点 (u, v) での合成変位(メッシュ + パペット。割合・左上原点)。
    public func warpDisplacement(u: Double, v: Double) -> WarpPoint {
        var d = WarpPoint(x: 0, y: 0)
        if let m = meshWarp, !m.isIdentity { d = d + m.displacement(u: u, v: v) }
        if let p = puppetWarp, !p.isIdentity { d = d + p.displacement(u: u, v: v) }
        // 極端な重ね合わせでも絵が破綻しないよう、変位そのものを抑える
        return WarpPoint(x: min(max(d.x, -1.5), 1.5), y: min(max(d.y, -1.5), 1.5))
    }

    /// 一番大きな合成変位(割合)。描画の作業範囲の余白の目安。
    public var warpMaxDisplacement: Double {
        max(meshWarp?.maxDisplacement ?? 0, puppetWarp?.maxDisplacement ?? 0)
    }
}

// MARK: - 編集(純粋な計算)

/// メッシュ/パペット変形の編集(UI にも Undo にも依存しない)。変えたときだけ true を返す。
public enum WarpEditing {
    public static func supports(_ c: Clip) -> Bool { Clip.supportsWarp(c.type) }

    // メッシュ

    /// メッシュを用意する(無ければ既定の格子で作る)。すでにあれば何もしない。
    @discardableResult
    public static func ensureMesh(_ c: inout Clip) -> Bool {
        guard supports(c), c.meshWarp == nil else { return false }
        c.meshWarp = MeshWarp()
        return true
    }

    /// 格子の列・行を変える。各新格子点の変位は、旧変位場をその点で測って引き継ぐ(形が大きく崩れない)。
    @discardableResult
    public static func setMeshGrid(_ c: inout Clip, cols: Int, rows: Int) -> Bool {
        guard supports(c) else { return false }
        let old = c.meshWarp ?? MeshWarp()
        let nc = MeshWarp.clampGrid(cols), nr = MeshWarp.clampGrid(rows)
        guard nc != old.cols || nr != old.rows else { return false }
        var pts: [WarpPoint] = []
        for i in 0..<(nc * nr) {
            let h = MeshWarp.home(index: i, cols: nc, rows: nr)
            let d = old.displacement(u: h.x, v: h.y)
            pts.append(WarpPoint(x: MeshWarp.clampPos(h.x + d.x), y: MeshWarp.clampPos(h.y + d.y)))
        }
        c.meshWarp = MeshWarp(cols: nc, rows: nr, points: pts)
        return true
    }

    /// 制御点 1 つを位置 (x, y)(割合)へ動かす。
    @discardableResult
    public static func setMeshPoint(_ c: inout Clip, index: Int, x: Double, y: Double) -> Bool {
        guard supports(c), var m = c.meshWarp, m.points.indices.contains(index) else { return false }
        let p = WarpPoint(x: MeshWarp.clampPos(x), y: MeshWarp.clampPos(y))
        guard m.points[index] != p else { return false }
        m.points[index] = p
        c.meshWarp = m
        return true
    }

    /// 制御点 1 つを元の位置へ戻す。
    @discardableResult
    public static func resetMeshPoint(_ c: inout Clip, index: Int) -> Bool {
        guard let m = c.meshWarp, m.points.indices.contains(index) else { return false }
        return setMeshPoint(&c, index: index, x: m.home(index: index).x, y: m.home(index: index).y)
    }

    /// メッシュ変形を外す(設定そのものを消す)。
    @discardableResult
    public static func clearMesh(_ c: inout Clip) -> Bool {
        guard c.meshWarp != nil else { return false }
        c.meshWarp = nil
        return true
    }

    // パペット

    /// パペットを用意する(無ければ空で作る)。
    @discardableResult
    public static func ensurePuppet(_ c: inout Clip) -> Bool {
        guard supports(c), c.puppetWarp == nil else { return false }
        c.puppetWarp = PuppetWarp()
        return true
    }

    /// ピンを位置 (hx, hy)(割合)に打つ。追加したピンの番号を返す(打てなければ nil)。
    @discardableResult
    public static func addPin(_ c: inout Clip, hx: Double, hy: Double, fixed: Bool = false) -> Int? {
        guard supports(c) else { return nil }
        var p = c.puppetWarp ?? PuppetWarp()
        guard p.pins.count < PuppetWarp.maxPins else { return nil }
        p.pins.append(PuppetPin(hx: hx, hy: hy, fixed: fixed))
        c.puppetWarp = p
        return p.pins.count - 1
    }

    /// ピン 1 つを位置 (x, y)(割合)へ動かす(固定ピンは動かせない)。
    @discardableResult
    public static func movePin(_ c: inout Clip, index: Int, x: Double, y: Double) -> Bool {
        guard supports(c), var p = c.puppetWarp, p.pins.indices.contains(index), !p.pins[index].fixed else { return false }
        let pin = PuppetPin(hx: p.pins[index].hx, hy: p.pins[index].hy, x: x, y: y, fixed: false)
        guard p.pins[index] != pin else { return false }
        p.pins[index] = pin
        c.puppetWarp = p
        return true
    }

    /// ピンの固定/可動を切り替える(固定にすると現在の位置は元の位置へ戻る)。
    @discardableResult
    public static func setPinFixed(_ c: inout Clip, index: Int, _ fixed: Bool) -> Bool {
        guard var p = c.puppetWarp, p.pins.indices.contains(index), p.pins[index].fixed != fixed else { return false }
        let old = p.pins[index]
        p.pins[index] = PuppetPin(hx: old.hx, hy: old.hy, x: old.x, y: old.y, fixed: fixed)
        c.puppetWarp = p
        return true
    }

    @discardableResult
    public static func removePin(_ c: inout Clip, index: Int) -> Bool {
        guard var p = c.puppetWarp, p.pins.indices.contains(index) else { return false }
        p.pins.remove(at: index)
        c.puppetWarp = p
        return true
    }

    @discardableResult
    public static func setPuppetRadius(_ c: inout Clip, _ radius: Double) -> Bool {
        guard supports(c) else { return false }
        var p = c.puppetWarp ?? PuppetWarp()
        let r = PuppetWarp.clampRadius(radius)
        guard p.radius != r || c.puppetWarp == nil else { return false }
        p.radius = r
        c.puppetWarp = p
        return true
    }

    /// パペット変形を外す(設定そのものを消す)。
    @discardableResult
    public static func clearPuppet(_ c: inout Clip) -> Bool {
        guard c.puppetWarp != nil else { return false }
        c.puppetWarp = nil
        return true
    }
}

// MARK: - 描画(変位場サンプラ)

/// 変位場で画素を動かす共通サンプラ。入力はクリップ 1 枚ぶんの画素(作業範囲の CGImage)、
/// 出力は同じ大きさの画像。出力の各画素について、その場所の変位を引いた元の位置から
/// 双線形で色を取る(逆写像)。変位が 0 の画素は元の画素そのままになる。
/// 端の外は端の画素を延ばして読む(絵が縮んでも透明な穴が開かない)。
///
/// 手法の選定(詳しくは docs/メッシュ・パペット変形.md): Core Image には汎用のメッシュ
/// ワープ用フィルタが無く、CIWarpKernel は格子点の数が可変で引数に載せにくい。
/// そのため変位場の評価+サンプリングを CPU で行う。画素単位で独立なので決定的で、
/// プレビューと書き出しで同じ結果になる。代償として大きな作業範囲では CIFilter より遅い。
public enum WarpRenderer {
    /// `bounds` は、変形の座標(割合)の基準になる矩形(画像の画素・左上原点)。
    /// クリップの絵の範囲を渡す。範囲の外の画素にも、場を外挿して変位を与える
    /// (メッシュは端のセルで抑え、パペットは距離で決まる)。
    public static func warp(_ image: CGImage, clip: Clip, bounds: CGRect) -> CGImage? {
        guard clip.hasActiveWarp, image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let w = image.width, h = image.height
        // 元の画素(RGBA・premultiplied)
        var src = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let sctx = CGContext(data: &src, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        sctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var dst = [UInt8](repeating: 0, count: w * h * 4)
        let bw = Double(bounds.width), bh = Double(bounds.height)
        let bx = Double(bounds.minX), by = Double(bounds.minY)
        for py in 0..<h {
            let v = (Double(py) + 0.5 - by) / bh
            for px in 0..<w {
                let u = (Double(px) + 0.5 - bx) / bw
                let d = clip.warpDisplacement(u: u, v: v)
                let di = (py * w + px) * 4
                if abs(d.x) < 1e-12 && abs(d.y) < 1e-12 {
                    dst[di] = src[di]; dst[di + 1] = src[di + 1]; dst[di + 2] = src[di + 2]; dst[di + 3] = src[di + 3]
                    continue
                }
                // 元の位置(画像の画素・左上原点)。画素の中心どうしで測る
                let sx = (u - d.x) * bw + bx - 0.5
                let sy = (v - d.y) * bh + by - 0.5
                sample(src, w: w, h: h, x: sx, y: sy, into: &dst, at: di)
            }
        }
        guard let dctx = CGContext(data: &dst, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return dctx.makeImage()
    }

    /// 双線形サンプリング(端はクランプ)。premultiplied のまま混ぜるので、透明な縁でも色がにじまない。
    private static func sample(_ src: [UInt8], w: Int, h: Int, x: Double, y: Double, into dst: inout [UInt8], at di: Int) {
        let cx = min(max(x, 0), Double(w - 1)), cy = min(max(y, 0), Double(h - 1))
        let x0 = Int(cx.rounded(.down)), y0 = Int(cy.rounded(.down))
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let fx = cx - Double(x0), fy = cy - Double(y0)
        for ch in 0..<4 {
            let top = Double(src[(y0 * w + x0) * 4 + ch]) * (1 - fx) + Double(src[(y0 * w + x1) * 4 + ch]) * fx
            let bot = Double(src[(y1 * w + x0) * 4 + ch]) * (1 - fx) + Double(src[(y1 * w + x1) * 4 + ch]) * fx
            dst[di + ch] = UInt8(min(max((top * (1 - fy) + bot * fy).rounded(), 0), 255))
        }
    }
}
