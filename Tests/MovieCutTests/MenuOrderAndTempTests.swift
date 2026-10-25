import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// M7: メニューバーの並び(SwiftUI が崩した順番の直し)と、再生用の一時ファイルの置き場所・掃除。
@MainActor
final class MenuOrderAndTempTests: XCTestCase {
    // MARK: 並び

    func testOrderedPutsClipPlaybackGoBeforeView() {
        let swiftUIOrder = ["Movie Cut", "ファイル", "編集", "表示", "クリップ", "再生", "移動", "ウィンドウ", "ヘルプ"]
        XCTAssertEqual(MenuOrder.ordered(swiftUIOrder), ["Movie Cut", "ファイル", "編集", "クリップ", "再生", "移動", "表示", "ウィンドウ", "ヘルプ"])
        // M5 のときの崩れ(再生が表示の後ろ)
        XCTAssertEqual(MenuOrder.ordered(["Movie Cut", "ファイル", "編集", "表示", "再生", "ウィンドウ", "ヘルプ"]), ["Movie Cut", "ファイル", "編集", "再生", "表示", "ウィンドウ", "ヘルプ"])
        // すでに正しければそのまま(2 回やっても同じ)
        let right = MenuOrder.ordered(swiftUIOrder)
        XCTAssertEqual(MenuOrder.ordered(right), right)
        // 英語表記でも並べられる。知らない題は知っているものの後ろに元の順
        // ヘルプは必ず最後。知らない題はヘルプの前
        XCTAssertEqual(MenuOrder.ordered(["App", "View", "File", "Edit", "Zzz", "Window", "Help"]), ["App", "File", "Edit", "View", "Window", "Zzz", "Help"])
        // 実機の表記(ウインドウ=イ入り)でも、ヘルプより前に来る
        XCTAssertEqual(MenuOrder.ordered(["Movie Cut", "ファイル", "編集", "表示", "ヘルプ", "ウインドウ"]), ["Movie Cut", "ファイル", "編集", "表示", "ウインドウ", "ヘルプ"])
        XCTAssertEqual(MenuOrder.ordered(["App"]), ["App"])
        XCTAssertEqual(MenuOrder.ordered([]), [])
    }

    private func menu(_ titles: [String]) -> NSMenu {
        let m = NSMenu(title: "main")
        for t in titles {
            let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            it.submenu = NSMenu(title: t)
            it.submenu?.addItem(NSMenuItem(title: "項目-\(t)", action: nil, keyEquivalent: ""))
            m.addItem(it)
        }
        return m
    }

    func testFixReordersTheRealMenuKeepingItemsAndSubmenus() {
        let m = menu(["Movie Cut", "ファイル", "編集", "表示", "クリップ", "再生", "移動", "ウィンドウ", "ヘルプ"])
        let originals = Dictionary(uniqueKeysWithValues: m.items.map { (MenuOrder.title(of: $0), $0) })
        XCTAssertTrue(MenuOrder.fix(m))
        XCTAssertEqual(m.items.map(MenuOrder.title(of:)), ["Movie Cut", "ファイル", "編集", "クリップ", "再生", "移動", "表示", "ウィンドウ", "ヘルプ"])
        for it in m.items { XCTAssertTrue(it === originals[MenuOrder.title(of: it)], "項目そのものを移すだけ(作り直さない)") }
        XCTAssertEqual(m.items[3].submenu?.items.first?.title, "項目-クリップ")
        XCTAssertFalse(MenuOrder.fix(m), "2 回目は何も変えない")
        XCTAssertEqual(m.items.count, 9)
    }

