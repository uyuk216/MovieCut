import Foundation

/// 音声エフェクト・パン・音量の編集の純粋な計算(UI にも Undo にも依存しない)。
/// 変えたときだけ true を返す(何も変わらない編集は Undo に登録しない)。既定に戻った項目は nil に戻して、ファイルに書かない。
public enum AudioFxEditing {
    public static func supports(_ c: Clip) -> Bool { Clip.supportsAudioFx(c) }

    // MARK: 共通

    /// `audioFx` を書き換える。空になったら nil に戻す。変化があれば true。
    @discardableResult
    static func edit(_ c: inout Clip, _ change: (inout AudioFx) -> Void) -> Bool {
        guard supports(c) else { return false }
        let before = c.audioFx
        var fx = before ?? AudioFx()
        change(&fx)
        c.audioFx = fx.isEmpty ? nil : fx
        return c.audioFx != before
    }

    // MARK: イコライザー

    public enum Band: CaseIterable, Sendable {
        case low, mid, high
        public var label: String {
            switch self { case .low: return "低域（100 Hz）"; case .mid: return "中域（1 kHz）"; case .high: return "高域（8 kHz）" }
        }
        public func value(of e: AudioFx.EQ) -> Double {
            switch self { case .low: return e.lowDb; case .mid: return e.midDb; case .high: return e.highDb }
        }
    }

    /// 帯域の値(dB)。0 に戻した帯域は書かず、3 つとも 0 なら EQ ごと外す。
    @discardableResult
    public static func setEQ(_ c: inout Clip, band: Band, db: Double) -> Bool {
        let v = AudioFx.EQ.clampDb((db * 10).rounded() / 10)
        return edit(&c) { fx in
            var e = fx.eq ?? AudioFx.EQ()
            switch band {
            case .low: e.low = v == 0 ? nil : v
            case .mid: e.mid = v == 0 ? nil : v
            case .high: e.high = v == 0 ? nil : v
            }
            fx.eq = (e.low == nil && e.mid == nil && e.high == nil && e.extra.isEmpty) ? nil : e
        }
    }

    @discardableResult
    public static func resetEQ(_ c: inout Clip) -> Bool { edit(&c) { $0.eq = nil } }

    // MARK: コンプレッサー

    public enum CompressorParam: CaseIterable, Sendable {
        case threshold, ratio, attack, release, makeup
        public var range: ClosedRange<Double> {
            switch self {
            case .threshold: return AudioFx.Compressor.thresholdRange
            case .ratio: return AudioFx.Compressor.ratioRange
            case .attack: return AudioFx.Compressor.attackRange
            case .release: return AudioFx.Compressor.releaseRange
            case .makeup: return AudioFx.Compressor.makeupRange
            }
        }
        public func value(of c: AudioFx.Compressor) -> Double {
            switch self {
            case .threshold: return c.thresholdDb
            case .ratio: return c.ratioValue
            case .attack: return c.attackMs
            case .release: return c.releaseMs
            case .makeup: return c.makeupDb
            }
        }
        public var label: String {
            switch self {
            case .threshold: return "しきい値（dB）"
            case .ratio: return "比率（:1）"
            case .attack: return "アタック（ms）"
            case .release: return "リリース（ms）"
            case .makeup: return "メイクアップ（dB）"
            }
        }
        public var undoName: String { "コンプレッサーの変更" }
    }

