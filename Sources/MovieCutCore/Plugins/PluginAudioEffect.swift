import Foundation

// MARK: - プラグイン音声エフェクトの境界(W2-13 プラグイン機構の音声版)
//
// 映像エフェクト(`VideoEffectProviding`)と対になる、音声エフェクト用の接続点。
// MovieCut の音声は「48 kHz ステレオ Float32 をオフラインで混ぜる」方式(`AudioMixer` →
// `AudioFxChain`)なので、境界もリアルタイム再生ではなく **ブロック単位のオフライン処理**
// として切る。将来 VST3 ホストが入るときは、このプロトコルの裏側に置く(呼び出し側は変えない)。
//
// 未ロード/未対応のときの扱い(この境界の約束):
// - プロバイダが無い・プラグインが見つからないときは、解決は nil / 専用エラーで返し、
//   呼び出し側は「音を変えない(バイパス)」に落とす。黙って別の音に化けることはしない。
// - 処理器が作れない/ホストが未実装のときは `BypassAudioEffectProcessor` が使われ、
//   バッファには一切触らない(入力とバイト単位で同じ音になる)。バイパスした量は数えて残す。

/// プラグインが提供する音声エフェクト 1 種の記述子(映像版 `PluginEffectDescriptor` の音声版)。
/// 識別子 `id` はプロジェクトに残す文字列そのもの。内蔵と衝突しないよう接頭辞付きにする
/// (VST3 は "vst3.<バンドルID>"、MovieCut プラグインは "plugin.<名前>")。
public struct PluginAudioEffectDescriptor: Equatable, Sendable {
    public var id: String
    public var label: String
    /// 引数の仕様(並ぶ順)。映像エフェクトと同じ `EffectParamSpec` を使う。
    public var params: [EffectParamSpec]

    public init(id: String, label: String, params: [EffectParamSpec] = []) {
        self.id = id; self.label = label; self.params = params
    }

    public func spec(_ key: String) -> EffectParamSpec? { params.first { $0.key == key } }
}

/// 1 クリップ分の処理を担う処理器。ブロックごとに `process` が呼ばれ、状態はブロックをまたいで続く
/// (`AudioFxChain` の各プロセッサと同じ流儀)。スレッドはミックス側の 1 本だけを想定する。
public protocol AudioEffectProcessing: AnyObject {
    /// 担当するエフェクト識別子。
    var effectID: String { get }
    /// 左右別のバッファをその場で書き換える。`frames` フレームぶんだけ触る。
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int)
    /// 状態を初期化する(クリップの頭から掛け直すときに使う)。
    func reset()
}

/// 音声エフェクトプラグインの接続点。記述子の宣言と、処理器の生成だけを担う。
public protocol AudioEffectProviding {
    /// 提供する音声エフェクトの記述子の一覧。
    var audioEffectDescriptors: [PluginAudioEffectDescriptor] { get }
    /// 処理器を作る。担当外・作れないときは nil(呼び出し側はバイパスに落とす)。
    func makeProcessor(effectID: String, sampleRate: Double, values: [String: Double]) -> (any AudioEffectProcessing)?
}

public extension AudioEffectProviding {
    func descriptor(forAudioEffectID effectID: String) -> PluginAudioEffectDescriptor? {
        audioEffectDescriptors.first { $0.id.lowercased() == effectID.trimmingCharacters(in: .whitespaces).lowercased() }
    }
    func handlesAudioEffect(_ effectID: String) -> Bool { descriptor(forAudioEffectID: effectID) != nil }
}

/// 何もしない処理器(バイパス)。未ロード・未対応のときの正式な受け皿で、
/// バッファには一切触らない = 入力とバイト単位で同じ音になる。バイパスした量は検証用に数える。
public final class BypassAudioEffectProcessor: AudioEffectProcessing {
    public let effectID: String
    /// バイパスを表す理由(例: "VST3 ホスト未実装")。表示と記録に使う。
    public let reason: String
    public private(set) var processedFrames: Int = 0
    public private(set) var processCalls: Int = 0

    public init(effectID: String, reason: String) {
        self.effectID = effectID; self.reason = reason
    }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        // 意図的に何もしない(バイパス)。引数は数えるためだけに受ける。
        _ = left; _ = right
        processedFrames += max(0, frames)
        processCalls += 1
    }

    public func reset() {
        processedFrames = 0
        processCalls = 0
    }
}

// MARK: - VST3 ホストの到達状態

/// VST3 の音声処理ホストが今どこまで到達しているか。UI とテストが同じ事実を参照するための単一の置き場。
public enum VST3HostAvailability: Equatable, Sendable {
    /// スキャン(検出・メタ情報)はできるが、音声処理ホストは未実装。処理は常にバイパス。
    case processingNotImplemented
    /// C++ ブリッジ(`VST3BridgeRuntime`)が見つかりハンドシェイクも通った。
    /// この環境では実処理の経路が有効(読み込めないプラグインは個別にバイパス)。
    /// Mac 実機でのフィクスチャ検証が済むまでは「検証待ち」であることを docs に明記する。
    case bridgeAvailable

    /// この環境の到達状態。ブリッジライブラリが無い環境では従来どおり検出のみ。
    public static var current: VST3HostAvailability {
        VST3BridgeRuntime.isAvailable ? .bridgeAvailable : .processingNotImplemented
    }

    /// 音声を実際に処理できるか。
    public var canProcessAudio: Bool {
        switch self { case .processingNotImplemented: return false; case .bridgeAvailable: return true }
    }

