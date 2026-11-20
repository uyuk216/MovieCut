import Foundation

// MARK: - VST3 スロット(クリップの音声エフェクトとしての VST3 指定)
//
// `AudioFx` の任意キー `vst3` に、VST3 プラグインの指定(スロット)を配列で持つ。
// 追加方式の約束(拡張エフェクト `extended` と同じ):
// - スロットが無い/空のクリップは、プロジェクトファイルも音も従来と **バイト単位で一致** する。
// - 音声処理は、ミックスへプロバイダ(`VST3EffectProvider`)を渡した経路(再生・書き出し・
//   測定・試聴)でのみ効く。接続位置は当初の設計どおり「拡張エフェクトの後・リミッターの前」
//   (`AudioFxChain`)。プロバイダを渡さない経路ではスロットは **音を変えない**(バイパス = 原音)。
//   `AudioFx.isActive` / `hasChain` / `cacheToken` には今も含めない(ミキサー側がプロバイダの
//   有無で別扱いし、再生キャッシュ鍵へは鍵材料 `vst3CacheToken` を別枠で足す。`AudioCacheKey` 参照)。
// - プラグインがこの Mac に無くても、指定はそのまま残る(名前の控えを一緒に保存する)。
//   読み込み側は「見つからない VST3 スロット = バイパス + 未検出の表示」として扱う。

/// VST3 スロットの処理状態。今は 1 種類だけ(将来ホストが入れば増える)。
public enum VST3ProcessingStatus: Equatable, Sendable {
    /// 音声処理ホスト未実装。指定は保存されるが音は変わらない(バイパス)。
    case notImplemented
    /// ブリッジが使える環境。読み込めたプラグインは実処理し、読み込めなければバイパス。
    case bridgeAvailable

    /// ユーザー向けの短い説明。
    public var userFacingNote: String {
        switch self {
        case .notImplemented: return "検出のみ対応のため、この指定は音を変えません(バイパス)"
        case .bridgeAvailable: return "ブリッジ経由で処理します(読み込めない場合はバイパス)"
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
        /// プラグイン状態チャンク(Base64)。ホストが取得できたときだけ入る(W6-1)。
        /// 無い/空のときは書かない。壊れた Base64 は `stateData` で nil になるだけで保持はする。
        public var state: String?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["bundleId", "name", "enabled", "params", "state"]

        public init(bundleID: String, name: String? = nil, enabled: Bool = true, params: [String: Double]? = nil, state: String? = nil) {
            self.bundleID = bundleID; self.name = name; self.enabled = enabled
            self.params = params?.filter { $0.value.isFinite }
            self.state = (state?.isEmpty ?? true) ? nil : state
        }

        /// 状態チャンクの実バイト列(Base64 を解いたもの)。解けなければ nil。
        public var stateData: Data? {
            guard let state, !state.isEmpty else { return nil }
            return Data(base64Encoded: state)
        }

        /// 設定として有効か(処理が未実装でも「指定が入っている」ことは別。音への効きは `processingStatus` を見る)。
        public var isEnabled: Bool { enabled }
        /// 今の到達状態での処理状態(ブリッジが無い環境では従来どおり未実装 = バイパス)。
        public var processingStatus: VST3ProcessingStatus {
            VST3HostAvailability.current.canProcessAudio ? .bridgeAvailable : .notImplemented
        }
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
            state = l.string("state").flatMap { $0.isEmpty ? nil : $0 }
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
            if let state, !state.isEmpty { try c.encode(state, forKey: AnyKey("state")) }
        }
    }

    /// VST3 スロットの一覧(無いときは空)。
    var vst3Slots: [VST3Slot] { vst3 ?? [] }
    /// スロットが 1 つでもあるか(ファイルに `vst3` を書く条件はこちらの実体で決まる)。
    var hasVST3Slots: Bool { !(vst3?.isEmpty ?? true) }
    /// 有効なスロットだけ。
    var enabledVST3Slots: [VST3Slot] { vst3Slots.filter { $0.isEnabled } }
    /// VST3 指定が音に効く場合のキャッシュ鍵部品(従来の `cacheToken` には含めない。
    /// 再生キャッシュ鍵は `AudioCacheKey` がこの材料を別枠で足す)。
    /// 有効なスロットだけを、バンドル ID・パラメータ(キー順)・状態の長さで決定的に並べる。
    var vst3CacheToken: String {
        enabledVST3Slots.map { slot in
            var part = "vst3=" + slot.bundleID.lowercased()
            if let params = slot.params, !params.isEmpty {
                part += "(" + params.keys.sorted().map { "\($0)=\(params[$0]!)" }.joined(separator: ",") + ")"
            }
            if let state = slot.state, !state.isEmpty { part += "[state:\(state.count)]" }
            return part
        }.joined(separator: ";")
    }
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

    /// VST3 スロットのパラメータ控えを 1 件設定する(W6-1)。
    /// 値は正規化値の約束で 0...1 に丸め、有限でない値は受けない。同じ値なら変化なし。
    @discardableResult
    static func setVST3SlotParam(_ c: inout Clip, at index: Int, key: String, value: Double) -> Bool {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, value.isFinite else { return false }
        let v = min(1, max(0, value))
        return edit(&c) { fx in
            guard fx.vst3Slots.indices.contains(index), fx.vst3Slots[index].params?[k] != v else { return }
            var slots = fx.vst3Slots
            var params = slots[index].params ?? [:]
            params[k] = v
            slots[index].params = params
            fx.vst3 = slots
        }
    }

    /// VST3 スロットのパラメータ控えを 1 件外す。控えが空になったら `params` ごと無くなる。
    @discardableResult
    static func removeVST3SlotParam(_ c: inout Clip, at index: Int, key: String) -> Bool {
        edit(&c) { fx in
            guard fx.vst3Slots.indices.contains(index), fx.vst3Slots[index].params?[key] != nil else { return }
            var slots = fx.vst3Slots
            var params = slots[index].params ?? [:]
            params[key] = nil
            slots[index].params = params.isEmpty ? nil : params
            fx.vst3 = slots
        }
    }

    /// VST3 スロットの状態チャンクを設定/消去する(W6-1)。同じ内容なら変化なし。
    @discardableResult
    static func setVST3SlotState(_ c: inout Clip, at index: Int, stateData: Data?) -> Bool {
        let encoded = stateData.map { $0.base64EncodedString() }
        return edit(&c) { fx in
            guard fx.vst3Slots.indices.contains(index), fx.vst3Slots[index].state != encoded else { return }
            var slots = fx.vst3Slots
            slots[index].state = encoded
            fx.vst3 = slots
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
