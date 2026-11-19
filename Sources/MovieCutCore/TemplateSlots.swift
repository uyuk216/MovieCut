import Foundation

// MARK: - テンプレートの差し替え項目(スロット)
//
// アイテムテンプレート(`ItemTemplate`)に「ここだけ差し替えられる」項目を定義するための型(Premiere の .mogrt 相当のローカル機能)。
// 差し替えられるのは文字・色・画像(素材パス)の 3 種類。テンプレートの見た目はそのままに、スロットで定義した項目だけを
// 適用時 / 新規作成時に入れ替える。
//
// 検証はこの層で完結する純粋な文字列チェックだけ。画像・素材のファイルが実在するかは確認しない(未検証。呼び出し側の責任)。
// 色は #RRGGBB / #RRGGBBAA(16 進)だけを有効とし、図形の塗り・線では "none" も有効とする。

/// スロットの種類(入力欄の種類)。
public enum TemplateSlotKind: String, Codable, Equatable, Sendable, CaseIterable {
    case text
    case color
    case image
}

/// スロットが差し替えるクリップの項目。
public enum TemplateSlotTarget: String, Codable, Equatable, Sendable, CaseIterable {
    case text = "text"
    case subtitleText = "subtitleText"
    case color = "color"
    case outline = "outline"
    case figureFill = "figureFill"
    case figureStroke = "figureStroke"
    case source = "src"

    /// この項目を差し替えるスロットの種類。
    public var kind: TemplateSlotKind {
        switch self {
        case .text, .subtitleText: return .text
        case .color, .outline, .figureFill, .figureStroke: return .color
        case .source: return .image
        }
    }

    /// 指定した種類のスロットで使える項目か。
    public func isCompatible(with kind: TemplateSlotKind) -> Bool { self.kind == kind }

    /// 色の項目で "none"(描かない)を許すか(図形の塗り・線だけ)。
    var allowsNoneColor: Bool { self == .figureFill || self == .figureStroke }

    /// この項目を持てるクリップの種類(nil = 全種)。
    func supports(clipType t: ClipType) -> Bool {
        switch self {
        case .text, .subtitleText: return t == .text || t == .voice
        case .source: return t == .image || t == .video || t == .audio
        case .color, .outline: return true
        case .figureFill, .figureStroke: return t == .shape
        }
    }
}

/// 差し替えに失敗した理由つきの記録。
public struct TemplateSlotRejection: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        /// テンプレートに無いスロット id。
        case unknownSlot
        /// 値の形が不正(色の書式違い・空の画像パス等)。
        case invalidValue
        /// 必須の文字が空。
        case emptyRequired
        /// スロットの項目が対象のクリップの種類と合わない。
        case incompatible
    }
    public var slotId: String
    public var reason: Reason
    public init(slotId: String, reason: Reason) { self.slotId = slotId; self.reason = reason }
}

/// 新規作成の結果(`ItemTemplate.instantiate(values:)`)。
public struct TemplateInstantiation {
    public var clip: Clip
    /// 実際に値を入れたスロットの id(テンプレートの定義順)。
    public var appliedSlotIds: [String]
    public var rejections: [TemplateSlotRejection]
    public init(clip: Clip, appliedSlotIds: [String] = [], rejections: [TemplateSlotRejection] = []) {
        self.clip = clip; self.appliedSlotIds = appliedSlotIds; self.rejections = rejections
    }
}

/// 既存クリップへの適用の結果(`ItemTemplate.apply(values:to:)`)。
public struct TemplateApplyResult: Equatable {
    /// クリップが実際に変わったか。
    public var changed: Bool
    public var appliedSlotIds: [String]
    public var rejections: [TemplateSlotRejection]
    public init(changed: Bool = false, appliedSlotIds: [String] = [], rejections: [TemplateSlotRejection] = []) {
        self.changed = changed; self.appliedSlotIds = appliedSlotIds; self.rejections = rejections
    }
}

/// 差し替え項目 1 個の定義。
public struct TemplateSlot: Codable, Equatable, Sendable, Identifiable {
    public static let maxLabelLength = 60
    public static let maxIdLength = 40

