import Foundation

// MARK: - エッセンシャルサウンド(音声クリップの種別タグ + 種別ごとの一括整音)
//
// Premiere Pro の「エッセンシャルサウンド」等価機能。
// 音のあるクリップに種別(会話 / ミュージック / 効果音(SFX) / アンビエンス)を付けると、
// 種別ごとの整音プリセットをワンクリックで適用できる。
//
// - 保存: `Clip.audioCategory` は種別があるときだけ書く(未分類 = キー自体を書かない)。
//   未設定の既存プロジェクトは従来とバイト単位で一致する。知らない種別文字列は
//   捨てずに `extra` へ残して書き戻す(`Clip.blendMode` と同じ作法)。
// - 整音は新しい音声処理を作らず、既存の設定の組み合わせだけで表す:
//   ノイズ除去・EQ・コンプレッサー・ノイズゲート・リミッター・ノーマライズ(`AudioFx`)、
//   「声として扱う」指定(`treatAsVoice`)、自動ダッキング(`Duck`)。
//   プリセットが触らない項目(リバーブ・ディレイ・パン・音量・フェード等)はそのまま残る。
// - タグ自体は音を変えない: ミックス段(`AudioMixer` / `Ducking`)はタグを読まないので、
//   タグを付けただけ・タグが無いクリップの音と挙動は従来と変わらない。
//   音が変わるのは整音プリセットを適用したときだけで、その内容も上の既存設定そのものである。
// - 編集: ロックされたレイヤー・クリップ(複合クリップの外側も含む)には触れない
//   (`ClipVoice` の「声として扱う」と同じ作法)。複合クリップの中の子にも効く。

/// 音声クリップの種別(エッセンシャルサウンド)。ファイルには rawValue の文字列で書く。
public enum AudioCategory: String, CaseIterable, Codable, Sendable {
    case dialogue
    case music
    case sfx
    case ambience

    /// 画面に出す名前(日本語)。
    public var label: String {
        switch self {
        case .dialogue: return "会話"
        case .music: return "ミュージック"
        case .sfx: return "効果音（SFX）"
        case .ambience: return "アンビエンス"
        }
    }

    /// 整音プリセットで何をするかの説明(パネルの文言。`L10nTable` のキーにもなる)。
    public var presetSummary: String {
        switch self {
        case .dialogue: return "ノイズ除去と声向けのEQ・コンプレッサーで聞き取りやすくし、ラウドネスをそろえます。声として扱う指定もオンにします。"
        case .music: return "声があるときに自動で下がるダッキングを設定し、ピークを整えます。"
        case .sfx: return "ピークとリミッターで音割れを防ぎます。ダッキングは設定しません。"
        case .ambience: return "控えめな音量にそろえ、緩やかなダッキングで会話の下に敷きます。"
        }
    }
}

// MARK: - 編集(純粋な計算)

public enum EssentialSoundEditing {
    /// 種別を付けられるクリップ: 音声エフェクトを受けられるクリップ(音声・ボイス・動画。フリーズフレームは無音なので除く)。
    public static func supports(_ c: Clip) -> Bool { Clip.supportsAudioFx(c) }

    /// 種別タグだけを付ける / 外す(整音はしない)。変われば true。
    /// 外す(未分類に戻す)ときも、適用済みのエフェクトはそのまま残る(タグと整音は別の操作)。
    @discardableResult
    public static func setCategory(_ c: inout Clip, _ category: AudioCategory?) -> Bool {
        guard supports(c) else { return false }
        let before = c.audioCategory
        let hadExtra = c.extra["audioCategory"] != nil
        c.audioCategory = category
        c.extra["audioCategory"] = nil
        return c.audioCategory != before || hadExtra
    }

    /// 種別タグ + 種別ごとの整音プリセットをまとめて適用する。変われば true。
    /// すでに同じ内容なら false(呼び出し側は Undo に積まない)。
    @discardableResult
    public static func applyPreset(_ c: inout Clip, category: AudioCategory) -> Bool {
        guard supports(c) else { return false }
        let before = c
        setCategory(&c, category)
        switch category {
        case .dialogue: applyDialogue(&c)
        case .music: applyMusic(&c)
        case .sfx: applySfx(&c)
        case .ambience: applyAmbience(&c)
        }
        return c != before
    }

    /// そのクリップの種別の整音が、すでに適用済みの内容と一致するか(パネルのボタンの有効判定)。
    public static func isPresetApplied(_ c: Clip) -> Bool {
        guard let category = c.audioCategory else { return false }
        var probe = c
        _ = applyPreset(&probe, category: category)
        return probe == c
    }

    // MARK: プリセットの中身(すべて既存設定の組み合わせ)

    /// `audioFx` を書き換える(空になったら nil に戻す)。
    private static func editFx(_ c: inout Clip, _ change: (inout AudioFx) -> Void) {
        var fx = c.audioFx ?? AudioFx()
        change(&fx)
        c.audioFx = fx.isEmpty ? nil : fx
    }

