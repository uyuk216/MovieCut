import SwiftUI
import AppKit
import AVFoundation
import MovieCutCore

/// 選んだ素材フォルダを覚える(UserDefaults)。
enum AudioLibraryStore {
    static let defaultsKey = "audioLibrary.folder"

    static func folder(defaults: UserDefaults = .standard) -> URL? {
        guard let p = defaults.string(forKey: defaultsKey), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static func setFolder(_ url: URL?, defaults: UserDefaults = .standard) {
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

/// 出力とは別の「素材ブラウザ」。フォルダの音声を一覧し、試し聴きして、再生ヘッドの位置に音声クリップとして追加する。
struct AudioLibrarySheet: View {
    @ObservedObject var model: ProjectModel
    @State private var folder: URL? = AudioLibraryStore.folder()
    @State private var entries: [AudioLibrary.Entry] = []
    @StateObject private var preview = AudioPreviewPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("素材ブラウザ").font(.title3.bold())
            HStack(spacing: 8) {
                Text(folder?.path ?? "フォルダが選ばれていません")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("audio-library-folder")
                Spacer(minLength: 8)
                Button("フォルダを選ぶ…") { chooseFolder() }
                Button("再読み込み") { Task { await reload() } }.disabled(folder == nil)
            }
            if folder == nil {
                Text("BGM や効果音を入れたフォルダを選ぶと、中の音声ファイルがここに並びます。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else if entries.isEmpty {
                Text("このフォルダに音声ファイル(mp3・wav・m4a・aac・ogg)はありません。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else {
                List(entries) { e in row(e) }
                    .frame(minHeight: 260)
                    .accessibilityIdentifier("audio-library-list")
            }
            HStack {
                Text("追加は再生ヘッド(\(String(format: "%.2f", model.currentTime)) 秒)の位置に。1 回の取り消しで戻せます。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("閉じる") { preview.stop(); model.showAudioLibrary = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { await reload() }
        .onDisappear { preview.stop() }
    }

    @ViewBuilder
    private func row(_ e: AudioLibrary.Entry) -> some View {
        HStack(spacing: 10) {
            Button {
                preview.toggle(e.url)
            } label: {
                Image(systemName: preview.playingURL == e.url ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!e.isReadable)
            .help("試し聴き")
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).lineLimit(1).truncationMode(.middle)
                Text(e.duration.map { Self.durationText($0) } ?? "読めないファイル")
                    .font(.caption).foregroundStyle(e.isReadable ? Color.secondary : Color.red)
            }
            Spacer(minLength: 8)
            Button("タイムラインに追加") { Task { _ = await Self.addToTimeline(e, model: model) } }
                .disabled(!e.isReadable || model.isLocked)
        }
        .accessibilityIdentifier("audio-library-row")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "BGM・効果音のフォルダを選ぶ"
        let run: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            AudioLibraryStore.setFolder(url)
            folder = url
            Task { await reload() }
        }
        if let w = model.window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    private func reload() async {
        guard let f = folder else { entries = []; return }
        entries = await AudioLibrary.scan(folder: f)
    }

    /// 「タイムラインに追加」: 読めるファイルを再生ヘッドに 1 つ置く(`addMedia` と同じ。Undo は 1 回)。置いた ID を返す。
    @MainActor
    static func addToTimeline(_ e: AudioLibrary.Entry, model: ProjectModel) async -> [String] {
        guard e.isReadable else { return [] }
        return await model.addMedia(urls: [e.url], at: model.currentTime)
    }

    static func durationText(_ s: Double) -> String {
        let total = Int((s).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
