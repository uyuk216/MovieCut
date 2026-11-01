import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

// MARK: - 色の変換

extension Color {
    init(hex: String) {
        let c = parseHexColor(hex) ?? CGColor(red: 0.3, green: 0.55, blue: 1, alpha: 1)
        self.init(cgColor: c)
    }

    /// "#rrggbb"(sRGB)
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        func b(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", b(ns.redComponent), b(ns.greenComponent), b(ns.blueComponent))
    }
}

/// "00:04.68" 形式
func timecode(_ t: Double) -> String {
    let c = Int((max(0, t) * 100).rounded())
    return String(format: "%02d:%02d.%02d", c / 6000, (c / 100) % 60, c % 100)
}

/// ウィンドウを取り出す(検証用のスナップショットとダイアログの親に使う)。
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}

// MARK: - 画面全体

struct ContentView: View {
    @ObservedObject var model: ProjectModel
    var fileURL: URL?
    @ObservedObject var dock: DockStore
    /// false なら、別ウインドウのパネルを画面に出さない(試験用)。
    private let presentsDockWindows: Bool
    @Environment(\.undoManager) private var undoManager

    @MainActor init(model: ProjectModel, fileURL: URL?, dock: DockStore? = nil, presentsDockWindows: Bool = true) {
        self.model = model
        self.fileURL = fileURL
        self.presentsDockWindows = presentsDockWindows
        self.dock = dock ?? AppServices.panelDock
    }

    var body: some View {
        VStack(spacing: 0) {
            DependencyBannerBar(center: AppServices.deps)
            ToolbarBar(model: model)
            Divider()
            // キャラクター・プレビュー・プロパティ・タイムライン(初期配置はこれまでの画面と同じ。並べ替えは DockLayout)
            DockHost(model: model, store: dock)
        }
        .frame(minWidth: 1100, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .overlay { BusyOverlay(message: model.busyMessage, onCancel: model.transcribeCancel ?? model.aiCancel) }
        .sheet(isPresented: $model.showSettings) { SettingsSheet(model: model) }
        .sheet(isPresented: $model.showResolutionSheet) { ResolutionSheet(model: model) }
        .sheet(isPresented: $model.showFpsSheet) { FrameRateSheet(model: model) }
        .sheet(isPresented: $model.showJumpSheet) { JumpToTimeSheet(model: model) }
        .sheet(isPresented: $model.showSilenceSheet) { SilenceCutSheet(model: model) }
        .sheet(isPresented: $model.showFindSheet) { FindReplaceSheet(model: model) }
        .sheet(isPresented: $model.showExportQueueSheet) { ExportQueueSheet(controller: AppServices.exportQueue) { model.showExportQueueSheet = false } }
        .sheet(isPresented: $model.showAudioLibrary) { AudioLibrarySheet(model: model) }
        .sheet(isPresented: Binding(get: { model.renamingMarkerId != nil }, set: { if !$0 { model.renamingMarkerId = nil } })) { RenameMarkerSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.isExporting }, set: { _ in })) { ExportSheet(model: model) }
        .alert(model.errorTitle, isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert(model.pendingDeleteCharId.flatMap { model.deleteConfirmation(for: $0)?.title } ?? "", isPresented: Binding(get: { model.pendingDeleteCharId != nil }, set: { if !$0 { model.pendingDeleteCharId = nil } })) {
            Button("消す", role: .destructive) { if let id = model.pendingDeleteCharId { model.deleteCharacter(id) } }
            Button("キャンセル", role: .cancel) { model.pendingDeleteCharId = nil }
        } message: { Text(model.pendingDeleteCharId.flatMap { model.deleteConfirmation(for: $0)?.message } ?? "") }
        .background(WindowAccessor { w in AppWindowPolicy.apply(to: w); model.window = w; if w.isMainWindow { ActiveDocument.shared.activate(model) } })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // タイムライン以外にドロップされたとき: 再生ヘッドの位置に置く(タイムライン上は TimelineCanvas が受ける)
            DropLoader.loadFileURLs(providers) { urls in
                Task { @MainActor in await model.addMedia(urls: urls) }
            }
        }
        .onAppear {
            model.undoManager = undoManager
            model.fileURL = fileURL
            model.installKeyboard()
            model.installDock(store: dock, presents: presentsDockWindows)
            if model.window?.isMainWindow == true { ActiveDocument.shared.activate(model) }
            DebugHooks.shared.attach(model)
        }
        .task { await AppServices.deps.refresh(project: model.project) }
        .task(id: model.project.voicevoxUrl) { await AppServices.speakers.load(baseURL: model.project.voicevoxUrl) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let w = note.object as? NSWindow, w === model.window { model.closeRecovery(); model.shutdown(); ActiveDocument.shared.deactivate(model) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { note in
            if let w = note.object as? NSWindow, w === model.window { ActiveDocument.shared.activate(model) }
        }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onChange(of: fileURL) { _, new in model.fileURL = new }
    }
}

// MARK: - ツールバー

struct ToolbarBar: View {
    @ObservedObject var model: ProjectModel

