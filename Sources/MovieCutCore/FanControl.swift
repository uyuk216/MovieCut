import Foundation
import Darwin

// 書き出し中のファン最大化(Core の純粋なロジック)。
//
// 構成:
//   FanModelPolicy   … 機種の許可リスト(MacBook Pro / Mac mini / Mac Studio だけ。それ以外と不明は対象外 = fail closed)
//   FanStatus        … ヘルパー(127.0.0.1 の HTTP)の /api/status を読んだ結果
//   FanBackend       … ファンを動かす口。HTTPFanBackend が 127.0.0.1:1200(ユーザー自身の fanctl)か :1201(同梱ヘルパー)に話しかける
//   FanGuard         … 状態機械。最大にするのは「ユーザーがオン・対象機種・ヘルパーが応答」のときだけ。
//                      終了・キャンセル・失敗・アプリ終了・クラッシュ(deinit)・シグナルで必ず自動に戻す。5 秒ごとの heartbeat と 95 ℃ の上限つき
//   FanHelperInstaller / FanWatchdogScript … 管理者権限のインストール用シェルと、ヘルパー側に見張りが無いときの見張り用シェルの組み立て(純粋関数)

// MARK: - エラー

public enum FanError: LocalizedError, Equatable {
    case unreachable(String)
    case server(status: Int, message: String)
    case badResponse(String)
    case notAutomatic(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let m): return "ファン制御サービスに接続できません(\(m))"
        case .server(let s, let m): return "ファン制御サービスがエラーを返しました(\(s)): \(m)"
        case .badResponse(let m): return "ファン制御サービスの応答を読めません(\(m))"
        case .notAutomatic(let m): return "ファンを自動に戻せたか確認できません(\(m))"
        }
    }
}

// MARK: - 機種の許可リスト

public enum FanMachineFamily: String, Equatable {
    case macBookPro, macMini, macStudio
}

public enum FanSupport: Equatable {
    case supported(FanMachineFamily)
    case unsupported(String)
    public var isSupported: Bool { if case .supported = self { return true } else { return false } }
}

/// 機種の判定。許可リスト方式: MacBook Pro / Mac mini / Mac Studio 以外(MacBook Air・iMac・Mac Pro・不明)はすべて対象外。
/// `hwModel` は `sysctl hw.model`(例 Mac17,2 / MacBookPro16,1)、`marketingName` は system_profiler の「モデル名」(例 MacBook Pro)。
/// Apple Silicon の識別子(Mac17,2)は名前を含まないので、モデル名が読めなければ対象外にする。
public enum FanModelPolicy {
    public static let unsupportedMessage = "この Mac は対象外です(MacBook Air など)"

    private static func normalized(_ s: String?) -> String {
        (s ?? "").lowercased().filter { !$0.isWhitespace }
    }

    static func familyFromName(_ name: String?) -> FanMachineFamily? {
        let n = normalized(name)
        if n.hasPrefix("macbookpro") { return .macBookPro }
        if n.hasPrefix("macmini") { return .macMini }
        if n.hasPrefix("macstudio") { return .macStudio }
        return nil
    }

    static func familyFromModel(_ model: String?) -> FanMachineFamily? {
        let n = normalized(model)
        if n.hasPrefix("macbookpro") { return .macBookPro }
        if n.hasPrefix("macmini") { return .macMini }
        return nil   // MacXX,Y 形式(Mac Studio を含む)は識別子だけでは決められない
    }

    /// 名前や識別子が、ファンのない・対象外と分かっている機種を指しているか。
    static func isKnownDenied(_ s: String?) -> Bool {
        let n = normalized(s)
        return ["macbookair", "imac", "macpro"].contains { n.hasPrefix($0) }
    }

    public static func classify(hwModel: String?, marketingName: String?) -> FanSupport {
        if isKnownDenied(hwModel) || isKnownDenied(marketingName) { return .unsupported(unsupportedMessage) }
        let byName = familyFromName(marketingName)
        let byModel = familyFromModel(hwModel)
        switch (byName, byModel) {
        case let (a?, b?): return a == b ? .supported(a) : .unsupported(unsupportedMessage)   // 食い違いは対象外
        case let (a?, nil): return .supported(a)
        case let (nil, b?): return normalized(marketingName).isEmpty ? .supported(b) : .unsupported(unsupportedMessage)
        case (nil, nil): return .unsupported(unsupportedMessage)
        }
    }
}

