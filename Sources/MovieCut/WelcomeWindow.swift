import SwiftUI
import AppKit
import MovieCutCore

/// 最近使ったプロジェクトの一覧(アプリ全体で 1 つ)。開く・保存したときに記録する。
@MainActor
final class RecentProjectsController: ObservableObject {
    static let shared = RecentProjectsController(store: DebugHooks.isQuiet ? MemoryRecentProjectsStore() : UserDefaultsRecentProjectsStore())

    @Published private(set) var recents: RecentProjects
    private let store: RecentProjectsStore
    var fileExists: (String) -> Bool

    init(store: RecentProjectsStore, fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.store = store
        self.fileExists = fileExists
        self.recents = RecentProjects.load(from: store)
    }

    /// 開いた / 保存した。ファイルの更新日も控える。
    func record(url: URL?, now: Date = Date()) {
        guard let url, url.isFileURL else { return }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        recents.touch(path: url.path, modified: mod, now: now)
        recents.save(to: store)
        ActiveDocument.shared.refresh()
    }

    func remove(path: String) {
        recents.remove(path: path)
        recents.save(to: store)
        ActiveDocument.shared.refresh()
    }

    func clear() {
        recents.removeAll()
        recents.save(to: store)
        ActiveDocument.shared.refresh()
    }

    func isMissing(_ e: RecentProject) -> Bool { recents.isMissing(e, fileExists: fileExists) }
}

/// ファイル ▸ 最近使った項目 の 1 項目(メニューの状態に持たせる軽い写し)。
struct RecentMenuItem: Equatable {
    var path: String
    var name: String
    var missing: Bool
}

/// 起動時に出すかどうかの方針。
enum WelcomePolicy {
    static func shouldShow(showAtLaunch: Bool, launchedWithDocuments: Bool, docs: [LaunchDocInfo], quiet: Bool = false) -> Bool {
        showAtLaunch && !launchedWithDocuments && !quiet && docs.allSatisfy(\.isBlankUntitled)
    }

    /// 一覧の日付(例: 2026年10月23日 14:05)。
    static func dateText(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日 H:mm"
        return f.string(from: d)
    }

    static let missingText = "見つかりません"
}

enum WelcomeActions {
    @MainActor static func open(path: String) {
        let url = URL(fileURLWithPath: path)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) } else { WelcomeWindow.close() }
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var controller = RecentProjectsController.shared
    @State private var showAtLaunch = WelcomeSettings.showAtLaunch()
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.t("Movie Cut へようこそ")).font(.title2.bold()).padding(.top, 18)
            Text(L10n.t("最近使ったプロジェクト")).font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 8)
            if controller.recents.entries.isEmpty {
                Spacer()
                Text(L10n.t("最近使ったプロジェクトはありません")).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(controller.recents.entries) { e in
                        row(e).tag(e.path)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { if !controller.isMissing(e) { WelcomeActions.open(path: e.path) } }
                            .contextMenu {
                                Button(L10n.t("一覧から削除")) { controller.remove(path: e.path) }
                            }
                    }
                }
            }
            Divider()
            HStack {
                Toggle(L10n.t("起動時にこの画面を表示"), isOn: $showAtLaunch)
                    .onChange(of: showAtLaunch) { _, v in
                        WelcomeSettings.setShowAtLaunch(v)
                        ActiveDocument.shared.refresh()
                    }
                Spacer()
                Button(L10n.t("新規")) { NSDocumentController.shared.newDocument(nil); WelcomeWindow.close() }
                Button(L10n.t("開く…")) { WelcomeWindow.close(); NSDocumentController.shared.openDocument(nil) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 380)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            showAtLaunch = WelcomeSettings.showAtLaunch()
        }
    }

    @ViewBuilder private func row(_ e: RecentProject) -> some View {
        let missing = controller.isMissing(e)
        HStack(spacing: 10) {
            Image(systemName: missing ? "exclamationmark.triangle" : "film").frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(.headline)
                Text((e.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(missing ? WelcomePolicy.missingText : WelcomePolicy.dateText(e.modified ?? e.lastOpened))
                .font(.caption).foregroundStyle(missing ? Color.red : Color.secondary)
        }
        .opacity(missing ? 0.45 : 1)
        .padding(.vertical, 3)
    }
}

/// 起動時の画面(Xcode のウェルカム画面のようなもの)。1 つだけ。
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: WelcomeView())
        let w = NSWindow(contentViewController: host)
        w.title = "Movie Cut"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 620, height: 440))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }

    /// 起動の落ち着いたあとに 1 回だけ呼ぶ。出すなら、空の名称未設定は閉じる。
    static func showAtLaunchIfNeeded(launchedWithDocuments: Bool) {
        let docs = NSDocumentController.shared.documents
        let infos = docs.map { LaunchDocInfo(isUntitled: $0.fileURL == nil, isPristine: !$0.isDocumentEdited) }
        guard WelcomePolicy.shouldShow(showAtLaunch: WelcomeSettings.showAtLaunch(), launchedWithDocuments: launchedWithDocuments, docs: infos, quiet: DebugHooks.isQuiet) else { return }
        for d in docs { d.close() }
        show()
    }
}
