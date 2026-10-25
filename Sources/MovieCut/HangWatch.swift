import Foundation

/// 主スレッドの固まり(ストール)の記録。時刻は秒(単調時計)。外から注入できるので単体テストできる。
struct StallTracker {
    struct Stall: Equatable { var start: Double; var duration: Double }
    /// これより長く返事がなければストールとして数える(秒)。
    var threshold: Double = 0.100
    /// ストール中に「重い」として stack を取る時間(秒)。
    var sampleAfter: Double = 0.300
    private(set) var stalls: [Stall] = []
    /// ping を送った時刻(返事待ち)。nil なら待っていない。
    private(set) var pendingSince: Double?
    private var sampledThisStall = false

    init(threshold: Double = 0.100, sampleAfter: Double = 0.300) { self.threshold = threshold; self.sampleAfter = sampleAfter }

    mutating func pinged(at t: Double) { pendingSince = t; sampledThisStall = false }

    /// 返事が来た。長ければストールとして記録して返す。
    @discardableResult
    mutating func answered(at t: Double) -> Stall? {
        defer { pendingSince = nil }
        guard let s = pendingSince else { return nil }
        let d = t - s
        guard d > threshold else { return nil }
        let st = Stall(start: s, duration: d)
        stalls.append(st)
        return st
    }

    /// 返事待ちが `sampleAfter` を超えた最初の 1 回だけ true(そのとき `sample` を走らせる)。
    mutating func shouldSample(now t: Double) -> Bool {
        guard let s = pendingSince, !sampledThisStall, t - s >= sampleAfter else { return false }
        sampledThisStall = true
        return true
    }

    var summary: String {
        guard !stalls.isEmpty else { return "stalls=0" }
        let total = stalls.reduce(0) { $0 + $1.duration }
        let mx = stalls.map(\.duration).max() ?? 0
        return String(format: "stalls=%d max=%.0fms total=%.0fms", stalls.count, mx * 1000, total * 1000)
    }
}

/// `MC_DEBUG_HANGWATCH=1`: 背景スレッドが 25ms ごとに主キューへ ping を送り、100ms を超える返事の遅れを記録して出す。
/// 300ms 返事がなければ `sample <pid> 1 -file <dir>/hang-<n>.txt` を 1 回走らせる(`MC_DEBUG_HANGWATCH_SAMPLE=<dir>`)。
/// 局面ごとの集計は `phase("名前")` で区切る。終了時(`exit`/`terminate`)に全体と局面別の要約を出す。
final class HangWatch: @unchecked Sendable {
    static let shared = HangWatch()
    private let lock = NSLock()
    private var tracker = StallTracker()
    private var perPhase: [(name: String, tracker: StallTracker)] = []
    private var phaseName = "start"
    private var phaseTracker = StallTracker()
    private var running = false
    private var sampleDir: String?
    private var sampleCount = 0
    private let pid = ProcessInfo.processInfo.processIdentifier
    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    static var enabled: Bool { ProcessInfo.processInfo.environment["MC_DEBUG_HANGWATCH"] != nil }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        sampleDir = ProcessInfo.processInfo.environment["MC_DEBUG_HANGWATCH_SAMPLE"]
        if let d = sampleDir { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let t = Thread { [self] in loop() }
        t.name = "hangwatch"; t.qualityOfService = .userInteractive
        t.start()
    }

    /// 局面を切り替える(それまでの局面の集計を閉じる)。
    func phase(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        perPhase.append((phaseName, phaseTracker))
        phaseName = name; phaseTracker = StallTracker()
    }

    private func loop() {
        while true {
            let answered = DispatchSemaphore(value: 0)
            lock.lock(); tracker.pinged(at: now()); phaseTracker.pinged(at: now()); lock.unlock()
            DispatchQueue.main.async { answered.signal() }
            while answered.wait(timeout: .now() + 0.025) == .timedOut {
                lock.lock()
                let doSample = tracker.shouldSample(now: now())
                let n = doSample ? { sampleCount += 1; return sampleCount }() : 0
                let dir = sampleDir
                lock.unlock()
                if doSample, let dir {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    p.arguments = [String(pid), "1", "-file", "\(dir)/hang-\(n).txt"]
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                    try? p.run()
                }
            }
            lock.lock()
            let t = now()
            if let s = tracker.answered(at: t) {
                _ = phaseTracker.answered(at: t)
                let ph = phaseName
                lock.unlock()
                DebugHooks.out(String(format: "hang: %.0fms stall in phase \"%@\"", s.duration * 1000, ph))
            } else { _ = phaseTracker.answered(at: t); lock.unlock() }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    func printSummary() {
        lock.lock(); defer { lock.unlock() }
        perPhase.append((phaseName, phaseTracker)); phaseName = "end"; phaseTracker = StallTracker()
        DebugHooks.out("hang: summary total \(tracker.summary)")
        for (n, t) in perPhase { DebugHooks.out("hang: phase \(n): \(t.summary)") }
    }
}
