import XCTest
@testable import MovieCutCore

/// サイドカー取得の切り離し(レビューブロッカー修正の回帰): スケジュールは即座に返り、処理の遅さ・失敗が呼び出し元に影響しない。
final class SidecarSchedulingTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-sched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// NSLock で守る単純なフラグ。
    final class Flag {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    func testScheduleReturnsImmediatelyAndRunsLater() async {
        let flag = Flag()
        let start = Date()
        let task = RealVoiceProvider.scheduleSidecar {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            flag.set()
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "スケジュール自体は処理を待たない")
        XCTAssertFalse(flag.isSet)
        await task.value
        XCTAssertTrue(flag.isSet, "切り離した処理は後から実行される")
    }

    func testFailingOperationDoesNotPropagate() async {
        let flag = Flag()
        let task = RealVoiceProvider.scheduleSidecar {
            // 取得失敗相当: 中で throw しても try? で受ける形(本番の moraTimeline 取得と同じ受��方)
            let fetch: () async throws -> Void = { throw VoiceError.message("dummy") }
            _ = try? await fetch()
            flag.set()
        }
        await task.value
        XCTAssertTrue(flag.isSet)
    }

    func testDelayedSidecarWriteArrivesAfterSchedule() async throws {
        let wav = tmp.appendingPathComponent("v.wav")
        try Data().write(to: wav)
        let sidecar = VoicevoxMora.sidecarURL(forWav: wav.path)
        let segs = [TimedViseme(vowel: .a, start: 0, end: 0.2)]
        let task = RealVoiceProvider.scheduleSidecar {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let data = VoicevoxMora.encodeSidecar(segs) { try? data.write(to: sidecar, options: .atomic) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "スケジュール直後はまだ書かれていない(返却を待たせない)")
        await task.value
        let written = try XCTUnwrap(try? Data(contentsOf: sidecar))
        XCTAssertEqual(VoicevoxMora.decodeSidecar(written), segs)
    }
}