    /// 会話: 声を聞き取りやすくする。ノイズ除去 50%、声向け EQ、コンプレッサー、
    /// ノイズゲート、リミッター、ラウドネス −16 LUFS のノーマライズ。
    /// 音声クリップは「声として扱う」もオンにし(ダッキングの引き金になる)、ダッキングは外す。
    private static func applyDialogue(_ c: inout Clip) {
        if c.type == .audio {
            c.treatAsVoice = true
            c.extra["treatAsVoice"] = nil
        }
        c.duck = nil
        editFx(&c) { fx in
            fx.denoise = 0.5
            var eq = fx.eq ?? AudioFx.EQ()
            eq.low = -3; eq.mid = 2; eq.high = 1
            fx.eq = eq
            fx.compressor = AudioFx.Compressor(threshold: -18, ratio: 3, attack: 10, release: 120, makeup: 2)
            fx.gate = AudioFx.defaultGate
            fx.limiter = AudioFx.defaultLimiter
            fx.normalize = AudioFx.Normalize(targetDb: -16, mode: .loudness)
        }
    }

    /// ミュージック: 声があるときに下がるダッキング(既定値)を設定し、ピーク −1 dB の
    /// ノーマライズとリミッターで天井を守る。音楽にノイズ除去はかけない(付けていたら外す)。
    /// 「声として扱う」は外す(音楽はダッキングの引き金ではない)。
    private static func applyMusic(_ c: inout Clip) {
        if c.type == .audio {
            c.treatAsVoice = nil
            c.extra["treatAsVoice"] = nil
        }
        if DuckEditing.supports(c) { c.duck = Duck() }
        editFx(&c) { fx in
            fx.denoise = nil
            fx.denoiseSpectral = nil
            fx.normalize = AudioFx.Normalize(targetDb: -1, mode: .peak)
            fx.limiter = AudioFx.defaultLimiter
        }
    }

    /// 効果音: ピーク −3 dB のノーマライズとリミッターで音割れだけを防ぐ。
    /// ダッキングは設定せず、「声として扱う」も外す。EQ・ノイズ除去等は触らない。
    private static func applySfx(_ c: inout Clip) {
        if c.type == .audio {
            c.treatAsVoice = nil
            c.extra["treatAsVoice"] = nil
        }
        c.duck = nil
        editFx(&c) { fx in
            fx.normalize = AudioFx.Normalize(targetDb: -3, mode: .peak)
            fx.limiter = AudioFx.defaultLimiter
        }
    }

    /// アンビエンス: ラウドネス −23 LUFS の控えめな音量にそろえ、緩やかなダッキング
    /// (−8 dB / アタック 0.3 秒 / リリース 1 秒)で会話の下に敷く。
    /// 軽いノイズ除去(30%)と高域 −2 dB の抑制も入れる。「声として扱う」は外す。
    private static func applyAmbience(_ c: inout Clip) {
        if c.type == .audio {
            c.treatAsVoice = nil
            c.extra["treatAsVoice"] = nil
        }
        if DuckEditing.supports(c) { c.duck = Duck(amount: -8, attack: 0.3, release: 1.0) }
        editFx(&c) { fx in
            fx.denoise = 0.3
            var eq = fx.eq ?? AudioFx.EQ()
            eq.high = -2
            fx.eq = eq
            fx.normalize = AudioFx.Normalize(targetDb: -23, mode: .loudness)
            fx.limiter = AudioFx.defaultLimiter
        }
    }
}

// MARK: - プロジェクト単位の編集(複合クリップの中・ロックの扱いは「声として扱う」と同じ)

public extension ClipEditing {
    /// クリップ 1 つの種別を切り替える(複合クリップの中の子も探す)。
    /// 見つからない・対象外の型・変わらない・ロックされたレイヤー/クリップのときは nil。
    static func setAudioCategory(in project: Project, clipId: String, _ category: AudioCategory?) -> Project? {
        setAudioCategories(in: project, ids: [clipId], category)
    }

    /// 複数のクリップの種別を揃えて切り替える。ロックされたものは飛ばす。何も変わらなければ nil。
    static func setAudioCategories(in project: Project, ids: Set<String>, _ category: AudioCategory?) -> Project? {
        var p = project
        applyEssentialChange(&p.tracks, ids: ids, blocked: false) { EssentialSoundEditing.setCategory(&$0, category) }
        return p == project ? nil : p
    }

    /// 選んだクリップに、それぞれの種別の整音プリセットを適用する(種別が無いクリップは飛ばす)。
    /// ロックされたものは飛ばす。何も変わらなければ nil。
    static func applyEssentialSound(in project: Project, ids: Set<String>) -> Project? {
        var p = project
        applyEssentialChange(&p.tracks, ids: ids, blocked: false) { clip in
            guard let category = clip.audioCategory else { return false }
            return EssentialSoundEditing.applyPreset(&clip, category: category)
        }
        return p == project ? nil : p
    }

    private static func applyEssentialChange(_ tracks: inout [Track], ids: Set<String>, blocked: Bool, _ change: (inout Clip) -> Bool) {
        for ti in tracks.indices {
            let tb = blocked || tracks[ti].isLocked
            for ci in tracks[ti].clips.indices {
                if ids.contains(tracks[ti].clips[ci].id), !tb, !tracks[ti].clips[ci].isClipLocked {
                    _ = change(&tracks[ti].clips[ci])
                }
                if tracks[ti].clips[ci].type == .compound, var kids = tracks[ti].clips[ci].tracks {
                    applyEssentialChange(&kids, ids: ids, blocked: tb || tracks[ti].clips[ci].isClipLocked, change)
                    tracks[ti].clips[ci].tracks = kids
                }
            }
        }
    }
}
