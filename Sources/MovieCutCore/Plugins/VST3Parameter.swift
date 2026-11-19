import Foundation

// MARK: - VST3 パラメータ記述モデル(R5-1: 次工程のうち単体テスト可能な範囲)
//
// 将来の実ホストが `IEditController::getParameterInfo` から受け取る情報を、
// VST3 SDK に依存しない純粋な Swift モデルとして先に固定する。狙い:
// - パラメータ自動生成 UI(`PluginAudioEffect.swift` の記述子 `params`)の入力形式を決める
// - スロットの `params` 控え(AudioFx.VST3Slot)を、実プラグイン無しでも検証・整形できるようにする
// - 正規化値(0...1。VST3 の `ParamValue`)と表示値(plain)の往復規則を 1 か所に寄せる
//
// ここにあるのは「記述と検証」だけ。実プラグインからの取得・実値の適用は実ホストの仕事で、
// このファイルはバイナリを一切ロードしない(スキャンの安全性は従来どおり)。

/// VST3 パラメータ 1 件の記述(`ParameterInfo` の MovieCut 側モデル)。
public struct VST3ParameterDescriptor: Equatable, Sendable {
    /// パラメータ ID(VST3 の `ParamID`。プラグイン内で一意な 32 ビット値)。
    public var id: UInt32
    /// 正式名称(例: "Gain")。
    public var title: String
    /// 短い名称(例: "Gn")。無ければ nil(UI は title を使う)。
    public var shortTitle: String?
    /// 単位の表示文字列(例: "dB" / "%")。無ければ nil。
    public var units: String?
    /// 離散段数。0 = 連続、1 = トグル(オン/オフ)、2 以上 = その段数 - 1 が正規化の刻み。
    /// (VST3 の stepCount の意味そのまま: 取り得る値の数は stepCount + 1)
    public var stepCount: Int
    /// 既定の正規化値(0...1)。
    public var defaultNormalizedValue: Double
    /// 表示値(plain)の範囲。線形対応のものだけ持つ(対数カーブ等は実ホスト側の変換が必要で、
    /// ここでは扱わない = nil のとき plain 変換は提供しない)。
    public var plainRange: ClosedRange<Double>?
    public var flags: Flags

    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// オートメーション対象にできる。
        public static let canAutomate = Flags(rawValue: 1 << 0)
        /// 読み取り専用(メーター等)。UI は編集不可にする。
        public static let isReadOnly = Flags(rawValue: 1 << 1)
        /// 値のラップ(上限を超えたら下限へ戻る。ロータリー系)。
        public static let isWrapAround = Flags(rawValue: 1 << 2)
        /// 一覧選択型(値 = 項目のインデックス)。
        public static let isList = Flags(rawValue: 1 << 3)
        /// バイパス用パラメータ(プラグインのバイパス切替そのもの)。
        public static let isBypass = Flags(rawValue: 1 << 4)
        /// プログラム(プリセット)切替用。
        public static let isProgramChange = Flags(rawValue: 1 << 5)
    }

    public init(id: UInt32, title: String, shortTitle: String? = nil, units: String? = nil,
                stepCount: Int = 0, defaultNormalizedValue: Double = 0,
                plainRange: ClosedRange<Double>? = nil, flags: Flags = []) {
        self.id = id; self.title = title; self.shortTitle = shortTitle; self.units = units
        self.stepCount = stepCount; self.defaultNormalizedValue = defaultNormalizedValue
        self.plainRange = plainRange; self.flags = flags
    }

    /// スロットの `params` 控えで使う文字列キー(パラメータ ID の 10 進表記)。
    public var storageKey: String { String(id) }

    /// 表示用の名前(短縮名があればそちらを優先しない。自動生成 UI のラベルは正式名称が安全)。
    public var displayTitle: String { title.isEmpty ? storageKey : title }

    /// トグル(オン/オフ)か。
    public var isToggle: Bool { stepCount == 1 }
    /// 離散値か(トグル含む)。
    public var isStepped: Bool { stepCount > 0 }

    // MARK: 正規化値の整形

    /// 正規化値をこのパラメータの規則に合わせて整形する:
    /// 有限でなければ既定値、0...1 に丸め、離散なら段にスナップする。
    public func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return clampedDefault }
        var v = min(1, max(0, value))
        if stepCount > 0 {
            let steps = Double(stepCount)
            v = (v * steps).rounded() / steps
        }
        return v
    }

    /// 既定値を整形したもの(不正な既定値でも 0...1 に収まる)。
    public var clampedDefault: Double {
        guard defaultNormalizedValue.isFinite else { return 0 }
        return min(1, max(0, defaultNormalizedValue))
    }

    // MARK: plain(表示値)との往復(線形範囲を持つものだけ)

    /// 正規化値 → 表示値。`plainRange` が無ければ nil(変換を提供しない)。
    public func plainValue(forNormalized normalizedValue: Double) -> Double? {
        guard let plainRange else { return nil }
        let v = normalized(normalizedValue)
        return plainRange.lowerBound + v * (plainRange.upperBound - plainRange.lowerBound)
    }

    /// 表示値 → 正規化値。`plainRange` が無ければ nil。範囲外は丸め、離散なら段に寄せる。
    public func normalizedValue(forPlain plainValue: Double) -> Double? {
        guard let plainRange, plainValue.isFinite else { return nil }
        let span = plainRange.upperBound - plainRange.lowerBound
        guard span > 0 else { return clampedDefault }
        return normalized((plainValue - plainRange.lowerBound) / span)
    }

    // MARK: 自動生成 UI への変換

    /// プラグイン機構の記述子(`PluginAudioEffectDescriptor.params`)へ変換する。
    /// UI が扱うのは正規化値(0...1)で統一する(plain は表示専用)。
    /// 読み取り専用とバイパスは自動生成 UI の編集対象にしないため nil を返す。
    public func effectParamSpec() -> EffectParamSpec? {
        guard !flags.contains(.isReadOnly), !flags.contains(.isBypass) else { return nil }
        return EffectParamSpec(key: storageKey, label: displayTitle, range: 0...1,
                               defaultValue: clampedDefault,
                               step: stepCount > 0 ? 1.0 / Double(stepCount) : 0.01,
                               unit: isToggle ? .toggle : .plain)
    }
}

