import Foundation

/// キーフレームの編集の純粋な計算(UI にも Undo にも依存しない)。時刻はすべて「クリップの頭からの秒」。
public enum KeyframeEditing {
    /// 再生ヘッドがキーに「ぴったり」とみなす幅: 半コマ(|Δ| < 1/(2·fps))。
    public static func tolerance(fps: Double) -> Double { 0.5 / max(1, fps) }

    /// ファイルを短く保つための丸め(マイクロ秒)。
    static func round6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

    /// その項目のキーが再生ヘッド(`t`)にあるときの番号。
    public static func keyIndex(_ clip: Clip, key: String, at t: Double, tolerance tol: Double) -> Int? {
        guard let ks = clip.keyframes[key] else { return nil }
        var best: Int?
        var bestD = Double.infinity
        for (i, k) in ks.enumerated() {
            let d = abs(k.t - t)
            if d < tol, d < bestD { best = i; bestD = d }
        }
        return best
    }

    /// ◇ ボタンの状態。
    public enum KeyState: Equatable {
        case none        // ◇ キーなし(動かさない項目)
        case between     // 半塗り: 動く項目だが、ここにキーはない
        case onKey       // ◆ ここにキーがある
    }

    public static func state(_ clip: Clip, key: String, at t: Double, tolerance tol: Double) -> KeyState {
        guard Animation.isAnimated(key, in: clip) else { return .none }
        return keyIndex(clip, key: key, at: t, tolerance: tol) != nil ? .onKey : .between
    }

    // MARK: キーの追加・削除

    /// ◇ を押したとき: ここにキーがあれば消し、無ければ「いまの値」で足す。
    /// 最後の 1 つを消したときは、その値を設定値にして、見た目が変わらないようにする。
    /// 動かせない項目(そのクリップの種類に無い)は何もせず false。
    @discardableResult
    public static func toggle(_ clip: inout Clip, key: String, at t: Double, tolerance tol: Double) -> Bool {
        guard Animation.keys(for: clip).contains(key) else { return false }
        if let i = keyIndex(clip, key: key, at: t, tolerance: tol) {
            let removed = clip.keyframes[key]![i]
            clip.keyframes[key]!.remove(at: i)
            if clip.keyframes[key]!.isEmpty {
                clip.keyframes[key] = nil
                clip.setStaticValue(Animation.clamp(key, removed.v, type: clip.type), of: key)
            }
        } else {
            let v = Animation.value(of: key, in: clip, at: t)
            insert(&clip, key: key, Keyframe(t: round6(t), v: v))
        }
        return true
    }

    /// キーを正しい位置へ足す(同じ時刻のキーは置き換える)。
    static func insert(_ clip: inout Clip, key: String, _ k: Keyframe) {
        var list = clip.keyframes[key] ?? []
        list.removeAll { abs($0.t - k.t) < 1e-9 }
        list.append(k)
        list.sort { $0.t < $1.t }
        clip.keyframes[key] = list
    }

    /// 項目の値を、再生ヘッド(`t`)で書く。その項目にキーがあれば、ここのキーを更新(無ければ新しく足す)。
    /// キーが無ければ、設定値を書く(従来どおり)。キーを足すときのイージングは、前後のキーに合わせず「一定」。
    public static func setValue(_ clip: inout Clip, key: String, _ value: Double, at t: Double, tolerance tol: Double) {
        let v = Animation.clamp(key, value, type: clip.type)
        guard Animation.isAnimated(key, in: clip) else {
            clip.setStaticValue(v, of: key)
            return
        }
        if let i = keyIndex(clip, key: key, at: t, tolerance: tol) {
            clip.keyframes[key]![i].v = v
        } else {
            insert(&clip, key: key, Keyframe(t: round6(t), v: v))
        }
    }

    /// 全項目のキーの時刻(重複なし・昇順)。
    public static func keyTimes(_ clip: Clip) -> [Double] { Animation.allKeyTimes(clip.keyframes) }

