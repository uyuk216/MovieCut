import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

// MARK: - 偽物

@MainActor
final class FakePresenter: StatusItemPresenting {
    var isVisible = false
    var buttonTitle = ""
    var onAction: ((StatusAction) -> Void)?
    var onMenuOpen: (() -> Void)?
    var onMenuClose: (() -> Void)?
    private(set) var renders: [[StatusMenuEntry]] = []
    var last: [StatusMenuEntry] { renders.last ?? [] }
    func render(_ entries: [StatusMenuEntry]) { renders.append(entries) }
}

final class FakeProbe: EngineProbing, @unchecked Sendable {
    var alive = false
    var startedByUs = false
    var isInstalled = true
    private(set) var calls = 0
    func isAlive() async -> Bool { calls += 1; return alive }
}

@MainActor
final class FakeActions: StatusActionHandling {
    var performed: [StatusAction] = []
    func perform(_ action: StatusAction) { performed.append(action) }
}

/// M7: メニューバーの状態アイコン(状態 → メニューの中身・書き出しの進み具合・VOICEVOX の確認・表示の切り替え)。
@MainActor
final class StatusBarTests: XCTestCase {
    private var presenter: FakePresenter!
    private var export: ExportStatusCenter!
    private var probe: FakeProbe!
    private var actions: FakeActions!
    private var prefs: MemoryStatusPreference!
    private var recents: [URL] = []
    private var controller: MenuBarStatusController!

    override func setUp() async throws {
        presenter = FakePresenter(); export = ExportStatusCenter(); probe = FakeProbe(); actions = FakeActions(); prefs = MemoryStatusPreference(true)
        recents = []
        controller = MenuBarStatusController(presenter: presenter, export: export, probe: probe, recentURLs: { [unowned self] in self.recents }, preferences: prefs, handler: actions)
    }

    private func titles(_ e: [StatusMenuEntry]) -> [String] {
        e.compactMap { if case .title(let t) = $0 { return t } else { return nil } }
    }
    private func action(_ e: [StatusMenuEntry], _ a: StatusAction) -> (title: String, enabled: Bool)? {
        for x in e { if case .action(let t, let act, let en) = x, act == a { return (t, en) } }
        return nil
    }

    // MARK: メニューの中身

    func testIdleMenuContents() {
        let e = StatusMenuBuilder.entries(for: StatusBarState())
        XCTAssertEqual(titles(e), ["Movie Cut", "書き出し: なし", "VOICEVOX: 停止中"])
        XCTAssertNil(action(e, .cancelExport), "書き出していないときはキャンセルを出さない")
        XCTAssertEqual(action(e, .startEngine)?.title, "起動")
        XCTAssertTrue(action(e, .startEngine)!.enabled)
        XCTAssertFalse(action(e, .stopEngine)!.enabled)
        XCTAssertEqual(action(e, .newDocument)?.title, "新規")
        XCTAssertEqual(action(e, .openDocument)?.title, "開く…")
        XCTAssertEqual(action(e, .showApp)?.title, "Movie Cut を表示")
        XCTAssertEqual(action(e, .quit)?.title, "終了")
        XCTAssertTrue(e.contains(.recents([])))
        XCTAssertEqual(e.first, .title("Movie Cut"))
    }

    func testExportLineAndCancelItem() {
        let snap = ExportStatusCenter.Snapshot(fileName: "動画-short.mp4", fraction: 0.374)
        let e = StatusMenuBuilder.entries(for: StatusBarState(export: snap))
        XCTAssertEqual(titles(e)[1], "書き出し中 37% — 動画-short.mp4")
        XCTAssertEqual(action(e, .cancelExport)?.title, "キャンセル")
        XCTAssertTrue(action(e, .cancelExport)!.enabled)
        XCTAssertEqual(StatusMenuBuilder.buttonTitle(snap), " 37%")
        XCTAssertEqual(StatusMenuBuilder.buttonTitle(nil), "")
        XCTAssertEqual(StatusMenuBuilder.percent(1.7), 100)
        XCTAssertEqual(StatusMenuBuilder.percent(-1), 0)
        XCTAssertEqual(StatusMenuBuilder.percent(.nan), 0)
        XCTAssertEqual(StatusMenuBuilder.percent(0.995), 100)
    }

