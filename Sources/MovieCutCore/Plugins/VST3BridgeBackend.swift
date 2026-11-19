import Foundation

// MARK: - VST3 ブリッジの Swift 側バックエンド境界(W6-1)
//
// C++ ブリッジ(ABI の正は `docs/vst3-bridge/MovieCutVST3Bridge.h`)を Swift から
// 使うための内部境界。実装は 2 つ:
// - `VST3NativeBridgeBackend`: 共有ライブラリを dlopen して C ABI を直接呼ぶ
//   (`VST3NativeBridge.swift`)。ライブラリが無い環境では生成自体が nil になる。
// - `UnavailableVST3BridgeBackend`: 全操作が `.notImplemented` を返す受け皿。
//   テストや、ブリッジが無いビルドでの明示的な表現に使う。
//
// この境界を越えて例外や生ポインタの所有権は出さない。失敗はすべて
// `VST3BridgeStatus` で返り、呼び出し側(`VST3HostProcessor`)は
// 「失敗 = そのプラグインはバイパス、音声経路は止めない」に落とす。

/// ブリッジから見たクラス情報 1 件(C ABI の `MCVST3ClassInfo` の Swift 版)。
public struct VST3BridgeClassInfo: Equatable, Sendable {
    public var category: String
    public var name: String
    public var vendor: String?
    public var version: String?
    /// クラス ID(CID)の 32 桁 16 進表記(moduleinfo.json と同じ狙いの表記)。
    public var cidHex: String
    public init(category: String, name: String, vendor: String? = nil, version: String? = nil, cidHex: String) {
        self.category = category; self.name = name; self.vendor = vendor; self.version = version; self.cidHex = cidHex
    }
    /// 音声モジュール本体のクラスか。
    public var isAudioModule: Bool { category.contains("Audio Module Class") }
}

/// VST3 ブリッジのバックエンド。呼び出し順序の契約は `VST3BridgeSession` が正で、
/// 順序の管理は呼び出し側(`VST3HostProcessor`)が担う。バックエンドは渡された
/// 操作をそのままブリッジへ渡すだけにする(順序違反の検出を二重化しないため)。
public protocol VST3BridgeBackend: AnyObject {
    /// 版数照合。成功時はプロトコル版数を返す。
    func handshake() -> (status: VST3BridgeStatus, version: Int32?)
    /// バンドルを開く(クラス列挙まで)。
    func openBundle(path: String) -> VST3BridgeStatus
    /// 開いたバンドルのクラス一覧。
    func classInfos() -> (status: VST3BridgeStatus, infos: [VST3BridgeClassInfo])
    /// 音声プロセッサを生成・初期化する(cid が nil なら最初の音声モジュールクラス)。
    func createProcessor(cid: String?) -> VST3BridgeStatus
    /// バス構成と setup を確定する(交渉結果は呼び出し側の契約ロジックが決めたもの)。
    func setupProcessing(_ setup: VST3ProcessSetup, layout: VST3BusLayout) -> VST3BridgeStatus
    /// 有効化/無効化。
    func setActive(_ active: Bool) -> VST3BridgeStatus
    /// 1 ブロック処理する(ステレオ分離バッファ。入力と出力は別バッファで渡すこと)。
    func processBlock(inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>,
                      outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>,
                      frames: Int, changes: [VST3ParameterChangePoint]) -> (status: VST3BridgeStatus, latency: Int?)
    /// パラメータ記述一覧を取得する。
    func parameterInfos() -> (status: VST3BridgeStatus, infos: [VST3ParameterDescriptor])
    /// パラメータの現在値(正規化値)。
    func getParameterNormalized(id: UInt32) -> (status: VST3BridgeStatus, value: Double?)
    /// パラメータへ現在値を設定する(正規化値)。
    func setParameterNormalized(id: UInt32, value: Double) -> VST3BridgeStatus
    /// プラグイン申告のレイテンシ/テール(フレーム)。取得できなければ nil。
    func latencyAndTail() -> (latency: Int, tail: Int)?
    /// 状態チャンクの取得(プロジェクト保存用)。
    func getState() -> (status: VST3BridgeStatus, data: Data?)
    /// 状態チャンクの復元(有効化前にだけ呼ぶ)。
    func setState(_ data: Data) -> VST3BridgeStatus
    /// 後片付け(冪等。複数回呼んでもよい)。
    func dispose()
}

/// ブリッジが無いときのバックエンド。全操作が `.notImplemented`。
/// これを使う限り音は一切変わらない(生成側がバイパスへ落とす)。
public final class UnavailableVST3BridgeBackend: VST3BridgeBackend {
    public init() {}
    public func handshake() -> (status: VST3BridgeStatus, version: Int32?) { (.notImplemented, nil) }
    public func openBundle(path: String) -> VST3BridgeStatus { .notImplemented }
    public func classInfos() -> (status: VST3BridgeStatus, infos: [VST3BridgeClassInfo]) { (.notImplemented, []) }
    public func createProcessor(cid: String?) -> VST3BridgeStatus { .notImplemented }
    public func setupProcessing(_ setup: VST3ProcessSetup, layout: VST3BusLayout) -> VST3BridgeStatus { .notImplemented }
    public func setActive(_ active: Bool) -> VST3BridgeStatus { .notImplemented }
    public func processBlock(inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>,
                             outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>,
                             frames: Int, changes: [VST3ParameterChangePoint]) -> (status: VST3BridgeStatus, latency: Int?) {
        (.notImplemented, nil)
    }
    public func parameterInfos() -> (status: VST3BridgeStatus, infos: [VST3ParameterDescriptor]) { (.notImplemented, []) }
    public func getParameterNormalized(id: UInt32) -> (status: VST3BridgeStatus, value: Double?) { (.notImplemented, nil) }
    public func setParameterNormalized(id: UInt32, value: Double) -> VST3BridgeStatus { .notImplemented }
    public func latencyAndTail() -> (latency: Int, tail: Int)? { nil }
    public func getState() -> (status: VST3BridgeStatus, data: Data?) { (.notImplemented, nil) }
    public func setState(_ data: Data) -> VST3BridgeStatus { .notImplemented }
    public func dispose() {}
}
