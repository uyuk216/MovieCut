import XCTest
import SwiftUI
import MovieCutCore
@testable import MovieCut

/// メモリ上のファン(HTTP を使わない)。FanGuard を通して手動 / 自動が切り替わる。
final class StubFanBackend: FanBackend {
    private let lock = NSLock()
    private var _manual = false
    private var _log: [String] = []
    var label: String { "stub" }
    var port: Int { 0 }
    var baseURL: URL { URL(string: "http://127.0.0.1:0")! }
    var supportsWatchdog: Bool { true }
    var isManual: Bool { lock.lock(); defer { lock.unlock() }; return _manual }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    private func snapshot() -> FanStatus {
        FanStatus(fans: [FanReading(index: 0, actualRPM: 2500, minimumRPM: 2317, maximumRPM: 6550, targetRPM: _manual ? 6550 : 2500, mode: _manual ? "manual" : "auto")], hottestCoreCelsius: 55)
    }
    func status() throws -> FanStatus { lock.lock(); defer { lock.unlock() }; return snapshot() }
    func setMax() throws { lock.lock(); _manual = true; _log.append("max"); lock.unlock() }
    func setAuto() throws { lock.lock(); _manual = false; _log.append("auto"); lock.unlock() }
    func heartbeat() throws -> FanStatus { try status() }
}

