import SwiftUI
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import MovieCutCore

/// 検証用フック(環境変数があるときだけ動く。普段は何もしない)。
///
/// - `MC_SNAPSHOT_DIR=<dir>`  最初のプレビュー画面が描けるまで待ち、`MC_SNAPSHOT_DELAY` 秒(既定 0.5)後に
///   ウィンドウを `<dir>/window.png` に書いて終了する。シートが出ていれば `<dir>/sheet.png` も書く。
/// - `MC_OPEN=<path.ymproj>`  起動時にそのファイルを開き、スナップショットや下のフックはそのドキュメントに対して行う。
/// - `MC_DEBUG_SIZE=WxH`      解像度ピッカーと同じ経路(`selectResolution`)で解像度を変える。
/// - `MC_DEBUG_SCRIPT="行1\n行2"` 台本ボタンと同じ関数(`generateVoices`)を起動後に実行する(`\n` は改行として扱う)。
/// - `MC_DEBUG_EXPORT=<out.mp4>` ツールバーの書き出しと同じ関数(`runExport`)を保存パネルなしで実行し、
///   結果を標準出力に出して終了する。`MC_SNAPSHOT_DIR` も付けると、書き出し開始から DELAY 秒後に写真を撮る(進行シート確認用)。
/// - `MC_DEBUG_SHEET=settings` 設定シートを開いた状態にする。
/// - `MC_DEBUG_WINDOW=WxH`   ウィンドウの中身の大きさを指定する(スナップショットの寸法をそろえる)。
/// - `MC_DEBUG_TREE=1`       スナップショット時にビュー階層を標準出力へ出す。
/// - `MC_DEBUG_ZOOM=<pps>`    タイムラインの拡大率(pt/秒、5〜400)を指定する。
/// - `MC_DEBUG_SELECT_CLIP=<index>` 全クリップ(レイヤー順)の index 番目を選択する。
/// - `MC_DEBUG_TIME=<sec>`    再生ヘッドをその時刻へ動かす(プレビューも追従)。
/// - `MC_DEBUG_PLAY=<sec>`    `MC_DEBUG_PLAY_FROM`(既定 0)から再生を始め、<sec> 秒待ってから
///   `play: t=… expected≈… dropped=… engineRunning=…` を出して終了する(t は画面の時刻、expected は始めた時刻 + 実際に経った秒数、
///   dropped は描画が間に合わず捨てられたフレーム数)。
/// - `MC_DEBUG_SEEK_TEST=1`   1 秒再生 → 2.5 秒へシーク → 0.5 秒待つ、で時計が追従するか確かめて `seek-test: … ok=…` を出して終了する。
///   (プロジェクトの長さが 3.5 秒以上ないと確かめられない)
/// - `MC_DEBUG_DRAWTIME=<N>`  タイムラインを N 回描き直して、1 回あたりの描画時間(ms)を `timeline-draw: …` に出す。
/// - `MC_DEBUG_EDIT="move:<idx>:<dt>[:<行>];trimL:<idx>:<dt>;trimR:<idx>:<dt>;split:<idx>@<t>;delete:<idx>;text;blur;media:<path>"`
///   タイムライン編集(M4a)を ; 区切りで順に実行する。UI と同じ関数(タイムラインのドラッグ処理 / `splitSelected` / `deleteSelected` /
///   `addTextClip` / `addBlurClip` / `addMedia`)を通る。<idx> は全クリップ(レイヤー順)の番号(前の操作の結果に対しての番号)、<dt> は秒、
///   move の <行> は移動先のレイヤー番号(省略で同じレイヤー)、split は再生ヘッドを <t> に置いてから分割する。
///   終わったら全クリップの `edit: T<レイヤー> #<番号> <種類> start= dur= off=` と Undo の状態を標準出力に出す。
///   `MC_SNAPSHOT_DIR` も付けると、その結果の画面を撮る(`MC_DEBUG_SELECT_CLIP` / `MC_DEBUG_TIME` は編集のあとに効く)。
/// - `MC_DEBUG_HOLD_DRAG=<move|trimL|trimR>:<idx>:<dt>[:<行>]` ドラッグを途中(マウスを離す前)の状態で止める。吸着の案内線が写る。
///   `MC_DEBUG_EDIT` と `MC_DEBUG_SELECT_CLIP` / `MC_DEBUG_TIME` のあとに実行され、再生ヘッドの時刻が吸着の候補になる。
/// - `MC_DEBUG_SELECT_CHAR=<index>` キャラ一覧の index 番目を左の一覧で選んだのと同じ(`selectCharacter`)にして、プロパティ欄をキャラの設定にする。
///   VOICEVOX のキャラのときは話者一覧が読めるまで(最大 40 秒)待ち、`speakers: state=… count=…` を出す。
/// - `MC_DEBUG_INSPECTOR_SCROLL=bottom` 右のプロパティ欄を一番下までスクロールしてから撮る(下の方の項目を見るため)。
/// - `MC_DEBUG_DELETE_CHAR=<index>[:ask|:do]` index 番目のキャラを消す確認を出す(`:ask` 省略時。画面に確認の警告が出る)か、
///   `:do` で確認を通して実際に消す(`deleteCharacter`)。結果(キャラ数・クリップ数・Undo の状態)を標準出力に出す。
/// - `MC_DEBUG_VOICE_EDIT=<新しいセリフ>` 選択中(`MC_DEBUG_SELECT_CLIP`)のボイスクリップのセリフを、プロパティ欄のセリフ欄と同じ関数
///   (`setVoiceText`)で書き換え、前後の `src` / 長さ / WAV の実長 / offset を出し、Undo して元に戻ったことも出す。
///   最後に Redo までして Undo の状態を出す。`MC_DEBUG_SCRIPT` のあとに実行される。
/// - `MC_DEBUG_SECOND=1`      別画面ウィンドウを開き、`MC_SNAPSHOT_DIR` があれば `<dir>/second.png` にも書く(`window.png` と同時)。
/// - `MC_DEBUG_MENU=1`        メニューバー(`NSApp.mainMenu`)の全項目(題・キー・有効・チェック・サブメニュー)を標準出力へ。
///   `MC_DEBUG_MENU=export` なら書き出し中(`MC_DEBUG_EXPORT` と一緒に使う)の状態を出す。`MC_DEBUG_MENU=1,export` なら両方(カンマ区切り)。
/// - `MC_DEBUG_MENU_CLICK="出力/解像度/縦 1080×1920;背景色/白;…"` メニュー項目を `NSMenu.performActionForItem(at:)` で本当に押し、そのたびに状態を出す。
///   `MC_DEBUG_MENU_SCRIPT` で台本欄の文字を先に入れられる。
/// - `MC_DEBUG_DEPS=missing`   依存チェックの結果を「VOICEVOX も AquesTalkPlayer も無い」に固定する(バナーの確認用)。
/// - `MC_DEBUG_EDITED=1`      編集 → 保存で、ウィンドウの「未保存の点」(isDocumentEdited)が変わるかを出す(MC_OPEN の一時コピーで使う)。
/// - `MC_DEBUG_QUIT=1|engine|dirty` ⌘Q の経路。`engine` は VOICEVOX エンジンを自分で起動してから終了、`dirty` は未保存で終了を試みて確認シートが出るかを出す。
/// - `MC_DEBUG_FRAME=set:x,y,w,h|print|min` ウィンドウの位置の記憶と最小サイズの確認。
/// - `MC_DEBUG_ABOUT=1`       About パネルを開き、ウィンドウの題と中の文字をすべて標準出力へ出して終了する。
/// - `MC_DEBUG_SAVEAS=1`     (`MC_DEBUG_DOCS` と一緒に)最初の書類に「保存」を送り、保存パネルの提案名と許可する型を出して取り消す。
/// - `MC_DEBUG_DOCS=1`        起動の数秒後に、開いているドキュメントの一覧を出して終了する(`open -a app file.ymproj` の確認用)。
///
/// ## 静かな起動(`MC_DEBUG_*` / `MC_SNAPSHOT_DIR` / `MC_OPEN` のどれかがあるとき)
/// アクティベーションポリシーは `.accessory`(Dock にもメニューバーにも出ない)、前面にしない、ウィンドウは画面の遠く(x=-30000)、
/// メニューバーの状態アイコン(NSStatusItem)は作らない(`NullStatusItemPresenter`。表示の設定も保存しない)、
/// `MC_DEBUG_MAXSEC`(既定 20)秒で自分で終了する。終了時には再生用の一時ファイルも消す。
///
/// ## 上の一覧に無かった環境変数(M7 でまとめて記載)
/// - `MC_SNAPSHOT_DELAY=<sec>`   スナップショットを撮るまでの待ち(既定 0.5)。
/// - `MC_DEBUG_PLAY_FROM=<sec>`  `MC_DEBUG_PLAY` の再生開始時刻(既定 0)。
/// - `MC_DEBUG_MENU_TWICE=1`     `MC_DEBUG_MENU` を 4 秒後にもう一度出す(メニューが組み直されても崩れないかの確認)。
/// - `MC_DEBUG_MENU_KEYS="cmd+shift+t;…"` キーを本物のキーイベントにしてメニューバーへ渡し、反応するか見る。
/// - `MC_DEBUG_WINDOWS=1`        開いているウィンドウとドキュメントを一覧にして終了する(`MC_DEBUG_DOCS` の仲間。待ちは `MC_DEBUG_DOCS_WAIT`、既定 2 秒)。
///   `MC_DEBUG_CLOSEALL=1` を付けると全部閉じてから終了(復元状態の掃除用)、`MC_DEBUG_REOPEN=1` は全部閉じて Dock のクリック(reopen)を送り、
///   `MC_DEBUG_TERMINATE=1` は普通の終了(⌘Q 相当)で終わる(復元状態もふつうに書かれる)。
/// - `MC_DEBUG_DOCS_WAIT=<sec>`  `MC_DEBUG_DOCS` / `MC_DEBUG_WINDOWS` で一覧を出すまでの待ち。
/// - `MC_DEBUG_KEEP_STATE=1`     検証の起動でもウィンドウの復元状態を読み書きする(通常は無効にしている)。
/// - `MC_DEBUG_HANGWATCH=1`      主スレッドの固まりを記録する(100ms 超の返事の遅れ)。`MC_DEBUG_HANGWATCH_SAMPLE=<dir>` で、300ms 固まったときに `sample` を取る。
/// - `MC_DEBUG_SWEEP=1`          (`MC_DEBUG_HANGWATCH=1` と一緒に)主スレッドの重い作業を一通り行って、局面ごとの固まりを数える。
///   `MC_DEBUG_SWEEP_EXPORT=<out.mp4>` を付けると最後に書き出しも行う。
/// - `MC_DEBUG_ENGINE_URL=<url>` `MC_DEBUG_QUIT=engine` が自分のエンジンを起動するときの URL(本物の VOICEVOX と別ポートで試すため)。
/// - `MC_DEBUG_TRACE=1`          起動と終了の経路のトレースを出す。
/// - `MC_DEBUG_VISIBLE=1`        静かな起動をやめて普通に表示する(画面を撮るとき用)。
/// - `MC_DEBUG_MAXSEC=<sec>`     静かな起動で自分で終了するまでの秒数(既定 20)。
/// - `MC_NOCANVAS=1`             タイムラインのキャンバスを隠す(固まりの切り分け用)。
/// - `MC_DEBUG_DEPS=missing|missing-voicevox|missing-aquestalk` 依存チェックの結果を固定する。
///
/// ## M7 で足したもの
/// - `MC_DEBUG_STATUS=1`         メニューバーの状態アイコンのメニューの中身(`StatusMenuBuilder`)を標準出力へ。書き出し中(`MC_DEBUG_EXPORT` と一緒)は、その最中の分も出す。
/// - `MC_DEBUG_SHEET=jump|rename-marker` 「時間を指定して移動」/「マーカーの名前変更」のシートを開いた状態にする(`settings` は既存)。
/// - `MC_DEBUG_JUMP_VALUE=<text>` `MC_DEBUG_MENU_CLICK` で「時間を指定して移動…」を押したあと、シートの決定と同じ関数(`commitJump`)にこの文字を渡す。
/// - `MC_DEBUG_MENU_CLICK` の特別な項目(`@` で始まる): `@time=<sec>` 再生ヘッドを動かす / `@select=<index>` 全クリップの index 番目を選ぶ /
///   `@clips` クリップとマーカーを全部出す / `@export=<preset>:<out>` 書き出しメニューの項目が押せることを確かめたうえで、保存パネルを出さずに
///   同じ関数(`runExport(to:preset:)`)で書き出す(preset は `current` か `youtube1080` など)。
@MainActor
final class DebugHooks {
    static let shared = DebugHooks()
    private let env = ProcessInfo.processInfo.environment
    private var started = false