/// この Mac の機種名の取得(sysctl と system_profiler)。結果はプロセス内で 1 回だけ取る。
public enum FanMachine {
    public struct Info: Equatable { public var hwModel: String?; public var marketingName: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Info?

    public static func detect() -> Info {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let info = Info(hwModel: sysctlString("hw.model"), marketingName: marketingNameFromProfiler())
        cached = info
        return info
    }

    public static func support() -> FanSupport {
        let i = detect()
        return FanModelPolicy.classify(hwModel: i.hwModel, marketingName: i.marketingName)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// `system_profiler SPHardwareDataType -json` の machine_name。
    static func marketingNameFromProfiler() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPHardwareDataType", "-json", "-detailLevel", "mini"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseProfilerJSON(data)
    }

    public static func parseProfilerJSON(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["SPHardwareDataType"] as? [[String: Any]],
              let name = list.first?["machine_name"] as? String, !name.isEmpty else { return nil }
        return name
    }
}

// MARK: - 状態(/api/status)

public struct FanReading: Equatable {
    public var index: Int
    public var actualRPM: Double?
    public var minimumRPM: Double?
    public var maximumRPM: Double?
    public var targetRPM: Double?
    public var mode: String
    public init(index: Int, actualRPM: Double? = nil, minimumRPM: Double? = nil, maximumRPM: Double? = nil, targetRPM: Double? = nil, mode: String) {
        self.index = index; self.actualRPM = actualRPM; self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM; self.targetRPM = targetRPM; self.mode = mode
    }
    /// "auto" と "system" 以外は手動(または不明)として扱う。
    public var isManual: Bool { !(mode == "auto" || mode == "system") }
}

public struct FanStatus: Equatable {
    public var fans: [FanReading]
    /// CPU / SoC / GPU のセンサーの最高温度(読めなければ nil)。
    public var hottestCoreCelsius: Double?
    public init(fans: [FanReading], hottestCoreCelsius: Double? = nil) { self.fans = fans; self.hottestCoreCelsius = hottestCoreCelsius }

    public var hasFans: Bool { !fans.isEmpty }
    public var anyManual: Bool { fans.contains { $0.isManual } }
    public var allAutomatic: Bool { !fans.contains { $0.isManual } }
    public var maximumRPM: Double? { fans.compactMap(\.maximumRPM).max() }

    /// 温度の上限監視に使うセンサー(Apple Silicon: Tp=Pコア Te=Eコア Tg=GPU Ts=SoC、Intel: TC=CPU TG=GPU)。
    static let coreSensorPrefixes = ["Tp", "Te", "Tg", "Ts", "TC", "TG"]

    public static func parse(_ data: Data) throws -> FanStatus {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FanError.badResponse("JSON ではありません")
        }
        if let ok = obj["ok"] as? Bool, ok == false { throw FanError.badResponse((obj["error"] as? String) ?? "ok=false") }
        guard let rawFans = obj["fans"] as? [[String: Any]] else { throw FanError.badResponse("fans がありません") }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        let fans = rawFans.enumerated().map { (i, f) in
            FanReading(index: (f["index"] as? NSNumber)?.intValue ?? i, actualRPM: num(f["actualRPM"]), minimumRPM: num(f["minimumRPM"]),
                       maximumRPM: num(f["maximumRPM"]), targetRPM: num(f["targetRPM"]), mode: (f["mode"] as? String) ?? "unknown")
        }
        var hottest: Double?
        if let sensors = obj["sensors"] as? [[String: Any]] {
            for s in sensors {
                guard let key = s["key"] as? String, let c = num(s["celsius"]), c.isFinite else { continue }
                guard coreSensorPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
                hottest = max(hottest ?? c, c)
            }
        }
        return FanStatus(fans: fans, hottestCoreCelsius: hottest)
    }
}

// MARK: - バックエンド(HTTP)

public protocol FanBackend: AnyObject {
    var label: String { get }
    var port: Int { get }
    var baseURL: URL { get }
    /// ヘルパー側に「heartbeat が途切れたら自動に戻す」見張りがあるか。無いバックエンドには FanGuard が外付けの見張り(FanSidecar)を付ける。
    var supportsWatchdog: Bool { get }
    func status() throws -> FanStatus
    func setMax() throws
    func setAuto() throws
    func heartbeat() throws -> FanStatus
}

