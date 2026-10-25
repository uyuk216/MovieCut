import Foundation

public struct VoicevoxStyle: Equatable, Sendable { public var id: Int; public var name: String }
public struct VoicevoxSpeaker: Equatable, Sendable { public var name: String; public var styles: [VoicevoxStyle] }

public enum VoiceError: LocalizedError {
    case http(String, Int)
    case badResponse(String)
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .http(let what, let code): return "VOICEVOX の \(what) が失敗しました(HTTP \(code))。VOICEVOX が起動しているか確認してください。"
        case .badResponse(let what): return "VOICEVOX の応答を読めませんでした(\(what))。"
        case .message(let m): return m
        }
    }
}

/// VOICEVOX エンジンの HTTP クライアント(main.js の voicevox-speakers / voicevox-synth と同じ)。
public struct VoicevoxClient {
    public var baseURL: String
    public var cache: VoiceCache
    public var session: URLSession

    public init(baseURL: String = "http://127.0.0.1:50021", cache: VoiceCache = .standard, session: URLSession = .shared) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.cache = cache
        self.session = session
    }

    /// encodeURIComponent 相当(英数と - . _ ~ 以外は %XX)。
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: baseURL + path) else { throw VoiceError.message("VOICEVOX の URL が正しくありません: \(baseURL)") }
        return u
    }

    private func send(_ req: URLRequest, _ what: String) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw VoiceError.http(what, code) }
        return data
    }

    /// GET /speakers
    public func speakers() async throws -> [VoicevoxSpeaker] {
        let data = try await send(URLRequest(url: try url("/speakers")), "speakers")
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw VoiceError.badResponse("speakers") }
        return arr.map { s in
            let styles = (s["styles"] as? [[String: Any]] ?? []).compactMap { st -> VoicevoxStyle? in
                guard let id = (st["id"] as? NSNumber)?.intValue else { return nil }
                return VoicevoxStyle(id: id, name: st["name"] as? String ?? "")
            }
            return VoicevoxSpeaker(name: s["name"] as? String ?? "", styles: styles)
        }
    }

    /// POST /audio_query → パラメータ設定 → POST /synthesis → キャッシュへ書く。
    public func synthesize(text: String, speaker: Int, speed: Double? = nil, pitch: Double? = nil, intonation: Double? = nil, volume: Double? = nil) async throws -> URL {
        let key = VoiceCache.key([.string("vv"), .string(baseURL), .string(text), .number(Double(speaker)), .opt(speed), .opt(pitch), .opt(intonation), .opt(volume)])
        if let hit = cache.hit(forKey: key) { return hit }
        let out = try cache.url(forKey: key)

        var qreq = URLRequest(url: try url("/audio_query?text=\(Self.encode(text))&speaker=\(speaker)"))
        qreq.httpMethod = "POST"
        let qdata = try await send(qreq, "audio_query")
        guard var query = try JSONSerialization.jsonObject(with: qdata) as? [String: Any] else { throw VoiceError.badResponse("audio_query") }
        query["speedScale"] = speed ?? 1
        query["pitchScale"] = pitch ?? 0
        query["intonationScale"] = intonation ?? 1
        query["volumeScale"] = volume ?? 1

        var sreq = URLRequest(url: try url("/synthesis?speaker=\(speaker)"))
        sreq.httpMethod = "POST"
        sreq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sreq.httpBody = try JSONSerialization.data(withJSONObject: query)
        let wav = try await send(sreq, "synthesis")
        let tmp = out.appendingPathExtension("part")
        try wav.write(to: tmp)
        _ = try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}

/// VOICEVOX.app 同梱のエンジンを画面なしで起動する(startVoicevox 相当)。自分で起動したものだけ shutdown で止める。
public final class VoicevoxEngine {
    public static let defaultBinary = "/Applications/VOICEVOX.app/Contents/Resources/vv-engine/run"
    public let binaryPath: String
    private var process: Process?
    private let lock = NSLock()

    public init(binaryPath: String = VoicevoxEngine.defaultBinary) { self.binaryPath = binaryPath }

    /// 自分で起動したエンジンがあるか。
    public var startedByUs: Bool { lock.withLock { process?.isRunning == true } }

    /// 性能コア数(取れなければ論理コア数の 6 割、最低 2)。
    public static func cpuThreads() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        p.arguments = ["-n", "hw.perflevel0.logicalcpu"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let n = Int(s), n > 0 { return n }
        }
        return max(2, Int((Double(ProcessInfo.processInfo.activeProcessorCount) * 0.6).rounded()))
    }

    /// GET /version が通るか(短いタイムアウト)。
    public static func isAlive(baseURL: String, timeout: TimeInterval = 0.8) async -> Bool {
        guard let u = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/version") else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch { return false }
    }

    /// 動いていなければ(localhost のときだけ)起動して、最大 30 秒待つ。バイナリが無ければ何もせず false。
    public func ensureRunning(baseURL: String) async -> Bool {
        if await Self.isAlive(baseURL: baseURL) { return true }
        guard let comps = URLComponents(string: baseURL), let host = comps.host,
              ["127.0.0.1", "localhost", "::1"].contains(host) else { return false }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return false }
        let port = comps.port ?? 50021
        let alreadyStarted: Bool = lock.withLock { process?.isRunning == true }
        if !alreadyStarted {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binaryPath)
            p.arguments = ["--host", "127.0.0.1", "--port", String(port), "--cpu_num_threads", String(Self.cpuThreads())]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            lock.withLock { process = p }
        }
        for _ in 0..<60 {
            if await Self.isAlive(baseURL: baseURL) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// 自分で起動したエンジンだけ止める。
    public func shutdown() {
        let p: Process? = lock.withLock { let x = process; process = nil; return x }
        guard let p, p.isRunning else { return }
        p.terminate()
        p.waitUntilExit()
    }
}
