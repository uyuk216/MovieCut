import Foundation
import ImageIO

// AI 画像生成フック。ユーザーが指定したローカルのコマンドが、プロンプトから画像ファイルを書く。
// - プロンプトは標準入力と環境変数 `MOVIECUT_PROMPT` で渡す(シェルは通さない)。
// - 出力先のパスは、コマンドの指定の後ろに最後の引数として付く。
// - クラウドは呼ばない(コマンドが何をするかはユーザーの責任。送る前に内容を確認する)。

/// 設定(UserDefaults)。AI の文章用の設定とは別。既定は空(未設定)。
public enum AIImageSettings {
    public static let key = "aiImage.command"
    public static let maxPromptLength = 2000

    public static func command(_ d: UserDefaults = DataLocations.current.defaults) -> String { d.string(forKey: key) ?? "" }

    public static func setCommand(_ c: String, _ d: UserDefaults = DataLocations.current.defaults) {
        d.set(c.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }
}

public enum AIImageError: Error, LocalizedError, Equatable {
    case emptyPrompt
    case promptTooLong(Int)
    case noOutput
    case notAnImage

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "プロンプトが空です。"
        case .promptTooLong(let n): return "プロンプトが長すぎます(\(AIImageSettings.maxPromptLength) 文字まで。今は \(n) 文字)。"
        case .noOutput: return "コマンドが画像ファイルを書きませんでした。最後の引数の場所に、PNG などを書くコマンドにしてください。"
        case .notAnImage: return "コマンドが書いたファイルは、画像として読めませんでした。"
        }
    }
}

/// 画像の置き場所(Application Support/MovieCut/AIImages/<UUID>.png)。
public enum AIImageStore {
    public static func directory() -> URL {
        DataLocations.current.aiImages
    }

    public static func newOutputURL(in dir: URL = directory()) -> URL {
        dir.appendingPathComponent(UUID().uuidString + ".png")
    }

    /// ImageIO で 1 コマ以上読めるか。
    public static func isReadableImage(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }
}

/// 指定のコマンドで画像を作る。時間切れ・キャンセル・出力サイズの上限つき(`ProcessRun` と同じ)。
public struct CommandImageProvider {
    public static let envPromptKey = "MOVIECUT_PROMPT"
    public static let defaultTimeout: TimeInterval = 300
    public let executable: String
    public let arguments: [String]
    public let timeout: TimeInterval

    public init(commandLine: String, timeout: TimeInterval = CommandImageProvider.defaultTimeout) throws {
        let parts = AICommandLine.split(commandLine)
        guard let first = parts.first else { throw AIError.emptyCommand }
        guard let path = AICommandLine.resolve(first) else { throw AIError.commandNotFound(first) }
        self.executable = path
        self.arguments = Array(parts.dropFirst())
        self.timeout = timeout
    }

    /// プロンプトから画像を作り、`outputURL` に書かせる。書かれたファイルが画像として読めなければ失敗。
    public func generate(prompt: String, outputURL: URL) async throws {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { throw AIImageError.emptyPrompt }
        guard p.count <= AIImageSettings.maxPromptLength else { throw AIImageError.promptTooLong(p.count) }
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        let run = ProcessRun(executable: executable, arguments: arguments + [outputURL.path], input: Data(p.utf8),
                             timeout: timeout, maxOutputBytes: CommandAIProvider.defaultMaxOutputBytes,
                             environment: [Self.envPromptKey: p])
        try await withTaskCancellationHandler {
            do { _ = try await run.start() } catch AIError.emptyResponse {
                // 画像だけを書くコマンドは標準出力が空でよい
            }
        } onCancel: {
            run.cancel()
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else { throw AIImageError.noOutput }
        guard AIImageStore.isReadableImage(outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AIImageError.notAnImage
        }
    }
}