    /// ツールバーのボタンの題(試験が「解像度・設定・書き出しがウィンドウに無い」ことを確かめるための一覧。解像度・設定・書き出しはメニューバーの「出力」へ移した)。
    enum Title {
        static let addMedia = "素材を追加", text = "テキスト", blur = "ぼかし範囲", split = "分割", delete = "削除"
        static let all = [addMedia, text, blur, split, delete]
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                Button(Title.addMedia) { model.chooseAndAddMedia() }
                    .help("画像・動画・音声を再生ヘッドの位置に追加(Finder からのドラッグ&ドロップも可)")
                Button(Title.text) { model.addTextClip() }
                    .help("一番上のレイヤーに文字を追加")
                Button(Title.blur) { model.addBlurClip() }
                    .help("一番上のレイヤーにぼかし範囲を追加")
            }
            .disabled(model.isLocked)
            Divider().frame(height: 18)
            Group {
                Button(Title.split) { model.splitSelected() }
                    .disabled(model.isLocked || !model.canSplit)
                    .help("選択中のクリップを再生ヘッドで分割(S)")
                Button(Title.delete) { model.deleteSelected() }
                    .disabled(model.isLocked || model.selectedClip == nil)
                    .help("選択中のクリップを削除(Delete)")
            }
            Spacer(minLength: 12)
            FanStatusText(fan: AppServices.fan)
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private var statusLine: String {
        if !model.statusText.isEmpty { return model.statusText }
        let n = model.project.allClips.count
        return n > 0 ? "クリップ \(n) 個" : ""
    }
}

// MARK: - 左パネル

struct LeftPanel: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var speakers: SpeakerCatalog
    @Binding var scriptText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("キャラクター").font(.headline)
                Spacer()
                Button("＋") { model.addCharacter() }
                    .help("キャラクターを追加")
            }
            .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.project.characters) { ch in
                        CharacterRow(ch: ch, speakerName: ch.speaker.flatMap { speakers.label(for: $0) }, selected: ch.id == model.effectiveSelectedCharId) { model.selectCharacter(ch.id) }
                            .contextMenu {
                                Button("このキャラを消す", role: .destructive) { model.requestDeleteCharacter(ch.id) }
                                    .disabled(model.project.characters.count <= 1)
                            }
                    }
                }
            }
            .frame(maxHeight: 176)
            .fixedSize(horizontal: false, vertical: model.project.characters.count <= 3)
            Text("台本").font(.headline).padding(.top, 14).padding(.bottom, 4)
            Text("1行に1セリフ。「キャラ名: セリフ」の形で書くと、そのキャラで読み上げます。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $scriptText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                if scriptText.isEmpty {
                    Text("霊夢: ゆっくりしていってね！\nずんだもん: ずんだもんなのだ")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            Button {
                Task { await model.generateVoicesFromScript() }
            } label: {
                Text("台本から音声を作ってタイムラインに並べる")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(12)
    }
}