    /// オン / オフ。オンにすると既定値のコンプレッサーを足す。オフは設定を残したまま切る(`enabled` = false)。
    @discardableResult
    public static func setCompressorEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        edit(&c) { fx in
            if on { var k = fx.compressor ?? AudioFx.Compressor(); k.enabled = true; fx.compressor = k }
            else if var k = fx.compressor { k.enabled = false; fx.compressor = k }
        }
    }

    @discardableResult
    public static func setCompressor(_ c: inout Clip, _ p: CompressorParam, _ v: Double) -> Bool {
        let r = p.range
        let x = v.isFinite ? (min(max(v, r.lowerBound), r.upperBound) * 10).rounded() / 10 : r.lowerBound
        return edit(&c) { fx in
            var k = fx.compressor ?? AudioFx.Compressor()
            switch p {
            case .threshold: k.threshold = x
            case .ratio: k.ratio = x
            case .attack: k.attack = x
            case .release: k.release = x
            case .makeup: k.makeup = x
            }
            fx.compressor = k
        }
    }

    // MARK: リバーブ

    @discardableResult
    public static func setReverbEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        edit(&c) { fx in
            if on { var k = fx.reverb ?? AudioFx.Reverb(); k.enabled = true; fx.reverb = k }
            else if var k = fx.reverb { k.enabled = false; fx.reverb = k }
        }
    }

    @discardableResult
    public static func setReverbMix(_ c: inout Clip, _ v: Double) -> Bool {
        let x = (min(max(v.isFinite ? v : 0, 0), 1) * 100).rounded() / 100
        return edit(&c) { fx in var k = fx.reverb ?? AudioFx.Reverb(); k.mixValue = x; fx.reverb = k }
    }

    @discardableResult
    public static func setReverbSize(_ c: inout Clip, _ size: AudioFx.ReverbSize) -> Bool {
        edit(&c) { fx in var k = fx.reverb ?? AudioFx.Reverb(); k.size = size.rawValue; fx.reverb = k }
    }

    // MARK: ノーマライズ

    @discardableResult
    public static func setNormalizeEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        edit(&c) { fx in
            if on { var k = fx.normalize ?? AudioFx.Normalize(); k.enabled = true; fx.normalize = k }
            else if var k = fx.normalize { k.enabled = false; fx.normalize = k }
        }
    }

    @discardableResult
    public static func setNormalizeTarget(_ c: inout Clip, _ db: Double) -> Bool {
        edit(&c) { fx in
            var k = fx.normalize ?? AudioFx.Normalize()
            let r = AudioFx.Normalize.range(for: k.modeOrDefault)
            k.target = (min(max(db.isFinite ? db : r.upperBound, r.lowerBound), r.upperBound) * 10).rounded() / 10
            fx.normalize = k
        }
    }

    /// モードを替える。目標は新しいモードの範囲に収め直す(ピーク −1 dB → ラウドネスでは −16 LUFS など、モードごとの既定)。
    @discardableResult
    public static func setNormalizeMode(_ c: inout Clip, _ mode: AudioFx.NormalizeMode) -> Bool {
        edit(&c) { fx in
            var k = fx.normalize ?? AudioFx.Normalize()
            if fx.normalize != nil && k.modeOrDefault == mode { return }
            k.mode = mode.rawValue
            k.target = mode == .peak ? AudioFx.Normalize.defaultTarget : -16
            fx.normalize = k
        }
    }

    // MARK: ノイズ除去

    /// 強さ 0〜1(小数 2 桁)。0 は未設定に戻して書かない。変わらなければ false。
    @discardableResult
    public static func setDenoise(_ c: inout Clip, _ v: Double) -> Bool {
        let x = (AudioFx.clampDenoise(v) * 100).rounded() / 100
        return edit(&c) { fx in fx.denoise = x > 0 ? x : nil }
    }

    /// 既定の強さ(ノイズ除去を初めて入れるとき)。
    public static let defaultDenoise = 0.5

    /// 音程(半音)。0.1 刻みに丸め、0 に戻ったら項目ごと外す。変化があれば true。
    public static func setPitch(_ c: inout Clip, _ semitones: Double) -> Bool {
        let x = (AudioFx.clampPitch(semitones) * 10).rounded() / 10
        return edit(&c) { fx in fx.pitch = x != 0 ? x : nil }
    }

    // MARK: パン

    /// −1〜1(小数 2 桁)。0 は未設定に戻す。
    @discardableResult
    public static func setPan(_ c: inout Clip, _ v: Double) -> Bool {
        guard supports(c) else { return false }
        let x = (min(max(v.isFinite ? v : 0, -1), 1) * 100).rounded() / 100
        let new: Double? = x == 0 ? nil : x
        guard c.pan != new else { return false }
        c.pan = new
        return true
    }

    // MARK: 音量

    /// 音量を `db` dB だけ上げ下げする(倍率の範囲 0〜2 に収める)。音量にキーがあれば、全部のキーを同じだけ動かす。
    /// 無音(0)のままは動かせない(0 に何をかけても 0)ので、そのときは変化なし。
    @discardableResult
    public static func stepVolume(_ c: inout Clip, db: Double) -> Bool {
        guard supports(c) else { return false }
        let k = pow(10, db / 20)
        func scaled(_ v: Double) -> Double { (min(max(v * k, 0), 2) * 1000).rounded() / 1000 }
        var changed = false
        if c.hasVolumeKeys {
            let old = c.keyframes["volume"]!
            let new = old.map { Keyframe(t: $0.t, v: scaled($0.v), ease: $0.ease) }
            if new != old { c.keyframes["volume"] = new; changed = true }
        } else {
            let old = c.volumeOrDefault
            let new = scaled(old)
            if new != old { c.volume = new; changed = true }
        }
        return changed
    }

    // MARK: プリセットとまとめて外す

    /// ノーマライズ(ピーク)。すでに同じ設定なら何もしない。
    @discardableResult
    public static func normalizePeak(_ c: inout Clip, targetDb: Double = -1) -> Bool {
        edit(&c) { fx in fx.normalize = AudioFx.Normalize(targetDb: targetDb, mode: .peak) }
    }

    /// ボイス向け: 低域の抑え(−3 dB)+ 中域の明瞭さ(+2 dB)+ 高域の抜け(+2 dB)+ 軽いコンプレッサー(−20 dB・3:1・メイクアップ +3 dB)。
    public static let voicePreset = AudioFx(eq: AudioFx.EQ(low: -3, mid: 2, high: 2),
                                            compressor: AudioFx.Compressor(threshold: -20, ratio: 3, attack: 8, release: 120, makeup: 3))

    @discardableResult
    public static func applyVoicePreset(_ c: inout Clip) -> Bool {
        edit(&c) { fx in fx.eq = voicePreset.eq; fx.compressor = voicePreset.compressor }
    }

    /// 音声エフェクト(EQ・コンプレッサー・リバーブ・ノーマライズ)とパンをすべて外す。音量・フェードはそのまま。
    @discardableResult
    public static func clearAll(_ c: inout Clip) -> Bool {
        guard supports(c) else { return false }
        var changed = false
        if c.audioFx != nil { c.audioFx = nil; changed = true }
        if c.pan != nil { c.pan = nil; changed = true }
        return changed
    }

    /// 外せるものがある(メニューの有効判定)。
    public static func hasAnyFx(_ c: Clip) -> Bool { c.audioFx != nil || c.pan != nil }
}