    /// テンプレート内で一意な識別子(英数と . _ - のみ)。
    public var id: String
    /// 画面に出す名前。
    public var label: String
    public var kind: TemplateSlotKind
    public var target: TemplateSlotTarget
    /// 既定値(テンプレート保存時のクリップの値)。無いときは nil。
    public var defaultValue: String?
    /// true のとき、文字が空の値を受け付けない。
    public var required: Bool

    public init(id: String, label: String, kind: TemplateSlotKind, target: TemplateSlotTarget,
                defaultValue: String? = nil, required: Bool = false) {
        self.id = id; self.label = label; self.kind = kind; self.target = target
        self.defaultValue = defaultValue; self.required = required
    }

    private enum CodingKeys: String, CodingKey { case id, label, kind, target, defaultValue, required }

    /// 古い・手書きの JSON でも落ちないよう、`defaultValue` と `required` は無くてよい。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(TemplateSlotKind.self, forKey: .kind)
        target = try c.decode(TemplateSlotTarget.self, forKey: .target)
        defaultValue = try? c.decodeIfPresent(String.self, forKey: .defaultValue)
        required = (try? c.decodeIfPresent(Bool.self, forKey: .required)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(kind, forKey: .kind)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(defaultValue, forKey: .defaultValue)
        if required { try c.encode(true, forKey: .required) }
    }

    // MARK: 整形

    /// ラベルを整える(前後の空白を除く、改行は空白に、最大 60 字)。空なら nil。
    public static func sanitizedLabel(_ s: String) -> String? {
        let t = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(maxLabelLength))
    }

    /// id を整える(英数と . _ - だけ残す)。空なら nil。
    public static func sanitizedId(_ s: String) -> String? {
        let kept = s.unicodeScalars.filter { u in
            u.isASCII && (CharacterSet.alphanumerics.contains(u) || u == "." || u == "_" || u == "-")
        }
        let t = String(String.UnicodeScalarView(kept))
        return t.isEmpty ? nil : String(t.prefix(maxIdLength))
    }

    // MARK: 対応関係

    /// kind と target の組み合わせが正しいか。
    public var isKindConsistent: Bool { target.isCompatible(with: kind) }

    /// 対象クリップに当てられるか(kind/target の対応 + クリップの種類)。
    public func isCompatible(with clip: Clip) -> Bool {
        isKindConsistent && target.supports(clipType: clip.type)
    }

    // MARK: 読み書き

    /// クリップの現在の値。
    public func value(in clip: Clip) -> String? {
        switch target {
        case .text: return clip.text
        case .subtitleText: return clip.subtitleText
        case .color: return clip.color
        case .outline: return clip.outline
        case .figureFill: return clip.figure?.fill
        case .figureStroke: return clip.figure?.stroke
        case .source: return clip.src
        }
    }

    /// 値を検証する。有効なら nil、無効なら理由。
    /// 文字: 必須なら空白のみも不可 / 任意なら空は不可(空は呼び出し側が「既定を使う」と扱う)。
    /// 色: #RRGGBB / #RRGGBBAA。図形の塗り・線は "none" も可。画像: 空でなければ可(実在は未検証)。
    public func validationFailure(of value: String) -> TemplateSlotRejection.Reason? {
        guard isKindConsistent else { return .incompatible }
        switch kind {
        case .text:
            if required {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyRequired : nil
            }
            return value.isEmpty ? .invalidValue : nil
        case .color:
            if target.allowsNoneColor && value == Figure.noneColor { return nil }
            return Self.isHexColor(value) ? nil : .invalidValue
        case .image:
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .invalidValue : nil
        }
    }

    /// 値を検証して、有効ならクリップへ書く。無効・種類違いなら何もせず false。
    @discardableResult
    public func apply(_ value: String, to clip: inout Clip) -> Bool {
        guard isCompatible(with: clip), validationFailure(of: value) == nil else { return false }
        switch target {
        case .text: clip.text = value
        case .subtitleText: clip.subtitleText = value
        case .color: clip.color = value
        case .outline: clip.outline = value
        case .figureFill:
            var f = clip.figure ?? Figure(); f.fill = value; clip.figure = f
        case .figureStroke:
            var f = clip.figure ?? Figure(); f.stroke = value; clip.figure = f
        case .source: clip.src = value
        }
        return true
    }

    static func isHexColor(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let body = s.dropFirst()
        guard body.count == 6 || body.count == 8 else { return false }
        return body.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