struct CharacterRow: View {
    let ch: Character
    /// VOICEVOX の話者一覧が読めていれば「ずんだもん（ノーマル）」
    var speakerName: String?
    let selected: Bool
    let action: () -> Void

    private var engineLabel: String {
        if ch.engine == "voicevox" { return speakerName ?? "VOICEVOX 話者 \(ch.speaker ?? 3)" }
        return "ゆっくり " + (ch.voice ?? "")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: ch.color)).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ch.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(engineLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color(red: 0.96, green: 0.78, blue: 0.24) : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 中央(プレビュー + 再生バー)

struct CenterPanel: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(project: model.project, time: model.currentTime, assets: model.assets, model: model, epoch: model.previewEpoch)
            .padding(10)
            TransportBar(model: model)
                .padding(.bottom, 10)
        }
    }
}

struct TransportBar: View {
    @ObservedObject var model: ProjectModel

    /// 再生バーの固定の題(解像度ピッカーは「出力」メニューへ移した)。
    enum Title {
        static let toStart = "⏮", play = "▶", pause = "⏸"
        static let all = [toStart, play, pause]
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(Title.toStart) { model.playback.goToStart() }
                .help("先頭へ(Home)")
            Button(model.isPlaying ? Title.pause : Title.play) { model.playback.togglePlay() }
                .help("再生 / 一時停止(Space)")
                .disabled(model.isLocked)
            Text("\(timecode(model.currentTime)) / \(timecode(model.project.endTime))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            // 解像度・fps は映像の上に重ねず、再生バーの時刻の右に小さく出す
            Text(VideoText.chip(width: model.project.width, height: model.project.height, fps: model.project.fps))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("プロジェクトの解像度とフレームレート(出力メニューで変えられます)")
        }
    }
}

// MARK: - オーバーレイとシート

struct BusyOverlay: View {
    let message: String?
    /// 取り消せる処理(AI への問い合わせ)のときだけ。
    var onCancel: (() -> Void)? = nil
    var body: some View {
        if let message {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(message).multilineTextAlignment(.center).font(.system(size: 14))
                    if let onCancel { Button("キャンセル", action: onCancel).keyboardShortcut(.cancelAction) }
                }
                .padding(24)
                .frame(minWidth: 280)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                .shadow(radius: 20)
            }
        }
    }
}

struct ExportSheet: View {
    @ObservedObject var model: ProjectModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.exportTitle).font(.headline)
            if !model.exportNotice.isEmpty {
                Text(model.exportNotice).font(.caption).foregroundStyle(.orange).frame(width: 320, alignment: .leading)
            }
            FanExportLines(fan: AppServices.fan)
            ProgressView(value: model.exportProgress).frame(width: 320)
            HStack {
                Text("\(Int((model.exportProgress * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { model.cancelExport() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .interactiveDismissDisabled()
    }
}

// MARK: - 時間を指定して移動 / マーカーの名前変更(M7)

/// 「時間を指定して移動…」(⌘J)。`12.5` `1:23` `1:23.5` `00:01:23.50` を受ける。Return で決定、Esc で取り消し。
struct JumpToTimeSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var text = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("時間を指定して移動").font(.headline)
            TextField("例: 12.5 / 1:23 / 1:23.5 / 00:01:23.50", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: text) { _, _ in failed = false }
            if failed {
                Text("時間を読み取れませんでした。例: 12.5(秒)・1:23(分:秒)・00:01:23.50(時:分:秒)").font(.caption).foregroundStyle(.red)
            } else {
                Text("全体の長さ \(timecode(model.project.endTime))。範囲を超えた値は先頭か末尾に収めます。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("キャンセル") { model.showJumpSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("移動") { commit() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear { text = timecode(model.currentTime); focused = true }
    }

    private func commit() { failed = !model.commitJump(text) }
}

