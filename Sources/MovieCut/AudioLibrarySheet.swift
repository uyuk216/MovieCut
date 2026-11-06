import SwiftUI
import AppKit
import AVFoundation
import MovieCutCore

/// 選んだ素材フォルダを覚える(UserDefaults)。
enum AudioLibraryStore {
    static let defaultsKey = "audioLibrary.folder"

    static func folder(defaults: UserDefaults = DataLocations.current.defaults) -> URL? {
        guard let p = defaults.string(forKey: defaultsKey), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static func setFolder(_ url: URL?, defaults: UserDefaults = DataLocations.current.defaults) {
        if let url { defaults.set(url.path, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
    }
}

/// 試し聴き(一度に 1 つだけ)。
@MainActor
final class AudioPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingURL: URL?
    private var player: AVAudioPlayer?

    /// 同じファイルなら止め、違うファイルなら切り替えて鳴らす。読めなければ何もしない。
    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
        playingURL = url
    }

    /// 最後まで鳴ったら印を消す(停止表示のまま残さない)。
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { self.finished(player) }
    }

    private func finished(_ p: AVAudioPlayer) {
        guard p === player else { return }
        stop()
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }
}

/// 出力とは別の「素材ブラウザ」。フォルダの動画・音声・画像を一覧(リスト/グリッド)し、名前で絞り、
/// 選ぶとプレビューを出す。ダブルクリックか Return で、再生ヘッドの位置に置く(`ClipEditing.place`・1 回の取り消し)。
struct AudioLibrarySheet: View {
    @ObservedObject var model: ProjectModel
    @State private var folder: URL? = AudioLibraryStore.folder()
    @State private var items: [MediaBrowser.Item] = []
    @State private var kind: MediaBrowser.KindFilter = .all
    @State private var query = ""
    @State private var gridMode = false
    @State private var sort: MediaBrowser.SortKey = .name
    @State private var selectedId: String?
    @State private var probeTask: Task<Void, Never>?
    @StateObject private var preview = AudioPreviewPlayer()