    /// 前後のキーの時刻。`key` が nil なら全項目。
    public static func previousKeyTime(_ clip: Clip, key: String?, before t: Double, tolerance tol: Double) -> Double? {
        times(clip, key: key).filter { $0 < t - tol }.max()
    }

    public static func nextKeyTime(_ clip: Clip, key: String?, after t: Double, tolerance tol: Double) -> Double? {
        times(clip, key: key).filter { $0 > t + tol }.min()
    }

    private static func times(_ clip: Clip, key: String?) -> [Double] {
        if let key { return (clip.keyframes[key] ?? []).map(\.t) }
        return keyTimes(clip)
    }

    /// 時刻 `t` にある全項目のキーを消す。消した数を返す。
    @discardableResult
    public static func removeKeys(_ clip: inout Clip, at t: Double, tolerance tol: Double) -> Int {
        var n = 0
        for key in Array(clip.keyframes.keys) {
            var removedAny = false
            while let i = keyIndex(clip, key: key, at: t, tolerance: tol) {
                let removed = clip.keyframes[key]!.remove(at: i)
                n += 1; removedAny = true
                if clip.keyframes[key]!.isEmpty {
                    clip.keyframes[key] = nil
                    clip.setStaticValue(Animation.clamp(key, removed.v, type: clip.type), of: key)
                    break
                }
            }
            _ = removedAny
        }
        return n
    }

    /// すべてのキーを消す。見た目が変わらないよう、時刻 `t` の値を設定値にする。消した項目の数を返す。
    @discardableResult
    public static func clearAll(_ clip: inout Clip, at t: Double) -> Int {
        let keys = clip.keyframes.filter { !$0.value.isEmpty }.keys.sorted()
        for key in keys {
            clip.setStaticValue(Animation.clamp(key, Animation.value(of: key, in: clip, at: t), type: clip.type), of: key)
        }
        clip.keyframes = [:]
        return keys.count
    }

    /// 時刻 `from` にある全項目のキーを `to` へ動かす(0〜`maxT` に収める)。行き先に別のキーがあれば置き換える。動いたら true。
    @discardableResult
    public static func moveKeys(_ clip: inout Clip, from: Double, to: Double, maxT: Double, tolerance tol: Double) -> Bool {
        let dest = round6(min(max(to, 0), max(0, maxT)))
        var moved = false
        for key in Array(clip.keyframes.keys) {
            guard let i = keyIndex(clip, key: key, at: from, tolerance: tol) else { continue }
            var list = clip.keyframes[key]!
            var k = list.remove(at: i)
            if abs(k.t - dest) < 1e-9 { clip.keyframes[key] = list + [k]; clip.keyframes[key]!.sort { $0.t < $1.t }; continue }
            k.t = dest
            list.removeAll { abs($0.t - dest) < 1e-9 }
            list.append(k)
            list.sort { $0.t < $1.t }
            clip.keyframes[key] = list
            moved = true
        }
        return moved
    }

    /// 見せる値(◇ の右の欄用): そのクリップ・時刻での値。
    public static func displayValue(_ clip: Clip, key: String, projectTime t: Double) -> Double {
        Animation.value(of: key, in: clip, at: t - clip.start)
    }

    // MARK: 変形のリセット

    /// 「変形をリセット」: 回転 0・反転なし・切り抜きなし・拡大 1 に戻し、回転と拡大のキーを消す(位置と不透明度は触らない)。変わったら true。
    @discardableResult
    public static func resetTransform(_ clip: inout Clip) -> Bool {
        let before = clip
        clip.rotation = nil; clip.flipH = nil; clip.flipV = nil; clip.crop = nil
        if clip.scale != nil { clip.scale = 1 }
        clip.keyframes["rotation"] = nil
        clip.keyframes["scale"] = nil
        return clip != before
    }
}

// MARK: - クイックプリセット

