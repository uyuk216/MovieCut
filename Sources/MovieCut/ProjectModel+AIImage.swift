import AppKit
import MovieCutCore

/// クリップ ▸ AIで画像を作る…: ローカルのコマンドが画像を書き、画像クリップとして再生ヘッドに置く(Undo は 1 回)。
/// 送る前に内容を見せて確認する(`aiUI.confirmSend`)。キャンセル可。クラウドは呼ばない。
extension ProjectModel {
    /// メニューから。プロンプトとコマンドを入れてもらう(コマンドは次回のために覚える)。
    func openAIImage() {
        guard !isLocked else { return }
        guard let v = AIDialogs.form(title: "AI で画像を作る",
                                     message: "ローカルのコマンドが画像を作ります(クラウドへは送りません)。コマンドはプロンプトを標準入力と環境変数 MOVIECUT_PROMPT で受け取り、最後の引数の場所に画像を書きます。次の画面で送る内容を確認できます。",
                                     fields: [("画像のプロンプト", ""), ("コマンド", AIImageSettings.command())], okTitle: "次へ")
        else { return }
        AIImageSettings.setCommand(v[1])
        Task { await generateAIImage(prompt: v[0]) }
    }

    /// 生成して画像クリップを置く。置いたクリップの id を返す(失敗・キャンセル・未確認なら nil)。
    @discardableResult
    func generateAIImage(prompt: String, commandLine: String? = nil, at time: Double? = nil) async -> String? {
        guard !isLocked else { return nil }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = (commandLine ?? AIImageSettings.command()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { statusText = "プロンプトを入れてください"; return nil }
        do { _ = try CommandImageProvider(commandLine: cmd) } catch {
            errorTitle = "AI で画像を作れません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        guard aiUI.confirmSend("コマンド: \(cmd)", p) else { statusText = "AI には送りませんでした"; return nil }
        guard let image = await runImageCommand(prompt: p, commandLine: cmd) else { return nil }
        // 読み込みが終わってから(busyMessage を外してから)書き換える。Undo は 1 回。
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        guard edit("AIで作った画像の追加", { pr in ids = ClipEditing.place(media: [(image.path, .image, 5)], at: t, in: &pr) }) else { return nil }
        selectedClipId = ids.last
        statusText = "AI で作った画像を追加しました"
        return ids.last
    }

    /// コマンドを走らせて画像ファイルを作る。キャンセルと失敗は画面に出して nil。
    private func runImageCommand(prompt: String, commandLine: String) async -> URL? {
        let out = AIImageStore.newOutputURL()
        busyMessage = "画像を作っています…"
        defer { busyMessage = nil; imageGenCancel = nil }
        do {
            let provider = try CommandImageProvider(commandLine: commandLine)
            let t = Task { try await provider.generate(prompt: prompt, outputURL: out) }
            imageGenCancel = { t.cancel() }
            try await t.value
            return out
        } catch is CancellationError {
            statusText = "画像の生成をキャンセルしました"
        } catch let e as AIError where e == .cancelled {
            statusText = "画像の生成をキャンセルしました"
        } catch {
            errorTitle = "AI で画像を作れませんでした"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        try? FileManager.default.removeItem(at: out)
        return nil
    }
}
