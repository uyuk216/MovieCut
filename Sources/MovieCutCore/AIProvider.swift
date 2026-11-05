import Foundation

// AI 連携の土台。クラウドの鍵はアプリに保存しない。
// 使えるのは「ユーザーが指定したローカルのコマンド(claude -p / codex exec など)」と「このマシン上のサーバー(Ollama など)」だけ。
// どの呼び出しも、ユーザーが操作したときだけ行う(自動送信なし)。

/// 1 回の問い合わせ(プロンプト → 返事の文字)。
public protocol AIProvider: Sendable {
    func complete(_ prompt: String) async throws -> String
}

/// AI 連携のエラー。`errorDescription` は画面に出す日本語。
public enum AIError: Error, LocalizedError, Equatable {
    case notConfigured
    case emptyCommand
    case commandNotFound(String)
    case launchFailed(String)
    case timedOut(Int)
    case cancelled
    case nonZeroExit(Int32, String)
    case outputTooLarge(Int)
    case emptyResponse
    case notLocalURL(String)
    case serverUnreachable(String)
    case httpStatus(Int)
    case badResponse
    case unparsable(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "AI が設定されていません。設定で、AI を呼ぶコマンド(例: claude -p)かローカルサーバーの URL を指定してください。"
        case .emptyCommand: return "AI を呼ぶコマンドが空です。"
        case .commandNotFound(let c): return "コマンドが見つかりません: \(c)"
        case .launchFailed(let m): return "コマンドを起動できませんでした: \(m)"
        case .timedOut(let s): return "AI の返事が \(s) 秒以内に来ませんでした。時間を延ばすか、短い内容でやり直してください。"
        case .cancelled: return "キャンセルしました。"
        case .nonZeroExit(let code, let err):
            let tail = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "コマンドがエラーで終わりました(終了コード \(code))。" + (tail.isEmpty ? "" : "\n" + tail)
        case .outputTooLarge(let n): return "AI の返事が大きすぎます(\(n) バイトを超えました)。途中で止めました。"
        case .emptyResponse: return "AI の返事が空でした。"
        case .notLocalURL(let u): return "このマシン上のサーバー(127.0.0.1 / localhost)だけ使えます: \(u)"
        case .serverUnreachable(let m): return "ローカルサーバーにつながりません: \(m)"
        case .httpStatus(let c): return "サーバーがエラーを返しました(HTTP \(c))。"
        case .badResponse: return "サーバーの返事を読めませんでした。"
        case .unparsable(let what): return "AI の返事から\(what)を読み取れませんでした。もう一度試すか、プロンプトを見直してください。"
        }
    }
}

// MARK: - 設定(UserDefaults。鍵は持たない)

public enum AIProviderKind: String, CaseIterable, Sendable {
    case none, command, http
    public var title: String {
        switch self {
        case .none: return "使わない"
        case .command: return "ローカルのコマンド"
        case .http: return "ローカルサーバー(Ollama 形式)"
        }
    }
}

public struct AISettings: Equatable, Sendable {
    public var kind: AIProviderKind = .none
    /// 例: `claude -p` / `codex exec -`。プロンプトは標準入力で渡す。
    public var command: String = ""
    /// 例: `http://127.0.0.1:11434`(Ollama)。127.0.0.1 / localhost / [::1] のみ。
    public var url: String = "http://127.0.0.1:11434"
    public var model: String = ""
    public var timeoutSeconds: Int = 120

    public static let timeoutRange = 5...900
    static let kindKey = "ai.kind", commandKey = "ai.command", urlKey = "ai.url", modelKey = "ai.model", timeoutKey = "ai.timeout"

    public init() {}

    public static func load(from d: UserDefaults = DataLocations.current.defaults) -> AISettings {
        var s = AISettings()
        s.kind = d.string(forKey: kindKey).flatMap(AIProviderKind.init(rawValue:)) ?? .none
        s.command = d.string(forKey: commandKey) ?? ""
        s.url = d.string(forKey: urlKey) ?? s.url
        s.model = d.string(forKey: modelKey) ?? ""
        let t = d.integer(forKey: timeoutKey)
        s.timeoutSeconds = t == 0 ? 120 : min(max(t, timeoutRange.lowerBound), timeoutRange.upperBound)
        return s
    }

