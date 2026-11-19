import AppKit
import MovieCutCore

/// 生成メディア共通連携口の画面側の流れ(最初の実装: 画像生成の API 直接連携)。
/// 生成そのものは Core(`GenerativeMediaProvider`)。ここは入力・送信前確認・
/// 進み表示・クリップ配置(Undo 1 回)だけを持つ。
/// 流れは共通: プロンプト指定 → 確認(送信内容・送信先・想定費用) → 生成 →
/// 結果を画像クリップとして再生ヘッドに配置。将来の動画/音声生成も同じ形にする。
/// 未設定のときは `ImageGenerationSettings.makeProvider()` がエラーを返し、
/// 画面にその旨が出る(メニュー項目も無効表示)。認証情報はここでも扱わない
/// (設定画面でユーザー自身が入れたものが UserDefaults にあるだけ)。
/// 既存のローカルコマンド方式(`ProjectModel+AIImage`)とは独立で、そちらは変えない。
extension ProjectModel {
    /// いまの設定で画像生成(API)が使えるか(メニューの有効・無効と案内に使う)。
    var imageGenerationConfigured: Bool { ImageGenerationSettings.load().isConfigured }

    /// クリップ ▸ AIで画像を生成(API)…: プロンプトと大きさを入れてもらう。
    func openGenerateImageAPI() {
        guard !isLocked else { return }
        let s = ImageGenerationSettings.load()
        guard s.isConfigured else {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = GenerativeMediaError.notConfigured.errorDescription
            return
        }
        guard let v = AIDialogs.form(title: "AI で画像を生成(API)",
                                     message: "あなたの API アカウントで画像を生成し、画像クリップとして再生ヘッドに置きます。次の画面で、送る内容・送信先・費用の注意を確認できます。",
                                     fields: [("画像のプロンプト", ""), ("大きさ", s.size)], okTitle: "次へ")
        else { return }
        let size = v[1].trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await generateImageViaAPI(prompt: v[0], size: size.isEmpty ? nil : size) }
    }

    /// 生成して画像クリップを置く。置いたクリップの id を返す(失敗・キャンセル・未確認なら nil)。
    @discardableResult
    func generateImageViaAPI(prompt: String, size: String? = nil, at time: Double? = nil) async -> String? {
        guard !isLocked else { return nil }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { statusText = "プロンプトを入れてください"; return nil }
        let settings = ImageGenerationSettings.load()
        let provider: GenerativeMediaProvider
        do { provider = try genMediaUI.makeImageProvider() } catch {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        let request = GenerativeMediaRequest(kind: .image, prompt: p, size: size ?? settings.size)
        do { try request.validate() } catch {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        // 送信前確認(必須): 送信先と、プロンプト・モデル・大きさ・費用の注意を見せる。
        let confirmation = settings.confirmation(prompt: p, size: request.size)
        guard genMediaUI.confirmSend(confirmation.destination, confirmation.summaryText) else {
            statusText = "生成サービスには送りませんでした"
            return nil
        }
        playback?.pause()
        busyMessage = "画像を生成しています…"
        let task = Task { try await provider.generate(request) }
        genMediaCancel = { task.cancel() }
        defer { genMediaCancel = nil; busyMessage = nil }
        let result: GenerativeMediaResult
        do { result = try await task.value } catch {
            if (error as? GenerativeMediaError) == .cancelled || error is CancellationError {
                statusText = "画像の生成をキャンセルしました"
                return nil
            }
            errorTitle = "画像を生成できませんでした"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        // 生成が終わってから(busyMessage を外してから)書き換える。Undo は 1 回。
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        guard edit("生成メディア(API)で作った画像の追加", { pr in
            ids = GenerativeMediaPlacement.place(result, at: t, in: &pr)
        }) else { return nil }
        selectedClipId = ids.last
        statusText = "生成した画像を追加しました"
        return ids.last
    }

    func cancelGenerativeMedia() { genMediaCancel?() }
}

/// 生成メディアの画面部品の差し替え口(テストではプロバイダと確認画面を偽物にする)。
struct GenMediaUI {
    var makeImageProvider: () throws -> GenerativeMediaProvider = { try ImageGenerationSettings.load().makeProvider() }
    var confirmSend: (_ destination: String, _ summary: String) -> Bool = { d, s in
        MainActor.assumeIsolated { AIDialogs.confirmSend(destination: d, prompt: s) }
    }
}