/// 「マーカーを名前変更…」。
struct RenameMarkerSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("マーカーの名前").font(.headline)
            TextField("名前", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .focused($focused)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("キャンセル") { model.renamingMarkerId = nil }
                    .keyboardShortcut(.cancelAction)
                Button("変更") { commit() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear {
            name = model.project.markers.first { $0.id == model.renamingMarkerId }?.name ?? ""
            focused = true
        }
    }

    private func commit() {
        if let id = model.renamingMarkerId { model.renameMarker(id: id, to: name) }
        model.renamingMarkerId = nil
    }
}

// MARK: - 設定シート(動画設定ほか)

struct SettingsSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VideoSettingsDraft
    @State private var res: ResolutionInput
    @State private var fpsChoice: String
    @State private var fpsText: String
    private let original: VideoSettingsDraft
    private static let customFpsTag = "custom"

    init(model: ProjectModel) {
        self.model = model
        let d = VideoSettingsDraft(model.project)
        _draft = State(initialValue: d)
        _res = State(initialValue: ResolutionInput(width: d.width, height: d.height, codec: d.codec, fps: d.fps))
        let isPreset = FrameRate.presets.contains { FrameRate.same($0, d.fps) }
        _fpsChoice = State(initialValue: isPreset ? FrameRate.label(d.fps) : Self.customFpsTag)
        _fpsText = State(initialValue: FrameRate.label(d.fps))
        original = d
    }

    private var sizeKey: String {
        let k = "\(res.width ?? 0)x\(res.height ?? 0)"
        return ResolutionPresets.isPreset(k) ? k : ResolutionPresets.customKey
    }
    private var fpsValid: Bool { if case .success = FrameRateInput.parse(fpsText) { return true } else { return false } }
    private var bgPreset: String {
        let b = draft.bg.lowercased()
        return ["#000000", "#ffffff", "#00b140"].contains(b) ? b : "custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("設定").font(.title3.bold())
            GroupBox("動画") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow(alignment: .top) {
                        Text("サイズ")
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: Binding(get: { sizeKey }, set: { k in
                                if let sz = ResolutionInput.parseSize(k) { res.set(width: sz.width, height: sz.height) }
                            })) {
                                ForEach(ResolutionPresets.items, id: \.key) { Text($0.label).tag($0.key) }
                                Text("カスタム").tag(ResolutionPresets.customKey)
                            }.labelsHidden().frame(width: 200)
                            ResolutionFields(input: $res)
                        }
                    }
                    GridRow(alignment: .top) {
                        Text("FPS")
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: Binding(get: { fpsChoice }, set: { k in
                                fpsChoice = k
                                if k != Self.customFpsTag { fpsText = k }
                            })) {
                                ForEach(FrameRate.presets, id: \.self) { Text("\(FrameRate.label($0)) fps").tag(FrameRate.label($0)) }
                                Text("カスタム").tag(Self.customFpsTag)
                            }.labelsHidden().frame(width: 200)
                            if fpsChoice == Self.customFpsTag {
                                FrameRateFields(text: $fpsText)
                            }
                        }
                    }
                    GridRow {
                        Text("背景色")
                        HStack {
                            ColorPicker("", selection: Binding(get: { Color(hex: draft.bg) }, set: { draft.bg = $0.hexString }), supportsOpacity: false)
                                .labelsHidden()
                            Picker("", selection: Binding(get: { bgPreset }, set: { v in if v != "custom" { draft.bg = v } })) {
                                Text("黒").tag("#000000")
                                Text("白").tag("#ffffff")
                                Text("緑（クロマキー）").tag("#00b140")
                                Text("自由").tag("custom")
                            }.labelsHidden().frame(width: 170)
                        }
                    }
                    GridRow {
                        Text("書き出し形式")
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: $draft.codec) {
                                Text("H.264（どこでも再生できる）").tag("h264")
                                Text("HEVC（同じ画質で小さい・4K向け）").tag("hevc")
                            }.labelsHidden().frame(width: 260)
                            if draft.codec == "h264", let w = res.width, let h = res.height, !OutputPlan.h264Supports(width: w, height: h) {
                                Text("注意: このサイズは H.264 で書き出せないので、書き出しは HEVC になります").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .padding(8)
            }
            FanSettingsBox(fan: AppServices.fan)
            GroupBox("VOICEVOX（互換エンジンも可）") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("エンジンのURL", text: $draft.voicevoxUrl)
                    Text("VOICEVOX は 50021、COEIROINK は 50031、SHAREVOX は 50025 が初期値です。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("ゆっくり（AquesTalk 系）") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("実行コマンド").font(.caption)
                    TextEditor(text: $draft.aquestalkCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 54)
                    Text("{text} {voice} {speed} {out} が置き換わります。{out} に WAV を書き出すコマンドにしてください。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("適用") {
                    guard res.isValid, let w = res.width, let h = res.height, case .success(let f) = FrameRateInput.parse(fpsText) else { return }
                    draft.width = w; draft.height = h; draft.fps = f
                    model.applySettings(draft, original: original)
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!res.isValid || !fpsValid)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: draft.codec) { _, c in res.codec = c }
        .onChange(of: fpsText) { _, t in if case .success(let v) = FrameRateInput.parse(t) { res.fps = v } }
    }
}

