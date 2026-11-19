import Foundation

// MARK: - VST3 スロット(クリップの音声エフェクトとしての VST3 指定)
//
// `AudioFx` の任意キー `vst3` に、VST3 プラグインの指定(スロット)を配列で持つ。
// 追加方式の約束(拡張エフェクト `extended` と同じ):
// - スロットが無い/空のクリップは、プロジェクトファイルも音も従来と **バイト単位で一致** する。
// - 音声処理ホストは未実装(調査: `docs/VST3プラグイン調査と到達範囲.md`)なので、スロットは
//   **音を変えない**。そのため `AudioFx.isActive` / `hasChain` / `cacheToken` には含めない
//   (バイパス = 原音が仕様。ホスト実装時に、チェーンの「拡張エフェクトの後・リミッターの前」
//   へ接続し、その時点で初めて含める)。
// - プラグインがこの Mac に無くても、指定はそのまま残る(名前の控えを一緒に保存する)。
//   読み込み側は「見つからない VST3 スロット = バイパス + 未検出の表示」として扱う。

/// VST3 スロットの処理状態。今は 1 種類だけ(将来ホストが入れば増える)。
public enum VST3ProcessingStatus: Equatable, Sendable {
    /// 音声処理ホスト未実装。指定は保存されるが音は変わらない(バイパス)。
    case notImplemented

    /// ユーザー向けの短い説明。
    public var userFacingNote: String {
        switch self {
        case .notImplemented: return "検出のみ対応のため、この指定は音を変えません(バイパス)"
        }
    }
}

public extension AudioFx {
    /// VST3 プラグイン 1 件分の指定。バンドル ID が identity で、表示名は「控え」として一緒に持つ
    /// (プラグインが消えた/別の Mac で開いたときも、何を指定したか分かるように)。
    struct VST3Slot: Codable, Equatable, Sendable {
        /// プラグインの識別子(バンドル ID。`VST3BundleInfo.slotIdentifier` と同じ規則)。
        public var bundleID: String
        /// 表示名の控え(追加した時点の名前)。プラグイン未検出でも表示に使える。
        public var name: String?
        /// false のときだけ書く(指定は残したまま一時的に切る。他のエフェクトと同じ流儀)。
        public var enabled: Bool = true
        /// パラメータの控え(キー = プラグイン側のパラメータ ID 文字列)。ホスト未実装の今は
        /// 読み書きだけが成立し、音には使わない。有限でない値は保存時に落とす。
        public var params: [String: Double]?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["bundleId", "name", "enabled", "params"]

        public init(bundleID: String, name: String? = nil, enabled: Bool = true, params: [String: Double]? = nil) {
            self.bundleID = bundleID; self.name = name; self.enabled = enabled
            self.params = params?.filter { $0.value.isFinite }
        }

        /// 設定として有効か(処理が未実装でも「指定が入っている」ことは別。音への効きは `processingStatus` を見る)。
        public var isEnabled: Bool { enabled }
        /// 今の到達状態での処理状態(常に未実装 = バイパス)。
        public var processingStatus: VST3ProcessingStatus { .notImplemented }
        /// 音声エフェクト解決用の識別子(`VST3BundleInfo.audioEffectID` と同じ規則)。
        public var audioEffectID: String { "vst3." + bundleID.lowercased() }
        /// 表示名(控えが無ければバンドル ID)。
        public var displayName: String {
            if let name, !name.isEmpty { return name }
            return bundleID
        }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            bundleID = l.string("bundleId") ?? ""
            name = l.string("name")
            enabled = l.bool("enabled") ?? true
            let raw: [String: Double]? = l.value("params")
            params = raw?.filter { $0.value.isFinite }
            extra = l.extra()
            // 型が違って読めなかった params は、捨てずにそのまま書き戻す
            if params == nil, let rawParams: JSONValue = l.value("params") {
                extra["params"] = rawParams
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            try c.encode(bundleID, forKey: AnyKey("bundleId"))
            try c.encodeIfPresent(name, forKey: AnyKey("name"))
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            if let params, !params.isEmpty {
                try c.encode(params.filter { $0.value.isFinite }, forKey: AnyKey("params"))
            }
        }
    }

    /// VST3 スロットの一覧(無いときは空)。
    var vst3Slots: [VST3Slot] { vst3 ?? [] }
    /// スロットが 1 つでもあるか(ファイルに `vst3` を書く条件はこちらの実体で決まる)。
    var hasVST3Slots: Bool { !(vst3?.isEmpty ?? true) }
    /// 有効なスロットだけ。
    var enabledVST3Slots: [VST3Slot] { vst3Slots.filter { $0.isEnabled } }
    /// 指定したバンドル ID のスロットがあるか(大文字小文字は区別しない)。
    func vst3Slot(forBundleID bundleID: String) -> VST3Slot? {
        vst3Slots.first { $0.bundleID.lowercased() == bundleID.lowercased() }
    }
}

// MARK: - 編集(純粋な計算。AudioFxEditing の流儀: 変えたときだけ true、空になったらキーを外す)

public extension AudioFxEditing {
    /// VST3 スロットを追加する。同じバンドル ID が既にあれば何もしない(false)。
    @discardableResult
    static func addVST3Slot(_ c: inout Clip, bundleID: String, name: String? = nil) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        return edit(&c) { fx in
            guard fx.vst3Slot(forBundleID: id) == nil else { return }
            var slots = fx.vst3Slots
            slots.append(AudioFx.VST3Slot(bundleID: id, name: name))
            fx.vst3 = slots
        }
    }

    /// VST3 スロットを外す。全部外れたら `vst3` キーごと無くなる。
    @discardableResult
    static func removeVST3Slot(_ c: inout Clip, at index: Int) -> Bool {
        edit(&c) { fx in
            guard fx.vst3Slots.indices.contains(index) else { return }
            var slots = fx.vst3Slots
            slots.remove(at: index)
            fx.vst3 = slots.isEmpty ? nil : slots
        }
    }

    /// VST3 スロットの有効/無効を切り替える(指定は残る)。
    @discardableResult
    static func setVST3SlotEnabled(_ c: inout Clip, at index: Int, enabled: Bool) -> Bool {
        edit(&c) { fx in
            guard fx.vst3Slots.indices.contains(index), fx.vst3Slots[index].enabled != enabled else { return }
            var slots = fx.vst3Slots
            slots[index].enabled = enabled
            fx.vst3 = slots
        }
    }
}
