import Foundation
import AppKit
import MovieCutCore

/// キーフレームとアニメーション(インスペクタの ◇、メニュー、タイムラインの菱形、プレビューの直接操作が呼ぶ)。
/// 計算は MovieCutCore の KeyframeEditing / Animation に任せ、ここは Undo・選択・再生位置だけ。
extension ProjectModel {
    /// 再生ヘッドがキーに「ぴったり」とみなす幅(半コマ)。
    var keyTolerance: Double { KeyframeEditing.tolerance(fps: project.fps) }

    /// メニューの「前後のキーへ」「追加/削除」の対象の項目。最後に触った項目が選択クリップで動かせるものならそれ、無ければ nil(= 動いている全項目)。
    var keyframeTargetKey: String? {
        guard let c = selectedClip, let k = focusedAnimatableKey, Animation.keys(for: c).contains(k) else { return nil }
        return k
    }

    /// 再生ヘッドの、クリップの頭からの秒(クリップの外のときは頭〜終わりに収める)。
    func clipTime(_ c: Clip) -> Double {
        min(max(currentTime - c.start, 0), c.duration)
    }

    /// インスペクタに出す値: 再生ヘッドでの値(キーがあれば補間後)。
    func animatedValue(_ key: String, of c: Clip) -> Double {
        Animation.value(of: key, in: c, at: clipTime(c))
    }

    func keyState(_ key: String, of c: Clip) -> KeyframeEditing.KeyState {
        KeyframeEditing.state(c, key: key, at: currentTime - c.start, tolerance: keyTolerance)
    }

    // MARK: ◇ ボタン

