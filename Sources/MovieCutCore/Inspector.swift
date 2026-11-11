import Foundation

/// フォントの選択肢(プロパティ欄のフォント Picker)。
public enum FontChoices {
    /// 利用者が追加したフォント(`FontLibrary` の登録後に入れる)。既定の一覧の後ろに続く。
    public static var userFamilies: [String] = []
    public static var all: [String] {
        defaultFonts + userFamilies.filter { !defaultFonts.contains($0) }
    }
    /// 現在の値が一覧に無いとき(別の PC のフォントなど)も選べるよう、先頭に足した一覧を返す。
    public static func options(including current: String?) -> [String] {
        guard let c = current, !c.isEmpty, !all.contains(c) else { return all }
        return [c] + all
    }
}

/// プロパティ欄で数値として編集する、クリップの項目。範囲の丸め(clamp)と読み書きをここに集める(UI にも Undo にも依存しない)。
public enum ClipField: CaseIterable {
    case start, duration, x, y, scale, opacity, volume, blur, fontSize, w, h, strength, mosaicSize

    /// 値の範囲。
    public var range: ClosedRange<Double> {
        switch self {
        case .start: return 0...(24 * 3600)
        case .duration: return ClipEditing.minDuration...(24 * 3600)
        case .x, .y, .w, .h: return 0...1
        case .scale: return 0.05...20
        case .opacity: return 0...1
        case .volume: return 0...2
        case .blur, .strength: return 0...300
        case .mosaicSize: return 2...100
        case .fontSize: return 8...1000
        }
    }

    /// 範囲に収める。開始・長さは小数 3 桁に丸める。NaN は範囲の下限。
    public func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return range.lowerBound }
        var x = min(max(v, range.lowerBound), range.upperBound)
        if self == .start || self == .duration { x = (x * 1000).rounded() / 1000 }
        return x
    }

    /// クリップの現在値(未設定は Electron 版と同じ既定値)。
    public func value(of c: Clip) -> Double {
        switch self {
        case .start: return c.start
        case .duration: return c.duration
        case .x: return c.xOrDefault
        case .y: return c.yOrDefault
        case .scale: return c.scaleOrDefault
        case .opacity: return c.opacityOrDefault
        case .volume: return c.volumeOrDefault
        case .blur: return c.blurOrDefault
        case .fontSize: return c.fontSizeOrDefault
        case .w: return c.wOrDefault
        case .h: return c.hOrDefault
        case .strength: return c.strengthOrDefault
        case .mosaicSize: return c.mosaicSizeOrDefault
        }
    }

    /// 丸めてから書き込む。
    public func apply(_ v: Double, to c: inout Clip) {
        let x = clamp(v)
        switch self {
        case .start: c.start = x
        case .duration: c.duration = x
        case .x: c.x = x
        case .y: c.y = x
        case .scale: c.scale = x
        case .opacity: c.opacity = x
        case .volume: c.volume = x
        case .blur: c.blur = x
        case .fontSize: c.fontSize = x
        case .w: c.w = x
        case .h: c.h = x
        case .strength: c.strength = x
        case .mosaicSize: c.mosaicSize = x
        }
    }

    /// この項目がキーフレームで動かせるとき、そのキーの名前。
    public var animationKey: String? {
        switch self {
        case .x: return "x"
        case .y: return "y"
        case .scale: return "scale"
        case .opacity: return "opacity"
        case .blur: return "blur"
        case .w: return "w"
        case .h: return "h"
        case .strength: return "strength"
        case .volume: return "volume"
        default: return nil
        }
    }

    /// 編集履歴に出す名前。
    public var undoName: String {
        switch self {
        case .start: return "開始時刻の変更"
        case .duration: return "長さの変更"
        case .x, .y: return "位置の変更"
        case .scale: return "拡大の変更"
        case .opacity: return "不透明度の変更"
        case .volume: return "音量の変更"
        case .blur: return "ぼかしの変更"
        case .fontSize: return "文字の大きさの変更"
        case .w, .h: return "ぼかし範囲の大きさの変更"
        case .strength: return "ぼかしの強さの変更"
        case .mosaicSize: return "モザイクの大きさの変更"
        }
    }
}