    private var active: Bool {
        ["MC_SNAPSHOT_DIR", "MC_DEBUG_SIZE", "MC_DEBUG_SCRIPT", "MC_DEBUG_EXPORT", "MC_DEBUG_SHEET", "MC_DEBUG_ZOOM", "MC_DEBUG_WINDOW", "MC_DEBUG_SELECT_CLIP",
         "MC_DEBUG_TIME", "MC_DEBUG_PLAY", "MC_DEBUG_SEEK_TEST", "MC_DEBUG_DRAWTIME", "MC_DEBUG_SECOND", "MC_DEBUG_EDIT", "MC_DEBUG_HOLD_DRAG", "MC_DEBUG_SELECT_CHAR", "MC_DEBUG_DELETE_CHAR", "MC_DEBUG_VOICE_EDIT", "MC_DEBUG_INSPECTOR_SCROLL",
         "MC_DEBUG_MENU", "MC_DEBUG_MENU_CLICK", "MC_DEBUG_MENU_KEYS", "MC_DEBUG_EDITED", "MC_DEBUG_QUIT", "MC_DEBUG_FRAME", "MC_DEBUG_HANGWATCH", "MC_DEBUG_SWEEP", "MC_DEBUG_STATUS"].contains { env[$0] != nil }
    }

    func appDidLaunch() {
        if env["MC_DEBUG_ABOUT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Self.out("about: mainMenu title=\(NSApp.mainMenu?.items.first?.title ?? "nil")")
                AppInfo.showAboutPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    func texts(_ v: NSView, _ out: inout [String]) {
                        if let t = v as? NSTextField, !t.stringValue.isEmpty { out.append(t.stringValue) }
                        if let t = v as? NSTextView, !t.string.isEmpty { out.append(t.string) }
                        v.subviews.forEach { texts($0, &out) }
                    }
                    for w in NSApp.windows where w.isVisible {
                        var out: [String] = []
                        if let c = w.contentView { texts(c, &out) }
                        Self.out("about: window title=\"\(w.title)\" class=\(type(of: w)) texts=\(out)")
                    }
                    Self.finish(0)
                }
            }
            return
        }
        if env["MC_DEBUG_DOCS"] != nil || env["MC_DEBUG_WINDOWS"] != nil {
            let wait = env["MC_DEBUG_DOCS_WAIT"].flatMap(Double.init) ?? (env["MC_DEBUG_WINDOWS"] != nil ? 2 : 4)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let docs = NSDocumentController.shared.documents
                Self.dumpWindows()
                if self.env["MC_DEBUG_CLOSEALL"] != nil {
                    // 復元状態の掃除用: 全部閉じて、状態が書き込まれるのを待ってから終わる
                    for d in docs { d.updateChangeCount(.changeCleared); d.close() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        Self.out("closeall: windows now \(Self.docWindowCount())")
                        NSApp.terminate(nil)
                    }
                    return
                }
                if self.env["MC_DEBUG_REOPEN"] != nil {
                    // Dock のアイコンのクリックと同じ: すべてのウィンドウを閉じて reopen を送る
                    for d in docs { d.updateChangeCount(.changeCleared); d.close() }
                    NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }.forEach { $0.close() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        Self.out("reopen: after closing all: visibleDocWindows=\(Self.docWindowCount()) documents=\(NSDocumentController.shared.documents.count)")
                        // 本物の kAEReopenApplication を自分に送る(Dock のクリックと同じ経路)
                        Self.sendReopenAppleEvent()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            Self.out("reopen: after reopen event:")
                            Self.dumpWindows()
                            Self.finish(0)
                        }
                    }
                    return
                }
                if self.env["MC_DEBUG_WINDOWS"] != nil {
                    // MC_DEBUG_TERMINATE=1: 普通の終了(⌘Q 相当)で終わる。復元状態もふつうに書かれる。
                    if self.env["MC_DEBUG_TERMINATE"] != nil { NSApp.terminate(nil); return }
                    Self.finish(0)
                }
                Self.out("docs: count=\(docs.count)")
                for d in docs {
                    let p = d.fileURL?.path ?? "-"
                    let proj = String(describing: type(of: d))
                    Self.out("docs: \(p) windows=\(d.windowControllers.compactMap { $0.window?.title }) class=\(proj)")
                    Self.out("docs: fileType=\(d.fileType ?? "nil") isDraft=\(d.isDraft) writableTypes(save)=\(d.writableTypes(for: .saveOperation)) tabbingModes=\(d.windowControllers.compactMap { $0.window?.tabbingMode.rawValue })")
                }
                Self.out("docs: allowsAutomaticWindowTabbing=\(NSWindow.allowsAutomaticWindowTabbing)")
                Self.out("docs: mcpjc conforms json=\(UTType.mcpjc.conforms(to: .json)) ext=\(UTType.mcpjc.preferredFilenameExtension ?? "nil"); ymproj conforms mcpjc=\(UTType.ymproj.conforms(to: .mcpjc)) ext=\(UTType.ymproj.preferredFilenameExtension ?? "nil")")
                if self.env["MC_DEBUG_SAVEAS"] != nil, let d = docs.first(where: { $0.fileURL != nil }) ?? docs.first {
                    // 変更ありにして「保存」(⌘S)を送り、保存パネルが出るか・元のファイルが書き換わるかを見る。
                    // そのあと「別名で保存…」でも提案名と許可する型を出す(パネルはすぐ取り消す)。
                    func panel() -> NSSavePanel? {
                        (NSApp.windows.compactMap { $0 as? NSSavePanel } + (d.windowControllers.first?.window?.sheets.compactMap { $0 as? NSSavePanel } ?? [])).first
                    }
                    func mtime() -> Date? { d.fileURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date } }
                    let m0 = mtime()
                    d.windowControllers.first?.window?.debugOrderFront()
                    d.updateChangeCount(.changeDone)
                    DebugHooks.quietActivate(); d.save(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if let sp = panel() {
                            Self.out("saveas: Save -> panel shown name=\(sp.nameFieldStringValue) types=\(sp.allowedContentTypes.map(\.identifier)) exts=\(sp.allowedContentTypes.compactMap(\.preferredFilenameExtension))")
                            sp.cancel(nil)
                        } else {
                            Self.out("saveas: Save -> NO panel; saved in place; fileURL=\(d.fileURL?.lastPathComponent ?? "nil") mtimeChanged=\(mtime() != m0) fileType=\(d.fileType ?? "nil")")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            d.saveAs(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                if let sp = panel() {
                                    Self.out("saveas: SaveAs -> panel name=\(sp.nameFieldStringValue) types=\(sp.allowedContentTypes.map(\.identifier)) exts=\(sp.allowedContentTypes.compactMap(\.preferredFilenameExtension))")
                                    sp.cancel(nil)
                                } else { Self.out("saveas: SaveAs -> NO panel") }
                                Self.finish(0)
                            }
                        }
                    }
                    return
                }
                Self.finish(0)
            }
            return
        }
        guard env["MC_OPEN"] != nil || active else { return }
        NSWindow.allowsAutomaticWindowTabbing = false   // 検証中は、開いた書類が裏のタブに隠れないようにする
        DebugHooks.quietActivate()
        if let path = env["MC_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, error in
                    if let error { Self.out("MC_OPEN 失敗: \(error.localizedDescription)"); exit(2) }
                }
            }
        }
        // どのドキュメントも現れなかったときの保険
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if !self.started { Self.out("debug: ドキュメントが現れませんでした"); exit(3) }
        }
    }

    /// ドキュメントの画面が出たときに呼ばれる。MC_OPEN があれば、そのファイルのものだけ相手にする。
    func attach(_ model: ProjectModel) {
        guard active, !started else { return }
        if let path = env["MC_OPEN"] {
            let want = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard model.fileURL?.resolvingSymlinksInPath().path == want else { return }
        }
        started = true
        Task { @MainActor in await self.run(model) }
    }

    private func run(_ model: ProjectModel) async {
        while model.window == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        DebugHooks.quietActivate()
        model.window?.debugOrderFront()
        let delay = env["MC_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 0.5

        if let s = env["MC_DEBUG_WINDOW"] {
            let p = s.lowercased().split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { model.window?.setContentSize(NSSize(width: p[0], height: p[1])); if !DebugHooks.isQuiet { model.window?.center() }; try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        if let s = env["MC_DEBUG_SIZE"] { model.selectResolution(s) }
        if let s = env["MC_DEBUG_SCRIPT"] {
            await model.generateVoices(from: s.replacingOccurrences(of: "\\n", with: "\n"))
            Self.out("script: \(model.statusText)\(model.errorMessage.map { " ERROR: \($0)" } ?? "")")
        }
        if env["MC_DEBUG_SHEET"] == "settings" { model.showSettings = true }
        if env["MC_DEBUG_SHEET"] == "jump" { model.showJumpSheet = true }
        if env["MC_DEBUG_SHEET"] == "resolution" { model.showResolutionSheet = true }
        if env["MC_DEBUG_SHEET"] == "fps" { model.showFpsSheet = true }
        if let z = env["MC_DEBUG_ZOOM"].flatMap(Double.init) { model.pps = TimelineLayout.clampPps(z) }
        if let spec = env["MC_DEBUG_EDIT"] {
            await settle(model)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await runEdits(spec, model)
        }
        if let i = env["MC_DEBUG_SELECT_CLIP"].flatMap(Int.init) {
            let clips = model.project.allClips
            if clips.indices.contains(i) { model.selectedClipId = clips[i].id }
        }
        if let i = env["MC_DEBUG_SELECT_CHAR"].flatMap(Int.init) {
            let chars = model.project.characters
            if chars.indices.contains(i) {
                model.selectCharacter(chars[i].id)
                if chars[i].engine == "voicevox" { await waitSpeakers(model) }
                Self.out("select-char: \(chars[i].name) engine=\(chars[i].engine) mode=\(model.inspectorMode)")
            } else { Self.out("select-char: index \(i) がありません") }
        }
        if let s = env["MC_DEBUG_DELETE_CHAR"] { await debugDeleteChar(s, model) }
        if let t = env["MC_DEBUG_VOICE_EDIT"] { await debugVoiceEdit(t, model) }
        if let t = env["MC_DEBUG_TIME"].flatMap(Double.init) { model.currentTime = t }
        let menuModes = (env["MC_DEBUG_MENU"] ?? "").split(separator: ",").map(String.init)
        if let m = menuModes.first(where: { $0 != "export" }) {
            await settle(model)
            await bringToFront(model)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dumpMainMenu(label: m)
            if env["MC_DEBUG_MENU_TWICE"] != nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                model.window?.debugOrderFront()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                dumpMainMenu(label: m + " +4s")
            }
        }
        if env["MC_DEBUG_STATUS"] != nil { dumpStatus("idle") }
        if let spec = env["MC_DEBUG_MENU_CLICK"] { await menuClicks(spec, model) }
        if let spec = env["MC_DEBUG_MENU_KEYS"] { await menuKeys(spec, model) }
        if let f = env["MC_DEBUG_FRAME"] { await debugFrame(f, model) }
        if env["MC_DEBUG_EDITED"] != nil { await debugEdited(model) }
        if env["MC_DEBUG_SWEEP"] != nil { await debugSweep(model) }
        if let q = env["MC_DEBUG_QUIT"] { await debugQuit(q, model) }
        if let spec = env["MC_DEBUG_HOLD_DRAG"] {
            await settle(model)
            try? await Task.sleep(nanoseconds: 300_000_000)
            holdDrag(spec, model)
        }

        if env["MC_DEBUG_PLAY"] != nil || env["MC_DEBUG_SEEK_TEST"] != nil {
            await runPlaybackDebug(model)
            Self.finish(0)
        }
        if let n = env["MC_DEBUG_DRAWTIME"].flatMap(Int.init) {
            await settle(model)
            try? await Task.sleep(nanoseconds: 500_000_000)   // SwiftUI がズームなどをキャンバスへ渡すのを待つ
            measureDraw(model, count: n)
        }

        if let out = env["MC_DEBUG_EXPORT"] {
            if env["MC_SNAPSHOT_DIR"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self.snapshot(model)
                }
            }
            let url = URL(fileURLWithPath: out)
            let t0 = Date()
            if menuModes.contains("export") {
                Task { @MainActor in
                    while !model.isExporting { try? await Task.sleep(nanoseconds: 20_000_000) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    Self.out(String(format: "menu: (書き出し中 progress=%.2f isExporting=%@)", model.exportProgress, model.isExporting ? "true" : "false"))
                    self.dumpMainMenu(label: "export")
                    if self.env["MC_DEBUG_STATUS"] != nil { self.dumpStatus("exporting") }
                }
            }
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

        if env["MC_DEBUG_INSPECTOR_SCROLL"] == "bottom", let win = model.window, let root = win.contentView {
            await settle(model)
            try? await Task.sleep(nanoseconds: 400_000_000)
            // 右端にある縦スクロール(プロパティ欄)を探して、一番下へ
            func all(_ v: NSView) -> [NSScrollView] { (v is NSScrollView ? [v as! NSScrollView] : []) + v.subviews.flatMap(all) }
            if let sv = all(root).filter({ $0.convert($0.bounds, to: nil).minX > win.frame.width - 320 && $0.hasVerticalScroller }).first, let doc = sv.documentView {
                let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
                sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? maxY : 0))
                sv.reflectScrolledClipView(sv.contentView)
                Self.out("inspector-scroll: bottom doc=\(Int(doc.frame.height)) view=\(Int(sv.contentView.bounds.height))")
            } else { Self.out("inspector-scroll: scroll view not found") }
        }
        if env["MC_DEBUG_SECOND"] != nil {
            model.toggleSecondScreen()
            Self.out("second: open=\(model.isSecondScreenOpen) frame=\(model.secondScreen.window.map { NSStringFromRect($0.frame) } ?? "-")")
        }

        if env["MC_SNAPSHOT_DIR"] != nil {
            await settle(model)
            // 依存チェックの結果(バナー)が出るまで待つ
            var bw = 0.0
            while AppServices.deps.checkCount == 0 && !AppServices.deps.dismissedThisSession && bw < 8 { try? await Task.sleep(nanoseconds: 50_000_000); bw += 0.05 }
            if env["MC_DEBUG_SECOND"] != nil { try? await Task.sleep(nanoseconds: 800_000_000) }
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

    // MARK: プロパティ欄・キャラクターの検証

    /// 話者一覧が読み込まれる(または失敗する)まで待つ(最大 40 秒)。
    private func waitSpeakers(_ model: ProjectModel) async {
        var waited = 0.0
        let cat = AppServices.speakers
        while (cat.state == .idle || cat.state == .loading) && waited < 40 {
            try? await Task.sleep(nanoseconds: 100_000_000); waited += 0.1
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        Self.out("speakers: state=\(cat.state) count=\(cat.choices.count) first=\(cat.choices.first?.label ?? "-")")
    }

    private func debugDeleteChar(_ spec: String, _ model: ProjectModel) async {
        let f = spec.split(separator: ":").map(String.init)
        guard let i = f.first.flatMap(Int.init), model.project.characters.indices.contains(i) else { Self.out("delete-char: 指定が読めません: \(spec)"); return }
        let ch = model.project.characters[i]
        let before = (model.project.characters.count, model.project.allClips.count)
        if f.count > 1, f[1] == "do" {
            let ok = model.deleteCharacter(ch.id)
            let um = model.effectiveUndoManager
            Self.out("delete-char: \(ch.name) ok=\(ok) characters \(before.0)→\(model.project.characters.count) clips \(before.1)→\(model.project.allClips.count) selectedChar=\(model.effectiveSelectedCharId == model.project.characters.first?.id ? "first" : "other") canUndo=\(um.canUndo)")
            um.undo()
            Self.out("delete-char: undo → characters \(model.project.characters.count) clips \(model.project.allClips.count)")
        } else {
            model.selectCharacter(ch.id)
            model.requestDeleteCharacter(ch.id)
            Self.out("delete-char: 確認を出しました pending=\(model.pendingDeleteCharId != nil) \(model.deleteConfirmation(for: ch.id).map { "\($0.title) / \($0.message)" } ?? "-")")
        }
    }

    private func debugVoiceEdit(_ text: String, _ model: ProjectModel) async {
        guard let id = model.selectedClipId ?? model.project.allClips.first(where: { $0.type == .voice })?.id, let before = model.clip(id), before.type == .voice else {
            Self.out("voice-edit: ボイスクリップを選べません"); return
        }
        func wavLen(_ c: Clip) -> String { c.src.flatMap { try? RealVoiceProvider.duration(of: URL(fileURLWithPath: $0)) }.map { String(format: "%.3f", $0) } ?? "-" }
        func line(_ label: String, _ c: Clip) {
            Self.out("voice-edit: \(label) text=\"\(c.text ?? "")\" src=\(c.src.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-") wav=\(wavLen(c))s duration=\(String(format: "%.3f", c.duration)) offset=\(String(format: "%.3f", c.offset))")
        }
        model.selectedClipId = id
        line("before", before)
        let ok = await model.setVoiceText(text, clipId: id)
        let um = model.effectiveUndoManager
        if let a = model.clip(id) { line("after (ok=\(ok), duration≈wav+0.15: \(abs(a.duration - (Double(wavLen(a)) ?? 0) - 0.15) < 0.002))", a) }
        Self.out("voice-edit: canUndo=\(um.canUndo) undoName=\(um.undoActionName) error=\(model.errorMessage ?? "-")")
        um.undo()
        if let u = model.clip(id) { line("undone (== before: \(u == before))", u) }
        um.redo()
        if let r = model.clip(id) { line("redone", r) }
        um.undo()
        Self.out("voice-edit: final canUndo=\(um.canUndo) canRedo=\(um.canRedo)")
    }

    // MARK: タイムライン編集の検証

    private func dragMode(_ s: String) -> TimelineCanvas.DragMode? {
        switch s { case "move": return .move; case "trimL": return .trimLeft; case "trimR": return .trimRight; default: return nil }
    }

    /// "move:0:1.3[:2]" 形式。
    private func parseDrag(_ spec: String, _ model: ProjectModel) -> (id: String, mode: TimelineCanvas.DragMode, dt: Double, row: Int?)? {
        let f = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3, let mode = dragMode(f[0]), let i = Int(f[1]), let dt = Double(f[2]) else { return nil }
        let clips = model.project.allClips
        guard clips.indices.contains(i) else { return nil }
        return (clips[i].id, mode, dt, f.count > 3 ? Int(f[3]) : nil)
    }

    private func holdDrag(_ spec: String, _ model: ProjectModel) {
        guard let canvas = findCanvas(model.window?.contentView), let d = parseDrag(spec, model) else { Self.out("hold-drag: 指定が読めません: \(spec)"); return }
        canvas.debugDrag(clipId: d.id, mode: d.mode, deltaT: d.dt, targetTrack: d.row, hold: true)
        Self.out(String(format: "hold-drag: %@ guides=%@", spec, canvas.snapGuides.map { String(format: "%.3f", $0) }.joined(separator: ",")))
        dumpClips(model, label: "hold-drag")
    }

    private func dumpClips(_ model: ProjectModel, label: String) {
        for (ti, tr) in model.project.tracks.enumerated() {
            for (ci, c) in tr.clips.enumerated() {
                Self.out(String(format: "%@: T%d #%d %@ start=%.3f dur=%.3f off=%.3f", label, ti, ci, c.type.rawValue, c.start, c.duration, c.offset))
            }
        }
    }

    private func runEdits(_ spec: String, _ model: ProjectModel) async {
        let canvas = findCanvas(model.window?.contentView)
        for raw in spec.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            let head = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
            let nth: (String) -> Int? = { Int($0) }
            switch head {
            case "move", "trimL", "trimR":
                guard let canvas, let d = parseDrag(raw, model) else { Self.out("edit: 指定が読めません: \(raw)"); continue }
                canvas.debugDrag(clipId: d.id, mode: d.mode, deltaT: d.dt, targetTrack: d.row)
            case "split":
                // split:<idx>@<t>
                let body = raw.dropFirst("split:".count).split(separator: "@").map(String.init)
                let clips = model.project.allClips
                guard body.count == 2, let i = nth(body[0]), let t = Double(body[1]), clips.indices.contains(i) else { Self.out("edit: 指定が読めません: \(raw)"); continue }
                model.selectedClipId = clips[i].id
                model.currentTime = t
                Self.out("edit: split → \(model.splitSelected())")
            case "delete":
                let clips = model.project.allClips
                guard let i = nth(String(raw.dropFirst("delete:".count))), clips.indices.contains(i) else { Self.out("edit: 指定が読めません: \(raw)"); continue }
                model.selectedClipId = clips[i].id
                Self.out("edit: delete → \(model.deleteSelected())")
            case "text": _ = model.addTextClip()
            case "blur": _ = model.addBlurClip()
            case "media":
                let path = String(raw.dropFirst("media:".count))
                let ids = await model.addMedia(urls: [URL(fileURLWithPath: path)])
                Self.out("edit: media \(path) → \(ids.count) 個")
            default:
                Self.out("edit: 知らない操作: \(raw)")
            }
            canvas?.syncFromModel()
        }
        dumpClips(model, label: "edit")
        let um = model.effectiveUndoManager
        Self.out("edit: canUndo=\(um.canUndo) canRedo=\(um.canRedo) selected=\(model.selectedClipId ?? "-")")
    }

    // MARK: メニュー・ネイティブ動作の検証

    private static func shortcutText(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let k = item.keyEquivalent
        let names = ["\r": "⏎", "\u{3}": "⌅", "\u{8}": "⌫", "\u{7f}": "⌫", " ": "Space", "\u{1b}": "⎋",
                     "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→"]
        if let n = names[k] { return s + n }
        return s + k.uppercased() + (k.unicodeScalars.first.map { $0.value > 126 || $0.value < 32 ? "(U+\(String($0.value, radix: 16)))" : "" } ?? "")
    }

    private static func menuLines(_ menu: NSMenu, depth: Int) -> [String] {
        var out: [String] = []
        let pad = String(repeating: "  ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem { out.append(pad + "----"); continue }
            var line = pad + item.title
            let sc = shortcutText(item)
            if !sc.isEmpty { line += "  [\(sc)]" }
            line += item.isEnabled ? "" : "  (無効)"
            switch item.state { case .on: line += "  ✓"; case .mixed: line += "  −"; default: break }
            if item.isHidden { line += "  (隠し)" }
            if item.isAlternate { line += "  (代替)" }
            if let a = item.action, item.submenu == nil { line += "  → \(NSStringFromSelector(a))" }
            out.append(line)
            if let sub = item.submenu { out += menuLines(sub, depth: depth + 1) }
        }
        return out
    }

    /// メニューの有効・チェックは、メニューが開かれる(update される)ときに決まる。読む前に全階層を更新する。
    private static func updateAll(_ menu: NSMenu) {
        // 本物のメニューを開いたときと同じ更新(SwiftUI のメニューは menuNeedsUpdate の中で中身を差し替える)
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for i in menu.items { if let s = i.submenu { updateAll(s) } }
    }

    private func dumpMainMenu(label: String) {
        guard let menu = NSApp.mainMenu else { Self.out("menu: mainMenu がありません"); return }
        Self.updateAll(menu)
        if let w = NSApp.keyWindow { Self.out("menu: keyWindow collectionBehavior.fullScreenPrimary=\(w.collectionBehavior.contains(.fullScreenPrimary)) styleMask.fullScreen=\(w.styleMask.contains(.fullScreen)) isMainWindow=\(w.isMainWindow) tabbing=\(w.tabbingMode.rawValue) windows=\(NSApp.windows.map { $0.title })") }
        Self.out("menu: active.model=\(ActiveDocument.shared.model != nil) state=\(ActiveDocument.shared.state)")
        Self.out("menu: ===== NSApp.mainMenu (\(label)) ===== appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow?.title ?? "-") mainWindow=\(NSApp.mainWindow?.title ?? "-")")
        for l in Self.menuLines(menu, depth: 0) { Self.out("menu: " + l) }
        Self.out("menu: ===== end =====")
        Self.out("menu: top-level order = \(menu.items.map { MenuOrder.title(of: $0) }) (MenuOrder.fixCount=\(MenuOrder.fixCount))")
    }

    /// メニューバーの状態アイコンのメニューの中身(本物の NSStatusItem は作らず、中身のモデルだけ出す)。
    private func dumpStatus(_ label: String) {
        let c = AppServices.statusBar
        Self.out("status: ===== status item menu (\(label)) ===== presenter=\(type(of: c.presenter)) visible=\(c.presenter.isVisible) enabled(pref)=\(c.isEnabled) buttonTitle=\"\(c.presenter.buttonTitle)\" engine=\(c.state.engine)")
        for l in StatusMenuBuilder.lines(c.entries) { Self.out("status: " + l) }
        Self.out("status: ===== end =====")
    }

    /// 題の一致。キーのヒントを添えた題(「クリップを分割  (S)」)は、ヒントを除いた名前でも一致させる。
    static func titleMatches(_ title: String, _ name: String) -> Bool {
        title == name || title.hasPrefix(name + "  (")
    }

    /// 「出力/解像度/縦 1080×1920」(「解像度/…」のように途中からでも探せる)のような道筋で項目を探す(最初の名前は、メニューバーのどの階層にあってもよい)。
    private static func findMenuItem(_ path: [String], in menu: NSMenu) -> (NSMenu, Int)? {
        func descend(_ menu: NSMenu, _ rest: ArraySlice<String>) -> (NSMenu, Int)? {
            guard let first = rest.first, let i = menu.items.firstIndex(where: { Self.titleMatches($0.title, first) }) else { return nil }
            if rest.count == 1 { return (menu, i) }
            guard let sub = menu.items[i].submenu else { return nil }
            return descend(sub, rest.dropFirst())
        }
        func search(_ menu: NSMenu) -> (NSMenu, Int)? {
            if let r = descend(menu, path[...]) { return r }
            for item in menu.items { if let sub = item.submenu, let r = search(sub) { return r } }
            return nil
        }
        return search(menu)
    }

    private func stateLine(_ model: ProjectModel) -> String {
        let um = model.effectiveUndoManager
        let sel = model.selectedClip.map { $0.type.rawValue } ?? "-"
        return "state: active=\(ActiveDocument.shared.model === model) locked=\(model.isLocked) size=\(model.project.width)x\(model.project.height) codec=\(model.project.codec) bg=\(model.project.bg) clips=\(model.project.allClips.count) chars=\(model.project.characters.count) selected=\(sel) canUndo=\(um.canUndo) undo=\"\(um.undoActionName)\" t=\(String(format: "%.3f", model.currentTime)) markers=\(model.project.markers.count) status=\"\(model.statusText)\" error=\(model.errorMessage ?? "-")"
    }

    /// このドキュメントを前面にして、メニューの操作先(ActiveDocument)になるまで待つ。
    private func bringToFront(_ model: ProjectModel) async {
        DebugHooks.quietActivate()
        model.window?.debugOrderFront()
        var w = 0.0
        while ActiveDocument.shared.model !== model && w < 5 {
            model.window?.debugOrderFront()
            ActiveDocument.shared.activate(model)
            try? await Task.sleep(nanoseconds: 100_000_000); w += 0.1
        }
    }

    private func menuClicks(_ spec: String, _ model0: ProjectModel) async {
        await settle(model0)
        await bringToFront(model0)    // メニューの操作先(ActiveDocument)にする(静かな起動では前面にならないため)
        // 空の書類が複数あるとき、メニューが操作するのは前面(メイン)の書類。そちらを相手にする
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let model = ActiveDocument.shared.model ?? model0
        if let t = env["MC_DEBUG_MENU_SCRIPT"] { model.scriptText = t.replacingOccurrences(of: "\\n", with: "\n") }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        Self.out("menu-click: initial " + stateLine(model))
        for raw in spec.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            if raw.hasPrefix("@") { await menuClickToken(raw, model); continue }
            let path = raw.split(separator: "/").map(String.init)
            guard let main = NSApp.mainMenu, let (menu, idx) = Self.findMenuItem(path, in: main) else {
                Self.out("menu-click: \(raw) → 見つかりません"); continue
            }
            let item = menu.items[idx]
            let before = item.state
            Self.updateAll(main)
            guard item.isEnabled else { Self.out("menu-click: \(raw) → 無効のため押せません"); continue }
            menu.performActionForItem(at: idx)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if model.showJumpSheet, let v = env["MC_DEBUG_JUMP_VALUE"] {
                // シートの Return と同じ関数
                let t0 = model.currentTime
                let ok = model.commitJump(v)
                Self.out("menu-click:   (時間を指定して移動シート: 入力 \"\(v)\" → \(ok ? "決定" : "読めない") 再生位置 \(String(format: "%.3f", t0)) → \(String(format: "%.3f", model.currentTime)), 終わり \(String(format: "%.3f", model.project.endTime)))")
            }
            var waited = 0.0
            while model.busyMessage != nil && waited < 120 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 0.1 }
            try? await Task.sleep(nanoseconds: 800_000_000)   // メニューの✓が更新されるのを待つ
            Self.updateAll(main)   // 本物のメニューを開いたときと同じ更新をして、✓ を読み直す
            Self.out("menu-click: \(raw) → 押しました (✓ \(before == .on ? "on" : "off") → \(menu.items[idx].state == .on ? "on" : "off"))")
            Self.out("menu-click:   " + stateLine(model))
        }
    }

    /// `MC_DEBUG_MENU_CLICK` の `@` で始まる特別な項目。
    private func menuClickToken(_ raw: String, _ model: ProjectModel) async {
        let body = String(raw.dropFirst())
        let kv = body.split(separator: "=", maxSplits: 1).map(String.init)
        switch kv[0] {
        case "time":
            if kv.count == 2, let t = Double(kv[1]) { model.currentTime = t; try? await Task.sleep(nanoseconds: 300_000_000) }
            Self.out("menu-click: @time → \(String(format: "%.3f", model.currentTime))")
        case "select":
            if kv.count == 2, let i = Int(kv[1]), model.project.allClips.indices.contains(i) { model.selectedClipId = model.project.allClips[i].id; try? await Task.sleep(nanoseconds: 300_000_000) }
            Self.out("menu-click: @select → selected=\(model.selectedClip.map { "\($0.type.rawValue) \($0.id)" } ?? "-")")
        case "clips":
            dumpClips(model, label: "clips")
            for m in model.project.markers { Self.out(String(format: "clips: marker %@ time=%.3f name=%@", m.id, m.time, m.name)) }
            Self.out("clips: selected=\(model.selectedClipId ?? "-") layers=\(model.project.tracks.count) endTime=\(String(format: "%.3f", model.project.endTime))")
        case "export":
            // @export=<preset|current>:<out>
            let parts = (kv.count == 2 ? kv[1] : "").split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { Self.out("menu-click: @export の指定が読めません: \(raw)"); return }
            // 前の書き出しが終わったあと、メニューの有効・無効が組み直されるのを待つ
            while model.isExporting { try? await Task.sleep(nanoseconds: 50_000_000) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let preset = ExportPreset(cliName: parts[0])
            let itemName = preset?.title ?? "現在の設定で書き出す…"
            Self.updateAll(NSApp.mainMenu!)
            let found = NSApp.mainMenu.flatMap { Self.findMenuItem(["書き出し", itemName], in: $0) }
            let enabled = found.map { $0.0.items[$0.1].isEnabled } ?? false
            Self.out("menu-click: @export → メニュー項目「ファイル ▸ 書き出し ▸ \(itemName)」found=\(found != nil) enabled=\(enabled)")
            guard enabled else { return }
            let before = model.project
            let url = URL(fileURLWithPath: parts[1])
            let suggested = model.exportSuggestedName(preset: preset)
            let t0 = Date()
            let r = await model.runExport(to: url, preset: preset)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            Self.out(String(format: "menu-click: @export → %@ suggestedName=%@ result=%@ bytes=%d (%.1fs) documentUnchanged=%@ status=%@", url.lastPathComponent, suggested, "\(r)", size, Date().timeIntervalSince(t0), model.project == before ? "true" : "false", model.statusText))
        default:
            Self.out("menu-click: \(raw) → 読めません")
        }
    }

    /// キー(⌘+ など)を本物のキーイベントにしてメニューバーへ渡し、項目が反応するか見る。
    private func menuKeys(_ spec: String, _ model0: ProjectModel) async {
        await settle(model0)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let model = ActiveDocument.shared.model ?? model0
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let codes: [String: UInt16] = ["=": 24, "-": 27, "0": 29, "t": 17, "b": 11, "c": 8, "i": 34, "e": 14, "p": 35, ",": 43, "return": 36, "a": 0, "s": 1, "z": 6, "x": 7, "v": 9]
        for raw in spec.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            let parts = raw.split(separator: "+").map(String.init)
            guard let key = parts.last, let code = codes[key] else { Self.out("menu-key: \(raw) → 読めません"); continue }
            var flags: NSEvent.ModifierFlags = []
            if parts.contains("cmd") { flags.insert(.command) }
            if parts.contains("shift") { flags.insert(.shift) }
            if parts.contains("opt") { flags.insert(.option) }
            let chars = key == "return" ? "\r" : (flags.contains(.shift) ? (key == "=" ? "+" : key.uppercased()) : key)
            let ign = key == "return" ? "\r" : key
            guard let win = model.window,
                  let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code) else { continue }
            let pps0 = model.pps, clips0 = model.project.allClips.count, sets0 = model.showSettings
            Self.updateAll(NSApp.mainMenu!)
            let fileURL = model.fileURL
            func mt() -> String { fileURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date)?.map { String($0.timeIntervalSince1970) } } ?? "-" }
            let m0 = mt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { Self.out("menu-key: (6 秒たちました) \(raw)") }
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if key == "s" { Self.out("menu-key: save → file mtime changed=\(mt() != m0) docEdited=\(model.window.flatMap { NSDocumentController.shared.document(for: $0) }?.isDocumentEdited ?? false)") }
            Self.out(String(format: "menu-key: %@ → handled=%@ pps %.1f→%.1f clips %d→%d settingsSheet %@→%@", raw, handled ? "true" : "false", pps0, model.pps, clips0, model.project.allClips.count, sets0 ? "on" : "off", model.showSettings ? "on" : "off"))
        }
    }

    private func debugEdited(_ model: ProjectModel) async {
        guard let win = model.window else { return }
        await settle(model)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let doc = NSDocumentController.shared.document(for: win)
        let path = doc?.fileURL?.path
        func mtime() -> String { path.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date)?.map { String($0.timeIntervalSince1970) } } ?? "-" }
        Self.out("edited: start isDocumentEdited=\(win.isDocumentEdited) docEdited=\(doc?.isDocumentEdited ?? false) title=\"\(win.title)\" file=\(path ?? "-") mtime=\(mtime())")
        Self.out("edited: model.undoManager=\(model.undoManager != nil) same-as-doc=\(doc?.undoManager === model.undoManager) same-as-window=\(win.undoManager === model.undoManager) docUM=\(doc?.undoManager != nil) groupsByEvent=\(model.undoManager?.groupsByEvent ?? false) levels=\(model.undoManager?.levelsOfUndo ?? -1)")
        model.addTextClip()
        try? await Task.sleep(nanoseconds: 800_000_000)
        Self.out("edited: um.canUndo=\(model.effectiveUndoManager.canUndo) docUM.canUndo=\(doc?.undoManager?.canUndo ?? false) updateChangeCount-edited=\(doc?.isDocumentEdited ?? false)")
        func edited(_ label: String) {
            Self.out("edited: \(label) window.isDocumentEdited=\(win.isDocumentEdited) doc.isDocumentEdited=\(doc?.isDocumentEdited ?? false) title=\"\(win.title)\" controllers=\(doc?.windowControllers.map { String(describing: type(of: $0)) } ?? [])")
        }
        edited("after edit")
        let um = model.effectiveUndoManager
        um.undo()
        try? await Task.sleep(nanoseconds: 800_000_000)
        edited("after undo")
        um.redo()
        try? await Task.sleep(nanoseconds: 800_000_000)
        edited("after redo")
        if let doc, path != nil {
            let t0 = mtime()
            if let url = doc.fileURL {
                doc.save(to: url, ofType: doc.fileType ?? "jp.local.moviecut.project", for: .saveOperation) { err in
                    Self.out("edited: save completion error=\(err?.localizedDescription ?? "nil")")
                }
            }
            var w = 0.0
            while doc.isDocumentEdited && w < 10 { try? await Task.sleep(nanoseconds: 100_000_000); w += 0.1 }
            try? await Task.sleep(nanoseconds: 500_000_000)
            edited("after save (waited \(String(format: "%.1f", w))s, mtime changed=\(mtime() != t0))")
            let reread = path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.flatMap { try? Project.decode(from: $0) }
            Self.out("edited: file on disk now has \(reread?.tracks.flatMap { $0.clips }.count ?? -1) clips (model has \(model.project.allClips.count))")
        } else { Self.out("edited: 保存先が無いので保存は試しません") }
    }

    /// 終了の経路の確認。`MC_DEBUG_QUIT=<mode>[+engine]`
    /// - `1`: 未保存なしで ⌘Q(`NSApp.terminate`)。そのまま終わるはず。
    /// - `engine`(または `+engine`): 先に VOICEVOX エンジンを自分で起動する(`MC_DEBUG_ENGINE_URL` でポートを変えられる)。
    /// - `dirty`: 編集して未保存にしてから終了を試み、確認シートの題・ボタンを出す。`dirty:cancel` / `dirty:discard` / `dirty:save` は
    ///   そのボタン(キャンセル / 保存しない / 保存)を実際に押して、アプリが生きているか・終わったか・ファイルが書けたかを出す。
    ///   (`dirty:save` は `MC_OPEN` で開いた一時コピーに保存する。保存先が無い書類は保存パネルになるため。)
    private func debugQuit(_ mode0: String, _ model: ProjectModel) async {
        await settle(model)
        let parts = mode0.split(separator: "+").map(String.init)
        let mode = parts.first ?? "1"
        if parts.contains("engine") || mode == "engine" {
            // MC_DEBUG_ENGINE_URL: 本物の VOICEVOX が動いていても自分のエンジンを別ポートで起動して確かめるため
            let url = env["MC_DEBUG_ENGINE_URL"] ?? model.project.voicevoxUrl
            let ok = await AppServices.engine.ensureRunning(baseURL: url)
            Self.out("quit: engine ensureRunning=\(ok) startedByUs=\(AppServices.engine.startedByUs)")
        }
        if mode.hasPrefix("dirty") {
            let action = mode.split(separator: ":").dropFirst().first.map(String.init)
            let clipsBefore = model.project.allClips.count
            model.addTextClip()
            try? await Task.sleep(nanoseconds: 800_000_000)
            Self.out("quit: dirty window.isDocumentEdited=\(model.window?.isDocumentEdited ?? false) NSDocument.isDocumentEdited=\(model.window.flatMap { NSDocumentController.shared.document(for: $0)?.isDocumentEdited } ?? false) clips \(clipsBefore)→\(model.project.allClips.count)")
            let t0 = CACurrentMediaTime()
            // NSApp.terminate は、未保存の書類があると確認シートの答えが出るまで戻ってこない(AppKit が入れ子のイベントループで待つ。
            // 主スレッドは止まっておらずループは回っている)。なので、シートを調べてボタンを押す側は terminate の前に走らせておく。
            // (確認待ちの入れ子ループでは async の続き = メインキュー が動かないので、common モードの Timer で見張る)
            self.watchQuitSheet(model, action: action, t0: t0)
            Self.out("quit: terminate を呼びます")
            NSApp.terminate(nil)
            // ここへ戻ってくるのは、キャンセルされたとき(終了しないとき)だけ
            Self.out(String(format: "quit: terminate が戻りました(%.2fs 後)= 終了は取り消されました。running=%@", CACurrentMediaTime() - t0, NSApp.isRunning ? "yes" : "no"))
            try? await Task.sleep(nanoseconds: 3_500_000_000)   // ボタンを押した側の「N 秒後」の報告が出るのを待つ
            Self.finish(0)
        }
        Self.out("quit: NSApp.terminate を呼びます")
        NSApp.terminate(nil)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        Self.out("quit: まだ動いています(終了が止められました)")
        Self.finish(1)
    }

    private var quitWatchTimer: Timer?

    private func watchQuitSheet(_ model: ProjectModel, action: String?, t0: CFTimeInterval) {
        var pressed = false
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !pressed else { return }
                let elapsed = CACurrentMediaTime() - t0
                guard let sheet = model.window?.attachedSheet else {
                    if elapsed > 10 { Self.out("quit: 10 秒待っても確認シートが出ません"); Self.finish(1) }
                    return
                }
                pressed = true; timer.invalidate()
                Self.out(String(format: "quit: terminate の %.2fs 後 確認シートあり(主スレッドは動いている)", elapsed))
                func collect(_ v: NSView, _ buttons: inout [NSButton], _ texts: inout [String]) {
                    if let b = v as? NSButton, !b.title.isEmpty { buttons.append(b) }
                    if let t = v as? NSTextField, !t.stringValue.isEmpty { texts.append(t.stringValue) }
                    v.subviews.forEach { collect($0, &buttons, &texts) }
                }
                var buttons: [NSButton] = [], texts: [String] = []
                if let c = sheet.contentView { collect(c, &buttons, &texts) }
                Self.out("quit: シート class=\(type(of: sheet)) texts=\(texts) buttons=\(buttons.map(\.title))")
                if let dir = self.env["MC_SNAPSHOT_DIR"], let png = Self.png(of: sheet, over: NSColor(calibratedWhite: 0.2, alpha: 1)) {
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("quit-sheet.png"))
                }
                guard let action else { Self.finish(0) }
                // 保存済みの書類だと「保存しない」は「変更を元に戻す」という名前で出る(自動保存つきの書類のシート)
                let wants: [String] = ["cancel": ["キャンセル"], "discard": ["保存しない", "変更を元に戻す"], "save": ["保存"]][action] ?? [action]
                guard let button = buttons.first(where: { wants.contains($0.title) }) else { let want = wants[0]
                    Self.out("quit: ボタン「\(want)」が見つかりません"); Self.finish(1) }
                let want = button.title
                let path = model.fileURL?.path
                let mtime0 = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
                Self.out("quit: ボタン「\(want)」を押します")
                button.performClick(nil)
                // 押したあと: 「保存しない」「保存」ならアプリはここで終わる。生きていたら(= 終わらない)様子を出す
                for delay in [1.0, 3.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.reportAfterQuitButton(model, want: want, path: path, mtime0: mtime0, label: "「\(want)」の \(delay)s 後(= まだ終わっていない)")
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        quitWatchTimer = t
    }

    private func reportAfterQuitButton(_ model: ProjectModel, want: String, path: String?, mtime0: Date?, label: String) {
        let mtime1 = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        let onDisk = path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.flatMap { try? Project.decode(from: $0) }
        Self.out("quit: \(label): アプリは生きている edited=\((model.window?.isDocumentEdited ?? false) ? "yes" : "no") sheet=\(model.window?.attachedSheet != nil ? "あり" : "なし") ファイル更新=\(mtime0 != mtime1 ? "yes" : "no") ディスク上のクリップ数=\(onDisk.map { String($0.allClips.count) } ?? "-") モデルのクリップ数=\(model.project.allClips.count)")
    }

    /// `MC_DEBUG_SWEEP=1`(`MC_DEBUG_HANGWATCH=1` と一緒に): 主スレッドで本物の仕事をする一連の局面を順に行い、局面ごとの固まりを数える。
    /// MC_OPEN の書類(一時コピー)に対して行う。マウスは使えないので、ドラッグはジェスチャー API(begin/update/commit)で再現する。
    /// `MC_DEBUG_SWEEP_EXPORT=<out.mp4>` があれば最後に書き出し(UI と同じ runExport)も行う。
    private func debugSweep(_ model: ProjectModel) async {
        await settle(model)
        let hw = HangWatch.shared
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func phase(_ n: String) { hw.phase(n); Self.out("sweep: phase \(n)") }
        phase("idle 1.5s"); await sleep(1.5)
        phase("select clips")
        for c in model.project.allClips.prefix(60) { model.selectedClipId = c.id; await sleep(0.01) }
        phase("edit text/slider (gesture)")
        model.addTextClip(); await sleep(0.2)
        if let id = model.selectedClipId ?? model.project.allClips.last?.id {
            model.beginGesture()
            for i in 0..<120 {
                var p = model.project
                if let ti = p.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }), let ci = p.tracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    p.tracks[ti].clips[ci].start += 0.001 * Double(i % 5)
                }
                model.updateGesture(p); await sleep(0.008)
            }
            model.commitGesture("ドラッグ")
            for i in 0..<30 { model.setClipField(.opacity, Double(i % 10) / 10 + 0.05, clipId: id); await sleep(0.01) }
        }
        phase("undo/redo")
        for _ in 0..<10 { model.effectiveUndoManager.undo(); await sleep(0.02) }
        for _ in 0..<10 { model.effectiveUndoManager.redo(); await sleep(0.02) }
        phase("save (real, ⌘S path)")
        if let d = model.window.flatMap({ NSDocumentController.shared.document(for: $0) }) {
            d.save(nil); await sleep(1.5)
            Self.out("sweep: saved isDocumentEdited=\(d.isDocumentEdited)")
        }
        phase("resolution switch")
        model.selectResolution("1280x720"); await sleep(0.5); model.selectResolution("1920x1080"); await sleep(0.5)
        phase("playback 2s")
        model.playback.play(); await sleep(2); model.playback.pause()
        phase("window resize 60Hz x1.5s")
        if let w = model.window {
            let f0 = w.frame
            for i in 0..<90 {
                var f = f0; f.size.width += CGFloat(i % 40) * 4; f.size.height += CGFloat(i % 30) * 4
                w.setFrame(f, display: true); await sleep(1.0 / 60)
            }
            w.setFrame(f0, display: true)
        }
        phase("second screen open/close")
        model.toggleSecondScreen(); await sleep(0.7); model.toggleSecondScreen(); await sleep(0.5)
        if let out = env["MC_DEBUG_SWEEP_EXPORT"] {
            phase("export")
            let r = await model.runExport(to: URL(fileURLWithPath: out))
            Self.out("sweep: export \(r)")
        }
        phase("end")
        Self.finish(0)
    }

    private func debugFrame(_ spec: String, _ model: ProjectModel) async {
        guard let win = model.window else { return }
        await settle(model)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if spec.hasPrefix("set:") {
            let p = spec.dropFirst(4).split(separator: ",").compactMap { Double($0) }
            guard p.count == 4 else { Self.out("frame: 指定が読めません"); return }
            Self.out("frame: before \(NSStringFromRect(win.frame)) autosave=\"\(win.frameAutosaveName)\"")
            win.setFrame(NSRect(x: p[0], y: p[1], width: p[2], height: p[3]), display: true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            Self.out("frame: set → \(NSStringFromRect(win.frame))")
            win.close()
            try? await Task.sleep(nanoseconds: 500_000_000)
            Self.finish(0)
        } else if spec == "min" {
            Self.out("frame: before content=\(NSStringFromSize(win.contentView?.frame.size ?? .zero)) minSize=\(NSStringFromSize(win.minSize)) contentMinSize=\(NSStringFromSize(win.contentMinSize))")
            win.setContentSize(NSSize(width: 300, height: 300))
            try? await Task.sleep(nanoseconds: 600_000_000)
            Self.out("frame: setContentSize(300,300) → content=\(NSStringFromSize(win.contentView?.frame.size ?? .zero)) frame=\(NSStringFromRect(win.frame))")
            Self.finish(0)
        } else {
            Self.out("frame: print \(NSStringFromRect(win.frame)) autosave=\"\(win.frameAutosaveName)\" screen=\(NSStringFromRect(win.screen?.visibleFrame ?? .zero))")
            Self.finish(0)
        }
    }

    // MARK: 再生の検証

    private func runPlaybackDebug(_ model: ProjectModel) async {
        await settle(model)
        let pb = model.playback!
        let end = model.project.endTime
        Self.out(String(format: "project: end=%.3fs clips=%d fps=%@", end, model.project.allClips.count, FrameRate.label(model.project.fps)))
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        /// 再生が始まる(ミックスの準備が終わる)まで待つ
        func waitPlaying() async -> Bool {
            var w = 0.0
            while !pb.isPlaying && w < 120 { await sleep(0.02); w += 0.02 }
            return pb.isPlaying
        }
        if let secs = env["MC_DEBUG_PLAY"].flatMap(Double.init) {
            let from = env["MC_DEBUG_PLAY_FROM"].flatMap(Double.init) ?? 0
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
        if env["MC_DEBUG_SEEK_TEST"] != nil {
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
        guard let dir = env["MC_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let win = model.window else { Self.out("snapshot: no window"); return }
        if env["MC_DEBUG_TREE"] != nil {
            func dump(_ v: NSView, _ d: Int) {
                Self.out(String(repeating: " ", count: d) + "\(type(of: v)) \(NSStringFromRect(v.frame)) hidden=\(v.isHidden)")
                if d < 8 { for c in v.subviews { dump(c, d + 1) } }
            }
            if let cv = win.contentView { dump(cv, 0) }
        }
        if let png = Self.png(of: win) { try? png.write(to: url.appendingPathComponent("window.png")) }
        if let second = model.secondScreen.window, let png = Self.png(of: second) { try? png.write(to: url.appendingPathComponent("second.png")) }
        if let sheet = win.attachedSheet, let png = Self.png(of: sheet, over: NSColor(calibratedWhite: 0.2, alpha: 1)) {
            try? png.write(to: url.appendingPathComponent("sheet.png"))
        }
        Self.out("snapshot: wrote \(url.path)")
    }

    /// ウィンドウの中身を PNG にする(画面収録の許可に頼らず、レイヤーを直接描く)。
    /// `over` を指定すると、その色を下地にして重ねる(警告シートは背景が半透明で、そのままだと文字だけが写るため)。
    static func png(of win: NSWindow, over background: NSColor? = nil) -> Data? {
        guard let view = win.contentView else { return nil }
        win.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let bg = background else { return rep.representation(using: .png, properties: [:]) }
        let out = NSImage(size: view.bounds.size)
        out.lockFocus()
        bg.setFill(); NSRect(origin: .zero, size: view.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let r2 = NSBitmapImageRep(data: tiff) else { return nil }
        return r2.representation(using: .png, properties: [:])
    }

    nonisolated static func trace(_ s: String) {
        if ProcessInfo.processInfo.environment["MC_DEBUG_TRACE"] != nil { out("trace: " + s) }
    }

    /// 検証用の環境変数(`MC_DEBUG_*` / `MC_SNAPSHOT_DIR` / `MC_OPEN`)が 1 つでもあれば、ウィンドウの復元状態を読まず・書かない。
    /// (検証の起動は exit() で終わるため、復元状態が残ると、次にユーザーが普通に起動したとき余計なウィンドウが復元される。)
    /// 復元の可否は AppKit が起動の早い段階で UserDefaults の引数ドメインから読むので、App.init で入れる。
    nonisolated static func suppressStateRestorationIfDebugging() {
        let env = ProcessInfo.processInfo.environment
        guard env.keys.contains(where: { $0.hasPrefix("MC_DEBUG_") || $0 == "MC_SNAPSHOT_DIR" || $0 == "MC_OPEN" }),
              env["MC_DEBUG_KEEP_STATE"] == nil else { return }
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["ApplePersistenceIgnoreState"] = true
        domain["NSQuitAlwaysKeepsWindows"] = false
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    /// 検証用の環境変数があるか(静かな起動にする)。
    nonisolated static var isDebugRun: Bool {
        let env = ProcessInfo.processInfo.environment
        return env.keys.contains { $0.hasPrefix("MC_DEBUG_") || $0 == "MC_SNAPSHOT_DIR" || $0 == "MC_OPEN" }
    }

    /// 静かな起動: Dock にもメニューバーにも出ない(.accessory)・前面にしない・ウィンドウは画面の遠くの外・20 秒で自分で終わる。
    /// ユーザーが同じ Mac で作業していても邪魔をしないため。`MC_DEBUG_VISIBLE=1` で通常の表示に戻せる(画面を撮るとき用)。
    nonisolated static var isQuiet: Bool { isDebugRun && ProcessInfo.processInfo.environment["MC_DEBUG_VISIBLE"] == nil }

    static func quietActivate() {
        if isQuiet { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 起動の最初(applicationWillFinishLaunching)に呼ぶ。
    static func enterQuietModeIfNeeded() {
        if HangWatch.enabled { HangWatch.shared.start() }
        guard isQuiet else { return }
        NSApp.setActivationPolicy(.accessory)
        let limit = ProcessInfo.processInfo.environment["MC_DEBUG_MAXSEC"].flatMap(Double.init) ?? 20
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            out("debug: \(limit) 秒たったので自分で終了します")
            if HangWatch.enabled { HangWatch.shared.printSummary() }
            PlaybackTempFiles.removeCurrent()
            exit(0)
        }
    }

    /// 書類ウィンドウ(NSPanel でない・見えている)の数。
    static func docWindowCount() -> Int {
        NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }.count
    }

    /// `NSApp.windows` と `NSDocumentController.shared.documents` を出す(MC_DEBUG_WINDOWS / MC_DEBUG_DOCS)。
    static func dumpWindows() {
        let docs = NSDocumentController.shared.documents
        out("windows: count=\(NSApp.windows.count) visibleDocWindows=\(docWindowCount()) documents=\(docs.count)")
        for (i, w) in NSApp.windows.enumerated() {
            out("windows: [\(i)] class=\(type(of: w)) title=\"\(w.title)\" visible=\(w.isVisible) frame=\(NSStringFromRect(w.frame)) delegate=\(w.delegate.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        for d in docs {
            out("windows: doc \(type(of: d)) url=\(d.fileURL?.lastPathComponent ?? "untitled") windowControllers=\(d.windowControllers.count) edited=\(d.isDocumentEdited)")
        }
    }

    /// 自分自身に kAEReopenApplication を送る(Dock のアイコンのクリックと同じ)。
    static func sendReopenAppleEvent() {
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication), targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        AESendMessage(ev.aeDesc!, nil, AESendMode(kAENoReply), 1)
    }

    nonisolated static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    /// 終了の経路の確認用(`MC_DEBUG_QUIT` があるときだけ出す)。
    static func logQuit(engineStartedByUs: Bool, after: Bool = false) {
        guard ProcessInfo.processInfo.environment["MC_DEBUG_QUIT"] != nil else { return }
        out("quit: applicationWillTerminate \(after ? "after shutdown" : "before shutdown") engineStartedByUs=\(engineStartedByUs)")
    }

    /// 書き出しの未保存確認などで止まらないよう、エンジンだけ止めて直接終わる。
    static func finish(_ code: Int32) -> Never {
        if HangWatch.enabled { HangWatch.shared.printSummary() }
        AppServices.engine.shutdown()
        PlaybackTempFiles.removeCurrent()
        exit(code)
    }
}

extension NSWindow {
    /// 検証用: 静かな起動では前面にせず、画面の外(x=-30000)に置く。
    @MainActor func debugOrderFront() {
        if DebugHooks.isQuiet {
            if frame.origin.x > -20000 { setFrameOrigin(NSPoint(x: -30000, y: -30000)) }
            orderBack(nil)
        } else {
            makeKeyAndOrderFront(nil)
        }
    }
}
