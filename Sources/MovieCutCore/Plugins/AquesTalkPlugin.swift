import Foundation

/// ゆっくり音声(AquesTalkPlayer の外部コマンド)のプラグイン専用シンセサイザ。
///
/// 内蔵 `AquesTalkSynthesizer` のロジックの「複製」。内蔵側は変更せずそのまま残してあり、
/// 実行ファイルの探索・検証、引数の組み立て、キャッシュキーは内蔵と同一にしてある(等価性はテストで確認する)。
/// 型(`AquesTalkPresets` / `VoiceCache` / `VoiceError`)と探索・検証(`AquesTalkLocator` / `ExecutableTrust`)は Core 既存のものを使う。
///
/// 速さの扱いも内蔵と同一: キャラの `speed`(%表記、標準 100。ゆっくり 130% は speed = 130)を
/// そのまま受け取り、キャッシュキーに含める。AquesTalkPlayer のコマンドライン
/// (`-P` / `-T` / `-W` のみ)に速さの指定は無いため引数には含めず、100・未指定以外では
/// 生成後の WAV に音程保持の時間伸縮(`VoiceTimeStretch`、内蔵と共有の部品)をかけて反映する。
public struct AquesTalkPluginSynthesizer {
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
        // (移すだけなので中身のバイト列は変わらない)。内蔵 AquesTalkSynthesizer と同じ手順。
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

    static func run(executable: URL, arguments: [String], expecting out: URL, timeout: TimeInterval = AquesTalkPluginSynthesizer.timeout) async throws {
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
            // 標準エラーは溜めながら読む(終了後にまとめて読むと、出力が多いときにパイプが
            // 満杯になって子プロセスが書き込み待ちで止まってしまう)。
            final class ErrBox: @unchecked Sendable { let lock = NSLock(); var data = Data(); var eof = false }
            let errBox = ErrBox()
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    errBox.lock.withLock { errBox.eof = true }
                } else { errBox.lock.withLock { errBox.data.append(d) } }
            }
            p.terminationHandler = { proc in
                // 終了直後は読み取りの完了(EOF)がまだ届いていないことがあるので少しだけ待つ。
                // 孫プロセスがパイプを受け継いでいると EOF が来ないため、上限を付ける
                // (終了ハンドラで読み切ろうとすると、待ちが戻らなくなる)。
                for _ in 0..<50 {
                    if errBox.lock.withLock({ errBox.eof }) { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                err.fileHandleForReading.readabilityHandler = nil
                let data = errBox.lock.withLock { errBox.data }
                let msg = String(String(decoding: data, as: UTF8.self).suffix(400))
                let late = flag.lock.withLock { flag.on }
                if late { cont.resume(throwing: VoiceError.message("コマンドが \(Int(timeout)) 秒以内に終わらなかったので止めました。")) }
                else if proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path) { cont.resume() }
                else { cont.resume(throwing: VoiceError.message("コマンド失敗 (\(proc.terminationStatus)): \(msg)")) }
            }
            do { try p.run() } catch { err.fileHandleForReading.readabilityHandler = nil; cont.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    flag.lock.withLock { flag.on = true }
                    p.terminate()
                    // 終了要求を無視するプロセスは 2 秒後に強制終了する(終了ハンドラが必ず呼ばれ、待ちが戻るように)。
                    let pid = p.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if p.isRunning { kill(pid, SIGKILL) }
                    }
                }
            }
        }
    }
}

/// AquesTalk プラグインの `VoiceProvider`。処理手順は `RealVoiceProvider` の aquestalk 分岐と同一。
public final class AquesTalkPluginProvider: VoiceProvider {
    public let synthesizer: AquesTalkPluginSynthesizer
    /// 使われたエンジンの記録("aquestalk" / "say")。内蔵 `RealVoiceProvider` と同じ持ち方。
    public private(set) var enginesUsed: Set<String> = []
    private let lock = NSLock()

    public init(synthesizer: AquesTalkPluginSynthesizer) {
        self.synthesizer = synthesizer
    }

    /// 内蔵 `RealVoiceProvider` が AquesTalk を組み立てる条件と同じ(キャッシュ + プロジェクト素材フォルダを実行禁止に)。
    public convenience init(project: Project, cache: VoiceCache = .standard) {
        self.init(synthesizer: AquesTalkPluginSynthesizer(cache: cache, forbiddenRoots: RealVoiceProvider.mediaFolders(of: project)))
    }

    /// say で代用しているか(UI の警告用)。内蔵と同じ意味。
    public var usingFallback: Bool { synthesizer.usingFallback }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        let url = try await synthesizer.synthesize(text: text, voice: character.voice, speed: character.speed)
        lock.withLock { _ = enginesUsed.insert(usingFallback ? "say" : "aquestalk") }
        return VoiceResult(url: url, duration: try RealVoiceProvider.duration(of: url))
    }
}

/// AquesTalk プラグインの名前空間(マニフェスト)。
public enum AquesTalkPlugin {
    public static let pluginID = "jp.local.moviecut.plugin.aquestalk"

    public static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: "AquesTalk",
                       version: "1.0.0",
                       hooks: [.voice],
                       entryPoint: "AquesTalkPlugin",
                       minimumAppVersion: nil,
                       voiceEngineIDs: ["aquestalk"],
                       requiresLicense: false,
                       description: "AquesTalk(ゆっくり)で音声合成するプラグイン(組み込み)")
    }

    /// `manifest.json` の中身(PluginDiscovery で読める形)。
    public static func manifestJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }
}
