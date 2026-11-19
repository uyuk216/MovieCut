import Foundation

// MARK: - 生成メディア共通連携口(生成 AI 系の土台)
//
// Premiere の「生成メディア」群(画像生成・動画生成・効果音生成・音楽生成・
// サウンドスケープ生成・生成延長)に共通する流れを、1 つの連携口にまとめた土台。
//
//   対象範囲/プロンプト指定 → 送信前確認(送信内容・送信先・想定費用)
//   → 生成(ユーザーの API キー/アカウントで実行) → 結果をクリップとして配置
//
// 設計方針(ユーザー決定 2026-11-19。棚卸し表の D グループ共通前提):
// - MovieCut 本体は連携口(プロバイダ境界と UI)だけを用意し、生成そのものは
//   ユーザー自身の API キー/アカウントで実行され、費用もユーザーのものになる。
// - キーはユーザーのマシン内にのみ保存し、開発側サーバには一切置かない・
//   経由させない(既存の AI テキスト生成 `TextGenerationSettings` と同じ作法。
//   保存先はこの Mac のアプリ設定(UserDefaults)だけで、プロジェクトには書かない)。
// - 生成前に、送信内容・送信先・想定費用をユーザーが確認する流れを必須とする
//   (既存 `AIProvider` の送信前確認 `GenerativeMediaConfirmation` がその表現)。
// - 未設定のときは機能を無効表示にする(各設定の `isConfigured` /
//   `makeProvider()` が `GenerativeMediaError.notConfigured` を投げる)。
//
// この土台の上に、最初の実装として画像生成の API 直接連携
// (`ImageGeneration.swift` の `OpenAICompatibleImageProvider`)が乗る。
// 将来の動画/音声生成も、`GenerativeMediaProvider` を実装して同じ確認・
// 配置(`GenerativeMediaPlacement`)の流れに乗せる。
// 既存の AI 画像生成フック(ローカルコマンド方式 `AIImage.swift`)とは独立した
// 追加で、その挙動は変えない。

/// 生成メディアの種類。将来の種類はここへ足す(配置先のクリップ種別は `clipType`)。
public enum GenerativeMediaKind: String, CaseIterable, Sendable {
    case image
    case video
    case audio
    case music
    case soundscape

    public var title: String {
        switch self {
        case .image: return "画像"
        case .video: return "動画"
        case .audio: return "効果音"
        case .music: return "音楽"
        case .soundscape: return "サウンドスケープ"
        }
    }

    /// 生成結果を置くときのクリップ種別。
    public var clipType: ClipType {
        switch self {
        case .image: return .image
        case .video: return .video
        case .audio, .music, .soundscape: return .audio
        }
    }

    /// 配置するときの既定の長さ(秒)。画像は既存の AI 画像フックと同じ 5 秒。
    public var defaultDuration: Double {
        switch self {
        case .image: return 5
        case .video, .audio, .music, .soundscape: return 5
        }
    }
}

/// 生成の依頼(共通)。プロンプト必須。`targetStart` は配置先の時刻(秒、
/// nil = 呼び出し側が再生ヘッド等で決める)。`size` は種類ごとの大きさ指定
/// (画像なら "1024x1024" のような文字列。解釈はプロバイダ側)。
public struct GenerativeMediaRequest: Equatable, Sendable {
    public var kind: GenerativeMediaKind
    public var prompt: String
    public var targetStart: Double?
    public var targetDuration: Double?
    public var size: String?

    public init(kind: GenerativeMediaKind, prompt: String, targetStart: Double? = nil,
                targetDuration: Double? = nil, size: String? = nil) {
        self.kind = kind
        self.prompt = prompt
        self.targetStart = targetStart
        self.targetDuration = targetDuration
        self.size = size
    }