// MARK: - ドロップされたファイルの取り出し

enum DropLoader {
    /// NSItemProvider から file URL を取り出す(順番はそのまま)。取り出せる物があれば true。
    static func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let list = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !list.isEmpty else { return false }
        var urls = [URL?](repeating: nil, count: list.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (i, p) in list.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                lock.withLock { urls[i] = url }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls.compactMap { $0 }) }
        return true
    }
}

// MARK: - 書き出し中のファン最大化の表示

/// 設定シートの「書き出し」欄。チェックはアプリ全体の設定(すぐ保存。「適用」を待たない)。
struct FanSettingsBox: View {
    @ObservedObject var fan: FanService
    var body: some View {
        GroupBox("書き出し") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("書き出し中はファンを最大にする", isOn: Binding(get: { fan.enabled }, set: { fan.setEnabled($0) }))
                    .disabled(!fan.isAvailable)
                    .accessibilityIdentifier("fan-max-toggle")
                if let reason = fan.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if fan.availability == nil {
                    Text("確認しています…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("終了・キャンセル・失敗・アプリ終了のどれでも自動に戻します。95 ℃ に達したときも自動に戻します。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if fan.machineSupported && fan.availability != nil && !fan.helperInstalled {
                        Button("ファン制御を有効にする…") { fan.install() }.disabled(fan.busy)
                    }
                    if fan.helperInstalled {
                        Button("ファン制御を無効にする…") { fan.uninstall() }.disabled(fan.busy)
                    }
                }
            }.padding(8)
        }
        .onAppear { fan.refresh() }
    }
}

/// 書き出しシートの中のファンの状態とお知らせ。
struct FanExportLines: View {
    @ObservedObject var fan: FanService
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !fan.statusLine.isEmpty { Text(fan.statusLine).font(.callout).monospacedDigit() }
            if !fan.notice.isEmpty { Text(fan.notice).font(.caption).foregroundStyle(.orange).frame(width: 320, alignment: .leading) }
        }
    }
}

/// ツールバー右端の状態表示(ファンを使ったあとも「ファン: 自動」を残す)。
struct FanStatusText: View {
    @ObservedObject var fan: FanService
    var body: some View {
        if !fan.statusLine.isEmpty {
            Text(fan.statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