    /// ユーザー向けの正直な説明(誤解させない文言をここに固定する)。
    public var userFacingNote: String {
        switch self {
        case .processingNotImplemented:
            return "VST3 プラグインは「検出のみ」対応です。音声処理は未対応のため、指定しても音はそのまま(バイパス)になります。"
        case .bridgeAvailable:
            return "VST3 プラグインの音声処理ブリッジが見つかりました。読み込めないプラグインは音がそのまま(バイパス)になります。"
        }
    }

    /// バイパス処理器に付ける理由。
    public var bypassReason: String {
        switch self {
        case .processingNotImplemented: return "VST3 ホスト未実装(検出のみ対応)"
        case .bridgeAvailable: return "VST3 プラグインを読み込めなかったためバイパス"
        }
    }
}

/// 検出した VST3 バンドルを音声エフェクトとして並べるプロバイダ。
///
/// 記述子はスキャン結果から作る(バイナリは読まない)。処理器は、ホストが未実装の間は
/// 常にバイパス処理器を返す — つまり「一覧に出る・プロジェクトに指定を残せる・音は変わらない」
/// がこの到達範囲の仕様。ホスト実装時は `makeProcessor` の中身だけを差し替える。
public struct VST3EffectProvider: AudioEffectProviding {
    public var plugins: [VST3BundleInfo]
    public var availability: VST3HostAvailability
    /// 音声エフェクト ID(小文字) -> パラメータ記述一覧(R5-1 で追加)。
    /// 実ホストがパラメータを取得できるようになるまでの間は空が普通で、その場合は
    /// 従来どおり記述子の  は空になる。スキャンだけではパラメータは分からない
    /// (moduleinfo.json には載らない)ため、ここは「取得できたときの置き場」。
    public var parameterDescriptorsByEffectID: [String: [VST3ParameterDescriptor]]
    /// テスト/組み込み用のバックエンド差し替え口。nil なら、ブリッジが使える環境で
    /// `VST3NativeBridgeBackend` を使う。差し替えた場合は availability よりこちらを優先する。
    public var backendFactory: ((VST3BundleInfo) -> (any VST3BridgeBackend)?)?

    public init(plugins: [VST3BundleInfo], availability: VST3HostAvailability = .current,
                parameterDescriptorsByEffectID: [String: [VST3ParameterDescriptor]] = [:],
                backendFactory: ((VST3BundleInfo) -> (any VST3BridgeBackend)?)? = nil) {
        self.plugins = plugins
        self.availability = availability
        self.parameterDescriptorsByEffectID = parameterDescriptorsByEffectID
        self.backendFactory = backendFactory
    }

    /// そのプラグインのパラメータ記述(無ければ空)。
    public func parameterDescriptors(for info: VST3BundleInfo) -> [VST3ParameterDescriptor] {
        parameterDescriptorsByEffectID[info.audioEffectID.lowercased()] ?? []
    }

    /// スキャン結果から作る(構造が揃ったものだけを並べる)。
    public init(scanResult: VST3ScanResult, availability: VST3HostAvailability = .current) {
        self.init(plugins: scanResult.usablePlugins, availability: availability)
    }

    /// 標準の置き場をスキャンして作る、アプリ全体で共有する生成経路。
    /// `VST3Panel` のスキャン(`VST3Scanner.scanStandard()`)と同じ入口で、再生・書き出し・
    /// 測定・試聴へ渡すプロバイダはすべてここから作る(二重実装しない)。
    /// 置き場にプラグインが無ければ空のプロバイダになり、ミックスは従来と一致する。
    public static func standard() -> VST3EffectProvider {
        VST3EffectProvider(scanResult: VST3Scanner.scanStandard())
    }

    public var audioEffectDescriptors: [PluginAudioEffectDescriptor] {
        plugins.map { info in
            PluginAudioEffectDescriptor(id: info.audioEffectID, label: info.name + "(VST3)",
                                        params: parameterDescriptors(for: info).compactMap { $0.effectParamSpec() })
        }
    }

    public func makeProcessor(effectID: String, sampleRate: Double, values: [String: Double]) -> (any AudioEffectProcessing)? {
        makeProcessor(effectID: effectID, sampleRate: sampleRate, values: values, stateData: nil)
    }

    /// 状態チャンク付きで処理器を作る(W6-1)。実処理が成立しなければ必ずバイパスを返す
    /// (nil は「担当外」のときだけ。音声経路が止まることはない)。
    public func makeProcessor(effectID: String, sampleRate: Double, values: [String: Double], stateData: Data?) -> (any AudioEffectProcessing)? {
        guard descriptor(forAudioEffectID: effectID) != nil,
              let info = plugins.first(where: { $0.audioEffectID.lowercased() == effectID.lowercased() }) else { return nil }
        let backend: (any VST3BridgeBackend)?
        if let backendFactory {
            backend = backendFactory(info)
        } else if availability.canProcessAudio {
            backend = VST3NativeBridgeBackend()
        } else {
            backend = nil
        }
        guard let backend else {
            return BypassAudioEffectProcessor(effectID: effectID, reason: availability.bypassReason)
        }
        let cid = info.moduleClasses.first { $0.isAudioModule }?.cid
        let host = VST3HostProcessor(effectID: effectID, backend: backend, bundlePath: info.bundleURL.path,
                                     cid: cid, sampleRate: sampleRate, values: values, stateData: stateData)
        guard host.isReady else {
            return BypassAudioEffectProcessor(effectID: effectID, reason: availability.bypassReason)
        }
        return host
    }
}