/// 127.0.0.1 のヘルパーに話しかける。短いタイムアウト、プロキシなし、Origin ヘッダは付けない(付けるとヘルパーが拒否する)。
public final class HTTPFanBackend: FanBackend {
    public enum Kind: Equatable { case userFanctl, bundledHelper }
    public static let userPort = 1200
    public static let bundledPort = 1201

    public let kind: Kind
    public let port: Int
    public let host: String
    private let session: URLSession

    public init(kind: Kind, port: Int? = nil, host: String = "127.0.0.1", timeout: TimeInterval = 2) {
        self.kind = kind
        self.port = port ?? (kind == .userFanctl ? Self.userPort : Self.bundledPort)
        self.host = host
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.connectionProxyDictionary = [:]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        session = URLSession(configuration: cfg)
    }

    public var label: String { kind == .userFanctl ? "fanctl(:\(port))" : "Movie Cut ファンヘルパー(:\(port))" }
    public var supportsWatchdog: Bool { kind == .bundledHelper }
    public var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(nil, forHTTPHeaderField: "Origin")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        session.dataTask(with: req) { d, r, e in result = (d, r, e); sem.signal() }.resume()
        sem.wait()
        if let e = result.2 { throw FanError.unreachable(e.localizedDescription) }
        guard let http = result.1 as? HTTPURLResponse else { throw FanError.badResponse("HTTP 応答がありません") }
        let data = result.0 ?? Data()
        guard (200..<300).contains(http.statusCode) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw FanError.server(status: http.statusCode, message: msg ?? "(本文なし)")
        }
        return data
    }

    public func status() throws -> FanStatus { try FanStatus.parse(try send("GET", "/api/status")) }
    public func setMax() throws { _ = try send("POST", "/api/all", body: ["mode": "fixedPercent", "percent": 100]) }
    public func setAuto() throws { _ = try send("POST", "/api/all", body: ["mode": "auto"]) }
    public func heartbeat() throws -> FanStatus {
        switch kind {
        case .userFanctl: return try status()   // ユーザーの fanctl に heartbeat はない(状態の取得で代える。見張りは FanSidecar)
        case .bundledHelper: return try FanStatus.parse(try send("POST", "/api/heartbeat", body: [:]))
        }
    }
}

public enum FanBackendResolver {
    /// 1200(ユーザー自身の fanctl)が応答すればそれを、なければ 1201(同梱ヘルパー)を使う。どちらも応答しなければ nil。
    public static func resolve(candidates: [FanBackend]? = nil) -> (backend: FanBackend, status: FanStatus)? {
        let list: [FanBackend] = candidates ?? [HTTPFanBackend(kind: .userFanctl), HTTPFanBackend(kind: .bundledHelper)]
        for b in list {
            if let s = try? b.status() { return (b, s) }
        }
        return nil
    }
}

// MARK: - 使えるかどうか(UI 用)

public enum FanAvailability: Equatable {
    case available(backend: String)
    case unsupportedMachine
    case serviceMissing
    case noFan

    public var isAvailable: Bool { if case .available = self { return true } else { return false } }

    /// 使えないときの 1 行の理由(日本語)。使えるときは nil。
    public var reason: String? {
        switch self {
        case .available: return nil
        case .unsupportedMachine: return FanModelPolicy.unsupportedMessage
        case .serviceMissing: return "ファン制御サービスが見つかりません — 設定で有効にできます"
        case .noFan: return "この Mac にはファンがありません"
        }
    }

    public static func evaluate(support: FanSupport, resolved: (backend: FanBackend, status: FanStatus)?) -> FanAvailability {
        guard support.isSupported else { return .unsupportedMachine }
        guard let r = resolved else { return .serviceMissing }
        guard r.status.hasFans else { return .noFan }
        return .available(backend: r.backend.label)
    }
}

// MARK: - 外付けの見張り(ヘルパーに見張りが無いとき)

/// ヘルパー側に見張りが無いバックエンド(ユーザー自身の fanctl)向け。親プロセスが消えたら(kill -9 を含む)、別プロセスのシェルが自動に戻す。
public enum FanWatchdogScript {
    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func make(parentPID: Int32, autoURL: String) -> String {
        """
        PID=\(parentPID)
        while /bin/kill -0 "$PID" 2>/dev/null; do /bin/sleep 1; done
        for i in 1 2 3 4 5 6 7 8; do
          /usr/bin/curl -s -m 3 -X POST -H 'Content-Type: application/json' -d '{"mode":"auto"}' \(shellQuote(autoURL)) | /usr/bin/grep -q '"ok":true' && exit 0
          /bin/sleep 1
        done
        exit 1
        """
    }
}

