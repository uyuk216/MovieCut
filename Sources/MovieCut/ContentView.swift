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
    @Environment(\.undoManager) private var undoManager

    @AppStorage("timelineHeight") private var timelineHeight: Double = 230
    @State private var dragStartHeight: Double?

    var body: some View {
        GeometryReader { geo in
            let h = min(max(timelineHeight, 160), max(160, geo.size.height * 0.55))
            VStack(spacing: 0) {
                DependencyBannerBar(center: AppServices.deps)
                ToolbarBar(model: model)
                Divider()
                HStack(spacing: 0) {
                    LeftPanel(model: model, speakers: AppServices.speakers, scriptText: $model.scriptText)
                        .frame(width: 300)
                    Divider()
                    CenterPanel(model: model)
                    Divider()
                    InspectorView(model: model, speakers: AppServices.speakers)
                        .frame(width: 280)
                }
                .disabled(model.isLocked)
                splitter(totalHeight: geo.size.height)
                TimelineSection(model: model)
                    .frame(height: h)
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .overlay { BusyOverlay(message: model.busyMessage) }
        .sheet(isPresented: $model.showSettings) { SettingsSheet(model: model) }
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
            if model.window?.isMainWindow == true { ActiveDocument.shared.activate(model) }
            DebugHooks.shared.attach(model)
        }
        .task { await AppServices.deps.refresh(project: model.project) }
        .task(id: model.project.voicevoxUrl) { await AppServices.speakers.load(baseURL: model.project.voicevoxUrl) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let w = note.object as? NSWindow, w === model.window { model.shutdown(); ActiveDocument.shared.deactivate(model) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { note in
            if let w = note.object as? NSWindow, w === model.window { ActiveDocument.shared.activate(model) }
        }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onChange(of: fileURL) { _, new in model.fileURL = new }
    }

    /// タイムラインとの境のドラッグ(高さは UserDefaults に保存、160〜ウィンドウの 55%)。
    private func splitter(totalHeight: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            Rectangle().fill(Color.clear).frame(height: 7)
        }
        .frame(height: 7)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { v in
                    if dragStartHeight == nil { dragStartHeight = min(max(timelineHeight, 160), max(160, totalHeight * 0.55)) }
                    let proposed = (dragStartHeight ?? 230) - Double(v.translation.height)
                    timelineHeight = min(max(proposed, 160), max(160, Double(totalHeight) * 0.55))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }
}

// MARK: - ツールバー

struct ToolbarBar: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                Button("素材を追加") { model.chooseAndAddMedia() }
                    .help("画像・動画・音声を再生ヘッドの位置に追加(Finder からのドラッグ&ドロップも可)")
                Button("テキスト") { model.addTextClip() }
                    .help("一番上のレイヤーに文字を追加")
                Button("ぼかし範囲") { model.addBlurClip() }
                    .help("一番上のレイヤーにぼかし範囲を追加")
            }
            .disabled(model.isLocked)
            Divider().frame(height: 18)
            Group {
                Button("分割") { model.splitSelected() }
                    .disabled(model.isLocked || !model.canSplit)
                    .help("選択中のクリップを再生ヘッドで分割(S)")
                Button("削除") { model.deleteSelected() }
                    .disabled(model.isLocked || model.selectedClip == nil)
                    .help("選択中のクリップを削除(Delete)")
            }
            Spacer(minLength: 12)
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("設定") { model.showSettings = true }
                .disabled(model.isLocked)
            Button("MP4 書き出し") { model.chooseAndExport() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport)
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
            ZStack(alignment: .topLeading) {
                PreviewView(project: model.project, time: model.currentTime, assets: model.assets, model: model, epoch: model.previewEpoch)
                Text(String(format: "%d×%d · %dfps", model.project.width, model.project.height, model.project.fps))
                    .font(.system(size: 12))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
            .padding(10)
            TransportBar(model: model)
                .padding(.bottom, 10)
        }
    }
}

struct TransportBar: View {
    @ObservedObject var model: ProjectModel

    private var resolutionBinding: Binding<String> {
        Binding(get: { model.resolutionKey }, set: { model.selectResolution($0) })
    }

    var body: some View {
        HStack(spacing: 10) {
            Button("⏮") { model.playback.goToStart() }
                .help("先頭へ(Home)")
            Button(model.isPlaying ? "⏸" : "▶") { model.playback.togglePlay() }
                .help("再生 / 一時停止(Space)")
                .disabled(model.isLocked)
            Button(model.isSecondScreenOpen ? "別画面を閉じる" : "別画面に表示") { model.toggleSecondScreen() }
                .help("外付け画面にプレビューを全画面で出す(Esc で閉じる)")
            HStack(spacing: 6) {
                Text("解像度")
                Picker("解像度", selection: resolutionBinding) {
                    ForEach(ResolutionPresets.items, id: \.key) { Text($0.label).tag($0.key) }
                    if !ResolutionPresets.isPreset(model.resolutionKey) {
                        Text(String(format: "%d×%d", model.project.width, model.project.height)).tag(model.resolutionKey)
                    }
                    Divider()
                    Text("自由…").tag(ResolutionPresets.customKey)
                }
                .labelsHidden()
                .frame(width: 170)
            }
            Text("\(timecode(model.currentTime)) / \(timecode(model.project.endTime))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - オーバーレイとシート

struct BusyOverlay: View {
    let message: String?
    var body: some View {
        if let message {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(message).multilineTextAlignment(.center).font(.system(size: 14))
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
            Text("MP4 を書き出しています").font(.headline)
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

// MARK: - 設定シート(動画設定ほか)

struct SettingsSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VideoSettingsDraft
    private let original: VideoSettingsDraft

    init(model: ProjectModel) {
        self.model = model
        let d = VideoSettingsDraft(model.project)
        _draft = State(initialValue: d)
        original = d
    }

    private var sizeKey: String {
        let k = "\(draft.width)x\(draft.height)"
        return ResolutionPresets.isPreset(k) ? k : ResolutionPresets.customKey
    }
    private var bgPreset: String {
        let b = draft.bg.lowercased()
        return ["#000000", "#ffffff", "#00b140"].contains(b) ? b : "custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("設定").font(.title3.bold())
            GroupBox("動画") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("サイズ")
                        Picker("", selection: Binding(get: { sizeKey }, set: { k in
                            let parts = k.split(separator: "x").compactMap { Int($0) }
                            if parts.count == 2 { draft.width = parts[0]; draft.height = parts[1] }
                        })) {
                            ForEach(ResolutionPresets.items, id: \.key) { Text($0.label).tag($0.key) }
                            Text("自由").tag(ResolutionPresets.customKey)
                        }.labelsHidden().frame(width: 200)
                    }
                    GridRow {
                        Text("幅 × 高さ")
                        HStack {
                            TextField("", value: $draft.width, format: .number.grouping(.never)).frame(width: 80)
                            Text("×")
                            TextField("", value: $draft.height, format: .number.grouping(.never)).frame(width: 80)
                        }
                    }
                    GridRow {
                        Text("FPS")
                        Picker("", selection: $draft.fps) {
                            Text("24").tag(24); Text("30").tag(30); Text("60").tag(60)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
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
                        Picker("", selection: $draft.codec) {
                            Text("H.264（どこでも再生できる）").tag("h264")
                            Text("HEVC（同じ画質で小さい・4K向け）").tag("hevc")
                        }.labelsHidden().frame(width: 260)
                    }
                }
                .padding(8)
            }
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
                    model.applySettings(draft, original: original)
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
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