    public func save(to d: UserDefaults = DataLocations.current.defaults) {
        d.set(kind.rawValue, forKey: Self.kindKey)
        d.set(command, forKey: Self.commandKey)
        d.set(url, forKey: Self.urlKey)
        d.set(model, forKey: Self.modelKey)
        d.set(timeoutSeconds, forKey: Self.timeoutKey)
    }

    /// 設定からプロバイダを作る。未設定・不正なら日本語のエラー。
    public func makeProvider() throws -> AIProvider {
        switch kind {
        case .none: throw AIError.notConfigured
        case .command: return try CommandAIProvider(commandLine: command, timeout: TimeInterval(timeoutSeconds))
        case .http: return try HTTPAIProvider(baseURL: url, model: model, timeout: TimeInterval(timeoutSeconds))
        }
    }

    /// 送信先の説明(送信前のプレビューに出す)。
    public var destinationDescription: String {
        switch kind {
        case .none: return "(未設定)"
        case .command: return "コマンド: \(command)"
        case .http: return "ローカルサーバー: \(url)" + (model.isEmpty ? "" : "(モデル \(model))")
        }
    }
}

// MARK: - コマンドの分割(シェルは通さない)

public enum AICommandLine {
    /// 空白で分け、'...' と "..." と \ のエスケープを解釈する(シェル展開・パイプ・リダイレクトはしない)。
    public static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", has = false
        var quote: Swift.Character? = nil
        var esc = false
        for ch in s {
            if esc { cur.append(ch); esc = false; has = true; continue }
            if ch == "\\" && quote != "'" { esc = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; has = true; continue }
            if ch.isWhitespace {
                if has { out.append(cur); cur = ""; has = false }
                continue
            }
            cur.append(ch); has = true
        }
        if has { out.append(cur) }
        return out
    }

    /// 実行ファイルを探す。"/" を含むならそのまま、無ければ PATH と、GUI アプリでは入っていない定番の場所から。
    public static func resolve(_ exe: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if exe.contains("/") {
            let p = (exe as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        let home = NSHomeDirectory()
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", home + "/.local/bin", home + "/.claude/local", home + "/.npm-global/bin"]
        for d in dirs {
            let p = d + "/" + exe
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

// MARK: - コマンド版

/// ユーザーが指定したコマンドを起動し、プロンプトを標準入力に渡して、標準出力を返す。
/// 時間切れ・キャンセル・出力サイズの上限つき。シェルは通さない。
public struct CommandAIProvider: AIProvider {
    public static let defaultMaxOutputBytes = 1_000_000
    public let executable: String
    public let arguments: [String]
    public let timeout: TimeInterval
    public let maxOutputBytes: Int

    public init(commandLine: String, timeout: TimeInterval = 120, maxOutputBytes: Int = CommandAIProvider.defaultMaxOutputBytes) throws {
        let parts = AICommandLine.split(commandLine)
        guard let first = parts.first else { throw AIError.emptyCommand }
        guard let path = AICommandLine.resolve(first) else { throw AIError.commandNotFound(first) }
        self.executable = path
        self.arguments = Array(parts.dropFirst())
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    public func complete(_ prompt: String) async throws -> String {
        let run = ProcessRun(executable: executable, arguments: arguments, input: Data(prompt.utf8), timeout: timeout, maxOutputBytes: maxOutputBytes)
        return try await withTaskCancellationHandler {
            try await run.start()
        } onCancel: {
            run.cancel()
        }
    }
}

/// 1 回のプロセス実行。terminate は何度呼んでもよい。
final class ProcessRun: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private var outcome: AIError?          // 先に決まった理由(時間切れ・キャンセル・大きすぎ)
    private var finished = false
    private let input: Data, timeout: TimeInterval, cap: Int

    init(executable: String, arguments: [String], input: Data, timeout: TimeInterval, maxOutputBytes: Int, environment: [String: String] = [:]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + extra
        process.environment = env
        self.input = input; self.timeout = timeout; self.cap = maxOutputBytes
    }

    private func setOutcome(_ e: AIError) {
        lock.lock()
        let first = outcome == nil && !finished
        if first { outcome = e }
        lock.unlock()
        if first, process.isRunning { process.terminate() }
    }

    func cancel() { setOutcome(.cancelled) }

    func start() async throws -> String {
        signal(SIGPIPE, SIG_IGN)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock(); self.out.append(d); let n = self.out.count; self.lock.unlock()
            if n > self.cap { self.setOutcome(.outputTooLarge(self.cap)) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock(); if self.err.count < 4000 { self.err.append(d.prefix(4000 - self.err.count)) }; self.lock.unlock()
        }
        let status: Int32 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            lock.lock()
            let pre = outcome            // 起動前にキャンセル済み
            lock.unlock()
            if let pre { cont.resume(throwing: pre); return }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: AIError.launchFailed(error.localizedDescription))
                return
            }
            let data = input
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: data)
                try? stdin.fileHandleForWriting.close()
            }
            let t = timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + t) { [weak self] in
                self?.setOutcome(.timedOut(Int(t.rounded())))
            }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        // 残りを読む(上限まで)
        let rest = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        let (why, o, e) = lock.withLock { () -> (AIError?, Data, Data) in
            finished = true
            if out.count <= cap { out.append(rest.prefix(max(0, cap + 1 - out.count))) }
            return (outcome, out, err)
        }
        if let why { throw why }
        if o.count > cap { throw AIError.outputTooLarge(cap) }
        guard status == 0 else { throw AIError.nonZeroExit(status, String(decoding: e, as: UTF8.self)) }
        let text = String(decoding: o, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AIError.emptyResponse }
        return text
    }
}