public protocol FanSidecar: AnyObject {
    func start(parentPID: Int32, autoURL: String)
    func stop()
}

/// 別セッション(POSIX_SPAWN_SETSID)で /bin/sh を起動する。親が `timeout` などでプロセスグループごと kill されても巻き込まれない。
public final class ShellFanSidecar: FanSidecar {
    private var pid: pid_t = 0
    private let lock = NSLock()
    public init() {}

    public func start(parentPID: Int32, autoURL: String) {
        lock.lock(); defer { lock.unlock() }
        guard pid == 0 else { return }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let script = FanWatchdogScript.make(parentPID: parentPID, autoURL: autoURL)
        var child: pid_t = 0
        let args = ["sh", "-c", script]
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let rc = posix_spawn(&child, "/bin/sh", &actions, &attr, cargs, environ)
        for p in cargs { free(p) }
        cargs.removeAll()
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&actions)
        if rc == 0 { pid = child }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard pid != 0 else { return }
        let p = pid
        pid = 0
        kill(p, SIGKILL)
        DispatchQueue.global(qos: .utility).async { var st: Int32 = 0; waitpid(p, &st, 0) }   // ゾンビを残さない
    }
}

// MARK: - FanGuard

public final class FanGuard {
    public enum State: Equatable { case idle, engaged, releaseFailed }
    public enum ReleaseReason: Equatable { case finished, cancelled, failed, appQuit, signal, overTemperature, deinitialized }
    public enum EngageResult: Equatable {
        case engaged(maximumRPM: Double?)
        case skipped(String)
        case failed(String)
    }
    public enum Event: Equatable {
        case engaged(maximumRPM: Double?)
        case released(ReleaseReason)
        case notice(String)
    }

    public static let defaultTemperatureLimit = 95.0
    public static let defaultHeartbeatInterval: TimeInterval = 5

    private let backend: FanBackend
    private let enabled: Bool
    private let support: FanSupport
    private let temperatureLimit: Double
    private let heartbeatInterval: TimeInterval
    private let sidecar: FanSidecar?
    private let onEvent: ((Event) -> Void)?
    private let queue = DispatchQueue(label: "moviecut.fanguard")
    private var timer: DispatchSourceTimer?
    private var _state: State = .idle
    private var tripped = false          // 温度で外したら、その書き出しの間は二度と最大にしない
    private var lastMaximumRPM: Double?
    private var failedBeats = 0
    private let stateLock = NSLock()

    public init(backend: FanBackend, enabled: Bool, support: FanSupport,
                temperatureLimit: Double = FanGuard.defaultTemperatureLimit,
                heartbeatInterval: TimeInterval = FanGuard.defaultHeartbeatInterval,
                sidecar: FanSidecar? = nil, onEvent: ((Event) -> Void)? = nil) {
        self.backend = backend; self.enabled = enabled; self.support = support
        self.temperatureLimit = temperatureLimit; self.heartbeatInterval = heartbeatInterval
        self.sidecar = sidecar; self.onEvent = onEvent
        FanGuardRegistry.shared.register(self)
    }

    deinit {
        // クラッシュ・取りこぼし対策: 最大のまま消えるくらいなら、ここで自動に戻す。
        if _state != .idle { _ = restoreAuto(reason: .deinitialized, emit: false) }
    }

