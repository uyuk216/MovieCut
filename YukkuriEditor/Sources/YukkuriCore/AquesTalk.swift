import Foundation

public enum AquesTalkPresets {
    /// 標準で入っているプリセット(実機で -P を試して確認したもの)。
    public static let all = ["れいむ", "まりさ", "中性", "機械", "ロボット"]
}

/// `say` での代用コマンド(renderer.js の KYOKO_COMMAND)。
public let kyokoFallbackCommand = "say -v Kyoko -o {out} --data-format=LEI16@24000 {text}"

/// シェルのシングルクォート(main.js shq)。
public func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// {text} {voice} {speed} {out} を置き換える。
public func applyCommandTemplate(_ template: String, text: String, voice: String?, speed: String, out: String) -> String {
    template
        .replacingOccurrences(of: "{text}", with: shellQuote(text))
        .replacingOccurrences(of: "{voice}", with: shellQuote(voice ?? ""))
        .replacingOccurrences(of: "{speed}", with: shellQuote(speed))
        .replacingOccurrences(of: "{out}", with: shellQuote(out))
}

/// ゆっくり音声(AquesTalkPlayer の外部コマンド)。AquesTalkPlayer が無く既定コマンドのままなら `say -v Kyoko` で代用する。
public struct AquesTalkSynthesizer {
    public static let playerPath = "/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer"
    public var cache: VoiceCache
    public var playerPath: String
    public init(cache: VoiceCache = .standard, playerPath: String = AquesTalkSynthesizer.playerPath) {
        self.cache = cache
        self.playerPath = playerPath
    }

    public var playerInstalled: Bool { FileManager.default.fileExists(atPath: playerPath) }

    /// 実際に使うコマンド(プレーヤー無し + 既定コマンドなら say)。
    public func effectiveCommand(_ commandTemplate: String) -> (command: String, usingFallback: Bool) {
        if !playerInstalled && commandTemplate == defaultAquesTalkCommand { return (kyokoFallbackCommand, true) }
        return (commandTemplate, false)
    }

    public func synthesize(text: String, voice: String?, speed: Double?, commandTemplate: String) async throws -> URL {
        let (command, _) = effectiveCommand(commandTemplate)
        guard !command.isEmpty else { throw VoiceError.message("設定でゆっくり音声のコマンドを指定してください") }
        let key = VoiceCache.key([.string("aq"), .string(command), .string(text), .opt(voice), .opt(speed)])
        if let hit = cache.hit(forKey: key) { return hit }
        let out = try cache.url(forKey: key)
        let speedText = speed.map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int($0)) : String($0) } ?? "100"
        let cmd = applyCommandTemplate(command, text: text, voice: voice, speed: speedText, out: out.path)
        try await Self.run(cmd, expecting: out)
        return out
    }

    static func run(_ cmd: String, expecting out: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = err.fileHandleForReading.readDataToEndOfFile()
                let msg = String(String(decoding: data, as: UTF8.self).suffix(400))
                if proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path) { cont.resume() }
                else { cont.resume(throwing: VoiceError.message("コマンド失敗 (\(proc.terminationStatus)): \(msg)")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