    public var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 実行前に確かめる(空・長すぎるプロンプトは、通信の前に止める)。
    public func validate() throws {
        let p = trimmedPrompt
        guard !p.isEmpty else { throw GenerativeMediaError.emptyPrompt }
        guard p.count <= AIImageSettings.maxPromptLength else {
            throw GenerativeMediaError.promptTooLong(p.count)
        }
    }
}

/// 生成の結果。ファイルとしてマシン内にあり、クリップとして配置できる。
public struct GenerativeMediaResult: Equatable, Sendable {
    public var kind: GenerativeMediaKind
    public var fileURL: URL
    /// 配置するときの長さ(秒)。0 以下なら種類の既定を使う。
    public var duration: Double

    public init(kind: GenerativeMediaKind, fileURL: URL, duration: Double = 0) {
        self.kind = kind
        self.fileURL = fileURL
        self.duration = duration
    }

    public var clipType: ClipType { kind.clipType }
    public var placementDuration: Double { duration > 0 ? duration : kind.defaultDuration }
}

/// 生成メディア共通の失敗。`errorDescription` は画面に出す日本語。
/// API キーの値は、どの文にも含めない。
public enum GenerativeMediaError: Error, LocalizedError, Equatable {
    /// エンドポイント等が未設定(機能は無効)。
    case notConfigured
    case emptyPrompt
    case promptTooLong(Int)
    /// そのプロバイダが扱えない種類。
    case unsupportedKind(GenerativeMediaKind)
    /// エンドポイントの URL が不正、または安全でない(http の非ローカル宛先など)。
    case invalidEndpoint(String)
    /// HTTP のエラー応答(状態コードと本文の冒頭)。
    case http(Int, String)
    case emptyResponse
    case unparsable(String)
    case transport(String)
    case cancelled
    /// 返ってきたファイルが画像として読めなかった(画像生成用)。
    case notAnImage

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "生成メディア(API)が設定されていません。ファイル ▸ 生成メディア(API)の設定… で、接続先のエンドポイントとモデルを指定してください(未設定のあいだは、この機能は使えません)。"
        case .emptyPrompt:
            return "プロンプトが空です。"
        case .promptTooLong(let n):
            return "プロンプトが長すぎます(\(AIImageSettings.maxPromptLength) 文字まで。今は \(n) 文字)。"
        case .unsupportedKind(let kind):
            return "この生成サービスは\(kind.title)の生成に対応していません。"
        case .invalidEndpoint(let why):
            return "エンドポイントが正しくありません: \(why)"
        case .http(let code, let body):
            let tail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "生成サービスがエラーを返しました(HTTP \(code))。" + (tail.isEmpty ? "" : "\n" + String(tail.prefix(300)))
        case .emptyResponse:
            return "生成サービスの返事が空でした。"
        case .unparsable(let what):
            return "生成サービスの返事から\(what)を読み取れませんでした。モデルやエンドポイントを見直してください。"
        case .transport(let detail):
            return "生成サービスへつながりませんでした: \(detail)"
        case .cancelled:
            return "キャンセルしました。"
        case .notAnImage:
            return "生成サービスが返したファイルは、画像として読めませんでした。"
        }
    }
}

// MARK: - プロバイダ境界(差し替え可能)

/// 生成メディアの差し替え口。種類ごとに実装し、共通の確認・配置の流れに乗る。
/// 実装はユーザーのアカウントで生成し、結果ファイルをマシン内に返す。
public protocol GenerativeMediaProvider: Sendable {
    /// このプロバイダが生成できる種類。
    var supportedKinds: [GenerativeMediaKind] { get }
    /// 送信先の説明(画面に出す。キーは含めない)。
    var destinationDescription: String { get }
    func generate(_ request: GenerativeMediaRequest) async throws -> GenerativeMediaResult
}

public extension GenerativeMediaProvider {
    func supports(_ kind: GenerativeMediaKind) -> Bool { supportedKinds.contains(kind) }
}

// MARK: - 送信前確認(必須の流れの表現)