    public var state: State { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    private func setState(_ s: State) { stateLock.lock(); _state = s; stateLock.unlock() }

    // MARK: 開始

    /// ユーザーがオン・対象機種・ヘルパーが応答・ファンがある、のときだけ最大にする。何度呼んでも 1 回分(冪等)。
    @discardableResult
    public func engage() -> EngageResult {
        queue.sync { engageLocked() }
    }

    private func engageLocked() -> EngageResult {
        if state == .engaged { return .engaged(maximumRPM: lastMaximumRPM) }
        guard enabled else { return .skipped("オフです") }
        guard support.isSupported else { return .skipped(FanModelPolicy.unsupportedMessage) }
        guard !tripped else { return .skipped("温度が高かったため、この書き出しでは自動のままです") }
        let before: FanStatus
        do { before = try backend.status() } catch { return .skipped("ファン制御サービスに接続できません") }
        guard before.hasFans else { return .skipped("この Mac にはファンがありません") }
        if let t = before.hottestCoreCelsius, t >= temperatureLimit {
            return .skipped("温度が高いため、ファンは自動のままです(\(Int(t)) ℃)")
        }
        // 先に見張りを付けてから最大にする(最大にした直後にクラッシュしても戻せるように)
        if !backend.supportsWatchdog, let sidecar {
            sidecar.start(parentPID: getpid(), autoURL: backend.baseURL.appendingPathComponent("api/all").absoluteString)
        }
        do { try backend.setMax() } catch {
            try? backend.setAuto()   // 途中まで効いていても確実に戻す
            _ = restoreAuto(reason: .failed, emit: false)
            return .failed(error.localizedDescription)
        }
        setState(.engaged)
        failedBeats = 0
        let after = try? backend.status()
        if let a = after, !a.anyManual {
            _ = restoreAuto(reason: .failed, emit: false)
            return .failed("ファンが手動にならなかったため自動に戻しました")
        }
        lastMaximumRPM = after?.maximumRPM ?? before.maximumRPM
        startTimer()
        onEvent?(.engaged(maximumRPM: lastMaximumRPM))
        return .engaged(maximumRPM: lastMaximumRPM)
    }

    // MARK: 終了

    /// 必ず自動に戻す(終了・キャンセル・失敗・アプリ終了・シグナル)。戻せたか(確認できたか)を返す。何も最大にしていなければ true。
    @discardableResult
    public func release(_ reason: ReleaseReason = .finished) -> Bool {
        queue.sync { restoreAuto(reason: reason, emit: true) }
    }

    private func restoreAuto(reason: ReleaseReason, emit: Bool) -> Bool {
        stopTimer()
        guard state != .idle else { sidecar?.stop(); return true }
        var ok = false
        for attempt in 1...3 {
            do { try backend.setAuto() } catch { if attempt < 3 { Thread.sleep(forTimeInterval: 0.2) }; continue }
            if let s = try? backend.status() { ok = s.allAutomatic } else { ok = true }   // 状態が読めなくても setAuto が通っていれば戻したとみなす
            if ok { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if ok {
            setState(.idle)
            sidecar?.stop()
            if emit { onEvent?(.released(reason)) }
        } else {
            setState(.releaseFailed)   // 見張りは残す。次の heartbeat で再試行
            startTimer()
            if emit { onEvent?(.notice("ファンを自動に戻せませんでした。再試行します")) }
        }
        return ok
    }

    // MARK: heartbeat と温度の上限

    private func startTimer() {
        guard timer == nil, heartbeatInterval > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

    func tick() {
        if state == .releaseFailed { _ = restoreAuto(reason: .failed, emit: true); return }
        guard state == .engaged else { return }
        do {
            let s = try backend.heartbeat()
            failedBeats = 0
            if let t = s.hottestCoreCelsius, t >= temperatureLimit {
                tripped = true
                if restoreAuto(reason: .overTemperature, emit: true) {
                    onEvent?(.notice("温度が \(Int(temperatureLimit)) ℃に達したため、ファンを自動に戻しました(現在 \(Int(t)) ℃)"))
                }
            }
        } catch {
            failedBeats += 1
            if failedBeats >= 3 { onEvent?(.notice("ファン制御サービスから応答がありません")) }
        }
    }
}

/// 生きている FanGuard の一覧(弱参照)。アプリ終了とシグナルで全部を自動に戻す。
public final class FanGuardRegistry {
    public static let shared = FanGuardRegistry()
    private let lock = NSLock()
    private var guards: [WeakGuard] = []
    private struct WeakGuard { weak var guardRef: FanGuard? }

    func register(_ g: FanGuard) {
        lock.lock(); defer { lock.unlock() }
        guards.removeAll { $0.guardRef == nil }
        guards.append(WeakGuard(guardRef: g))
    }

    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return guards.compactMap(\.guardRef).filter { $0.state != .idle }.count
    }

    /// applicationWillTerminate / シグナルから呼ぶ。
    @discardableResult
    public func releaseAll(_ reason: FanGuard.ReleaseReason) -> Bool {
        lock.lock(); let list = guards.compactMap(\.guardRef); lock.unlock()
        return list.map { $0.release(reason) }.allSatisfy { $0 }
    }
}

/// SIGTERM / SIGINT を受けたら handler を呼ぶ(DispatchSource)。`reraise` なら、そのあと既定の動作で終了させる。
public final class FanSignalHandlers {
    private var sources: [DispatchSourceSignal] = []
    public init() {}

    public func install(signals: [Int32] = [SIGTERM, SIGINT], reraise: Bool = true, handler: @escaping () -> Void) {
        for sig in signals {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "moviecut.fansignal.\(sig)"))
            src.setEventHandler {
                handler()
                if reraise { signal(sig, SIG_DFL); raise(sig) }
            }
            src.resume()
            sources.append(src)
        }
    }

    public func uninstall(signals: [Int32] = [SIGTERM, SIGINT]) {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for sig in signals { signal(sig, SIG_DFL) }
    }
}

// MARK: - インストーラのシェル(管理者権限で実行する文字列)

public enum FanHelperInstaller {
    public static let label = "com.moviecut.fanhelper"
    public static let installedBinary = "/usr/local/libexec/moviecut-fanhelper"
    public static let installedPlist = "/Library/LaunchDaemons/com.moviecut.fanhelper.plist"