/// プロパティ欄で数値として編集する、キャラクターの項目。
public enum CharacterField: CaseIterable {
    case speed, pitch, intonation, x, y, scale

    /// 範囲(速さだけはエンジンで単位が違う)。
    public func range(engine: String) -> ClosedRange<Double> {
        switch self {
        case .speed: return engine == "aquestalk" ? 50...300 : 0.5...2
        case .pitch: return -0.15...0.15
        case .intonation: return 0...2
        case .x, .y: return -1...2
        case .scale: return 0.05...20
        }
    }

    public func clamp(_ v: Double, engine: String) -> Double {
        let r = range(engine: engine)
        guard v.isFinite else { return r.lowerBound }
        let x = min(max(v, r.lowerBound), r.upperBound)
        return (x * 1000).rounded() / 1000
    }

    public func value(of c: Character) -> Double {
        switch self {
        case .speed: return c.speed ?? (c.engine == "aquestalk" ? 100 : 1)
        case .pitch: return c.pitch ?? 0
        case .intonation: return c.intonation ?? 1
        case .x: return c.x
        case .y: return c.y
        case .scale: return c.scale
        }
    }

    public func apply(_ v: Double, to c: inout Character) {
        let x = clamp(v, engine: c.engine)
        switch self {
        case .speed: c.speed = x
        case .pitch: c.pitch = x
        case .intonation: c.intonation = x
        case .x: c.x = x
        case .y: c.y = x
        case .scale: c.scale = x
        }
    }

    public var undoName: String {
        switch self {
        case .speed: return "話す速さの変更"
        case .pitch: return "声の高さの変更"
        case .intonation: return "抑揚の変更"
        case .x, .y: return "立ち絵の位置の変更"
        case .scale: return "立ち絵の大きさの変更"
        }
    }
}

/// キャラクターの編集(UI にも Undo にも依存しない計算)。renderer.js の音声エンジン切り替え・キャラ削除と同じ。
public enum CharacterEditing {
    /// 音声エンジンを切り替える。速さの単位が違う(VOICEVOX は 1 が標準、ゆっくりは 100)ので、
    /// 範囲外の値だけ標準に直し、足りない項目を埋める(renderer.js renderCharProps の engine 切り替えと同じ)。
    public static func switchEngine(_ c: inout Character, to engine: String) {
        c.engine = engine
        if engine == "voicevox" {
            if !((c.speed ?? .infinity) <= 5) { c.speed = 1 }
            if c.pitch == nil { c.pitch = 0 }
            if c.intonation == nil { c.intonation = 1 }
            if c.speaker == nil { c.speaker = 3 }
        } else {
            if !((c.speed ?? 0) > 5) { c.speed = 100 }
            if (c.voice ?? "").isEmpty { c.voice = AquesTalkPresets.all.first ?? "女声1" }
        }
    }

    /// そのキャラのボイスクリップ。
    public static func voiceClips(of charId: String, in p: Project) -> [Clip] {
        p.allClips.filter { $0.type == .voice && $0.charId == charId }
    }

    /// キャラを消す: そのキャラのボイスクリップも消す。最後の 1 人、または存在しない id なら nil。
    public static func delete(charId: String, in p: Project) -> (project: Project, removedClipIds: [String])? {
        guard p.characters.count > 1, p.characters.contains(where: { $0.id == charId }) else { return nil }
        var q = p
        var removed: [String] = []
        for ti in q.tracks.indices {
            let gone = q.tracks[ti].clips.filter { $0.type == .voice && $0.charId == charId }
            removed += gone.map(\.id)
            q.tracks[ti].clips.removeAll { $0.type == .voice && $0.charId == charId }
        }
        q.characters.removeAll { $0.id == charId }
        return (q, removed)
    }
}

/// VOICEVOX の話者一覧(「キャラ2（ノーマル）」の形)。
public struct SpeakerChoice: Equatable, Sendable {
    public var id: Int
    public var label: String
    public init(id: Int, label: String) { self.id = id; self.label = label }

    public static func flatten(_ speakers: [VoicevoxSpeaker]) -> [SpeakerChoice] {
        speakers.flatMap { s in s.styles.map { SpeakerChoice(id: $0.id, label: "\(s.name)（\($0.name)）") } }
    }
}
