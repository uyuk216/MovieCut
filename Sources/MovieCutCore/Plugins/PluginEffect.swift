import Foundation
import CoreGraphics
import CoreImage

/// プラグインが提供する映像エフェクト 1 種の記述子。
///
/// 内蔵エフェクトの `EffectKind` + `params` に相当するものを、プラグイン側が宣言する形。
/// 識別子 `id` は `Effect.kind`(文字列)そのもので、プロジェクトファイルにはこの文字列で保存される。
/// 内蔵の `EffectKind.rawValue` と衝突しないよう、接頭辞付き(例: "plugin.invert")にするのが約束。
/// 引数の仕様は内蔵と同じ `EffectParamSpec` を使うので、範囲クランプ・既定値・キーフレームの流儀が揃う。
public struct PluginEffectDescriptor: Equatable, Sendable {
    /// エフェクト識別子(`Effect.kind` に書かれる文字列)。
    public var id: String
    /// 表示名(インスペクタ・メニュー用)。
    public var label: String
    /// 引数の仕様(並ぶ順)。
    public var params: [EffectParamSpec]
    /// 色を持つエフェクトの既定の色("#rrggbb")。無ければ nil。
    public var defaultColor: String?

    public init(id: String, label: String, params: [EffectParamSpec], defaultColor: String? = nil) {
        self.id = id
        self.label = label
        self.params = params
        self.defaultColor = defaultColor
    }

    public func spec(_ key: String) -> EffectParamSpec? { params.first { $0.key == key } }
}

/// 映像エフェクトプラグインの接続点。`EffectPipeline` が内蔵エフェクトと同じ経路で呼ぶ。
///
/// - 同期・画素単位の純粋処理とする(プレビューと書き出しの両方から、描画の最中に呼ばれるため)。
///   重い初期化はプロバイダ生成時に済ませ、ここでは `CIImage` → `CIImage` の変換だけを行う。
/// - 引数の値は、記述子の仕様でクランプ済みのものが渡る(キーフレーム補間も済んでいる)。
/// - 担当外の `effectID` では nil を返す(呼び出し側は「何もしない」として扱う)。
public protocol VideoEffectProviding {
    /// 提供するエフェクトの記述子の一覧。
    var effectDescriptors: [PluginEffectDescriptor] { get }
    /// 引数が「何もしない」値のとき true(速い道に戻す判定。内蔵の `EffectPipeline.isIdentity` に相当)。
    func isIdentity(effectID: String, values: [String: Double]) -> Bool
    /// 画像へエフェクトをかける。`bounds` はクリップの枠、`scale` は px 引数の解像度拡縮(内蔵と同じ意味)。
    func apply(effectID: String, image: CIImage, values: [String: Double], color: String, bounds: CGRect, scale: Double) -> CIImage?
}

public extension VideoEffectProviding {
    /// 既定では「何もしない」判定をしない(常に適用する)。
    func isIdentity(effectID: String, values: [String: Double]) -> Bool { false }

    /// 記述子を識別子で引く。
    func descriptor(forEffectID effectID: String) -> PluginEffectDescriptor? {
        effectDescriptors.first { $0.id.lowercased() == effectID.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}

/// 時刻を決めて引数を確定させたプラグインエフェクト(内蔵の `ResolvedEffect` に相当)。
public struct ResolvedPluginEffect: Equatable, Sendable {
    public var descriptor: PluginEffectDescriptor
    public var values: [String: Double]
    public var color: String

    public init(descriptor: PluginEffectDescriptor, values: [String: Double], color: String) {
        self.descriptor = descriptor
        self.values = values
        self.color = color
    }

    /// エフェクト識別子(`Effect.kind`)。
    public var effectID: String { descriptor.id }

    public func v(_ key: String) -> Double { values[key] ?? descriptor.spec(key)?.defaultValue ?? 0 }
}

extension Clip {
    /// プラグイン担当の有効なエフェクトが 1 つでもあるか(描画の速い道の判定用)。
    /// 内蔵の種類(`EffectKind` にあるもの)は数えない。識別子の照合は大文字小文字を区別しない。
    public func hasActivePluginEffect(effectIDs: Set<String>) -> Bool {
        let ids = Set(effectIDs.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        guard !ids.isEmpty else { return false }
        return effects.contains { $0.enabled && $0.known == nil && ids.contains($0.kind.trimmingCharacters(in: .whitespaces).lowercased()) }
    }
}
