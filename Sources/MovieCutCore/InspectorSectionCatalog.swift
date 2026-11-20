import Foundation

/// インスペクタの開閉できる節の定義(SwiftUI 非依存)。
/// 見出し・保存キー・既定の開閉をここに集め、ビュー側は id で参照する(文字列リテラルの散在を避ける)。
/// storageKey は常に `mc.disclosure.` + id。既存の保存済み状態を引き継ぐため、
/// 最上位の節の id(`inspector.timing` など)は従来の実キーと一致させてあり、変更してはいけない。
public struct InspectorSectionDefinition: Equatable {
    public enum Level: String { case top, sub }
    /// 安定した識別子。`mc.disclosure.` を除いた保存キーと同じ。
    public let id: String
    /// 見出し文言(L10n.t を通して表示する)。
    public let title: String
    /// UserDefaults の完全なキー(`mc.disclosure.<id>`)。
    public let storageKey: String
    /// 未保存のときの既定の開閉。
    public let defaultOpen: Bool
    /// true のとき、未保存の既定は固定値ではなく「効いている節だけ開く(または forceExpanded)」。defaultOpen は false 側の基準値。
    public let defaultsToActive: Bool
    public let level: Level

    public init(id: String, title: String, defaultOpen: Bool, defaultsToActive: Bool = false, level: Level) {
        self.id = id
        self.title = title
        self.storageKey = InspectorSectionCatalog.keyPrefix + id
        self.defaultOpen = defaultOpen
        self.defaultsToActive = defaultsToActive
        self.level = level
    }
}

public enum InspectorSectionCatalog {
    public static let keyPrefix = "mc.disclosure."