    func testVoicevoxLinesAndWhoMayStopIt() {
        func entries(_ s: EngineRunState, installed: Bool = true) -> [StatusMenuEntry] { StatusMenuBuilder.entries(for: StatusBarState(engine: s, engineInstalled: installed)) }
        let ours = entries(.runningByUs)
        XCTAssertTrue(titles(ours).contains("VOICEVOX: 起動中（このアプリが起動）"))
        XCTAssertFalse(action(ours, .startEngine)!.enabled)
        XCTAssertTrue(action(ours, .stopEngine)!.enabled, "自分で起動したものは止められる")
        let other = entries(.runningByOther)
        XCTAssertTrue(titles(other).contains("VOICEVOX: 起動中（ほかのアプリが起動）"))
        XCTAssertFalse(action(other, .stopEngine)!.enabled, "ほかのアプリが起動したものは止めない")
        XCTAssertTrue(titles(other).contains { $0.contains(StatusMenuBuilder.stopExplanation) }, "止められない理由を添える")
        XCTAssertFalse(action(other, .startEngine)!.enabled)
        let stopped = entries(.stopped)
        XCTAssertTrue(titles(stopped).contains("VOICEVOX: 停止中"))
        XCTAssertTrue(action(stopped, .startEngine)!.enabled)
        XCTAssertFalse(action(stopped, .stopEngine)!.enabled)
        let missing = entries(.stopped, installed: false)
        XCTAssertFalse(action(missing, .startEngine)!.enabled, "VOICEVOX が無ければ起動できない")
    }

    func testRecentsComeFromTheDocumentController() {
        recents = [URL(fileURLWithPath: "/a/動画1.mcpjc"), URL(fileURLWithPath: "/b/old.ymproj")]
        controller.start()
        XCTAssertEqual(presenter.last.compactMap { if case .recents(let r) = $0 { return r.map(\.name) } else { return nil } }.first, ["動画1", "old"])
        recents = [URL(fileURLWithPath: "/c/new.mcpjc")]
        controller.menuWillOpen()
        XCTAssertEqual(presenter.last.compactMap { if case .recents(let r) = $0 { return r.map(\.name) } else { return nil } }.first, ["new"], "開くたびに読み直す")
        controller.menuDidClose()
    }

    func testLinesForDebugDump() {
        let l = StatusMenuBuilder.lines(StatusMenuBuilder.entries(for: StatusBarState(export: .init(fileName: "x.mp4", fraction: 0.5), engine: .runningByUs, recents: [RecentProject(name: "P", url: URL(fileURLWithPath: "/p.mcpjc"))])))
        XCTAssertEqual(l.first, "[ラベル] Movie Cut")
        XCTAssertTrue(l.contains("[ラベル] 書き出し中 50% — x.mp4"))
        XCTAssertTrue(l.contains("最近開いたプロジェクト ▸"))
        XCTAssertTrue(l.contains("    P  → openRecent"))
    }

    // MARK: 書き出しの進み具合 → アイコン

    func testExportProgressUpdatesMenuAndButtonTitleLive() {
        controller.start()
        XCTAssertEqual(presenter.buttonTitle, "")
        let owner = NSObject()
        export.begin(owner: owner, fileName: "a.mp4", cancel: {})
        XCTAssertEqual(presenter.buttonTitle, " 0%")
        XCTAssertEqual(titles(presenter.last)[1], "書き出し中 0% — a.mp4")
        export.update(owner: owner, fraction: 0.37)
        XCTAssertEqual(presenter.buttonTitle, " 37%")
        XCTAssertEqual(titles(presenter.last)[1], "書き出し中 37% — a.mp4")
        XCTAssertNotNil(action(presenter.last, .cancelExport))
        export.end(owner: owner)
        XCTAssertEqual(presenter.buttonTitle, "")
        XCTAssertEqual(titles(presenter.last)[1], "書き出し: なし")
        XCTAssertNil(action(presenter.last, .cancelExport))
    }

