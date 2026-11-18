import Foundation
import CoreGraphics
import CoreImage

// MARK: - サンプル組み込みエフェクトプラグイン 1: 色反転

/// 色反転エフェクトを提供する組み込みプラグイン(サンプル)。
///
/// 内蔵エフェクトと同じ `EffectPipeline` の経路(解決 → 適用)で使えることを示すための最小実装。
/// 処理は色行列 1 枚で、アルファは変えない。強さ 0 で何もしない(恒等)。
public struct InvertEffectProvider: VideoEffectProviding {
    public init() {}

    public var effectDescriptors: [PluginEffectDescriptor] { [InvertEffectPlugin.descriptor] }

    public func isIdentity(effectID: String, values: [String: Double]) -> Bool {
        guard effectID == InvertEffectPlugin.effectID else { return false }
        return abs(values["amount"] ?? InvertEffectPlugin.descriptor.spec("amount")!.defaultValue) < 1e-6
    }

    public func apply(effectID: String, image: CIImage, values: [String: Double], color: String, bounds: CGRect, scale: Double) -> CIImage? {
        guard effectID == InvertEffectPlugin.effectID else { return nil }
        let spec = InvertEffectPlugin.descriptor.spec("amount")!
        let a = spec.clamp(values["amount"] ?? spec.defaultValue)
        // 反転と元の混ぜ合わせ: R' = (1-2a)·R + a(アルファはそのまま)。
        let f = 1 - 2 * a
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: a, y: a, z: a, w: 0),
        ])
    }
}

/// 色反転プラグインの名前空間(マニフェスト)。
public enum InvertEffectPlugin {
    public static let pluginID = "jp.local.moviecut.plugin.effect-invert"
    public static let effectID = "plugin.invert"

    public static var descriptor: PluginEffectDescriptor {
        PluginEffectDescriptor(
            id: effectID,
            label: "色反転(プラグイン)",
            params: [EffectParamSpec(key: "amount", label: "強さ", range: 0...1, defaultValue: 1, step: 0.01, unit: .percent)])
    }

    public static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: "色反転エフェクト",
                       version: "1.0.0",
                       hooks: [.effect],
                       entryPoint: "InvertEffectPlugin",
                       minimumAppVersion: nil,
                       effectIDs: [effectID],
                       requiresLicense: false,
                       description: "色を反転する映像エフェクト(組み込みサンプル)")
    }

    /// `manifest.json` の中身(PluginDiscovery で読める形)。
    public static func manifestJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }
}

// MARK: - サンプル組み込みエフェクトプラグイン 2: ポスタリゼーション

/// 階調を減らす(ポスタリゼーション)エフェクトを提供する組み込みプラグイン(サンプル)。
/// 階調数 32 でほぼ原画(恒等として扱う)、2 で最も強い。
public struct PosterizeEffectProvider: VideoEffectProviding {
    public init() {}

    public var effectDescriptors: [PluginEffectDescriptor] { [PosterizeEffectPlugin.descriptor] }

    public func isIdentity(effectID: String, values: [String: Double]) -> Bool {
        guard effectID == PosterizeEffectPlugin.effectID else { return false }
        let spec = PosterizeEffectPlugin.descriptor.spec("levels")!
        return spec.clamp(values["levels"] ?? spec.defaultValue) >= spec.range.upperBound
    }

    public func apply(effectID: String, image: CIImage, values: [String: Double], color: String, bounds: CGRect, scale: Double) -> CIImage? {
        guard effectID == PosterizeEffectPlugin.effectID else { return nil }
        let spec = PosterizeEffectPlugin.descriptor.spec("levels")!
        let levels = spec.clamp(values["levels"] ?? spec.defaultValue)
        return image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
    }
}

/// ポスタリゼーションプラグインの名前空間(マニフェスト)。
public enum PosterizeEffectPlugin {
    public static let pluginID = "jp.local.moviecut.plugin.effect-posterize"
    public static let effectID = "plugin.posterize"

    public static var descriptor: PluginEffectDescriptor {
        PluginEffectDescriptor(
            id: effectID,
            label: "ポスタリゼーション(プラグイン)",
            params: [EffectParamSpec(key: "levels", label: "階調数", range: 2...32, defaultValue: 6, step: 1, unit: .plain)])
    }

    public static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: "ポスタリゼーションエフェクト",
                       version: "1.0.0",
                       hooks: [.effect],
                       entryPoint: "PosterizeEffectPlugin",
                       minimumAppVersion: nil,
                       effectIDs: [effectID],
                       requiresLicense: false,
                       description: "階調を減らす映像エフェクト(組み込みサンプル)")
    }

    /// `manifest.json` の中身(PluginDiscovery で読める形)。
    public static func manifestJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }
}