// MARK: - ローカルサーバー版(Ollama 形式)

/// `POST {base}/api/generate`(stream なし)。127.0.0.1 / localhost / [::1] 以外は断る。
public struct HTTPAIProvider: AIProvider {
    /// (リクエスト) → (本体, HTTP ステータス)。テストで差し替える。
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    public static let maxResponseBytes = 2_000_000

    public let endpoint: URL
    public let model: String
    public let timeout: TimeInterval
    let transport: Transport

    public static func isLoopback(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }

    public init(baseURL: String, model: String, timeout: TimeInterval = 120, transport: Transport? = nil) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: trimmed), base.scheme == "http", Self.isLoopback(base.host) else { throw AIError.notLocalURL(trimmed) }
        self.endpoint = base.appendingPathComponent("api/generate")
        self.model = model
        self.timeout = timeout
        self.transport = transport ?? { req in
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func complete(_ prompt: String) async throws -> String {
        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "stream": false] as [String: Any])
        let data: Data, status: Int
        do { (data, status) = try await transport(req) } catch is CancellationError { throw AIError.cancelled } catch let e as AIError { throw e } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw AIError.cancelled }
            if (error as? URLError)?.code == .timedOut { throw AIError.timedOut(Int(timeout.rounded())) }
            throw AIError.serverUnreachable(error.localizedDescription)
        }
        if Task.isCancelled { throw AIError.cancelled }
        guard (200..<300).contains(status) else { throw AIError.httpStatus(status) }
        guard data.count <= Self.maxResponseBytes else { throw AIError.outputTooLarge(Self.maxResponseBytes) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["response"] as? String else { throw AIError.badResponse }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AIError.emptyResponse }
        return text
    }
}

// MARK: - テスト用

/// 決まった返事を返す(または遅らせる・失敗させる)偽のプロバイダ。
public final class FakeAIProvider: AIProvider, @unchecked Sendable {
    public enum Behavior: Sendable { case reply(String), fail(AIError), delay(seconds: Double, reply: String) }
    private let lock = NSLock()
    private var _prompts: [String] = []
    public let behavior: Behavior
    public init(_ b: Behavior) { behavior = b }
    public var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }

    public func complete(_ prompt: String) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        switch behavior {
        case .reply(let s): return s
        case .fail(let e): throw e
        case .delay(let s, let r):
            do { try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) } catch { throw AIError.cancelled }
            return r
        }
    }
}