    func testFixFindsWindowAndHelpMenusByIdentityEvenWithLocalizedTitles() {
        // 実機の順(ヘルプが先、ウインドウが後)。ウインドウ / ヘルプはシステムの題ではなく windowsMenu / helpMenu で判定する
        let m = menu(["Movie Cut", "ファイル", "編集", "クリップ", "再生", "移動", "表示", "Aide", "Fenster"])
        let help = m.items[7].submenu!, windows = m.items[8].submenu!
        XCTAssertTrue(MenuOrder.fix(m, windowsMenu: windows, helpMenu: help))
        XCTAssertEqual(m.items.map(MenuOrder.title(of:)), ["Movie Cut", "ファイル", "編集", "クリップ", "再生", "移動", "表示", "Fenster", "Aide"])
        XCTAssertFalse(MenuOrder.fix(m, windowsMenu: windows, helpMenu: help), "2 回目は何も変えない")
        // 実機の表記のまま: 題で判定(ヘルプを必ず最後に)
        let m2 = menu(["Movie Cut", "ファイル", "編集", "表示", "ヘルプ", "ウインドウ"])
        XCTAssertTrue(MenuOrder.fix(m2))
        XCTAssertEqual(m2.items.map(MenuOrder.title(of:)), ["Movie Cut", "ファイル", "編集", "表示", "ウインドウ", "ヘルプ"])
        XCTAssertFalse(MenuOrder.fix(m2))
    }

    func testFixUsesItemTitleWhenThereIsNoSubmenuTitle() {
        let m = NSMenu(title: "main")
        for t in ["A", "表示", "編集"] { m.addItem(NSMenuItem(title: t, action: nil, keyEquivalent: "")) }
        XCTAssertTrue(MenuOrder.fix(m))
        XCTAssertEqual(m.items.map(\.title), ["A", "編集", "表示"])
    }

    func testWatcherFixesTheOrderOnTheNextRunLoopTurnWhenTheMenuIsRebuilt() {
        let m = menu(["Movie Cut", "ファイル", "編集", "クリップ", "再生", "移動", "表示", "ウィンドウ", "ヘルプ"])
        MenuOrder.uninstall()
        MenuOrder.install(menu: { m })
        defer { MenuOrder.uninstall() }
        XCTAssertEqual(m.items.map(MenuOrder.title(of:)), ["Movie Cut", "ファイル", "編集", "クリップ", "再生", "移動", "表示", "ウィンドウ", "ヘルプ"])
        // SwiftUI が「表示」を CommandMenu の前に置き直した(= 追加の通知が来る)
        let view = m.items.first { MenuOrder.title(of: $0) == "表示" }!
        m.removeItem(view)
        m.insertItem(view, at: 3)
        XCTAssertEqual(m.items.map(MenuOrder.title(of:))[3], "表示", "通知の中ではまだ直さない")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(m.items.map(MenuOrder.title(of:)), ["Movie Cut", "ファイル", "編集", "クリップ", "再生", "移動", "表示", "ウィンドウ", "ヘルプ"], "次の run loop で直る(アプリの更新を待たない)")
        // 項目の追加(新しい CommandMenu)でも。題の無い項目(知らない題)はヘルプの前へ直す(1 回だけ)
        let n = MenuOrder.fixCount
        m.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(MenuOrder.fixCount, n + 1, "知らない題を入れて直すのは 1 回だけ")
        XCTAssertEqual(m.items.map(MenuOrder.title(of:)).last, "ヘルプ", "ヘルプは必ず最後")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(MenuOrder.fixCount, n + 1, "直ったあとは何もしない(ループしない)")
    }

    // MARK: 一時ファイル