/// クリップ ▸ アニメーション の項目。それぞれクリップの設定値(位置・拡大・回転・不透明度)を基準に、キーを書く。
/// 登場系(スライド・回転)は min(1 秒, 長さ) で終わり、ズーム・ケンバーンズはクリップの全長をかける。同じ項目の既存のキーは置き換える。
public enum AnimationPreset: String, CaseIterable, Sendable {
    case zoomIn, zoomOut, slideFromLeft, slideFromRight, slideFromTop, slideFromBottom, spinIn, kenBurns

    public var title: String {
        switch self {
        case .zoomIn: return "ズームイン"
        case .zoomOut: return "ズームアウト"
        case .slideFromLeft: return "左からスライド"
        case .slideFromRight: return "右からスライド"
        case .slideFromTop: return "上から"
        case .slideFromBottom: return "下から"
        case .spinIn: return "回転しながら登場"
        case .kenBurns: return "ゆっくり拡大（ケンバーンズ）"
        }
    }

    /// 編集履歴の名前。
    public var undoName: String { "アニメーション: " + title }

    /// 登場系の長さ(秒)の上限。
    public static let entranceSeconds = 1.0
    public static let zoomFactor = 1.5
    public static let kenBurnsFactor = 1.15
    public static let spinDegrees = 180.0
    public static let spinStartScale = 0.2

    /// 画像・動画・文字のクリップに当てる。当てられない(ぼかし範囲・音声など)ときは false。
    @discardableResult
    public func apply(to clip: inout Clip) -> Bool {
        guard [ClipType.image, .video, .text].contains(clip.type), clip.duration > 0 else { return false }
        let d = clip.duration
        let e = min(Self.entranceSeconds, d)
        let x = clip.xOrDefault, y = clip.yOrDefault, s = clip.scaleOrDefault, o = clip.opacityOrDefault, r = clip.rotationOrDefault
        func put(_ key: String, _ list: [Keyframe]) {
            clip.keyframes[key] = list.map { Keyframe(t: $0.t, v: Animation.clamp(key, $0.v, type: clip.type), ease: $0.ease) }
        }
        switch self {
        case .zoomIn:
            put("scale", [Keyframe(t: 0, v: s, ease: .easeInOut), Keyframe(t: d, v: s * Self.zoomFactor)])
        case .zoomOut:
            put("scale", [Keyframe(t: 0, v: s * Self.zoomFactor, ease: .easeInOut), Keyframe(t: d, v: s)])
        case .slideFromLeft:
            put("x", [Keyframe(t: 0, v: x - 1, ease: .easeOut), Keyframe(t: e, v: x)])
        case .slideFromRight:
            put("x", [Keyframe(t: 0, v: x + 1, ease: .easeOut), Keyframe(t: e, v: x)])
        case .slideFromTop:
            put("y", [Keyframe(t: 0, v: y - 1, ease: .easeOut), Keyframe(t: e, v: y)])
        case .slideFromBottom:
            put("y", [Keyframe(t: 0, v: y + 1, ease: .easeOut), Keyframe(t: e, v: y)])
        case .spinIn:
            put("rotation", [Keyframe(t: 0, v: r - Self.spinDegrees, ease: .easeOut), Keyframe(t: e, v: r)])
            put("scale", [Keyframe(t: 0, v: s * Self.spinStartScale, ease: .easeOut), Keyframe(t: e, v: s)])
            put("opacity", [Keyframe(t: 0, v: 0), Keyframe(t: e, v: o)])
        case .kenBurns:
            put("scale", [Keyframe(t: 0, v: s), Keyframe(t: d, v: s * Self.kenBurnsFactor)])
            put("x", [Keyframe(t: 0, v: x), Keyframe(t: d, v: x - 0.02)])
            put("y", [Keyframe(t: 0, v: y), Keyframe(t: d, v: y - 0.01)])
        }
        return true
    }
}

// MARK: - 切り抜きと変形の項目(インスペクタ)

/// 切り抜きの辺。
public enum CropEdge: CaseIterable, Sendable {
    case left, top, right, bottom