    public static func q(_ s: String) -> String { FanWatchdogScript.shellQuote(s) }

    /// ヘルパーを置いて launchd に登録するシェル。`helperSource` / `plistSource` はアプリ内のパス(空白や日本語を含んでよい)。
    public static func installScript(helperSource: String, plistSource: String) -> String {
        [
            "set -e",
            "/bin/mkdir -p /usr/local/libexec",
            "/usr/bin/install -m 755 -o root -g wheel \(q(helperSource)) \(q(installedBinary))",
            "/usr/bin/xattr -c \(q(installedBinary)) 2>/dev/null || true",
            "/usr/bin/install -m 644 -o root -g wheel \(q(plistSource)) \(q(installedPlist))",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/launchctl bootstrap system \(q(installedPlist))",
            "/bin/launchctl enable system/\(label)",
            "/bin/launchctl kickstart -k system/\(label)",
        ].joined(separator: "\n")
    }

    /// 止めて、登録を外して、ファイルを消すシェル(止まるとき、ヘルパーが全ファンを自動に戻す)。
    public static func uninstallScript() -> String {
        [
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/rm -f \(q(installedPlist)) \(q(installedBinary))",
        ].joined(separator: "\n")
    }

    /// AppleScript の文字列リテラルに入れるためのエスケープ(バックスラッシュ・ダブルクォート・改行)。
    public static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// `do shell script "…" with administrator privileges` の AppleScript 全文。
    public static func appleScript(shell: String, prompt: String = "Movie Cut のファン制御サービスを設定します。") -> String {
        "do shell script \"\(appleScriptEscape(shell))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"
    }
}

// MARK: - 組み立て(アプリと CLI が共用)

public enum FanControlCenter {
    /// 機種とサービスを調べて、使えるかどうかと、書き出し 1 回ぶんの FanGuard を返す。
    /// `port` を指定すると、そのポートだけを調べる(1200 = ユーザーの fanctl、それ以外 = 同梱ヘルパー。検証用)。
    public static func prepare(enabled: Bool, port: Int? = nil, support: FanSupport? = nil,
                               onEvent: ((FanGuard.Event) -> Void)? = nil) -> (availability: FanAvailability, guard: FanGuard?) {
        let sup = support ?? FanMachine.support()
        guard sup.isSupported else { return (.unsupportedMachine, nil) }
        let candidates: [FanBackend]? = port.map { [HTTPFanBackend(kind: $0 == HTTPFanBackend.userPort ? .userFanctl : .bundledHelper, port: $0)] }
        let resolved = FanBackendResolver.resolve(candidates: candidates)
        let availability = FanAvailability.evaluate(support: sup, resolved: resolved)
        guard availability.isAvailable, let r = resolved else { return (availability, nil) }
        let g = FanGuard(backend: r.backend, enabled: enabled, support: sup, sidecar: ShellFanSidecar(), onEvent: onEvent)
        return (availability, g)
    }

    /// 「ファン: 最大(6550 rpm)」/「ファン: 自動」の表示文。
    public static func statusLine(maximumRPM: Double?) -> String {
        maximumRPM.map { "ファン: 最大(\(Int($0.rounded())) rpm)" } ?? "ファン: 最大"
    }
    public static let autoStatusLine = "ファン: 自動"
}
