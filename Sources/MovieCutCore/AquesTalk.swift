import Foundation

public enum AquesTalkPresets {
    /// 標準で入っているプリセット(実機で -P を試して確認したもの)。
    public static let all = ["女声1", "女声2", "中性", "機械", "ロボット"]

    /// 旧名(古いプロジェクトファイルに保存されている名前)との対応表。
    /// 【旧ファイル互換のため】Sources で旧名が残ってよい唯一の場所。
    /// - 読み込み時: 旧名 → 新名(`canonicalVoice`)。保存し直すと新名になる。
    /// - 合成時: AquesTalkPlayer の `-P` は旧名の登録名しか受け付けない(実機確認: 新名はエラー)ため、新名 → 旧名(`playerName`)。
    static let legacyAliases: [(legacy: String, current: String)] = [("れいむ", "女声1"), ("まりさ", "女声2")]

    /// 旧名なら新名に直す。それ以外(新名・未知の名前・nil)はそのまま。
    public static func canonicalVoice(_ v: String?) -> String? {
        guard let v else { return nil }
        return legacyAliases.first { $0.legacy == v }?.current ?? v
    }

    /// AquesTalkPlayer の `-P` に渡す名前(旧名・新名のどちらでも同じ結果)。未知の名前はそのまま。
    public static func playerName(_ v: String?) -> String? {
        guard let v else { return nil }
        return legacyAliases.first { $0.current == v }?.legacy ?? v
    }
}

/// ゆっくり音声(AquesTalkPlayer の外部コマンド)。AquesTalkPlayer が無ければ `say -v Kyoko` で代用する。
///
/// 安全のため、実行するファイルは `AquesTalkLocator` が決まった場所から探し、`ExecutableTrust` で検証したものだけ。
/// プロジェクトファイルに書かれた「実行コマンド」(`aquestalkCommand`)は読み込むだけで、実行には使わない。
/// 引数は配列で渡し、シェルは通さない。
public struct AquesTalkSynthesizer {
    /// 標準のインストール先(表示・案内用)。
    public static let playerPath = "/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer"
    public static let sayPath = "/usr/bin/say"
    public static let timeout: TimeInterval = 60

    public var cache: VoiceCache
    /// 検証を通った AquesTalkPlayer の実体(無ければ nil = say で代用)。
    public let executable: URL?

    /// - `playerPath`: 試験用に場所を指定する(検証は通す)。nil なら決まった場所から探す。
    /// - `forbiddenRoots`: この下の実行ファイルは使わない(プロジェクト・素材のフォルダ)。
    public init(cache: VoiceCache = .standard, playerPath: String? = nil, forbiddenRoots: [URL] = []) {
        self.cache = cache
        if let p = playerPath {
            if case .success(let u) = ExecutableTrust.validate(path: p, forbiddenRoots: forbiddenRoots) { executable = u } else { executable = nil }
        } else {
            executable = AquesTalkLocator.resolve(forbiddenRoots: forbiddenRoots)
        }
    }

    public var playerInstalled: Bool { executable != nil }
    /// say で代用しているか。
    public var usingFallback: Bool { executable == nil }

    /// 実際に実行するものと引数(シェルを通さない配列)。
    func invocation(text: String, voice: String?, out: URL) -> (executable: URL, arguments: [String]) {
        if let exe = executable { return (exe, ["-P", AquesTalkPresets.playerName(voice) ?? "", "-T", text, "-W", out.path]) }
        return (URL(fileURLWithPath: Self.sayPath), ["-v", "Kyoko", "-o", out.path, "--data-format=LEI16@24000", "--", text])
    }

    public func synthesize(text: String, voice: String?, speed: Double?) async throws -> URL {
        let key = VoiceCache.key([.string("aq"), .string(executable?.path ?? "say"), .string(text), .opt(AquesTalkPresets.playerName(voice)), .opt(speed)])
        if let hit = cache.hit(forKey: key) { return hit }
        let out = try cache.url(forKey: key)
        let inv = invocation(text: text, voice: voice, out: out)
        try await Self.run(executable: inv.executable, arguments: inv.arguments, expecting: out)
        return out
    }

    static func run(executable: URL, arguments: [String], expecting out: URL, timeout: TimeInterval = AquesTalkSynthesizer.timeout) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            final class Flag: @unchecked Sendable { let lock = NSLock(); var on = false }
            let flag = Flag()
            p.terminationHandler = { proc in
                let data = err.fileHandleForReading.readDataToEndOfFile()
                let msg = String(String(decoding: data, as: UTF8.self).suffix(400))
                let late = flag.lock.withLock { flag.on }
                if late { cont.resume(throwing: VoiceError.message("コマンドが \(Int(timeout)) 秒以内に終わらなかったので止めました。")) }
                else if proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path) { cont.resume() }
                else { cont.resume(throwing: VoiceError.message("コマンド失敗 (\(proc.terminationStatus)): \(msg)")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { flag.lock.withLock { flag.on = true }; p.terminate() }
            }
        }
    }
}