    public var label: String {
        switch self {
        case .left: return "左"
        case .top: return "上"
        case .right: return "右"
        case .bottom: return "下"
        }
    }

    public func value(of c: Crop) -> Double {
        switch self {
        case .left: return c.l
        case .top: return c.t
        case .right: return c.r
        case .bottom: return c.b
        }
    }

    /// 辺を書く(0〜0.95・向かい合う辺の和 < 1 に収める。収まらないときは、書いた辺のほうを縮める)。
    public func apply(_ v: Double, to clip: inout Clip) {
        var c = clip.cropOrDefault
        let nv = v.isFinite ? min(max(v, 0), Crop.maxEdge) : 0
        let cap = 0.99
        switch self {
        case .left: c.l = min(nv, cap - c.r)
        case .right: c.r = min(nv, cap - c.l)
        case .top: c.t = min(nv, cap - c.b)
        case .bottom: c.b = min(nv, cap - c.t)
        }
        clip.crop = c.isEmpty ? nil : c
    }
}

// MARK: - プレビューでの直接操作(当たり判定と値の計算)

/// 画面(キャンバスの画素)上の、変形後のクリップの枠。回転は時計回りが正。
public struct TransformBox: Equatable, Sendable {
    public var center: CGPoint
    /// 回転・拡大を反映した、横・縦の大きさ(反転は枠の形を変えない)。
    public var width: Double
    public var height: Double
    public var rotation: Double

    public init(center: CGPoint, width: Double, height: Double, rotation: Double) {
        self.center = center; self.width = width; self.height = height; self.rotation = rotation
    }

    /// 回転の取っ手が枠の上端から離れる距離(画素)。
    public static let rotationHandleOffset = 28.0

    private func rotated(_ dx: Double, _ dy: Double) -> CGPoint {
        let a = rotation * .pi / 180
        // 画面は y 下向き。正の回転は時計回り。
        return CGPoint(x: center.x + dx * cos(a) - dy * sin(a), y: center.y + dx * sin(a) + dy * cos(a))
    }

    /// 四隅(左上・右上・右下・左下)。
    public var corners: [CGPoint] {
        let hw = width / 2, hh = height / 2
        return [rotated(-hw, -hh), rotated(hw, -hh), rotated(hw, hh), rotated(-hw, hh)]
    }

    /// 回転の取っ手(上辺の中央から外へ)。
    public var rotationHandle: CGPoint { rotated(0, -height / 2 - Self.rotationHandleOffset) }

    public enum Hit: Equatable, Sendable {
        case corner(Int)
        case rotation
        case body
        case none
    }

    /// 点がどこに当たるか。取っ手 → 角 → 本体の順。`radius` は取っ手の当たり半径(画素)。
    public func hitTest(_ p: CGPoint, radius: Double) -> Hit {
        if hypot(p.x - rotationHandle.x, p.y - rotationHandle.y) <= radius { return .rotation }
        for (i, c) in corners.enumerated() where hypot(p.x - c.x, p.y - c.y) <= radius { return .corner(i) }
        // 本体: 枠の局所座標へ戻して内側判定
        let a = -rotation * .pi / 180
        let dx = p.x - center.x, dy = p.y - center.y
        let lx = dx * cos(a) - dy * sin(a), ly = dx * sin(a) + dy * cos(a)
        return abs(lx) <= width / 2 && abs(ly) <= height / 2 ? .body : .none
    }

    /// 角をつかんで動かしたときの拡大の倍率(中心からの距離の比)。
    public static func scaleRatio(center: CGPoint, from p0: CGPoint, to p: CGPoint) -> Double {
        let d0 = hypot(p0.x - center.x, p0.y - center.y)
        guard d0 > 1e-6 else { return 1 }
        return hypot(p.x - center.x, p.y - center.y) / d0
    }

