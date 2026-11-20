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
    /// 素材メタデータの絞り込み(キーワード・評価の下限・ラベル)。
    @State private var filterKeyword = ""
    @State private var filterMinRating: Int = 0
    @State private var filterLabel: String = ""
    /// 選択中のスマートコレクションの id(空は手入力の条件)。
    @State private var collectionId: String = ""
    @State private var newCollectionName = ""
    /// メタデータ編集欄の作業コピー(「保存」で Undo 1 回にまとめて反映する)。評価は -1 が未評価。
    @State private var editKeywords = ""
    @State private var editRating: Int = -1
    @State private var editNote = ""
    @State private var editLabel: String = ""
    /// 起点フォルダからの相対パス("" は起点そのもの)。サブフォルダ移動用(X-2)。
    @State private var subpath: String = ""
    @State private var subfolders: [MediaBrowser.FolderInfo] = []
    @State private var probeTask: Task<Void, Never>?
    @StateObject private var preview = AudioPreviewPlayer()

    /// 絞り込み条件。検索語は自由文として、名前だけでなくキーワード・メモにも当てる。
    /// スマートコレクションを選んでいるときは、その条件に検索語を AND で重ねる。
    private var criteria: MediaFilterCriteria {
        var c: MediaFilterCriteria
        if let saved = model.project.smartCollections.first(where: { $0.id == collectionId }) {
            c = saved.criteria
        } else {
            c = MediaFilterCriteria()
            let kw = filterKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kw.isEmpty { c.keywords = [kw] }
            if filterMinRating > 0 { c.minRating = filterMinRating }
            if !filterLabel.isEmpty { c.label = filterLabel }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { c.text = (c.text + " " + q).trimmingCharacters(in: .whitespaces) }
        return c
    }

    private var shown: [MediaBrowser.Item] {
        MediaBrowser.filter(items, kind: kind, query: "", sort: sort, metadata: model.project.mediaMetadata, criteria: criteria)
    }

    /// いま開いているフォルダ(起点 + subpath)。
    private var currentFolder: URL? {
        guard let folder else { return nil }
        return subpath.isEmpty ? folder : folder.appendingPathComponent(subpath)
    }

    /// パンくずの各段(表示名と、その段までの subpath)。
    private var breadcrumbParts: [(title: String, subpath: String)] {
        let comps = subpath.split(separator: "/").map(String.init)
        return comps.enumerated().map { (title: $0.element, subpath: comps.prefix($0.offset + 1).joined(separator: "/")) }
    }

    /// パンくず先頭(起点フォルダ)の表示名。
    private var rootTitle: String {
        guard let folder else { return "" }
        return BuiltInLibrary.isBuiltIn(folder) ? BuiltInLibrary.title : folder.lastPathComponent
    }
    private var selected: MediaBrowser.Item? { shown.first { $0.id == selectedId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("素材ブラウザ")).font(MCDesign.Font.title3.bold())
            HStack(spacing: 8) {
                Text(BuiltInLibrary.isBuiltIn(folder) ? "\(BuiltInLibrary.title)(\(BuiltInLibrary.licenseNote))" : (currentFolder?.path ?? "フォルダが選ばれていません"))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("audio-library-folder")
                Spacer(minLength: 8)
                Button(BuiltInLibrary.title) { useBuiltIn() }
                    .help(L10n.t("効果音・背景・図形を、このアプリが作ったものから選べます(ライセンス自由)"))
                    .accessibilityIdentifier("media-browser-builtin")
                Button(L10n.t("フォルダを選ぶ…")) { chooseFolder() }
                Button(L10n.t("再読み込み")) { reload() }.disabled(folder == nil)
            }
            breadcrumbBar
            if folder != nil && !items.isEmpty {
                HStack(spacing: 8) {
                    TextField(L10n.t("名前で検索"), text: $query)
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
            if folder != nil && !items.isEmpty {
                metadataFilterBar
            }
            if folder == nil {
                VStack(spacing: 10) {
                    InspectorGuideCard(symbol: "folder.badge.plus", heading: "フォルダが選ばれていません", message: "動画・音声・画像を入れたフォルダを選ぶと、中の素材がここに並びます。")
                        .frame(maxWidth: 420)
                    Button(L10n.t("フォルダを選ぶ…")) { chooseFolder() }
                }
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
            } else if items.isEmpty && subfolders.isEmpty && subpath.isEmpty {
                InspectorGuideCard(symbol: "tray", heading: "素材がありません", message: "このフォルダに対象の素材(動画・音声・画像)はありません。")
                    .frame(maxWidth: 420)
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
                Text(String(format: L10n.t("ダブルクリック・Return・ドラッグで追加。再生ヘッド(%.2f 秒)の位置か、ドロップした位置とレイヤーに置き、1 回の取り消しで戻せます。"), model.currentTime))
                    .font(.caption).foregroundStyle(MCDesign.Color.textSecondary)
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
                if shown.isEmpty && subfolders.isEmpty && subpath.isEmpty {
                    InspectorGuideCard(symbol: "magnifyingglass", heading: "一致する素材はありません", message: "検索語や種類の絞り込みを変えてみてください。")
                        .frame(maxWidth: 320)
                        .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        if !subpath.isEmpty { upCell }
                        ForEach(subfolders) { f in folderCell(f) }
                        ForEach(shown) { item in gridCell(item) }
                    }
                    .padding(4)
                }
            }
            .accessibilityIdentifier("audio-library-grid")
        } else {
            List(selection: $selectedId) {
                if !subpath.isEmpty || !subfolders.isEmpty {
                    Section {
                        if !subpath.isEmpty { upRow }
                        ForEach(subfolders) { f in folderRow(f) }
                    } header: {
                        Text(L10n.t("フォルダ"))
                    }
                }
                Section {
                    if shown.isEmpty {
                        InspectorGuideCard(symbol: "magnifyingglass", heading: "一致する素材はありません", message: "検索語や種類の絞り込みを変えてみてください。")
                    } else {
                        ForEach(shown) { item in listRow(item).tag(item.id) }
                    }
                }
            }
            .accessibilityIdentifier("audio-library-list")
        }
    }

    /// キーワード・評価・ラベルでの絞り込みと、スマートコレクションの選択・追加・削除。
    @ViewBuilder
    private var metadataFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(L10n.t("キーワードで絞り込み"), text: $filterKeyword)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                    .accessibilityIdentifier("media-browser-keyword-filter")
                Picker(L10n.t("評価"), selection: $filterMinRating) {
                    Text(L10n.t("評価で絞らない")).tag(0)
                    ForEach(1...5, id: \.self) { Text(String(format: L10n.t("★%d以上"), $0)).tag($0) }
                }
                .labelsHidden().frame(width: 120)
                .accessibilityIdentifier("media-browser-rating-filter")
                Picker(L10n.t("ラベル"), selection: $filterLabel) {
                    Text(L10n.t("ラベルで絞らない")).tag("")
                    ForEach(MediaLabelColor.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 110)
                .accessibilityIdentifier("media-browser-label-filter")
                Spacer(minLength: 8)
                Picker(L10n.t("コレクション"), selection: $collectionId) {
                    Text(L10n.t("コレクションなし")).tag("")
                    ForEach(model.project.smartCollections) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 170)
                .accessibilityIdentifier("media-browser-collection-picker")
            }
            HStack(spacing: 8) {
                TextField(L10n.t("コレクション名"), text: $newCollectionName)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                    .accessibilityIdentifier("media-browser-collection-name")
                Button(L10n.t("今の条件でコレクションを追加")) { addCollectionFromCurrentCriteria() }
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty || model.isLocked)
                if !collectionId.isEmpty {
                    Button(L10n.t("コレクションを削除")) { deleteSelectedCollection() }
                        .disabled(model.isLocked)
                }
                Spacer(minLength: 8)
            }
        }
    }

    /// 今の絞り込み条件(検索語は除く)をスマートコレクションとして保存する(Undo 1 回)。
    private func addCollectionFromCurrentCriteria() {
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var c = criteria
        c.text = ""
        if let made = model.addSmartCollection(name: name, criteria: c) {
            collectionId = made.id
            newCollectionName = ""
        }
    }

    /// 選択中のスマートコレクションを消す(Undo 1 回)。素材そのものは消えない。
    private func deleteSelectedCollection() {
        guard model.removeSmartCollection(id: collectionId) else { return }
        collectionId = ""
    }

    /// パンくず(起点 → サブフォルダ…)。段を押すとそのフォルダへ戻る。
    @ViewBuilder
    private var breadcrumbBar: some View {
        if folder != nil, !subpath.isEmpty || !subfolders.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Button(rootTitle) { goTo(subpath: "") }.buttonStyle(.link)
                ForEach(Array(breadcrumbParts.enumerated()), id: \.offset) { _, part in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(part.title) { goTo(subpath: part.subpath) }.buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("media-browser-breadcrumb")
        }
    }

    private func folderRow(_ f: MediaBrowser.FolderInfo) -> some View {
        Button { enter(f) } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    .frame(width: 44, height: 30)
                Text(f.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("media-browser-folder-row")
    }

    private var upRow: some View {
        Button { goUp() } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up").foregroundStyle(.secondary)
                    .frame(width: 44, height: 30)
                Text(L10n.t("一つ上のフォルダへ")).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("media-browser-up-row")
    }

    private func folderCell(_ f: MediaBrowser.FolderInfo) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                Image(systemName: "folder.fill").font(MCDesign.Font.largeTitle).foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 60)
            Text(f.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .padding(4)
        .frame(width: 96)
        .contentShape(Rectangle())
        .onTapGesture { enter(f) }
        .accessibilityIdentifier("media-browser-folder-cell")
    }

    private var upCell: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                Image(systemName: "arrow.up").font(MCDesign.Font.title).foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 60)
            Text(L10n.t("一つ上へ")).font(.caption).lineLimit(1)
        }
        .padding(4)
        .frame(width: 96)
        .contentShape(Rectangle())
        .onTapGesture { goUp() }
        .accessibilityIdentifier("media-browser-up-cell")
    }

    /// サブフォルダへ入る。
    private func enter(_ f: MediaBrowser.FolderInfo) {
        subpath = f.relativePath
        reload()
    }

    /// 一つ上のフォルダへ戻る。
    private func goUp() {
        subpath = (subpath as NSString).deletingLastPathComponent
        reload()
    }

    /// パンくずで指定した段へ移動する。
    private func goTo(subpath target: String) {
        subpath = target
        reload()
    }

    private func listRow(_ e: MediaBrowser.Item) -> some View {
        HStack(spacing: 10) {
            MediaThumbnailView(item: e, width: 44, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).lineLimit(1).truncationMode(.middle)
                Text(Self.infoText(e)).font(.caption).foregroundStyle(e.unreadable ? .red : .secondary)
                if let m = model.mediaMetadata(for: e.url.path), !m.isEmpty {
                    Text(Self.metadataSummary(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
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
            if let m = model.mediaMetadata(for: e.url.path), !m.isEmpty {
                Text(Self.metadataSummary(m)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
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
                    AudioWaveformView(item: s)
                }
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
                Divider()
                metadataEditor(for: s)
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

    /// 選択素材のメタデータ編集欄。「保存」でまとめて反映する(Undo 1 回)。
    @ViewBuilder
    private func metadataEditor(for s: MediaBrowser.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("素材のメタデータ")).font(.headline)
            TextField(L10n.t("キーワード(カンマ区切り)"), text: $editKeywords)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("media-metadata-keywords")
            HStack(spacing: 6) {
                Text(L10n.t("評価"))
                Picker(L10n.t("評価"), selection: $editRating) {
                    Text(L10n.t("未評価")).tag(-1)
                    ForEach(0...5, id: \.self) { Text("★\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 100)
                .accessibilityIdentifier("media-metadata-rating")
            }
            HStack(spacing: 6) {
                Text(L10n.t("ラベル"))
                Picker(L10n.t("ラベル"), selection: $editLabel) {
                    Text(L10n.t("なし")).tag("")
                    ForEach(MediaLabelColor.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 110)
                .accessibilityIdentifier("media-metadata-label")
            }
            TextField(L10n.t("メモ"), text: $editNote, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
                .accessibilityIdentifier("media-metadata-note")
            HStack(spacing: 8) {
                Button(L10n.t("メタデータを保存")) { saveMetadata(for: s) }
                    .disabled(model.isLocked)
                Button(L10n.t("メタデータを消去")) { clearMetadata(for: s) }
                    .disabled(model.isLocked)
            }
        }
        .onAppear { loadMetadataEditor(for: s) }
        .onChange(of: s.id) { _, _ in loadMetadataEditor(for: s) }
    }

    private func loadMetadataEditor(for s: MediaBrowser.Item) {
        let m = model.mediaMetadata(for: s.url.path)
        editKeywords = (m?.keywords ?? []).joined(separator: ", ")
        editRating = m?.rating ?? -1
        editNote = m?.note ?? ""
        editLabel = m?.label ?? ""
    }

    private func saveMetadata(for s: MediaBrowser.Item) {
        let kws = editKeywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let note = editNote.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateMediaMetadata(for: s.url.path, keywords: kws,
                                  rating: editRating < 0 ? nil : editRating,
                                  note: note.isEmpty ? nil : editNote,
                                  label: editLabel.isEmpty ? nil : editLabel)
    }

    private func clearMetadata(for s: MediaBrowser.Item) {
        if model.clearMediaMetadata(for: s.url.path) { loadMetadataEditor(for: s) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L10n.t("素材のフォルダを選ぶ")
        // 素材ブラウザは別ウインドウ(非モーダル)なので、フォルダ選びも独立したパネルで出す
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            AudioLibraryStore.setFolder(url)
            folder = url
            subpath = ""
            reload()
        }
    }

    /// 同梱素材を一覧にする(初回は作る)。選んだフォルダの記憶は変えない。
    private func useBuiltIn() {
        folder = BuiltInLibrary.ensureInstalled()
        subpath = ""
        reload()
    }

    /// 一覧を読み直す。長さと読めるかは後から 1 件ずつ確かめて、確かめたものから行に反映する(読み込み中も操作できる)。
    private func reload() {
        probeTask?.cancel()
        guard let f = folder else { items = []; subfolders = []; return }
        let current = subpath.isEmpty ? f : f.appendingPathComponent(subpath)
        items = MediaBrowser.scan(folder: current)
        subfolders = MediaBrowser.subfolders(of: current, root: f)
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

    /// 行に出すメタデータの要約(評価・ラベル・キーワード)。
    static func metadataSummary(_ m: MediaMetadata) -> String {
        var parts: [String] = []
        if let r = m.rating { parts.append("★\(r)") }
        if let l = m.label, let c = MediaLabelColor.resolved(l) { parts.append(c.title) }
        if !m.keywords.isEmpty { parts.append(m.keywords.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: " ・ ")
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
