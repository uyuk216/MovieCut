import Foundation

/// 音量包絡線(音量キーフレーム)の直接編集の純粋な計算(UI にも Undo にも依存しない)。
///
/// データは従来どおり `Clip.keyframes["volume"]`(値は倍率 0〜2、時刻はクリップの頭からの秒)で、
/// ミックス・書き出しへの反映は既存の `VolumeEnvelope`(AudioMixer)が担う。ここは「点の追加・移動・削除」と
/// 「画面の縦位置 ↔ 音量」の対応だけを持つ。
/// 包絡線を持たないクリップを初めて編集するときは、見た目(聞こえ方)が変わらないよう、
/// 頭と終わりに「いまの設定音量」の点を置いてから編集する(素材化)。
public enum VolumeEnvelopeEditing {
    public static let key = Animation.volumeKey

    /// このクリップで音量包絡線を編集できるか(音声・ボイス・動画。静止画化したものは除く)。
    public static func supports(_ clip: Clip) -> Bool {
        Animation.keys(for: clip).contains(key)
    }

    /// 実際に保存されている点(時刻順)。
    public static func points(_ clip: Clip) -> [Keyframe] {
        Animation.normalized(clip.keyframes[key] ?? [])
    }

    /// クリップ内の時刻 `t` での音量(点があれば補間、無ければ設定値)。
    public static func gain(_ clip: Clip, at t: Double) -> Double {
        Animation.value(of: key, in: clip, at: t)
    }

    private static func round6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

    private static func clampedTime(_ t: Double, in clip: Clip) -> Double {
        min(max(round6(t), 0), max(0, clip.duration))
    }

    private static func clampedGain(_ v: Double, in clip: Clip) -> Double {
        Animation.clamp(key, v, in: clip)
    }

    /// 包絡線が無いクリップに、頭と終わりの基準点を置く(聞こえ方は変わらない)。既にある場合は何もしない。
    public static func materialize(_ clip: inout Clip) {
        guard supports(clip), points(clip).isEmpty else { return }
        let v = clip.volumeOrDefault
        var list = [Keyframe(t: 0, v: v)]
        if clip.duration > 1e-6 { list.append(Keyframe(t: round6(clip.duration), v: v)) }
        clip.keyframes[key] = list
    }

    /// 点を足す。同じ時刻(1ms 以内)に既にある点は置き換える。足した点の番号を返す(対象外なら nil)。
    @discardableResult
    public static func addPoint(_ clip: inout Clip, at t: Double, gain v: Double) -> Int? {
        guard supports(clip) else { return nil }
        materialize(&clip)
        let nt = clampedTime(t, in: clip), nv = clampedGain(v, in: clip)
        var list = points(clip)
        list.removeAll { abs($0.t - nt) < 0.001 }
        list.append(Keyframe(t: nt, v: nv))
        list = Animation.normalized(list)
        clip.keyframes[key] = list
        return list.firstIndex { abs($0.t - nt) < 1e-9 }
    }

    /// 点を動かす。前後の点の時刻を越えないよう止める(並び順は保つ)。動かせたら true。
    @discardableResult
    public static func movePoint(_ clip: inout Clip, index: Int, toTime t: Double, gain v: Double) -> Bool {
        var list = points(clip)
        guard supports(clip), list.indices.contains(index) else { return false }
        let lo = index > 0 ? list[index - 1].t + 0.01 : 0
        let hi = index + 1 < list.count ? list[index + 1].t - 0.01 : max(0, clip.duration)
        guard hi >= lo else { return false }
        list[index] = Keyframe(t: min(max(round6(t), lo), hi), v: clampedGain(v, in: clip), ease: list[index].ease)
        clip.keyframes[key] = list
        return true
    }

    /// 点を消す。最後の 1 点を消したら包絡線自体を無くし、その点の値を設定音量にして聞こえ方を保つ。
    @discardableResult
    public static func removePoint(_ clip: inout Clip, index: Int) -> Bool {
        var list = points(clip)
        guard supports(clip), list.indices.contains(index) else { return false }
        let removed = list.remove(at: index)
        if list.isEmpty {
            clip.keyframes[key] = nil
            clip.volume = removed.v
        } else {
            clip.keyframes[key] = list
        }
        return true
    }

    /// 点の時刻だけを動かす(横ドラッグ用に、値の変更と分けた入口)。
    @discardableResult
    public static func movePointTime(_ clip: inout Clip, index: Int, toTime t: Double) -> Bool {
        let list = points(clip)
        guard list.indices.contains(index) else { return false }
        return movePoint(&clip, index: index, toTime: t, gain: list[index].v)
    }

    // MARK: 画面との対応(縦位置は割合 0=下端 〜 1=上端で表す)

    /// 音量(0〜2) → 縦の割合。1.0(等倍)が中央。
    public static func fraction(forGain v: Double) -> Double {
        min(max(v, 0), 2) / 2
    }

    /// 縦の割合 → 音量(0〜2)。
    public static func gain(forFraction f: Double) -> Double {
        min(max(f, 0), 1) * 2
    }
}
