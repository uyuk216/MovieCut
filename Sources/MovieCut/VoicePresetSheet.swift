import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 「おすすめ音声設定…」: 配布された音声設定(JSON)を取り込み、選んだキャラの声に適用する。
enum VoicePresetSource {
    static let url = URL(string: "https://uyuk216.github.io/MovieCut/voice-presets.json")!

    /// この画面を開いたときと「ネットから取得」を押したときに呼ぶ。HTTPS のみ・10 秒・256KB・Cookie と資格情報なし。
    static func fetch() async throws -> VoicePresetCatalog {
        guard url.scheme == "https" else { throw VoicePresetCatalog.Failure.invalid }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 10
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.httpShouldHandleCookies = false
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > VoicePresetCatalog.maxBytes { throw VoicePresetCatalog.Failure.tooLarge }
        }
        return try VoicePresetCatalog.decode(data)
    }
}

struct VoicePresetSheet: View {
    @ObservedObject var model: ProjectModel
    let charId: String
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [VoicePreset] = []
    @State private var message: String?
    @State private var loading = false
    @State private var autoFetched = false
    /// 通信の差し替え口(テスト用)。既定は本物の取得。
    var loader: () async throws -> VoicePresetCatalog = { try await VoicePresetSource.fetch() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("おすすめ音声設定").font(.headline)
            Text("声の設定(エンジン・話者・速さ・高さ・抑揚)だけを、選んだキャラに入れます。名前や字幕の色は変わりません。この画面を開くと、一覧をネット(HTTPS)から一度だけ取得します。送るのは取得のリクエストだけです。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { Task { await loadFromNet() } } label: { Text("ネットから取得") }.disabled(loading)
                Button("ファイルから読み込み…") { loadFromFile() }.disabled(loading)
                if loading { ProgressView().controlSize(.small); Text(L10n.t("取得中…")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let m = message { Text(m).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            List(presets) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                        if let n = p.note { Text(n).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("適用") { model.applyVoicePreset(p, charId: charId); dismiss() }.disabled(model.isLocked)
                }
            }
            .frame(minHeight: 180)
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(16).frame(width: 440, height: 420)
        .task {
            // 開いたとき一覧が空なら、1 回だけ自動で取得する(シートを開いたのはユーザー操作)。
            guard !autoFetched, presets.isEmpty else { return }
            autoFetched = true
            await loadFromNet()
        }
    }

    private func show(_ c: VoicePresetCatalog) {
        presets = c.presets
        message = c.presets.isEmpty ? "使える設定がありませんでした。" : nil
    }

    private func loadFromNet() async {
        loading = true; message = nil
        defer { loading = false }
        switch await VoicePresetFetchOutcome.run(loader) {
        case .loaded(let p): presets = p; message = nil
        case .empty: presets = []; message = "使える設定がありませんでした。"
        case .failed(let m): message = m
        }
    }

    private func loadFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "おすすめ音声設定のファイルを選ぶ"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try InputLimits.readFile(url, limit: VoicePresetCatalog.maxBytes, what: "おすすめ音声設定のファイル")
            show(try VoicePresetCatalog.decode(data))
        } catch let e as LocalizedError { message = e.errorDescription }
        catch { message = "ファイルを読み込めませんでした。" }
    }
}