    func testStartPicksUpAnExportAlreadyRunning() {
        let owner = NSObject()
        export.begin(owner: owner, fileName: "early.mp4", cancel: {})
        export.update(owner: owner, fraction: 0.5)
        controller.start()
        XCTAssertEqual(titles(presenter.last)[1], "書き出し中 50% — early.mp4")
        export.end(owner: owner)
    }

    func testCancelItemCancelsTheRunningExportOnly() {
        controller.start()
        var cancelled: [String] = []
        let a = NSObject(), b = NSObject()
        export.begin(owner: a, fileName: "a.mp4", cancel: { cancelled.append("a") })
        export.begin(owner: b, fileName: "b.mp4", cancel: { cancelled.append("b") })
        XCTAssertEqual(export.current?.fileName, "b.mp4", "一番新しく始めた書き出しを見せる")
        presenter.onAction?(.cancelExport)
        XCTAssertEqual(cancelled, ["b"])
        XCTAssertTrue(actions.performed.isEmpty, "キャンセルは書き出しの共有へ。ほかの処理には回さない")
        export.end(owner: b)
        XCTAssertEqual(export.current?.fileName, "a.mp4")
        export.end(owner: a)
        presenter.onAction?(.cancelExport)    // 何も無いときは何も起きない
        XCTAssertEqual(cancelled, ["b"])
    }

    func testExportCenterIgnoresUnknownOwnersAndRepeatedFractions() {
        var count = 0
        export.observe { _ in count += 1 }
        let o = NSObject()
        export.update(owner: o, fraction: 0.4)       // 始まっていない
        export.end(owner: o)
        XCTAssertEqual(count, 0)
        export.begin(owner: o, fileName: "x", cancel: {})
        export.update(owner: o, fraction: 0.4); export.update(owner: o, fraction: 0.4)
        XCTAssertEqual(count, 2, "同じ値は通知しない")
        export.update(owner: o, fraction: 7)
        XCTAssertEqual(export.current?.fraction, 1, "0〜1 に収める")
        export.end(owner: o)
    }

    // MARK: 表示の切り替え

    func testShowHideAppliesImmediatelyAndPersistsThroughThePreference() {
        controller.start()
        XCTAssertTrue(presenter.isVisible, "既定は表示")
        controller.setEnabled(false)
        XCTAssertFalse(presenter.isVisible)
        XCTAssertFalse(prefs.isEnabled); XCTAssertFalse(controller.isEnabled)
        controller.setEnabled(true)
        XCTAssertTrue(presenter.isVisible); XCTAssertTrue(controller.isEnabled)
    }

    func testStartRespectsAHiddenPreference() {
        prefs.isEnabled = false
        controller.start()
        XCTAssertFalse(presenter.isVisible)
    }

    func testUserDefaultsPreferenceDefaultsToOnAndRoundTrips() {
        let suite = "moviecut-status-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = UserDefaultsStatusPreference(defaults: d)
        XCTAssertTrue(p.isEnabled)
        p.isEnabled = false
        XCTAssertFalse(UserDefaultsStatusPreference(defaults: d).isEnabled)
        XCTAssertEqual(UserDefaultsStatusPreference.key, "showMenuBarIcon")
        p.isEnabled = true
        XCTAssertTrue(UserDefaultsStatusPreference(defaults: d).isEnabled)
    }

    func testToggleMenuItemFlipsThePreferenceOfTheAppWideController() {
        // 静かな検証用の統制(本物を作らず、設定は保存しない)と同じ作りで確かめる
        let c = AppServices.makeStatusBar(quiet: true, export: ExportStatusCenter())
        XCTAssertTrue(c.presenter is NullStatusItemPresenter)
        XCTAssertTrue(c.isEnabled)
        c.setEnabled(false)
        XCTAssertFalse(c.isEnabled)
        XCTAssertFalse(UserDefaults.standard.object(forKey: UserDefaultsStatusPreference.key) as? Bool == false, "静かな起動では利用者の設定を書き換えない")
    }

    // MARK: 静かな起動