@MainActor
final class FanAppTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "moviecut.fan.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func service(_ defaults: UserDefaults, backend: StubFanBackend, availability: FanAvailability = .available(backend: "stub"),
                         support: FanSupport = .supported(.macBookPro)) -> FanService {
        let s = FanService(defaults: defaults)
        s.onChange = {}
        s.prepare = { enabled, onEvent in
            guard availability.isAvailable else { return (availability, nil) }
            return (availability, FanGuard(backend: backend, enabled: enabled, support: support, heartbeatInterval: 60, onEvent: onEvent))
        }
        return s
    }

    private func waitFor(_ cond: @autoclosure () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: メニューの仕様表

    func testMenuSpecs() {
        var s = MenuState()
        // まだ調べていない / 対象外: チェックは押せない。理由はヒントに出る
        XCTAssertFalse(AppMenuSpec.fanMaxToggle(s).enabled)
        s.fanReason = FanModelPolicy.unsupportedMessage
        XCTAssertEqual(AppMenuSpec.fanMaxToggle(s).displayTitle, "書き出し中はファンを最大にする  (この Mac は対象外です(MacBook Air など))")
        s.fanReason = FanAvailability.serviceMissing.reason
        XCTAssertTrue(AppMenuSpec.fanMaxToggle(s).displayTitle.contains("ファン制御サービスが見つかりません — 設定で有効にできます"))
        // 使える
        s.fanAvailable = true; s.fanReason = nil
        XCTAssertTrue(AppMenuSpec.fanMaxToggle(s).enabled)
        XCTAssertEqual(AppMenuSpec.fanMaxToggle(s).checked, false)
        s.fanEnabled = true
        XCTAssertEqual(AppMenuSpec.fanMaxToggle(s).checked, true)
        XCTAssertNil(AppMenuSpec.fanMaxToggle(s).hint)
        // インストール / 削除
        XCTAssertFalse(AppMenuSpec.fanInstall(s).enabled); XCTAssertFalse(AppMenuSpec.fanUninstall(s).enabled)
        s.fanCanInstall = true
        XCTAssertTrue(AppMenuSpec.fanInstall(s).enabled)
        s.fanCanInstall = false; s.fanInstalled = true
        XCTAssertTrue(AppMenuSpec.fanUninstall(s).enabled)
        XCTAssertEqual(AppMenuSpec.fanInstall(s).title, "ファン制御を有効にする…")
        XCTAssertEqual(AppMenuSpec.fanUninstall(s).title, "ファン制御を無効にする…")
        // ショートカットは持たない(重複テストは MenuTests が all() で見る)
        XCTAssertNil(AppMenuSpec.fanMaxToggle(s).shortcut); XCTAssertNil(AppMenuSpec.fanInstall(s).shortcut)
        let all = AppMenuSpec.all(s).map(\.command)
        XCTAssertTrue(all.contains(.fanMaxToggle) && all.contains(.fanInstall) && all.contains(.fanUninstall))
        let shortcuts = AppMenuSpec.all(s).compactMap(\.shortcut)
        XCTAssertEqual(shortcuts.count, Set(shortcuts).count)
    }

    // MARK: 設定

    func testSettingPersistsAndRequiresAvailability() async {
        let d = suite()
        let s = service(d, backend: StubFanBackend())
        s.setEnabled(true)
        XCTAssertFalse(s.enabled, "調べる前は、オンにできない")
        s.refresh(); await waitFor(s.availability != nil)
        XCTAssertTrue(s.isAvailable)
        s.setEnabled(true)
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(d.bool(forKey: FanService.defaultsKey))
        let again = FanService(defaults: d)
        XCTAssertTrue(again.enabled, "アプリ全体の設定として残る")
        s.setEnabled(false)
        XCTAssertFalse(d.bool(forKey: FanService.defaultsKey))
    }

    func testUnavailableShowsReasonAndTurnsOff() async {
        let d = suite()
        d.set(true, forKey: FanService.defaultsKey)
        let s = service(d, backend: StubFanBackend(), availability: .unsupportedMachine)
        XCTAssertTrue(s.enabled)
        s.refresh(); await waitFor(s.availability != nil)
        XCTAssertFalse(s.isAvailable)
        XCTAssertEqual(s.reason, "この Mac は対象外です(MacBook Air など)")
        XCTAssertFalse(s.enabled, "使えなくなったらオフに戻す")
        XCTAssertFalse(s.machineSupported)
        let missing = service(suite(), backend: StubFanBackend(), availability: .serviceMissing)
        missing.refresh(); await waitFor(missing.availability != nil)
        XCTAssertEqual(missing.reason, "ファン制御サービスが見つかりません — 設定で有効にできます")
        XCTAssertTrue(missing.machineSupported)
        missing.setEnabled(true)
        XCTAssertFalse(missing.enabled)
    }

    // MARK: 書き出しの前後

    func testBeginAndEndExportStatusLines() async {
        let b = StubFanBackend()
        let s = service(suite(), backend: b)
        s.refresh(); await waitFor(s.availability != nil)
        s.setEnabled(true)
        await s.beginExport()
        XCTAssertEqual(s.statusLine, "ファン: 最大(6550 rpm)")
        XCTAssertTrue(b.isManual)
        await s.endExport(.finished)
        XCTAssertEqual(s.statusLine, "ファン: 自動")
        XCTAssertFalse(b.isManual)
    }

    func testDisabledDoesNothing() async {
        let b = StubFanBackend()
        let s = service(suite(), backend: b)
        s.refresh(); await waitFor(s.availability != nil)
        await s.beginExport()
        XCTAssertEqual(s.statusLine, "")
        XCTAssertTrue(b.log.isEmpty)
        await s.endExport(.finished)
        XCTAssertEqual(s.statusLine, "")
    }

    func testUnsupportedSupportSkips() async {
        let b = StubFanBackend()
        let s = service(suite(), backend: b, support: .unsupported("x"))
        s.refresh(); await waitFor(s.availability != nil)
        s.setEnabled(true)
        await s.beginExport()
        XCTAssertFalse(b.isManual)
        XCTAssertEqual(s.statusLine, "")
    }

    // MARK: 本物の書き出し(モデルの経路)

    private func exportingModel() async -> ProjectModel {
        let m = ProjectModel(project: .new())
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        m.notices = OneTimeNotices()
        m.applyVideoSize(320, 180)
        await m.generateVoices(from: "霊夢: こんにちは")
        return m
    }

    func testExportEngagesDuringAndRestoresAfter() async {
        let saved = AppServices.fan
        defer { AppServices.fan = saved }
        let b = StubFanBackend()
        let s = service(suite(), backend: b)
        s.refresh(); await waitFor(s.availability != nil)
        s.setEnabled(true)
        AppServices.fan = s
        let m = await exportingModel()
        var sawMax = false, sawLine = false
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mc-fan-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if m.isExporting && b.isManual { sawMax = true }
                if s.statusLine == "ファン: 最大(6550 rpm)" { sawLine = true }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let outcome = await m.runExport(to: out)
        watcher.cancel()
        guard case .success = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(sawMax && sawLine, "書き出し中は最大")
        XCTAssertFalse(b.isManual, "終わったら自動")
        XCTAssertEqual(s.statusLine, "ファン: 自動")
        XCTAssertEqual(b.log, ["max", "auto"])
    }

    func testCancelledExportRestoresAuto() async {
        let saved = AppServices.fan
        defer { AppServices.fan = saved }
        let b = StubFanBackend()
        let s = service(suite(), backend: b)
        s.refresh(); await waitFor(s.availability != nil)
        s.setEnabled(true)
        AppServices.fan = s
        let m = await exportingModel()
        m.applyVideoSize(1920, 1080)       // キャンセルが間に合う長さにする
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mc-fan-c-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let t = Task { @MainActor in await m.runExport(to: out) }
        await waitFor(b.isManual)
        XCTAssertTrue(b.isManual)
        m.cancelExport()
        let outcome = await t.value
        switch outcome {
        case .cancelled, .success: break          // 速すぎて終わっていても、自動に戻っていればよい
        case .failure(let e): XCTFail("\(e)")
        }
        XCTAssertFalse(b.isManual)
        XCTAssertEqual(s.statusLine, "ファン: 自動")
    }
}
