import XCTest
import Network
@testable import MovieCutCore

// MARK: - 127.0.0.1 の偽ファン制御サービス(プロセス内)

final class FakeFanService {
    struct Req { var method: String; var path: String; var headers: [String: String]; var body: Data }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.fan.service")
    private let lock = NSLock()
    private var _requests: [Req] = []
    private var _mode = "auto"
    var fansCount = 1
    var temperature = 50.0
    var statusDown = false          // 状態の取得が 503
    var failSetMax = false          // 最大にする要求が 500
    var failSetAutoRemaining = 0    // この回数だけ自動に戻す要求が 500
    var ignoreMax = false           // 最大にしても手動にならない
    private(set) var port = 0

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.receive(c, Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else { throw XCTSkip("listener") }
        port = Int(p)
    }

    deinit { listener.cancel() }

    var requests: [Req] { lock.lock(); defer { lock.unlock() }; return _requests }
    var mode: String { get { lock.lock(); defer { lock.unlock() }; return _mode } set { lock.lock(); _mode = newValue; lock.unlock() } }
    func count(_ method: String, _ path: String) -> Int { requests.filter { $0.method == method && $0.path == path }.count }
    func autoPosts() -> Int { requests.filter { $0.path == "/api/all" && String(data: $0.body, encoding: .utf8)?.contains("auto") == true }.count }

    private func receive(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var full = acc; if let data { full.append(data) }
            if let req = self.parse(full) {
                let (status, obj) = self.handle(req)
                let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                var head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                head += ""
                var out = Data(head.utf8); out.append(body)
                c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
            } else if done || err != nil { c.cancel() } else { self.receive(c, full) }
        }
    }

    private func parse(_ data: Data) -> Req? {
        guard let r = data.range(of: Data([13, 10, 13, 10])) else { return nil }
        let head = String(decoding: data[..<r.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in head.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[r.upperBound...]
        guard body.count >= len else { return nil }
        return Req(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(len)))
    }

    private func statusJSON() -> [String: Any] {
        let fans: [[String: Any]] = (0..<fansCount).map { i in
            ["index": i, "mode": mode == "auto" ? "auto" : "manual", "minimumRPM": 2317, "maximumRPM": 6550,
             "targetRPM": mode == "auto" ? 2500 : 6550, "actualRPM": 2500]
        }
        return ["ok": true, "fans": fans, "sensors": [["key": "Tp01", "celsius": temperature], ["key": "TB0T", "celsius": 99], ["key": "Te04", "celsius": 40]]]
    }

    private func handle(_ r: Req) -> (Int, [String: Any]) {
        lock.lock(); _requests.append(r); lock.unlock()
        switch (r.method, r.path) {
        case ("GET", "/api/status"):
            return statusDown ? (503, ["ok": false, "error": "down"]) : (200, statusJSON())
        case ("POST", "/api/heartbeat"):
            return statusDown ? (503, ["ok": false, "error": "down"]) : (200, statusJSON())
        case ("POST", "/api/all"):
            let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            if (body["mode"] as? String) == "auto" {
                lock.lock(); defer { lock.unlock() }
                if failSetAutoRemaining > 0 { failSetAutoRemaining -= 1; return (500, ["ok": false, "error": "smc"]) }
                _mode = "auto"; return (200, ["ok": true])
            }
            if failSetMax { return (500, ["ok": false, "error": "smc write failed"]) }
            if !ignoreMax { mode = "manual" }
            return (200, ["ok": true])
        default: return (404, ["ok": false])
        }
    }
}

final class FakeSidecar: FanSidecar {
    var starts = 0, stops = 0
    func start(parentPID: Int32, autoURL: String) { starts += 1 }
    func stop() { stops += 1 }
}

private let proSupport = FanSupport.supported(.macBookPro)