    func testQuietModeNeverCreatesARealStatusItem() {
        let c = AppServices.makeStatusBar(quiet: true, export: ExportStatusCenter())
        XCTAssertTrue(c.presenter is NullStatusItemPresenter)
        c.start()
        c.menuWillOpen(); c.menuDidClose()
        XCTAssertFalse(c.presenter is NSStatusItemPresenter)
        let real = AppServices.makeStatusBar(quiet: false, export: ExportStatusCenter())
        XCTAssertTrue(real.presenter is NSStatusItemPresenter, "通常の起動では本物(まだ作っただけ。start するまで NSStatusItem は作られない)")
        XCTAssertFalse(real.presenter.isVisible)
    }

    // MARK: VOICEVOX の確認

    func testEngineStateMapping() async {
        probe.alive = false
        await controller.pollEngine(force: true)
        XCTAssertEqual(controller.state.engine, .stopped)
        probe.alive = true; probe.startedByUs = true
        await controller.pollEngine(force: true)
        XCTAssertEqual(controller.state.engine, .runningByUs)
        probe.startedByUs = false
        await controller.pollEngine(force: true)
        XCTAssertEqual(controller.state.engine, .runningByOther)
        probe.alive = false
        await controller.pollEngine(force: true)
        XCTAssertEqual(controller.state.engine, .stopped)
    }

    func testPollingIsThrottledToOncePerThreeSeconds() async {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = await controller.pollEngine(force: false, now: t0)
        let b = await controller.pollEngine(force: false, now: t0.addingTimeInterval(1))
        let c = await controller.pollEngine(force: false, now: t0.addingTimeInterval(2.9))
        let d = await controller.pollEngine(force: false, now: t0.addingTimeInterval(3.0))
        let e = await controller.pollEngine(force: false, now: t0.addingTimeInterval(3.5))
        XCTAssertEqual([a, b, c, d, e], [true, false, false, true, false])
        XCTAssertEqual(probe.calls, 2)
        let f = await controller.pollEngine(force: true, now: t0.addingTimeInterval(3.6))
        XCTAssertTrue(f, "force は間隔を無視")
        XCTAssertEqual(MenuBarStatusController.pollInterval, 3)
    }

    func testPollingRunsOnlyWhileTheMenuIsOpen() async throws {
        var sleeps: [TimeInterval] = []
        controller.sleep = { s in sleeps.append(s); try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(probe.calls, 0, "閉じている間は確かめない")
        controller.menuWillOpen()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertGreaterThan(probe.calls, 0)
        XCTAssertEqual(Set(sleeps), [3], "待ちは 3 秒")
        XCTAssertLessThanOrEqual(probe.calls, 2, "3 秒の間隔があるので、短い間に何度も確かめない")
        controller.menuDidClose()
        let after = probe.calls
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.calls, after, "閉じたら止まる")
        XCTAssertFalse(controller.isMenuOpen)
    }

    func testEngineStateChangeRebuildsTheMenu() async {
        controller.start()
        let n = presenter.renders.count
        probe.alive = true; probe.startedByUs = true
        await controller.pollEngine(force: true)
        XCTAssertGreaterThan(presenter.renders.count, n)
        XCTAssertTrue(titles(presenter.last).contains("VOICEVOX: 起動中（このアプリが起動）"))
        let m = presenter.renders.count
        await controller.pollEngine(force: true)     // 変わらなければ描き直さない
        XCTAssertEqual(presenter.renders.count, m)
    }

    // MARK: 項目を選んだとき

    func testActionsAreForwardedToTheHandler() {
        controller.start()
        let url = URL(fileURLWithPath: "/x/y.mcpjc")
        for a in [StatusAction.startEngine, .stopEngine, .openRecent(url), .newDocument, .openDocument, .showApp, .quit] { presenter.onAction?(a) }
        XCTAssertEqual(actions.performed, [.startEngine, .stopEngine, .openRecent(url), .newDocument, .openDocument, .showApp, .quit])
    }

    func testDockStaysNormalNoAccessoryPolicyChange() {
        // 状態アイコンは Dock のふるまいを変えない(LSUIElement にしない)
        let plist = try? String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/make-app.sh").path, encoding: .utf8)
        XCTAssertFalse((plist ?? "").contains("LSUIElement"))
    }
}
