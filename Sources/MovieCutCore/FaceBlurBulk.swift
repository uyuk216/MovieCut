import Foundation

// MARK: - 顔ぼかしの一括付与
//
// 既存の顔ぼかしは「1 クリップに faceBlur エフェクトを付け、描画時に Vision で検出した
// 全ての顔へ適用する」仕組み(検出枠は複数を扱える)。ここではその「複数クリップへの
// 一括付与・一括解除」を純粋な編集ロジックとして提供する。
// 顔追従(トラッキング)は第 3 波(#53)の担当で、ここには含めない。track 引数は既存の
// エフェクト引数としてそのまま保持されるだけである。

public enum FaceBlurBulk {
    /// 一括付与の設定。値は EffectKind.faceBlur の引数仕様に合わせる。
    public struct Options: Equatable, Sendable {
        /// 強さ 0〜1(既定 0.6)。
        public var strength: Double = 0.6
        /// 方式 0 = モザイク、1 = ぼかし。
        public var mode: Double = 0
        /// モザイクの大きさ(px、1920×1080 基準)。
        public var size: Double = 38
        /// 顔追従フラグ(既存引数の保持のみ。追従自体は #53)。
        public var track: Double = 0
        /// すでに顔ぼかしがあるクリップを上書きするか(false = 触らない)。
        public var replaceExisting: Bool = true
        /// 対応する全種別(テキスト・立ち絵を含む)を対象にするか(false = 映像系のみ)。
        public var includeAllSupportedTypes: Bool = false

        public init() {}
    }

    /// 対象にするクリップ種別か。
    public static func isTarget(_ clip: Clip, options: Options) -> Bool {
        guard Clip.supportsEffects(clip.type) else { return false }
        if options.includeAllSupportedTypes { return true }
        return clip.type == .image || clip.type == .video || clip.type == .compound
    }

    /// 設定から顔ぼかしエフェクトを作る(値は仕様で丸める)。
    public static func makeEffect(_ options: Options) -> Effect {
        var e = Effect(.faceBlur)
        let kind = EffectKind.faceBlur
        e.params["strength"] = kind.spec("strength")?.clamp(options.strength) ?? options.strength
        e.params["mode"] = kind.spec("mode")?.clamp(options.mode.rounded()) ?? options.mode
        e.params["size"] = kind.spec("size")?.clamp(options.size) ?? options.size
        e.params["track"] = kind.spec("track")?.clamp(options.track.rounded()) ?? options.track
        return e
    }

    /// そのクリップが顔ぼかしをすでに持っているか。
    public static func hasFaceBlur(_ clip: Clip) -> Bool {
        clip.effects.contains { $0.kind == EffectKind.faceBlur.rawValue }
    }

    /// 1 クリップへ付与する。変わったときだけ true。
    /// 既存がある場合は replaceExisting のとき最初の 1 つを新しい設定で置き換える(重複は作らない)。
    @discardableResult
    public static func apply(to clip: inout Clip, options: Options = Options()) -> Bool {
        guard isTarget(clip, options: options) else { return false }
        if let i = clip.effects.firstIndex(where: { $0.kind == EffectKind.faceBlur.rawValue }) {
            guard options.replaceExisting else { return false }
            let fresh = makeEffect(options)
            guard clip.effects[i].params != fresh.params else { return false }
            var updated = fresh
            updated.enabled = clip.effects[i].enabled
            updated.extra = clip.effects[i].extra
            clip.effects[i] = updated
            return true
        }
        clip.effects.append(makeEffect(options))
        return true
    }

    /// プロジェクトの全トラック(複合クリップの中も再帰)へ一括付与し、変えたクリップ数を返す。
    @discardableResult
    public static func apply(to project: inout Project, options: Options = Options()) -> Int {
        var changed = 0
        for ti in project.tracks.indices {
            changed += apply(to: &project.tracks[ti].clips, options: options)
        }
        return changed
    }

    static func apply(to clips: inout [Clip], options: Options) -> Int {
        var changed = 0
        for ci in clips.indices {
            if apply(to: &clips[ci], options: options) { changed += 1 }
            // 複合クリップの中身にも付ける
            if var nested = clips[ci].tracks {
                for ti in nested.indices { changed += apply(to: &nested[ti].clips, options: options) }
                clips[ci].tracks = nested
            }
        }
        return changed
    }

    /// プロジェクト全体から顔ぼかしを一括で外し、外したクリップ数を返す。
    @discardableResult
    public static func removeAll(from project: inout Project) -> Int {
        var changed = 0
        for ti in project.tracks.indices {
            changed += removeAll(from: &project.tracks[ti].clips)
        }
        return changed
    }

    static func removeAll(from clips: inout [Clip]) -> Int {
        var changed = 0
        for ci in clips.indices {
            let before = clips[ci].effects.count
            // エフェクト番号がずれるため、キーフレームの付け替えは EffectEditing.remove を使う
            var idx = clips[ci].effects.count - 1
            while idx >= 0 {
                if clips[ci].effects[idx].kind == EffectKind.faceBlur.rawValue {
                    EffectEditing.remove(&clips[ci], at: idx)
                }
                idx -= 1
            }
            if clips[ci].effects.count != before { changed += 1 }
            if var nested = clips[ci].tracks {
                for ti in nested.indices { changed += removeAll(from: &nested[ti].clips) }
                clips[ci].tracks = nested
            }
        }
        return changed
    }

    /// 顔ぼかしが付いているクリップの総数(複合の中も数える)。
    public static func count(in project: Project) -> Int {
        project.tracks.reduce(0) { $0 + count(in: $1.clips) }
    }

    static func count(in clips: [Clip]) -> Int {
        clips.reduce(0) { sum, c in
            sum + (hasFaceBlur(c) ? 1 : 0) + (c.tracks?.reduce(0) { $0 + count(in: $1.clips) } ?? 0)
        }
    }
}