final class FanModelPolicyTests: XCTestCase {
    func testAllowDenyTable() {
        // (hw.model, モデル名, 期待)
        let table: [(String?, String?, Bool)] = [
            ("Mac17,2", "MacBook Pro", true),
            ("MacBookPro16,1", "MacBook Pro", true),
            ("MacBookPro16,1", nil, true),              // Intel 形式の識別子は名前なしでも決まる
            ("Mac14,3", "Mac mini", true),
            ("Macmini9,1", nil, true),
            ("Mac13,1", "Mac Studio", true),
            ("Mac15,13", "MacBook Air", false),
            ("MacBookAir10,1", "MacBook Air", false),
            ("MacBookAir10,1", nil, false),
            ("Mac17,5", "iMac", false),
            ("iMac21,1", nil, false),
            ("Mac14,8", "Mac Pro", false),
            ("MacPro7,1", nil, false),
            ("Mac99,9", "Something New", false),       // 不明は対象外
            ("Mac17,2", nil, false),                    // 名前が読めない Apple Silicon は対象外
            ("Mac17,2", "", false),
            (nil, nil, false),
            ("MacBookAir10,1", "MacBook Pro", false),   // 食い違いは対象外
            ("MacBookPro16,1", "Mac mini", false),
            ("Mac17,2", "  macbook   pro ", true),      // 空白と大文字小文字は気にしない
        ]
        for (model, name, expected) in table {
            let r = FanModelPolicy.classify(hwModel: model, marketingName: name)
            XCTAssertEqual(r.isSupported, expected, "\(model ?? "nil") / \(name ?? "nil") → \(r)")
        }
        XCTAssertEqual(FanModelPolicy.classify(hwModel: "Mac13,1", marketingName: "MacBook Air"), .unsupported(FanModelPolicy.unsupportedMessage))
        XCTAssertEqual(FanModelPolicy.classify(hwModel: "Mac14,3", marketingName: "Mac mini"), .supported(.macMini))
        XCTAssertEqual(FanModelPolicy.classify(hwModel: "Mac13,1", marketingName: "Mac Studio"), .supported(.macStudio))
    }

    func testProfilerJSON() {
        let ok = Data(#"{"SPHardwareDataType":[{"machine_name":"MacBook Pro","machine_model":"Mac17,2"}]}"#.utf8)
        XCTAssertEqual(FanMachine.parseProfilerJSON(ok), "MacBook Pro")
        XCTAssertNil(FanMachine.parseProfilerJSON(Data("{}".utf8)))
        XCTAssertNil(FanMachine.parseProfilerJSON(Data("x".utf8)))
    }

    func testDetectThisMachineIsStable() {
        let a = FanMachine.detect(), b = FanMachine.detect()
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a.hwModel)
    }
}