    private func tempBase() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-temp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func touch(_ url: URL, ageDays: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageDays * 86400)], ofItemAtPath: url.path)
    }

    func testNewFilesGoToOneSubfolderWithThePidPrefix() throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let u = PlaybackTempFiles.newFileURL(base: base, pid: 4242)
        XCTAssertEqual(u.deletingLastPathComponent().lastPathComponent, PlaybackTempFiles.folderName)
        XCTAssertEqual(u.deletingLastPathComponent().deletingLastPathComponent().path, base.path)
        XCTAssertTrue(u.lastPathComponent.hasPrefix("moviecut-playback-4242-"))
        XCTAssertEqual(u.pathExtension, "caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.deletingLastPathComponent().path))
        XCTAssertNotEqual(PlaybackTempFiles.newFileURL(base: base, pid: 4242), u)
    }

    func testStaleFilesOlderThanADayAreRemovedAtStartup() throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let dir = PlaybackTempFiles.folderURL(base: base)
        let oldSub = dir.appendingPathComponent("moviecut-playback-111-old.caf")
        let freshSub = dir.appendingPathComponent("moviecut-playback-222-fresh.caf")
        let oldLegacy = base.appendingPathComponent("moviecut-playback-333-legacy-old.caf")
        let freshLegacy = base.appendingPathComponent("moviecut-playback-444-legacy-fresh.caf")
        let other = base.appendingPathComponent("someone-elses.caf")
        let notCaf = dir.appendingPathComponent("moviecut-playback-555-x.txt")
        try touch(oldSub, ageDays: 2); try touch(freshSub, ageDays: 0.5)
        try touch(oldLegacy, ageDays: 3); try touch(freshLegacy, ageDays: 0.1)
        try touch(other, ageDays: 9); try touch(notCaf, ageDays: 9)
        let n = PlaybackTempFiles.removeStale(base: base)
        XCTAssertEqual(n, 2)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: oldSub.path)); XCTAssertFalse(fm.fileExists(atPath: oldLegacy.path))
        XCTAssertTrue(fm.fileExists(atPath: freshSub.path), "1 日以内のものは(ほかの起動が使っているかもしれないので)残す")
        XCTAssertTrue(fm.fileExists(atPath: freshLegacy.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path), "関係ないファイルには触らない")
        XCTAssertTrue(fm.fileExists(atPath: notCaf.path))
        // 時刻を進めれば消える(now を差し替えられる)
        XCTAssertEqual(PlaybackTempFiles.removeStale(base: base, now: Date().addingTimeInterval(3 * 86400)), 2)
    }

    func testRemoveCurrentDeletesOnlyThisProcessesFilesAndTheEmptyFolder() throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let mine1 = PlaybackTempFiles.newFileURL(base: base, pid: 900), mine2 = PlaybackTempFiles.newFileURL(base: base, pid: 900)
        let theirs = PlaybackTempFiles.newFileURL(base: base, pid: 901)
        for u in [mine1, mine2, theirs] { try Data("x".utf8).write(to: u) }
        let legacyMine = base.appendingPathComponent("moviecut-playback-900-legacy.caf")
        try Data("x".utf8).write(to: legacyMine)
        XCTAssertEqual(PlaybackTempFiles.removeCurrent(base: base, pid: 900), 3)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: mine1.path)); XCTAssertFalse(fm.fileExists(atPath: mine2.path)); XCTAssertFalse(fm.fileExists(atPath: legacyMine.path))
        XCTAssertTrue(fm.fileExists(atPath: theirs.path), "別プロセスのファイルは残す")
        XCTAssertEqual(PlaybackTempFiles.removeCurrent(base: base, pid: 901), 1)
        XCTAssertFalse(fm.fileExists(atPath: PlaybackTempFiles.folderURL(base: base).path), "空になったフォルダは消す")
        XCTAssertEqual(PlaybackTempFiles.removeCurrent(base: base, pid: 901), 0)
    }

    func testPlaybackControllerWritesIntoTheSubfolderAndShutdownDeletesIt() async throws {
        var written: [URL] = []
        let m = ProjectModel(project: {
            var p = Project.new(); var c = Clip(); c.type = .voice; c.src = "/tmp/a.wav"; c.start = 0; c.duration = 3; p.tracks[0].clips.append(c); return p
        }())
        let c = PlaybackController(model: m, backend: FakeBackend(), clock: FakeClock(), debounce: 0, mixer: { _, u in
            try Data("mix".utf8).write(to: u); written.append(u); return 3
        })
        c.timerFallback = false
        m.playback = c
        c.warmUp()
        for _ in 0..<100 where written.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let u = try XCTUnwrap(written.first, "warmUp がミックスを作る")
        XCTAssertEqual(u.deletingLastPathComponent().lastPathComponent, PlaybackTempFiles.folderName)
        XCTAssertTrue(u.lastPathComponent.hasPrefix("moviecut-playback-\(ProcessInfo.processInfo.processIdentifier)-"))
        for _ in 0..<100 where c.debugBackendRunning == false && !FileManager.default.fileExists(atPath: u.path) { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path))
        c.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: u.path), "書類を閉じる(shutdown)と消える")
        // 終了時の掃除: 残っていた自分のファイルを全部消す
        let stray = PlaybackTempFiles.newFileURL()
        try Data("x".utf8).write(to: stray)
        XCTAssertGreaterThanOrEqual(PlaybackTempFiles.removeCurrent(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }
}
