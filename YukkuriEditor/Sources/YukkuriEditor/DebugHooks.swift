import SwiftUI
import AppKit
import QuartzCore
import YukkuriCore

/// 検証用フック(環境変数があるときだけ動く。普段は何もしない)。
///
/// - `YE_SNAPSHOT_DIR=<dir>`  最初のプレビュー画面が描けるまで待ち、`YE_SNAPSHOT_DELAY` 秒(既定 0.5)後に
///   ウィンドウを `<dir>/window.png` に書いて終了する。シートが出ていれば `<dir>/sheet.png` も書く。
/// - `YE_OPEN=<path.ymproj>`  起動時にそのファイルを開き、スナップショットや下のフックはそのドキュメントに対して行う。
/// - `YE_DEBUG_SIZE=WxH`      解像度ピッカーと同じ経路(`selectResolution`)で解像度を変える。
/// - `YE_DEBUG_SCRIPT="行1\n行2"` 台本ボタンと同じ関数(`generateVoices`)を起動後に実行する(`\n` は改行として扱う)。
/// - `YE_DEBUG_EXPORT=<out.mp4>` ツールバーの書き出しと同じ関数(`runExport`)を保存パネルなしで実行し、
///   結果を標準出力に出して終了する。`YE_SNAPSHOT_DIR` も付けると、書き出し開始から DELAY 秒後に写真を撮る(進行シート確認用)。
/// - `YE_DEBUG_SHEET=settings` 設定シートを開いた状態にする。
/// - `YE_DEBUG_WINDOW=WxH`   ウィンドウの中身の大きさを指定する(スナップショットの寸法をそろえる)。
/// - `YE_DEBUG_TREE=1`       スナップショット時にビュー階層を標準出力へ出す。
/// - `YE_DEBUG_ZOOM=<pps>`    タイムラインの拡大率(pt/秒、5〜400)を指定する。
/// - `YE_DEBUG_SELECT_CLIP=<index>` 全クリップ(レイヤー順)の index 番目を選択する。
/// - `YE_DEBUG_TIME=<sec>`    再生ヘッドをその時刻へ動かす(プレビューも追従)。
/// - `YE_DEBUG_PLAY=<sec>`    `YE_DEBUG_PLAY_FROM`(既定 0)から再生を始め、<sec> 秒待ってから
///   `play: t=… expected≈… dropped=… engineRunning=…` を出して終了する(t は画面の時刻、expected は始めた時刻 + 実際に経った秒数、
///   dropped は描画が間に合わず捨てられたフレーム数)。
/// - `YE_DEBUG_SEEK_TEST=1`   1 秒再生 → 2.5 秒へシーク → 0.5 秒待つ、で時計が追従するか確かめて `seek-test: … ok=…` を出して終了する。
///   (プロジェクトの長さが 3.5 秒以上ないと確かめられない)
/// - `YE_DEBUG_DRAWTIME=<N>`  タイムラインを N 回描き直して、1 回あたりの描画時間(ms)を `timeline-draw: …` に出す。
/// - `YE_DEBUG_SECOND=1`      別画面ウィンドウを開き、`YE_SNAPSHOT_DIR` があれば `<dir>/second.png` にも書く(`window.png` と同時)。
@MainActor
final class DebugHooks {
    static let shared = DebugHooks()
    private let env = ProcessInfo.processInfo.environment
    private var started = false

    private var active: Bool {
        ["YE_SNAPSHOT_DIR", "YE_DEBUG_SIZE", "YE_DEBUG_SCRIPT", "YE_DEBUG_EXPORT", "YE_DEBUG_SHEET", "YE_DEBUG_ZOOM", "YE_DEBUG_WINDOW", "YE_DEBUG_SELECT_CLIP",
         "YE_DEBUG_TIME", "YE_DEBUG_PLAY", "YE_DEBUG_SEEK_TEST", "YE_DEBUG_DRAWTIME", "YE_DEBUG_SECOND"].contains { env[$0] != nil }
    }