    /// 回転の取っ手をつかんだときの、回転の増分(度、時計回りが正)。-180〜180 に折り返す。
    public static func rotationDelta(center: CGPoint, from p0: CGPoint, to p: CGPoint) -> Double {
        let a0 = atan2(p0.y - center.y, p0.x - center.x), a1 = atan2(p.y - center.y, p.x - center.x)
        var d = (a1 - a0) * 180 / .pi
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }
}

/// 直接操作で変わる値(キーに書く / 設定値に書く先は呼び出し側)。
public enum DirectManipulation {
    /// 本体のドラッグ: 画素の移動量を、キャンバスに対する割合の位置に直す。
    public static func moved(x: Double, y: Double, dx: Double, dy: Double, canvas: CGSize) -> (x: Double, y: Double) {
        guard canvas.width > 0, canvas.height > 0 else { return (x, y) }
        return (x + dx / canvas.width, y + dy / canvas.height)
    }

    /// 角のドラッグ: 拡大 × 倍率(範囲に収める)。
    public static func scaled(_ scale: Double, ratio: Double) -> Double {
        Animation.clamp("scale", scale * ratio, type: .image)
    }

    /// 回転のドラッグ: 回転 + 増分。Shift で 15 度刻み。
    public static func rotated(_ rotation: Double, delta: Double, snap: Bool) -> Double {
        let r = rotation + delta
        let v = snap ? (r / 15).rounded() * 15 : r
        return Animation.clamp("rotation", v, type: .image)
    }
}

// MARK: - 直接操作の適用

extension TransformBox {
    /// クリップの、時刻 `t`(クリップの頭からの秒)での枠。`objectSize` は Renderer.objectSize(of:at:) の値(拡大を反映済み)。
    public static func make(clip: Clip, objectSize: CGSize, at t: Double, canvas: CGSize) -> TransformBox {
        TransformBox(center: CGPoint(x: Animation.value(of: "x", in: clip, at: t) * canvas.width, y: Animation.value(of: "y", in: clip, at: t) * canvas.height),
                     width: objectSize.width, height: objectSize.height, rotation: Animation.value(of: "rotation", in: clip, at: t))
    }
}

extension DirectManipulation {
    public enum Kind: Equatable, Sendable { case move, scale, rotate }

    /// ドラッグ開始時のクリップ `base` に、ポインタが `p0` から `p` へ動いた分の変形を当てる(画素はキャンバスの画素)。
    /// 動かす項目にキーがあれば、`t`(クリップの頭からの秒)のキーを更新・追加し、無ければ設定値を書く。
    public static func apply(_ kind: Kind, to base: Clip, at t: Double, tolerance tol: Double, from p0: CGPoint, to p: CGPoint, canvas: CGSize, snapRotation: Bool = false) -> Clip {
        var c = base
        let x0 = Animation.value(of: "x", in: base, at: t), y0 = Animation.value(of: "y", in: base, at: t)
        switch kind {
        case .move:
            let m = moved(x: x0, y: y0, dx: p.x - p0.x, dy: p.y - p0.y, canvas: canvas)
            KeyframeEditing.setValue(&c, key: "x", m.x, at: t, tolerance: tol)
            KeyframeEditing.setValue(&c, key: "y", m.y, at: t, tolerance: tol)
        case .scale:
            let center = CGPoint(x: x0 * canvas.width, y: y0 * canvas.height)
            let r = TransformBox.scaleRatio(center: center, from: p0, to: p)
            KeyframeEditing.setValue(&c, key: "scale", scaled(Animation.value(of: "scale", in: base, at: t), ratio: r), at: t, tolerance: tol)
        case .rotate:
            let center = CGPoint(x: x0 * canvas.width, y: y0 * canvas.height)
            let d = TransformBox.rotationDelta(center: center, from: p0, to: p)
            KeyframeEditing.setValue(&c, key: "rotation", rotated(Animation.value(of: "rotation", in: base, at: t), delta: d, snap: snapRotation), at: t, tolerance: tol)
        }
        return c
    }
}
