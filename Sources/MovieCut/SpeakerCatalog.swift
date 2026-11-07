import Foundation
import MovieCutCore

/// VOICEVOX の話者一覧(アプリ全体で 1 つ。`AppServices.speakers`)。
/// エンジンを(必要なら)起動してから `VoicevoxClient.speakers()` を 1 回だけ読み、キャラの一覧と話者 Picker で共有する。
@MainActor
final class SpeakerCatalog: ObservableObject {
    enum State: Equatable { case idle, loading, loaded, unavailable }

    @Published private(set) var state: State = .idle
    @Published private(set) var choices: [SpeakerChoice] = []
    private var labels: [Int: String] = [:]
    private var loadedURL: String?

    /// エンジンが動いているか確かめ、無ければ起動する(テストでは差し替える)。
    var ensureRunning: (String) async -> Bool
    /// 一覧の取得(テストでは URLProtocol を差した URLSession を使うクライアントに差し替える)。
    var fetch: (String) async throws -> [VoicevoxSpeaker]

    init(ensureRunning: @escaping (String) async -> Bool = { await AppServices.engine.ensureRunning(baseURL: $0) },
         fetch: @escaping (String) async throws -> [VoicevoxSpeaker] = { try await VoicevoxClient(baseURL: $0).speakers() }) {
        self.ensureRunning = ensureRunning
        self.fetch = fetch
    }

    /// 「キャラ2（ノーマル）」。一覧に無ければ nil。
    func label(for speaker: Int) -> String? { labels[speaker] }

    /// 読み込む。同じ URL で読み込み済み・読み込み中なら何もしない。つながらなかったときは次に呼ばれたとき再挑戦する。
    func load(baseURL: String) async {
        if state == .loading { return }
        if state == .loaded, loadedURL == baseURL { return }
        state = .loading
        guard await ensureRunning(baseURL) else { fail(); return }
        do {
            let list = SpeakerChoice.flatten(try await fetch(baseURL))
            guard !list.isEmpty else { fail(); return }
            choices = list
            labels = Dictionary(list.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
            loadedURL = baseURL
            state = .loaded
        } catch {
            fail()
        }
    }

    private func fail() {
        choices = []; labels = [:]; loadedURL = nil
        state = .unavailable
    }
}