/// 生成前にユーザーが確認する内容。送信先・プロンプト・大きさ・想定費用の
/// 注意を含む。API キーは絶対に含めない(テストでも担保する)。
public struct GenerativeMediaConfirmation: Equatable, Sendable {
    public var kind: GenerativeMediaKind
    public var destination: String
    public var prompt: String
    public var model: String
    public var sizeDescription: String?

    /// 費用についての固定の注意文。実際の単価はサービスごとに違うため、
    /// 金額そのものではなく「誰に課金されるか」を明示する。
    public static let costNote = "生成の費用は、あなたが設定した API アカウントに課金されます。MovieCut のサーバは経由しません。単価は利用するサービスの設定をご確認ください。"

    public init(kind: GenerativeMediaKind, destination: String, prompt: String,
                model: String, sizeDescription: String? = nil) {
        self.kind = kind
        self.destination = destination
        self.prompt = prompt
        self.model = model
        self.sizeDescription = sizeDescription
    }

    /// 確認画面の本文(送信先は確認画面側が別に添えるため、ここには含めない)。
    public var summaryText: String {
        var lines = ["\(kind.title)を生成します。", "プロンプト: \(prompt)"]
        if !model.isEmpty { lines.append("モデル: \(model)") }
        if let s = sizeDescription, !s.isEmpty { lines.append("大きさ: \(s)") }
        lines.append(Self.costNote)
        return lines.joined(separator: "\n")
    }
}

// MARK: - 結果の配置(共通)

/// 生成結果をクリップとしてプロジェクトへ置く(純粋関数)。
/// 置き方は既存の素材配置 `ClipEditing.place` と同じ(空いているレイヤーへ、
/// 無ければ新しいレイヤー)。Undo の登録は呼び出し側(画面側)の責務。
public enum GenerativeMediaPlacement {
    @discardableResult
    public static func place(_ result: GenerativeMediaResult, at time: Double, in project: inout Project) -> [String] {
        ClipEditing.place(media: [(result.fileURL.path, result.clipType, result.placementDuration)],
                          at: max(0, time), in: &project)
    }
}

// MARK: - テスト用モック

/// 決まった結果を返す(または失敗させる)偽のプロバイダ。実サービスとの
/// 疎通なしに、確認 → 生成 → 配置の流れを通しで確認するために使う。
public final class FakeGenerativeMediaProvider: GenerativeMediaProvider, @unchecked Sendable {
    public enum Behavior: Sendable {
        case succeed(URL, duration: Double)
        case fail(GenerativeMediaError)
        case delay(seconds: Double, URL, duration: Double)
    }
    private let lock = NSLock()
    private var _requests: [GenerativeMediaRequest] = []
    public let behavior: Behavior
    public let supportedKinds: [GenerativeMediaKind]
    public let destinationDescription: String

    public init(_ behavior: Behavior, supportedKinds: [GenerativeMediaKind] = GenerativeMediaKind.allCases,
                destinationDescription: String = "モックの生成サービス") {
        self.behavior = behavior
        self.supportedKinds = supportedKinds
        self.destinationDescription = destinationDescription
    }

    public var requests: [GenerativeMediaRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    public func generate(_ request: GenerativeMediaRequest) async throws -> GenerativeMediaResult {
        lock.withLock { _requests.append(request) }
        try request.validate()
        guard supportedKinds.contains(request.kind) else { throw GenerativeMediaError.unsupportedKind(request.kind) }
        switch behavior {
        case .succeed(let url, let duration):
            return GenerativeMediaResult(kind: request.kind, fileURL: url, duration: duration)
        case .fail(let e):
            throw e
        case .delay(let sec, let url, let duration):
            do { try await Task.sleep(nanoseconds: UInt64(sec * 1_000_000_000)) } catch { throw GenerativeMediaError.cancelled }
            return GenerativeMediaResult(kind: request.kind, fileURL: url, duration: duration)
        }
    }
}