    /// ◇: 再生ヘッドにキーがあれば消し、無ければ足す。1 回の Undo。
    @discardableResult
    func toggleKeyframe(_ key: String, clipId: String? = nil) -> Bool {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id) else { return false }
        focusedAnimatableKey = key
        let had = KeyframeEditing.keyIndex(c, key: key, at: currentTime - c.start, tolerance: keyTolerance) != nil
        var changed = false
        setClipProperty({ changed = KeyframeEditing.toggle(&$0, key: key, at: clipTime($0), tolerance: keyTolerance) }, name: had ? "キーフレームの削除" : "キーフレームの追加", clipId: id)
        return changed
    }

    /// 「キーフレームを追加/削除」(⌥⌘K): 最後に触った項目、無ければ動いている全項目(1 つでもここにキーがあれば全部消す、無ければ全部に足す)。
    @discardableResult
    func toggleKeyframeFromMenu() -> Bool {
        guard !isLocked, let c = selectedClip else { return false }
        if let k = keyframeTargetKey { return toggleKeyframe(k, clipId: c.id) }
        let animated = Animation.keys(for: c).filter { Animation.isAnimated($0, in: c) }
        guard !animated.isEmpty else {
            statusText = "◇ を押して、動かしたい項目にキーを付けてください"
            return false
        }
        let rel = currentTime - c.start, tol = keyTolerance
        let anyHere = animated.contains { KeyframeEditing.keyIndex(c, key: $0, at: rel, tolerance: tol) != nil }
        setClipProperty({ cl in
            let t = clipTime(cl)
            if anyHere { KeyframeEditing.removeKeys(&cl, at: t, tolerance: tol) }
            else { for k in animated { KeyframeEditing.toggle(&cl, key: k, at: t, tolerance: tol) } }
        }, name: anyHere ? "キーフレームの削除" : "キーフレームの追加", clipId: c.id)
        return true
    }

    /// ◀ ▶ / メニュー: 前後のキーへ再生ヘッドを動かす。`key` が nil なら全項目。動いたら true。
    @discardableResult
    func seekKeyframe(forward: Bool, key: String? = nil) -> Bool {
        guard let c = selectedClip else { return false }
        let k = key ?? keyframeTargetKey
        let rel = currentTime - c.start
        guard let t = forward ? KeyframeEditing.nextKeyTime(c, key: k, after: rel, tolerance: keyTolerance)
                              : KeyframeEditing.previousKeyTime(c, key: k, before: rel, tolerance: keyTolerance) else { return false }
        if let k { focusedAnimatableKey = k }
        playback.seek(to: c.start + t)
        return true
    }

    // MARK: 値の編集(キーがあればここのキー、無ければ設定値)

    /// 項目名 → 従来の数値項目(キーが無いときは、これで丸めて書く)。
    static func clipField(forKey key: String) -> ClipField? {
        switch key {
        case "x": return .x
        case "y": return .y
        case "scale": return .scale
        case "opacity": return .opacity
        case "blur": return .blur
        case "w": return .w
        case "h": return .h
        case "strength": return .strength
        case "volume": return .volume
        default: return nil
        }
    }

    static func undoName(forKey key: String) -> String {
        if let f = clipField(forKey: key) { return f.undoName }
        if EffectKey.parse(key) != nil { return "エフェクトの変更" }
        return key == "rotation" ? "回転の変更" : "値の変更"
    }

    /// クリップを書き換える関数: キーがあればここのキーを更新・追加、無ければ従来の丸め方で設定値を書く。
    func keyedChange(_ key: String, _ value: Double) -> (inout Clip) -> Void {
        let tol = keyTolerance
        let t = currentTime
        return { c in
            if Animation.isAnimated(key, in: c) {
                KeyframeEditing.setValue(&c, key: key, value, at: min(max(t - c.start, 0), c.duration), tolerance: tol)
            } else if let f = Self.clipField(forKey: key) {
                f.apply(value, to: &c)
            } else {
                KeyframeEditing.setValue(&c, key: key, value, at: 0, tolerance: tol)
            }
        }
    }

    /// 1 回の編集(Return・フォーカスが外れたとき)。
    func setKeyed(_ key: String, _ value: Double, clipId: String? = nil) {
        focusedAnimatableKey = key
        setClipProperty(keyedChange(key, value), name: Self.undoName(forKey: key), clipId: clipId)
    }

    /// ステッパーなどの連続編集。
    func coalescedKeyed(_ key: String, _ value: Double, clipId: String? = nil) {
        focusedAnimatableKey = key
        coalescedClipProperty(keyedChange(key, value), name: Self.undoName(forKey: key), clipId: clipId)
    }

    /// スライダーのドラッグ中。
    func liveKeyed(_ key: String, _ value: Double, clipId: String? = nil) {
        focusedAnimatableKey = key
        liveClipProperty(keyedChange(key, value), name: Self.undoName(forKey: key), clipId: clipId)
    }

    // MARK: 反転・切り抜き・リセット

    func setFlip(horizontal: Bool, _ on: Bool, clipId: String? = nil) {
        setClipProperty({ if horizontal { $0.flipH = on ? true : nil } else { $0.flipV = on ? true : nil } },
                        name: horizontal ? "左右反転の切り替え" : "上下反転の切り替え", clipId: clipId)
    }

    /// 切り抜きの 1 辺(割合 0〜0.95)。
    func setCropEdge(_ edge: CropEdge, _ value: Double, clipId: String? = nil) {
        setClipProperty({ edge.apply(value, to: &$0) }, name: "切り抜きの変更", clipId: clipId)
    }

    func coalescedCropEdge(_ edge: CropEdge, _ value: Double, clipId: String? = nil) {
        coalescedClipProperty({ edge.apply(value, to: &$0) }, name: "切り抜きの変更", clipId: clipId)
    }

    @discardableResult
    func resetTransform(clipId: String? = nil) -> Bool {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id) else { return false }
        var probe = c
        guard KeyframeEditing.resetTransform(&probe) else { return false }
        setClipProperty({ _ = KeyframeEditing.resetTransform(&$0) }, name: "変形のリセット", clipId: id)
        return true
    }

    // MARK: すべて消す・プリセット

    @discardableResult
    func clearKeyframes() -> Bool {
        guard !isLocked, let c = selectedClip, c.hasKeyframes else { return false }
        setClipProperty({ _ = KeyframeEditing.clearAll(&$0, at: clipTime($0)) }, name: "すべてのキーフレームを消去", clipId: c.id)
        focusedAnimatableKey = nil
        return true
    }

    @discardableResult
    func applyAnimationPreset(_ preset: AnimationPreset) -> Bool {
        guard !isLocked, let c = selectedClip else { return false }
        var probe = c
        guard preset.apply(to: &probe) else { return false }
        setClipProperty({ _ = preset.apply(to: &$0) }, name: preset.undoName, clipId: c.id)
        return true
    }

    // MARK: タイムラインの菱形(まとめて動かす)

    /// 時刻 `from` の全項目のキーを `to`(クリップの頭からの秒)へ動かした Project(ドラッグ中の `updateGesture` 用)。`base` から作り直す。
    func projectMovingKeys(base: Project, clipId: String, from: Double, to: Double) -> Project? {
        guard let loc = ClipEditing.locate(clipId, in: base) else { return nil }
        var p = base
        var c = p.tracks[loc.track].clips[loc.index]
        guard KeyframeEditing.moveKeys(&c, from: from, to: to, maxT: c.duration, tolerance: 1e-6) else { return nil }
        p.tracks[loc.track].clips[loc.index] = c
        return p
    }
}