final class FanStatusAndBackendTests: XCTestCase {
    func testParseStatus() throws {
        let json = #"{"ok":true,"fans":[{"index":0,"mode":"auto","minimumRPM":2317,"maximumRPM":6550,"targetRPM":2500,"actualRPM":2497}],"sensors":[{"key":"Tp01","celsius":51.5},{"key":"Te04","celsius":53},{"key":"TD23","celsius":127},{"key":"TB0T","celsius":32}]}"#
        let s = try FanStatus.parse(Data(json.utf8))
        XCTAssertEqual(s.fans.count, 1)
        XCTAssertEqual(s.fans[0].maximumRPM, 6550)
        XCTAssertTrue(s.allAutomatic)
        XCTAssertEqual(s.hottestCoreCelsius, 53)       // TD23(127)やバッテリーは上限監視に使わない
        XCTAssertThrowsError(try FanStatus.parse(Data("[]".utf8)))
        XCTAssertThrowsError(try FanStatus.parse(Data(#"{"ok":false,"error":"x"}"#.utf8)))
        XCTAssertThrowsError(try FanStatus.parse(Data(#"{"ok":true}"#.utf8)))
        let noFans = try FanStatus.parse(Data(#"{"ok":true,"fans":[]}"#.utf8))
        XCTAssertFalse(noFans.hasFans)
    }

    func testClientNoOriginAndBodies() throws {
        let svc = try FakeFanService()
        let b = HTTPFanBackend(kind: .bundledHelper, port: svc.port)
        _ = try b.status()
        try b.setMax()
        _ = try b.heartbeat()
        try b.setAuto()
        let reqs = svc.requests
        XCTAssertEqual(reqs.map { "\($0.method) \($0.path)" }, ["GET /api/status", "POST /api/all", "POST /api/heartbeat", "POST /api/all"])
        XCTAssertTrue(reqs.allSatisfy { $0.headers["origin"] == nil }, "Origin ヘッダを付けてはいけない")
        let maxBody = try JSONSerialization.jsonObject(with: reqs[1].body) as? [String: Any]
        XCTAssertEqual(maxBody?["mode"] as? String, "fixedPercent")
        XCTAssertEqual((maxBody?["percent"] as? NSNumber)?.intValue, 100)
        let autoBody = try JSONSerialization.jsonObject(with: reqs[3].body) as? [String: Any]
        XCTAssertEqual(autoBody?["mode"] as? String, "auto")
    }

    func testUserFanctlHeartbeatIsStatusGet() throws {
        let svc = try FakeFanService()
        let b = HTTPFanBackend(kind: .userFanctl, port: svc.port)
        _ = try b.heartbeat()
        XCTAssertEqual(svc.count("GET", "/api/status"), 1)
        XCTAssertEqual(svc.count("POST", "/api/heartbeat"), 0)
        XCTAssertFalse(b.supportsWatchdog)
        XCTAssertTrue(HTTPFanBackend(kind: .bundledHelper).supportsWatchdog)
        XCTAssertEqual(HTTPFanBackend(kind: .userFanctl).port, 1200)
        XCTAssertEqual(HTTPFanBackend(kind: .bundledHelper).port, 1201)
    }

    func testServerErrorAndUnreachable() throws {
        let svc = try FakeFanService()
        svc.failSetMax = true
        let b = HTTPFanBackend(kind: .bundledHelper, port: svc.port)
        XCTAssertThrowsError(try b.setMax()) { e in
            guard case FanError.server(let s, let m) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(s, 500); XCTAssertEqual(m, "smc write failed")
        }
        let closed = HTTPFanBackend(kind: .bundledHelper, port: 1, timeout: 1)
        XCTAssertThrowsError(try closed.status()) { e in
            guard case FanError.unreachable = e else { return XCTFail("\(e)") }
        }
    }

    func testResolverPrefersUserServiceThenBundled() throws {
        let user = try FakeFanService(), bundled = try FakeFanService()
        let u = HTTPFanBackend(kind: .userFanctl, port: user.port), h = HTTPFanBackend(kind: .bundledHelper, port: bundled.port)
        XCTAssertTrue(FanBackendResolver.resolve(candidates: [u, h])?.backend === u)
        user.statusDown = true
        XCTAssertTrue(FanBackendResolver.resolve(candidates: [u, h])?.backend === h)
        bundled.statusDown = true
        XCTAssertNil(FanBackendResolver.resolve(candidates: [u, h]))
    }

    func testAvailabilityTable() throws {
        let svc = try FakeFanService()
        let b = HTTPFanBackend(kind: .bundledHelper, port: svc.port)
        let ok = FanBackendResolver.resolve(candidates: [b])
        XCTAssertTrue(FanAvailability.evaluate(support: proSupport, resolved: ok).isAvailable)
        XCTAssertEqual(FanAvailability.evaluate(support: .unsupported("x"), resolved: ok), .unsupportedMachine)
        XCTAssertEqual(FanAvailability.evaluate(support: proSupport, resolved: nil), .serviceMissing)
        svc.fansCount = 0
        XCTAssertEqual(FanAvailability.evaluate(support: proSupport, resolved: FanBackendResolver.resolve(candidates: [b])), .noFan)
        XCTAssertEqual(FanAvailability.unsupportedMachine.reason, "この Mac は対象外です(MacBook Air など)")
        XCTAssertEqual(FanAvailability.serviceMissing.reason, "ファン制御サービスが見つかりません — 設定で有効にできます")
        XCTAssertNil(FanAvailability.available(backend: "x").reason)
    }
}

final class FanGuardTests: XCTestCase {
    private func make(_ svc: FakeFanService, enabled: Bool = true, support: FanSupport = proSupport, kind: HTTPFanBackend.Kind = .bundledHelper,
                      interval: TimeInterval = 60, sidecar: FanSidecar? = nil, events: EventBox? = nil) -> FanGuard {
        FanGuard(backend: HTTPFanBackend(kind: kind, port: svc.port), enabled: enabled, support: support, heartbeatInterval: interval,
                 sidecar: sidecar, onEvent: { events?.add($0) })
    }
    final class EventBox { private let l = NSLock(); private var e: [FanGuard.Event] = []
        func add(_ x: FanGuard.Event) { l.lock(); e.append(x); l.unlock() }
        var all: [FanGuard.Event] { l.lock(); defer { l.unlock() }; return e } }

    func testSuccessPath() throws {
        let svc = try FakeFanService(); let ev = EventBox()
        let g = make(svc, events: ev)
        XCTAssertEqual(g.engage(), .engaged(maximumRPM: 6550))
        XCTAssertEqual(svc.mode, "manual")
        XCTAssertEqual(g.state, .engaged)
        XCTAssertTrue(g.release(.finished))
        XCTAssertEqual(svc.mode, "auto")
        XCTAssertEqual(g.state, .idle)
        XCTAssertEqual(ev.all, [.engaged(maximumRPM: 6550), .released(.finished)])
    }

    func testRepeatedEngageIsIdempotent() throws {
        let svc = try FakeFanService()
        let g = make(svc)
        g.engage(); g.engage(); g.engage()
        XCTAssertEqual(svc.requests.filter { $0.path == "/api/all" }.count, 1)
        g.release(); g.release()   // 2 回目は何もしない
        XCTAssertEqual(svc.autoPosts(), 1)
        XCTAssertEqual(svc.mode, "auto")
    }

    func testSkippedWhenDisabledUnsupportedOrDown() throws {
        let svc = try FakeFanService()
        guard case .skipped = make(svc, enabled: false).engage() else { return XCTFail("disabled") }
        guard case .skipped = make(svc, support: .unsupported("x")).engage() else { return XCTFail("unsupported") }
        XCTAssertEqual(svc.count("POST", "/api/all"), 0)
        XCTAssertEqual(svc.mode, "auto")
        svc.statusDown = true
        guard case .skipped = make(svc).engage() else { return XCTFail("down") }
        XCTAssertEqual(svc.count("POST", "/api/all"), 0)
        svc.statusDown = false; svc.fansCount = 0
        guard case .skipped = make(svc).engage() else { return XCTFail("nofan") }
        XCTAssertEqual(svc.count("POST", "/api/all"), 0)
        let dead = FanGuard(backend: HTTPFanBackend(kind: .bundledHelper, port: 1, timeout: 1), enabled: true, support: proSupport)
        guard case .skipped = dead.engage() else { return XCTFail("closed port") }
    }

    func testServerErrorOnMaxLeavesAuto() throws {
        let svc = try FakeFanService(); svc.failSetMax = true
        let g = make(svc)
        guard case .failed(let msg) = g.engage() else { return XCTFail("expected failed") }
        XCTAssertTrue(msg.contains("smc write failed"))
        XCTAssertEqual(g.state, .idle)
        XCTAssertEqual(svc.mode, "auto")
    }

    func testNotManualAfterMaxIsRolledBack() throws {
        let svc = try FakeFanService(); svc.ignoreMax = true
        let g = make(svc)
        guard case .failed = g.engage() else { return XCTFail("expected failed") }
        XCTAssertEqual(g.state, .idle)
        XCTAssertEqual(svc.mode, "auto")
    }

    func testCancelMidExport() throws {
        let svc = try FakeFanService(); let ev = EventBox()
        let g = make(svc, events: ev)
        g.engage()
        XCTAssertEqual(svc.mode, "manual")
        XCTAssertTrue(g.release(.cancelled))
        XCTAssertEqual(svc.mode, "auto")
        XCTAssertEqual(ev.all.last, .released(.cancelled))
    }

    func testCrashSimulationDeinitRestoresAuto() throws {
        let svc = try FakeFanService()
        var g: FanGuard? = make(svc)
        g?.engage()
        XCTAssertEqual(svc.mode, "manual")
        g = nil                       // 解放漏れ・クラッシュ相当
        XCTAssertEqual(svc.mode, "auto")
    }

    func testRegistryReleaseAll() throws {
        let svc = try FakeFanService()
        let g = make(svc)
        g.engage()
        XCTAssertGreaterThanOrEqual(FanGuardRegistry.shared.activeCount, 1)
        XCTAssertTrue(FanGuardRegistry.shared.releaseAll(.appQuit))
        XCTAssertEqual(svc.mode, "auto")
        XCTAssertEqual(g.state, .idle)
    }

    func testReleaseRetriesThenSucceeds() throws {
        let svc = try FakeFanService()
        let g = make(svc)
        g.engage()
        svc.failSetAutoRemaining = 2
        XCTAssertTrue(g.release())
        XCTAssertEqual(svc.mode, "auto")
    }

    func testReleaseFailureKeepsGuardAndRetriesOnHeartbeat() throws {
        let svc = try FakeFanService()
        let g = make(svc, interval: 0.05)
        g.engage()
        svc.failSetAutoRemaining = 3
        XCTAssertFalse(g.release())
        XCTAssertEqual(g.state, .releaseFailed)
        let deadline = Date().addingTimeInterval(3)
        while g.state != .idle && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(g.state, .idle)
        XCTAssertEqual(svc.mode, "auto")
    }

    func testHeartbeatsWhileEngaged() throws {
        let svc = try FakeFanService()
        let g = make(svc, interval: 0.05)
        g.engage()
        Thread.sleep(forTimeInterval: 0.5)
        g.release()
        XCTAssertGreaterThanOrEqual(svc.count("POST", "/api/heartbeat"), 3)
        let after = svc.count("POST", "/api/heartbeat")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(svc.count("POST", "/api/heartbeat"), after, "解放後は heartbeat を送らない")
    }

    func testOverTemperatureReleasesAndLatches() throws {
        let svc = try FakeFanService(); let ev = EventBox()
        let g = make(svc, interval: 0.05, events: ev)
        g.engage()
        svc.temperature = 96
        let deadline = Date().addingTimeInterval(3)
        while g.state != .idle && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(g.state, .idle)
        XCTAssertEqual(svc.mode, "auto")
        XCTAssertTrue(ev.all.contains(.released(.overTemperature)))
        XCTAssertTrue(ev.all.contains { if case .notice(let m) = $0 { return m.contains("95") } else { return false } })
        svc.temperature = 40
        guard case .skipped = g.engage() else { return XCTFail("温度で外したあとは再度最大にしない") }
        XCTAssertEqual(svc.mode, "auto")
    }

    func testRefusesToEngageWhenAlreadyHot() throws {
        let svc = try FakeFanService(); svc.temperature = 97
        guard case .skipped = make(svc).engage() else { return XCTFail() }
        XCTAssertEqual(svc.count("POST", "/api/all"), 0)
    }

    func testSidecarOnlyForBackendWithoutWatchdog() throws {
        let svc = try FakeFanService()
        let side = FakeSidecar()
        let a = make(svc, kind: .userFanctl, sidecar: side)
        a.engage(); a.release()
        XCTAssertEqual(side.starts, 1)
        XCTAssertGreaterThanOrEqual(side.stops, 1)
        let side2 = FakeSidecar()
        let b = make(svc, kind: .bundledHelper, sidecar: side2)
        b.engage(); b.release()
        XCTAssertEqual(side2.starts, 0)
    }

    func testSidecarStoppedWhenMaxFails() throws {
        let svc = try FakeFanService(); svc.failSetMax = true
        let side = FakeSidecar()
        make(svc, kind: .userFanctl, sidecar: side).engage()
        XCTAssertEqual(side.starts, 1)
        XCTAssertGreaterThanOrEqual(side.stops, 1)
    }

    /// 本物の見張り: 親(ここでは sleep)が消えたら、別プロセスのシェルが自動に戻す(kill -9 相当)。
    func testRealSidecarRestoresAutoWhenParentDies() throws {
        let svc = try FakeFanService()
        svc.mode = "manual"
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["60"]
        try parent.run()
        let side = ShellFanSidecar()
        side.start(parentPID: parent.processIdentifier, autoURL: "http://127.0.0.1:\(svc.port)/api/all")
        defer { side.stop(); parent.terminate() }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(svc.mode, "manual", "親が生きている間は何もしない")
        kill(parent.processIdentifier, SIGKILL)
        let deadline = Date().addingTimeInterval(6)
        while svc.mode != "auto" && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(svc.mode, "auto")
        XCTAssertTrue(svc.requests.allSatisfy { $0.headers["origin"] == nil })
    }

    func testRealSidecarStoppedBeforeParentDiesDoesNothing() throws {
        let svc = try FakeFanService()
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["60"]
        try parent.run()
        let side = ShellFanSidecar()
        side.start(parentPID: parent.processIdentifier, autoURL: "http://127.0.0.1:\(svc.port)/api/all")
        side.stop()
        kill(parent.processIdentifier, SIGKILL)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(svc.autoPosts(), 0)
        parent.waitUntilExit()
    }

    func testSignalHandlerCallsRelease() throws {
        let svc = try FakeFanService()
        let g = make(svc)
        g.engage()
        let handlers = FanSignalHandlers()
        let done = expectation(description: "signal")
        handlers.install(signals: [SIGUSR2], reraise: false) {
            FanGuardRegistry.shared.releaseAll(.signal)
            done.fulfill()
        }
        kill(getpid(), SIGUSR2)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(svc.mode, "auto")
        handlers.uninstall(signals: [SIGUSR2])
    }
}

final class FanInstallerScriptTests: XCTestCase {
    func testShellQuote() {
        XCTAssertEqual(FanWatchdogScript.shellQuote("a b"), "'a b'")
        XCTAssertEqual(FanWatchdogScript.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(FanWatchdogScript.shellQuote("$(rm -rf /)"), "'$(rm -rf /)'")
    }

    func testInstallScriptQuotesPathsWithSpacesAndJapanese() {
        let s = FanHelperInstaller.installScript(helperSource: "/Applications/Movie Cut.app/Contents/Helpers/moviecut-fanhelper",
                                                 plistSource: "/Users/ゆう/it's here/com.moviecut.fanhelper.plist")
        XCTAssertTrue(s.contains("'/Applications/Movie Cut.app/Contents/Helpers/moviecut-fanhelper'"))
        XCTAssertTrue(s.contains("'/Users/ゆう/it'\\''s here/com.moviecut.fanhelper.plist'"))
        XCTAssertTrue(s.hasPrefix("set -e"))
        let lines = s.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("/bin/launchctl bootstrap system '/Library/LaunchDaemons/com.moviecut.fanhelper.plist'"))
        XCTAssertTrue(s.contains("/usr/local/libexec/moviecut-fanhelper"))
        XCTAssertTrue(s.contains("kickstart -k system/com.moviecut.fanhelper"))
        // bootstrap の前に bootout(再インストール)があること
        XCTAssertLessThan(s.range(of: "bootout")!.lowerBound, s.range(of: "bootstrap")!.lowerBound)
    }

    func testUninstallScript() {
        let s = FanHelperInstaller.uninstallScript()
        XCTAssertTrue(s.contains("bootout system/com.moviecut.fanhelper"))
        XCTAssertTrue(s.contains("rm -f '/Library/LaunchDaemons/com.moviecut.fanhelper.plist' '/usr/local/libexec/moviecut-fanhelper'"))
    }

    func testAppleScriptEscape() {
        XCTAssertEqual(FanHelperInstaller.appleScriptEscape(#"a"b\c"#), #"a\"b\\c"#)
        XCTAssertEqual(FanHelperInstaller.appleScriptEscape("x\ny"), "x\\ny")
        let script = FanHelperInstaller.appleScript(shell: "echo \"hi\"\nls")
        XCTAssertTrue(script.hasPrefix("do shell script \"echo \\\"hi\\\"\\nls\""))
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
    }

    func testShellScriptsAreValidSyntax() throws {
        let scripts = [
            FanHelperInstaller.installScript(helperSource: "/tmp/a b/h", plistSource: "/tmp/it's/p.plist"),
            FanHelperInstaller.uninstallScript(),
            FanWatchdogScript.make(parentPID: 123, autoURL: "http://127.0.0.1:1200/api/all"),
        ]
        for s in scripts {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-n", "-c", s]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, s)
        }
    }

    func testWatchdogScript() {
        let s = FanWatchdogScript.make(parentPID: 4242, autoURL: "http://127.0.0.1:1200/api/all")
        XCTAssertTrue(s.contains("PID=4242"))
        XCTAssertTrue(s.contains("'http://127.0.0.1:1200/api/all'"))
        XCTAssertTrue(s.contains(#"'{"mode":"auto"}'"#))
        XCTAssertFalse(s.lowercased().contains("origin"))
    }
}
