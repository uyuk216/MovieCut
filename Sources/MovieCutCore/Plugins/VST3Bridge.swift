import Foundation

// MARK: - C++ ブリッジのプロトコル定義(R5-1: インターフェース定義まで。実ロードはしない)
//
// 将来の C++ ブリッジモジュール(`MovieCutVST3Host`)と Swift 側の間で使う
// プロトコルを、定数と型として先に固定する。C 側の宣言は
// `docs/vst3-bridge/MovieCutVST3Bridge.h` に置き、この Swift 定義と 1 対 1 で対応させる
// (番号・並びを変えるときは両方を同時に変えること。テストが対応を固定する)。
//
// このファイルに実装は無い: 関数ポインタの解決・dlopen・実プラグインの生成は
// すべて実ホスト工程の仕事で、ここは「契約の置き場」に徹する。
// 外部プロセス分離(案 B)にする場合も、この opcode / status の組をそのまま IPC に載せられる。

/// ブリッジプロトコルの版数。互換の無い変更で +1 する。
public enum VST3Bridge {
    public static let protocolVersion: Int32 = 1
    /// C ヘッダ側のファイル名(対応の目印。読みには行かない)。
    public static let headerRelativePath = "docs/vst3-bridge/MovieCutVST3Bridge.h"
}

/// ブリッジへ依頼する操作(C ヘッダの `MCVST3Opcode` と同順・同値)。
public enum VST3BridgeOpcode: Int32, Equatable, Sendable, CaseIterable {
    /// 契約の版数照合だけを行う(プラグインには触らない)。
    case handshake = 0
    /// バンドルを開いてクラス一覧を返す(音声処理はまだしない)。
    case openBundle = 1
    /// 音声プロセッサを生成する。
    case createProcessor = 2
    /// バス構成と setup を確定する(`VST3BusLayout` / `VST3ProcessSetup` の交渉結果を渡す)。
    case setupProcessing = 3
    /// 有効化/無効化。
    case setActive = 4
    /// 1 ブロック処理する(`VST3ProcessBlockRequest` で検証済みの形状だけを渡す)。
    case processBlock = 5
    /// パラメータ記述一覧を取得する(`VST3ParameterDescriptor` の列になる)。
    case getParameterInfos = 6
    /// 状態チャンクの取得/復元(プロジェクト保存用)。
    case getState = 7
    case setState = 8
    /// 後片付け(生成の逆順)。
    case dispose = 9
}

/// ブリッジの結果コード(C ヘッダの `MCVST3Status` と同順・同値。VST3 の tresult の考え方に寄せる)。
public enum VST3BridgeStatus: Int32, Equatable, Sendable, CaseIterable {
    case ok = 0
    /// 「できた/ある」ではない一般の不一致(例: 対応構成なし)。
    case resultFalse = 1
    case invalidArgument = 2
    case notImplemented = 3
    case internalError = 4
    /// バンドル/プラグインが見つからない。
    case notFound = 5
    /// 呼び出し順序が契約違反(setup 前の process 等)。
    case wrongState = 6

    /// 呼び出し側がバイパスに落とすべき失敗か(`ok` 以外はすべて落とす、が原則)。
    public var shouldBypass: Bool { self != .ok }
}

/// ブリッジ呼び出しの順序契約(状態機械)。実ホストが守るべき順序を純粋ロジックで固定し、
/// テストで検証できるようにする。順序違反は `.wrongState` で弾く想定。
public enum VST3BridgeSession {
    public enum State: String, Equatable, Sendable {
        case closed       // 何も開いていない
        case opened       // バンドルを開いた
        case created      // プロセッサ生成済み
        case configured   // バス/setup 確定済み
        case active       // 有効化済み(処理可能)
    }

    /// その状態でその操作が許されるか。
    public static func allows(_ opcode: VST3BridgeOpcode, in state: State) -> Bool {
        switch opcode {
        case .handshake: return true
        case .openBundle: return state == .closed
        case .createProcessor: return state == .opened
        case .setupProcessing: return state == .created || state == .configured
        case .setActive: return state == .configured || state == .active
        case .processBlock: return state == .active
        case .getParameterInfos: return state == .created || state == .configured || state == .active
        case .getState: return state == .created || state == .configured || state == .active
        case .setState: return state == .created || state == .configured
        case .dispose: return state != .closed
        }
    }

    /// 操作後の状態(状態が変わらない操作は今の状態を返す)。許されない操作は nil。
    public static func stateAfter(_ opcode: VST3BridgeOpcode, in state: State) -> State? {
        guard allows(opcode, in: state) else { return nil }
        switch opcode {
        case .openBundle: return .opened
        case .createProcessor: return .created
        case .setupProcessing: return .configured
        case .setActive: return state == .configured ? .active : .configured // 無効化で configured へ戻る想定も含め、遷移先は呼び出し側の引数次第のため代表値
        case .dispose: return .closed
        default: return state
        }
    }
}

// MARK: - 実ホスト到達までの前提チェック(正直さの固定)

/// docs の「次にやるなら」の前提を、コード側でも判定できる形にしたもの。
/// すべて揃うまでは `VST3HostAvailability` は未実装のまま、という関係をテストで固定する。
public struct VST3HostPrerequisites: Equatable, Sendable {
    /// VST3 SDK 3.8+ を取得し、ライセンス記録を済ませたか。
    public var sdkAcquired: Bool
    /// C++ ブリッジモジュールがビルドに組み込まれているか。
    public var bridgeIncluded: Bool
    /// 検証用フィクスチャプラグイン(SDK サンプル等)が用意できたか。
    public var fixturePluginAvailable: Bool
    /// 配布判断(library validation の要否)が済んだか。
    public var distributionDecisionMade: Bool

    public init(sdkAcquired: Bool = false, bridgeIncluded: Bool = false,
                fixturePluginAvailable: Bool = false, distributionDecisionMade: Bool = false) {
        self.sdkAcquired = sdkAcquired; self.bridgeIncluded = bridgeIncluded
        self.fixturePluginAvailable = fixturePluginAvailable; self.distributionDecisionMade = distributionDecisionMade
    }

    /// 現在のビルドの実態(すべて未達。進んだら実態に合わせて更新する)。
    public static let current = VST3HostPrerequisites()

    /// 音声処理へ進んでよい前提が揃ったか。
    public var allSatisfied: Bool {
        sdkAcquired && bridgeIncluded && fixturePluginAvailable && distributionDecisionMade
    }

    /// 未達の前提の一覧(表示・報告用)。
    public var missingDescriptions: [String] {
        var out: [String] = []
        if !sdkAcquired { out.append("VST3 SDK の取得とライセンス記録") }
        if !bridgeIncluded { out.append("C++ ブリッジモジュールの組み込み") }
        if !fixturePluginAvailable { out.append("検証用フィクスチャプラグインの用意") }
        if !distributionDecisionMade { out.append("配布判断(library validation の要否)") }
        return out
    }
}