    func appDidLaunch() {
        guard env["YE_OPEN"] != nil || active else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let path = env["YE_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, error in
                    if let error { Self.out("YE_OPEN 失敗: \(error.localizedDescription)"); exit(2) }
                }
            }
        }
        // どのドキュメントも現れなかったときの保険
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if !self.started { Self.out("debug: ドキュメントが現れませんでした"); exit(3) }
        }
    }

    /// ドキュメントの画面が出たときに呼ばれる。YE_OPEN があれば、そのファイルのものだけ相手にする。
    func attach(_ model: ProjectModel) {
        guard active, !started else { return }
        if let path = env["YE_OPEN"] {
            let want = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard model.fileURL?.resolvingSymlinksInPath().path == want else { return }
        }
        started = true
        Task { @MainActor in await self.run(model) }
    }

    private func run(_ model: ProjectModel) async {
        while model.window == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        NSApp.activate(ignoringOtherApps: true)
        model.window?.makeKeyAndOrderFront(nil)
        let delay = env["YE_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 0.5

        if let s = env["YE_DEBUG_WINDOW"] {
            let p = s.lowercased().split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { model.window?.setContentSize(NSSize(width: p[0], height: p[1])); model.window?.center(); try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        if let s = env["YE_DEBUG_SIZE"] { model.selectResolution(s) }
        if let s = env["YE_DEBUG_SCRIPT"] {
            await model.generateVoices(from: s.replacingOccurrences(of: "\\n", with: "\n"))
            Self.out("script: \(model.statusText)\(model.errorMessage.map { " ERROR: \($0)" } ?? "")")
        }
        if env["YE_DEBUG_SHEET"] == "settings" { model.showSettings = true }
        if let z = env["YE_DEBUG_ZOOM"].flatMap(Double.init) { model.pps = TimelineLayout.clampPps(z) }
        if let i = env["YE_DEBUG_SELECT_CLIP"].flatMap(Int.init) {
            let clips = model.project.allClips
            if clips.indices.contains(i) { model.selectedClipId = clips[i].id }
        }
        if let t = env["YE_DEBUG_TIME"].flatMap(Double.init) { model.currentTime = t }

        if env["YE_DEBUG_PLAY"] != nil || env["YE_DEBUG_SEEK_TEST"] != nil {
            await runPlaybackDebug(model)
            Self.finish(0)
        }
        if let n = env["YE_DEBUG_DRAWTIME"].flatMap(Int.init) {
            await settle(model)
            try? await Task.sleep(nanoseconds: 500_000_000)   // SwiftUI がズームなどをキャンバスへ渡すのを待つ
            measureDraw(model, count: n)
        }

        if let out = env["YE_DEBUG_EXPORT"] {
            if env["YE_SNAPSHOT_DIR"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self.snapshot(model)
                }
            }
            let url = URL(fileURLWithPath: out)
            let t0 = Date()
            switch await model.runExport(to: url) {
            case .success(let u):
                let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                Self.out(String(format: "export: ok %@ (%d bytes, %.1fs)", u.path, size, Date().timeIntervalSince(t0)))
                Self.finish(0)
            case .cancelled:
                Self.out("export: cancelled"); Self.finish(1)
            case .failure(let e):
                Self.out("export: failed \(e.localizedDescription)"); Self.finish(1)
            }
        }

        if env["YE_DEBUG_SECOND"] != nil {
            model.toggleSecondScreen()
            Self.out("second: open=\(model.isSecondScreenOpen) frame=\(model.secondScreen.window.map { NSStringFromRect($0.frame) } ?? "-")")
        }

        if env["YE_SNAPSHOT_DIR"] != nil {
            await settle(model)
            if env["YE_DEBUG_SECOND"] != nil { try? await Task.sleep(nanoseconds: 800_000_000) }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            snapshot(model)
        }
        Self.finish(0)
    }

    /// 最初のフレームが描けて、新しい要求が無くなるまで待つ(最大 30 秒)。
    private func settle(_ model: ProjectModel) async {
        var waited = 0.0
        while !(model.previewFrameCount > 0 && model.previewIdle) && waited < 30 {
            try? await Task.sleep(nanoseconds: 50_000_000); waited += 0.05
        }
    }

    // MARK: 再生の検証

    private func runPlaybackDebug(_ model: ProjectModel) async {
        await settle(model)
        let pb = model.playback!
        let end = model.project.endTime
        Self.out(String(format: "project: end=%.3fs clips=%d fps=%d", end, model.project.allClips.count, model.project.fps))
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        /// 再生が始まる(ミックスの準備が終わる)まで待つ
        func waitPlaying() async -> Bool {
            var w = 0.0
            while !pb.isPlaying && w < 120 { await sleep(0.02); w += 0.02 }
            return pb.isPlaying
        }
        if let secs = env["YE_DEBUG_PLAY"].flatMap(Double.init) {
            let from = env["YE_DEBUG_PLAY_FROM"].flatMap(Double.init) ?? 0
            model.currentTime = from
            await settle(model)
            model.previewDropped = 0
            let frames0 = model.previewFrameCount
            let prep0 = CACurrentMediaTime()
            pb.play()
            guard await waitPlaying() else { Self.out("play: failed to start (\(model.statusText))"); return }
            let started = CACurrentMediaTime()
            let t0 = model.currentTime
            await sleep(secs)
            let elapsed = CACurrentMediaTime() - started
            let t = model.currentTime
            let running = pb.debugBackendRunning
            let stopped = !pb.isPlaying
            let expected = min(from + elapsed, end)
            Self.out(String(format: "play: t=%.3f expected≈%.3f dropped=%d engineRunning=%@", t, expected, model.previewDropped, running ? "true" : "false"))
            Self.out(String(format: "play: from=%.2f elapsed=%.3fs diff=%+.3fs prepare=%.2fs firstTick=%.3f ticks=%d framesShown=%d displayHz≈%.1f stoppedAtEnd=%@",
                            from, elapsed, t - expected, started - prep0, t0, pb.tickCount, model.previewFrameCount - frames0, Double(pb.tickCount) / max(0.001, elapsed), stopped ? "true" : "false"))
            pb.pause()
        }
        if env["YE_DEBUG_SEEK_TEST"] != nil {
            model.currentTime = 0
            await settle(model)
            pb.play()
            guard await waitPlaying() else { Self.out("seek-test: failed to start (\(model.statusText))"); return }
            await sleep(1.0)
            let t1 = model.currentTime
            pb.seek(to: 2.5)
            let t2 = model.currentTime
            await sleep(0.5)
            let t3 = model.currentTime
            let ok = abs(t1 - 1.0) < 0.15 && abs(t2 - 2.5) < 0.05 && abs(t3 - 3.0) < 0.15 && pb.isPlaying
            Self.out(String(format: "seek-test: t@1s=%.3f afterSeek=%.3f t@+0.5s=%.3f (want ≈1.0 / 2.5 / 3.0) engineRunning=%@ ok=%@", t1, t2, t3, pb.debugBackendRunning ? "true" : "false", ok ? "true" : "false"))
            pb.pause()
        }
    }

    // MARK: 描画時間

    private func findCanvas(_ v: NSView?) -> TimelineCanvas? {
        guard let v else { return nil }
        if let c = v as? TimelineCanvas { return c }
        for s in v.subviews { if let c = findCanvas(s) { return c } }
        return nil
    }

    private func measureDraw(_ model: ProjectModel, count n: Int) {
        guard let canvas = findCanvas(model.window?.contentView) else { Self.out("timeline-draw: canvas not found"); return }
        var times: [Double] = []
        let c0 = canvas.drawCount
        for _ in 0..<max(1, n) {
            canvas.needsDisplay = true
            canvas.displayIfNeeded()
            times.append(canvas.lastDrawMs)
        }
        let sorted = times.sorted()
        let avg = times.reduce(0, +) / Double(times.count)
        Self.out(String(format: "timeline-draw: avg=%.2fms median=%.2fms max=%.2fms min=%.2fms (draw calls=%d of %d) clipsDrawn=%d of %d, view=%.0fx%.0f pps=%.0f",
                        avg, sorted[sorted.count / 2], sorted.last ?? 0, sorted.first ?? 0, canvas.drawCount - c0, n, canvas.lastDrawClipCount, model.project.allClips.count,
                        canvas.bounds.width, canvas.bounds.height, canvas.geometry.pps))
    }

    // MARK: スナップショット

    private func snapshot(_ model: ProjectModel) {
        guard let dir = env["YE_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let win = model.window else { Self.out("snapshot: no window"); return }
        if env["YE_DEBUG_TREE"] != nil {
            func dump(_ v: NSView, _ d: Int) {
                Self.out(String(repeating: " ", count: d) + "\(type(of: v)) \(NSStringFromRect(v.frame)) hidden=\(v.isHidden)")
                if d < 8 { for c in v.subviews { dump(c, d + 1) } }
            }
            if let cv = win.contentView { dump(cv, 0) }
        }
        if let png = Self.png(of: win) { try? png.write(to: url.appendingPathComponent("window.png")) }
        if let second = model.secondScreen.window, let png = Self.png(of: second) { try? png.write(to: url.appendingPathComponent("second.png")) }
        if let sheet = win.attachedSheet, let png = Self.png(of: sheet) {
            try? png.write(to: url.appendingPathComponent("sheet.png"))
        }
        Self.out("snapshot: wrote \(url.path)")
    }

    /// ウィンドウの中身を PNG にする(画面収録の許可に頼らず、レイヤーを直接描く)。
    static func png(of win: NSWindow) -> Data? {
        guard let view = win.contentView else { return nil }
        win.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    /// 書き出しの未保存確認などで止まらないよう、エンジンだけ止めて直接終わる。
    private static func finish(_ code: Int32) -> Never {
        AppServices.engine.shutdown()
        exit(code)
    }
}