    private var shown: [MediaBrowser.Item] { MediaBrowser.filter(items, kind: kind, query: query, sort: sort) }
    private var selected: MediaBrowser.Item? { shown.first { $0.id == selectedId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("素材ブラウザ")).font(.title3.bold())
            HStack(spacing: 8) {
                Text(BuiltInLibrary.isBuiltIn(folder) ? "\(BuiltInLibrary.title)(\(BuiltInLibrary.licenseNote))" : (folder?.path ?? "フォルダが選ばれていません"))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("audio-library-folder")
                Spacer(minLength: 8)
                Button(BuiltInLibrary.title) { useBuiltIn() }
                    .help(L10n.t("効果音・背景・図形を、このアプリが作ったものから選べます(ライセンス自由)"))
                    .accessibilityIdentifier("media-browser-builtin")
                Button(L10n.t("フォルダを選ぶ…")) { chooseFolder() }
                Button(L10n.t("再読み込み")) { reload() }.disabled(folder == nil)
            }
            if folder != nil && !items.isEmpty {
                HStack(spacing: 8) {
                    TextField("名前で検索", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .accessibilityIdentifier("media-browser-search")
                    Picker(L10n.t("種類"), selection: $kind) {
                        ForEach(MediaBrowser.KindFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Spacer(minLength: 8)
                    Picker(L10n.t("並べ方"), selection: $sort) {
                        ForEach(MediaBrowser.SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                    .accessibilityIdentifier("media-browser-sort")
                    Picker(L10n.t("表示"), selection: $gridMode) {
                        Image(systemName: "list.bullet").tag(false)
                        Image(systemName: "square.grid.2x2").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 80)
                }
            }
            if folder == nil {
                Text(L10n.t("動画・音声・画像を入れたフォルダを選ぶと、中の素材がここに並びます。"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
            } else if items.isEmpty {
                Text(L10n.t("このフォルダに対象の素材(動画・音声・画像)はありません。"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
            } else if shown.isEmpty {
                Text(L10n.t("一致する素材はありません。")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    browserList
                        .frame(width: 380, height: 300)
                    previewPane
                        .frame(width: 210, height: 300, alignment: .topLeading)
                }
            }
            HStack {
                Text("ダブルクリック・Return・ドラッグで追加。再生ヘッド(\(String(format: "%.2f", model.currentTime)) 秒)の位置か、ドロップした位置とレイヤーに置き、1 回の取り消しで戻せます。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L10n.t("閉じる")) { preview.stop(); model.showAudioLibrary = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 480)
        .task { reload() }
        .onDisappear { preview.stop(); probeTask?.cancel() }
    }

    @ViewBuilder
    private var browserList: some View {
        if gridMode {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(shown) { item in gridCell(item) }
                }
                .padding(4)
            }
            .accessibilityIdentifier("audio-library-grid")
        } else {
            List(shown, selection: $selectedId) { item in
                listRow(item).tag(item.id)
            }
            .accessibilityIdentifier("audio-library-list")
        }
    }

    private func listRow(_ e: MediaBrowser.Item) -> some View {
        HStack(spacing: 10) {
            MediaThumbnailView(item: e, width: 44, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).lineLimit(1).truncationMode(.middle)
                Text(Self.infoText(e)).font(.caption).foregroundStyle(e.unreadable ? .red : .secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { add(e) }
        .modifier(BrowserDragSource(item: e))
        .accessibilityIdentifier("audio-library-row")
    }

    private func gridCell(_ e: MediaBrowser.Item) -> some View {
        VStack(spacing: 4) {
            MediaThumbnailView(item: e, width: 88, height: 60)
            Text(e.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .padding(4)
        .frame(width: 96)
        .background(selectedId == e.id ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { add(e) }
        .onTapGesture { selectedId = e.id }
        .modifier(BrowserDragSource(item: e))
        .accessibilityIdentifier("audio-library-cell")
    }

    @ViewBuilder
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = selected {
                MediaThumbnailView(item: s, width: 210, height: 118)
                Text(s.name).font(.headline).lineLimit(2).truncationMode(.middle)
                Text(Self.infoText(s)).font(.caption).foregroundStyle(s.unreadable ? .red : .secondary)
                if s.kind == .audio {
                    Button {
                        preview.toggle(s.url)
                    } label: {
                        Label(preview.playingURL == s.url ? "止める" : "試し聴き",
                              systemImage: preview.playingURL == s.url ? "stop.fill" : "play.fill")
                    }
                }
                Button(L10n.t("タイムラインに追加")) { add(s) }
                    .disabled(model.isLocked || s.unreadable)
            } else {
                Text(L10n.t("素材を選ぶと、ここにプレビューが出ます。")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: selectedId) { _, _ in preview.stop() }
        .onKeyPress(.return) {
            guard let s = selected, !model.isLocked, !s.unreadable else { return .ignored }
            add(s)
            return .handled
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "素材のフォルダを選ぶ"
        // 素材ブラウザは別ウインドウ(非モーダル)なので、フォルダ選びも独立したパネルで出す
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            AudioLibraryStore.setFolder(url)
            folder = url
            reload()
        }
    }

    /// 同梱素材を一覧にする(初回は作る)。選んだフォルダの記憶は変えない。
    private func useBuiltIn() {
        folder = BuiltInLibrary.ensureInstalled()
        reload()
    }

    /// 一覧を読み直す。長さと読めるかは後から 1 件ずつ確かめて、確かめたものから行に反映する(読み込み中も操作できる)。
    private func reload() {
        probeTask?.cancel()
        guard let f = folder else { items = []; return }
        items = MediaBrowser.scan(folder: f)
        selectedId = nil
        let targets = items
        probeTask = Task { @MainActor in
            for target in targets {
                if Task.isCancelled { return }
                let probed = await MediaBrowser.probe(url: target.url, kind: target.kind)
                if let i = items.firstIndex(where: { $0.id == target.id }) {
                    items[i] = MediaBrowser.applying(probed, to: items[i])
                }
            }
        }
    }

    /// 選んだ素材を再生ヘッドに置く(`addMedia` → `ClipEditing.place`。1 回の取り消し)。
    private func add(_ e: MediaBrowser.Item) {
        Task { _ = await Self.addToTimeline(url: e.url, model: model) }
    }

    /// 「タイムラインに追加」: 素材を再生ヘッドに 1 つ置く(`addMedia` と同じ。Undo は 1 回)。置いた ID を返す。
    @MainActor
    static func addToTimeline(url: URL, model: ProjectModel) async -> [String] {
        await model.addMedia(urls: [url], at: model.currentTime)
    }

    /// 旧い一覧の行(音声だけ)からの追加。読めないファイルは何もしない。
    @MainActor
    static func addToTimeline(_ e: AudioLibrary.Entry, model: ProjectModel) async -> [String] {
        guard e.isReadable else { return [] }
        return await addToTimeline(url: e.url, model: model)
    }

    static func kindText(_ k: ClipType) -> String {
        switch k {
        case .video: return "動画"
        case .audio: return "音声"
        case .image: return "画像"
        default: return "素材"
        }
    }

    static func durationText(_ s: Double) -> String {
        let total = Int((s).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 行の副題: 種類・長さ(分かったとき)・読めないときはその旨。
    static func infoText(_ e: MediaBrowser.Item) -> String {
        if e.unreadable { return "読めないファイル(壊れている・非対応の形式)" }
        var parts = [kindText(e.kind)]
        if let d = e.duration { parts.append(durationText(d)) }
        return parts.joined(separator: " ・ ")
    }
}

/// 読めるファイルは、タイムラインへドラッグできる(ファイル URL を渡す。Finder からのドロップと同じ経路)。
private struct BrowserDragSource: ViewModifier {
    let item: MediaBrowser.Item
    func body(content: Content) -> some View {
        if item.unreadable {
            content
        } else {
            content.onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        }
    }
}