    /// 保存キーの規則: 接頭辞 + 英数字・アンダースコアの語をドットでつないだもの(既存キーは camelCase を含む。例 `inspector.textStyle`)。
    public static func isValidStorageKey(_ key: String) -> Bool {
        guard key.hasPrefix(keyPrefix) else { return false }
        let rest = key.dropFirst(keyPrefix.count)
        guard !rest.isEmpty else { return false }
        let words = rest.split(separator: ".", omittingEmptySubsequences: false)
        return words.allSatisfy { w in
            guard let f = w.unicodeScalars.first, f.properties.isAlphabetic, f.isASCII else { return false }
            return w.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || $0 == "_") }
        }
    }

    private static func top(_ k: String, _ title: String, _ open: Bool) -> InspectorSectionDefinition {
        InspectorSectionDefinition(id: "inspector.\(k)", title: title, defaultOpen: open, level: .top)
    }
    private static func sub(_ id: String, _ title: String, open: Bool = true, active: Bool = false) -> InspectorSectionDefinition {
        InspectorSectionDefinition(id: id, title: title, defaultOpen: open, defaultsToActive: active, level: .sub)
    }

    /// 拡張エフェクト(AudioFxExtendedPanel)のグループ順。キーは `inspector.audioFx.ext.<key>`。
    public static let audioFxExtendedKeys = ["filter", "peq", "dist", "tube", "chorus", "flanger", "phaser", "tremolo", "vibrato", "wah", "echo", "lowq", "robot"]

    public static let all: [InspectorSectionDefinition] = [
        // 最上位(既存。実キーは従来どおり)
        top("timing", "タイミング", true), top("note", "注記", false), top("group", "グループ", false),
        top("voice", "セリフ", true), top("text", "文字", true), top("textStyle", "文字のスタイル", true),
        top("place", "位置・変形", true), top("compound", "中身", false), top("scene", "シーン", true),
        top("effect", "エフェクト", false), top("transition", "トランジション", false),
        top("blur", "ぼかし", true), top("visualizer", "ビジュアライザ", true), top("shape", "図形", true),
        top("speed", "速度", false), top("stabilize", "手ぶれ補正", false), top("mask", "形のマスク", false),
        top("audio", "音声", true),
        // 最上位(今回追加。従来は常に表示だったので既定は開)
        top("tracking", "トラッキング", true), top("objectMask", "オブジェクトマスク", true), top("hslMask", "HSLマスク", true),
        top("warpMesh", "メッシュ変形", true), top("warpPuppet", "パペット変形", true), top("camera", "カメラ", true),
        // 音声エフェクト(AudioFxPanel / AudioFxExtendedPanel / VST3Panel)。active 付きは「効いている節だけ開く」が未保存の既定
        sub("inspector.audioFx.basic", "基本調整"),
        sub("inspector.audioFx.eq", "イコライザー", open: false, active: true),
        sub("inspector.audioFx.comp", "コンプレッサー", open: false, active: true),
        sub("inspector.audioFx.reverb", "リバーブ", open: false, active: true),
        sub("inspector.audioFx.delay", "ディレイ", open: false, active: true),
        sub("inspector.audioFx.norm", "ノーマライズ", open: false, active: true),
        sub("inspector.audioFx.duck", "自動ダッキング", open: false, active: true),
        sub("inspector.audioFx.ext.filter", "フィルタ", open: false, active: true),
        sub("inspector.audioFx.ext.peq", "5バンドEQ", open: false, active: true),
        sub("inspector.audioFx.ext.dist", "ディストーション", open: false, active: true),
        sub("inspector.audioFx.ext.tube", "チューブ", open: false, active: true),
        sub("inspector.audioFx.ext.chorus", "コーラス", open: false, active: true),
        sub("inspector.audioFx.ext.flanger", "フランジャー", open: false, active: true),
        sub("inspector.audioFx.ext.phaser", "フェイザー", open: false, active: true),
        sub("inspector.audioFx.ext.tremolo", "トレモロ", open: false, active: true),
        sub("inspector.audioFx.ext.vibrato", "ビブラート", open: false, active: true),
        sub("inspector.audioFx.ext.wah", "ワウ", open: false, active: true),
        sub("inspector.audioFx.ext.echo", "エコー", open: false, active: true),
        sub("inspector.audioFx.ext.lowq", "低音質化", open: false, active: true),
        sub("inspector.audioFx.ext.robot", "ロボット化", open: false, active: true),
        sub("inspector.audioFx.vst3", "VST3", open: false, active: true),
        // 内側の節(従来は開閉できない静的見出し)
        sub("inspector.place.position", "位置"), sub("inspector.place.transform", "変形"),
        sub("inspector.place.crop", "切り抜き"), sub("inspector.place.look", "見た目"),
        sub("inspector.blur.range", "範囲"), sub("inspector.blur.look", "見た目"),
        sub("inspector.visualizer.range", "範囲"), sub("inspector.visualizer.input", "入力"), sub("inspector.visualizer.look", "見た目"),
        sub("inspector.shape.range", "範囲"), sub("inspector.shape.look", "見た目"),
        sub("inspector.voice.subtitle", "字幕"), sub("inspector.voice.audio", "音声"),
        sub("inspector.textStyle.balloon", "吹き出し"), sub("inspector.textStyle.style", "スタイル"),
        sub("inspector.textStyle.decoration", "装飾"), sub("inspector.textStyle.countdown", "カウントダウン"),
        sub("inspector.textStyle.otherClips", "他のクリップの値"), sub("inspector.textStyle.animation", "文字アニメーション"),
        sub("inspector.tachie.main", "立ち絵"), sub("inspector.tachie.expression", "表情の切り替え（再生位置）"),
        sub("inspector.tachie.image", "画像"), sub("inspector.tachie.mouth", "あいうえお（口の形）"),
        sub("inspector.rig.parts", "立ち絵パーツ"), sub("inspector.rig.expressions", "表情（パーツの組み合わせ）"),
        sub("inspector.character.basic", "基本"), sub("inspector.character.voice", "声"), sub("inspector.character.actions", "操作"),
    ]

    private static let byID: [String: InspectorSectionDefinition] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    public static func definition(id: String) -> InspectorSectionDefinition? { byID[id] }

    /// id から定義を引く。カタログに無い id はプログラムの誤り(テストが漏れを検出する)。
    public static func require(_ id: String) -> InspectorSectionDefinition {
        guard let d = byID[id] else { preconditionFailure("InspectorSectionCatalog に未登録の id: \(id)") }
        return d
    }
}

/// 開閉状態の保存。UserDefaults を注入できる(テストは専用 suite を渡す)。
/// 「ユーザーが明示的に開閉した値だけ」を保存し、未保存(nil)なら呼び出し側の既定判定を使う。
public struct InspectorDisclosureStore {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static var standard: InspectorDisclosureStore { InspectorDisclosureStore() }

    /// 保存済みの値。未保存なら nil。
    public func saved(_ def: InspectorSectionDefinition) -> Bool? { defaults.object(forKey: def.storageKey) as? Bool }
    public func saved(id: String) -> Bool? { InspectorSectionCatalog.definition(id: id).flatMap(saved) }
    public func set(_ open: Bool, for def: InspectorSectionDefinition) { defaults.set(open, forKey: def.storageKey) }
    public func set(_ open: Bool, id: String) { set(open, for: InspectorSectionCatalog.require(id)) }
    /// 保存を消して既定に戻す。
    public func clear(_ def: InspectorSectionDefinition) { defaults.removeObject(forKey: def.storageKey) }

    /// 保存値があればそれ、無ければ fallback(効いている節だけ開く等の既定判定の結果)。
    public func resolved(_ def: InspectorSectionDefinition, fallback: Bool) -> Bool { saved(def) ?? fallback }
}
