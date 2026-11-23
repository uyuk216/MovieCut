import Foundation

/// 声名とプレイヤーのプリセットの対応。
/// 女声1・女声2 は AquesTalk2 の「女性A」「女性G」に割り当てる。AquesTalk1(れいむ・まりさ)は濁音の子音の閉鎖区間に
/// 有声成分が無く、「ボタン→ホタン」のように濁点が落ちる(波形測定で確認)。AquesTalk2 の女性A・女性G は有声成分を確認済み。
/// AquesTalk1 の声も選択肢として残すため、「女声1（AquesTalk1）」「女声2（AquesTalk1）」を別の声名として用意した。
public enum AquesTalkPresets {
    /// 標準で入っているプリセット(実機で -P を試して確認したもの)。先頭が新規キャラの既定の声。
    public static let all = ["女声1", "女声2", "女声1（AquesTalk1）", "女声2（AquesTalk1）", "中性", "機械", "ロボット"]

    /// 旧名(古いプロジェクトファイルに保存されている名前)との対応表。
    /// 【旧ファイル互換のため】Sources で旧名が残ってよい唯一の場所(`playerNames` の AquesTalk1 側の名前は別)。
    /// - 読み込み時: 旧名 → 新名(`canonicalVoice`)。保存し直すと新名になる。
    /// 旧名「れいむ」「まりさ」は従来どおり女声1・女声2 に読み替える(AquesTalk1 版を使いたい場合は新声名を選び直す)。
    static let legacyAliases: [(legacy: String, current: String)] = [("れいむ", "女声1"), ("まりさ", "女声2")]

    /// 声名 → AquesTalkPlayer の `-P` に渡すプリセット名。ここに無い声名はそのまま渡す。
    static let playerNames: [String: String] = [
        "女声1": "女性A",
        "女声2": "女性G",
        "女声1（AquesTalk1）": "れいむ",
        "女声2（AquesTalk1）": "まりさ",
    ]

    /// 旧名なら新名に直す。それ以外(新名・未知の名前・nil)はそのまま。
    public static func canonicalVoice(_ v: String?) -> String? {
        guard let v else { return nil }
        return legacyAliases.first { $0.legacy == v }?.current ?? v
    }

    /// AquesTalkPlayer の `-P` に渡す名前(旧名・新名のどちらでも同じ結果)。未知の名前はそのまま。
    public static func playerName(_ v: String?) -> String? {
        guard let c = canonicalVoice(v) else { return nil }
        return playerNames[c] ?? c
    }
}

/// ゆっくり音声(AquesTalkPlayer の外部コマンド)。AquesTalkPlayer が無ければ `say -v Kyoko` で代用する。
/// 速さ(`Character.speed`、%)はプレイヤーの引数に無いため、100・未指定以外では生成後の WAV に
/// 音程保持の時間伸縮(`VoiceTimeStretch`)をかけて反映する(100・未指定は無変換で従来とバイト一致)。
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
        // 速さ 100・未指定では従来どおり無変換で作る(参照 WAV とのバイト一致を保つ互換条件)。
        // ただしキャッシュの場所へ直接書くと、途中終了したときに壊れた WAV が残り、
        // 次回に「キャッシュに当たった」として使われ続ける。隣の一時ファイルへ作ってから移す
        // (移すだけなので中身のバイト列は変わらない)。
        guard VoiceTimeStretch.needsStretch(speed: speed), let speed else {
            // 一時ファイルも .wav で終わる名前にする(プレイヤーが拡張子で形式を判定するため)
            let tmp = out.deletingLastPathComponent().appendingPathComponent("\(key).part-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let inv = invocation(text: text, voice: voice, out: tmp)
            try await Self.run(executable: inv.executable, arguments: inv.arguments, expecting: tmp)
            try VoiceCache.replaceItem(at: out, with: tmp)
            return out
        }
        // 速さは AquesTalkPlayer の引数に無いので、一度テンポラリへ生成してから音程保持の
        // 時間伸縮(`VoiceTimeStretch`)をかけてキャッシュの場所へ置く。say 代用のときも同じ。
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-aq-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: raw) }
        let inv = invocation(text: text, voice: voice, out: raw)
        try await Self.run(executable: inv.executable, arguments: inv.arguments, expecting: raw)
        // 伸縮の書き込みも、途中で失敗したときに壊れた WAV がキャッシュに残らないよう一時ファイル経由にする
        let stretched = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-aq-stretch-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: stretched) }
        try VoiceTimeStretch.apply(input: raw, speedPercent: speed, output: stretched)
        try VoiceCache.replaceItem(at: out, with: stretched)
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