// MARK: - パラメータ一覧の検証

public extension Array where Element == VST3ParameterDescriptor {
    /// 一覧としての問題を人間向けの文で返す(空 = 問題なし)。
    /// 実ホストが取得した一覧をそのまま信じず、UI/保存へ渡す前にここを通す想定。
    func vst3ValidationIssues() -> [String] {
        var issues: [String] = []
        var seen: Set<UInt32> = []
        for p in self {
            if !seen.insert(p.id).inserted { issues.append("パラメータ ID \(p.id) が重複している") }
            if p.title.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("パラメータ \(p.id) の名称が空") }
            if !p.defaultNormalizedValue.isFinite || !(0...1).contains(p.defaultNormalizedValue) {
                issues.append("パラメータ \(p.id) の既定値が 0...1 の範囲外")
            }
            if p.stepCount < 0 { issues.append("パラメータ \(p.id) の stepCount が負") }
            if let r = p.plainRange, !(r.upperBound > r.lowerBound) {
                issues.append("パラメータ \(p.id) の表示範囲が不正(下限 >= 上限)")
            }
        }
        return issues
    }

    /// ID で引く(重複時は最初の 1 件)。
    func vst3Parameter(id: UInt32) -> VST3ParameterDescriptor? { first { $0.id == id } }
    /// スロット控えの文字列キーで引く。
    func vst3Parameter(storageKey: String) -> VST3ParameterDescriptor? { first { $0.storageKey == storageKey } }
}

// MARK: - スロットの params 控えの整形(記述モデルとの照合)

public extension AudioFx.VST3Slot {
    /// 保存済みの `params` 控えを、パラメータ記述一覧に照らして整形したものを返す。
    /// - 記述に無いキーは落とす(別プラグインの控えや壊れた値を持ち込まない)
    /// - 値は各パラメータの規則(範囲・離散段)で整形する。有限でない値は落とす
    /// - 読み取り専用パラメータへの控えは落とす(書き込む意味が無い)
    /// 記述が空(未知)のときは、従来どおり有限チェックだけ済んだ控えをそのまま返す
    /// (プラグイン未検出でも指定を保持する、という既存の約束を壊さないため)。
    func sanitizedParams(against descriptors: [VST3ParameterDescriptor]) -> [String: Double] {
        guard let params else { return [:] }
        guard !descriptors.isEmpty else { return params.filter { $0.value.isFinite } }
        var out: [String: Double] = [:]
        for (key, value) in params {
            guard value.isFinite, let d = descriptors.vst3Parameter(storageKey: key),
                  !d.flags.contains(.isReadOnly) else { continue }
            out[key] = d.normalized(value)
        }
        return out
    }

    /// 控えが記述一覧と矛盾していないかの問題一覧(空 = 問題なし)。
    /// 記述が空のときは判定できないので問題なしとする(保持の約束を優先)。
    func paramIssues(against descriptors: [VST3ParameterDescriptor]) -> [String] {
        guard let params, !descriptors.isEmpty else { return [] }
        var issues: [String] = []
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            guard let d = descriptors.vst3Parameter(storageKey: key) else {
                issues.append("未知のパラメータ \(key) への値が保存されている")
                continue
            }
            if !value.isFinite { issues.append("パラメータ \(key) の値が有限でない") }
            else if d.normalized(value) != value {
                issues.append("パラメータ \(key) の値 \(value) が規則(範囲/離散段)に合っていない")
            }
        }
        return issues
    }
}
