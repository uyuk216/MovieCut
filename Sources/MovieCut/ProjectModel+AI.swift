import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// AI 連携の画面側の流れ。どの呼び出しも、メニューを選んだときだけ・送る内容を見せて確認したあとだけ。
/// プロンプトの組み立てと返事の読み取りは Core(AIPrompts)。ここは流れと Undo だけ。
extension ProjectModel {
    // MARK: 共通

    /// AI を 1 回呼ぶ。確認 → 問い合わせ(キャンセル可)→ 返事。失敗・キャンセルは状態欄かエラーに出して nil。
    func askAI(_ prompt: String) async -> String? {
        guard !isLocked else { return nil }
        let provider: AIProvider
        do { provider = try aiUI.makeProvider() } catch {
            errorTitle = "AI を使えません"; errorMessage = error.localizedDescription
            return nil
        }
        guard aiUI.confirmSend(aiUI.destination(), prompt) else { statusText = "AI には送りませんでした"; return nil }
        playback?.pause()
        busyMessage = "AI に問い合わせています…"
        let t = Task { try await provider.complete(prompt) }
        aiCancel = { t.cancel() }
        defer { aiCancel = nil; busyMessage = nil }
        do { return try await t.value } catch {
            if (error as? AIError) == .cancelled || error is CancellationError { statusText = "AI への問い合わせをキャンセルしました"; return nil }
            errorTitle = "AI を使えませんでした"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func cancelAI() { aiCancel?() }

    private func report(_ error: Error) {
        errorTitle = "AI の返事を使えません"
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: a) 台本

    /// ファイル ▸ AIで台本を作る…
    func openAIScriptDialog() {
        guard !isLocked else { return }
        let names = project.characters.map(\.name).joined(separator: ", ")
        guard let v = AIDialogs.form(title: "AI で台本を作る", message: "テーマと登場キャラを決めます。次の画面で、AI に送る内容を確認できます。",
                                     fields: [("テーマ", ""), ("登場キャラ", names), ("行数", "12")], okTitle: "次へ") else { return }
        let chars = v[1].split(whereSeparator: { $0 == "," || $0 == "、" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { await generateAIScript(theme: v[0], characterNames: chars, lineCount: Int(v[2]) ?? 12) }
    }

    /// 台本を作り、確認してから台本欄に入れる(音声は作らない。「台本から音声を作る」はユーザーが押す)。
    @discardableResult
    func generateAIScript(theme: String, characterNames: [String], lineCount: Int) async -> Bool {
        guard !theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { statusText = "テーマを入れてください"; return false }
        let names = characterNames.filter { n in project.characters.contains { $0.name == n } }
        guard !names.isEmpty else { statusText = "登場キャラは、このプロジェクトにいるキャラの名前で指定してください"; return false }
        let prompt = AIScriptPrompt.build(.init(theme: theme, characterNames: names, lineCount: lineCount))
        guard let reply = await askAI(prompt) else { return false }
        let lines: [String]
        do { lines = try AIScriptPrompt.parse(reply, characterNames: names) } catch { report(error); return false }
        guard let r = aiUI.review("AI が作った台本", "\(lines.count) 行できました。直してから台本欄に入れられます。音声は、台本欄に入れたあとで「台本から音声を作る」を押したときに作ります。",
                                  lines.joined(separator: "\n"), true, ["台本欄に入れる", "キャンセル"]) else { statusText = "台本は入れませんでした"; return false }
        let add = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !add.isEmpty else { return false }
        scriptText = scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? add : scriptText.trimmingCharacters(in: .newlines) + "\n" + add
        statusText = "台本を \(add.components(separatedBy: .newlines).count) 行、台本欄に入れました"
        return true
    }

    // MARK: b) チャプター

    /// 出力 ▸ チャプター案をAIで作る…
    func openAIChapters() { Task { await suggestAIChapters() } }

    @discardableResult
    func suggestAIChapters() async -> Bool {
        let cues = SubtitleFile.cues(from: project)
        guard !cues.isEmpty else { statusText = "字幕(ボイスのセリフ)がありません"; return false }
        let duration = project.endTime
        let built = AIChapterPrompt.build(cues: cues, duration: duration)
        guard let reply = await askAI(built.prompt) else { return false }
        let chapters: [AIChapterPrompt.Chapter]
        do { chapters = try AIChapterPrompt.parse(reply, duration: duration) } catch { report(error); return false }
        let made = Chapters.make(from: AIChapterPrompt.markers(from: chapters))
        let note = (built.truncated ? "字幕が長いので、前半だけを送りました。\n" : "") + made.warnings.joined(separator: "\n")
        guard let r = aiUI.review("AI のチャプター案", "\(made.count) 件。" + (note.isEmpty ? "" : "\n" + note), made.text, false,
                                  ["マーカーに足してコピー", "コピーだけ", "キャンセル"]) else { statusText = "チャプターは使いませんでした"; return false }
        if r.button == 0 { applyAIChapters(chapters) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(made.text, forType: .string)
        statusText = "チャプター \(made.count) 件をコピーしました" + (r.button == 0 ? "(マーカーにも足しました)" : "")
        return true
    }

    /// 出力 ▸ タイトル案をAIで作る…(字幕かマーカーがあれば作れる)。案はコピーする(プロジェクトは変えない)。
    func openAITitles() { Task { await suggestAITitles() } }

    @discardableResult
    func suggestAITitles() async -> Bool {
        let cues = SubtitleFile.cues(from: project)
        let names = project.markers.map(\.name)
        guard !cues.isEmpty || names.contains(where: { !$0.isEmpty }) else { statusText = "字幕かマーカーがありません"; return false }
        let built = AITitlePrompt.build(cues: cues, markerNames: names)
        guard let reply = await askAI(built.prompt) else { return false }
        let titles: [String]
        do { titles = try AITitlePrompt.parse(reply) } catch { report(error); return false }
        let text = titles.joined(separator: "\n")
        let note = built.truncated ? "字幕が長いので、前半だけを送りました。\n" : ""
        guard let r = aiUI.review("AI のタイトル案", note + "\(titles.count) 件。コピーして使えます。", text, false,
                                  ["コピーする", "キャンセル"]), r.button == 0 else { statusText = "タイトル案は使いませんでした"; return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = "タイトル案 \(titles.count) 件をコピーしました"
        return true
    }

    /// チャプターをマーカーとして足す。0.5 秒以内に同じマーカーがあれば足さない。Undo は 1 回。
    @discardableResult
    func applyAIChapters(_ chapters: [AIChapterPrompt.Chapter]) -> Bool {
        edit("AI のチャプターをマーカーに足す") { p in
            for m in AIChapterPrompt.markers(from: chapters) where !p.markers.contains(where: { abs($0.time - m.time) < 0.5 }) { p.markers.append(m) }
            p.markers = MarkerEditing.sorted(p.markers)
        }
    }

    // MARK: d) 字幕の翻訳

    /// 出力 ▸ 字幕を翻訳して書き出す…(字幕の文を AI で訳し、SRT にして保存する。送る前と保存の前に内容を見せる)
    func openAITranslateSubtitles() { Task { await translateSubtitlesWithAI() } }

    @discardableResult
    func translateSubtitlesWithAI() async -> Bool {
        let cues = SubtitleFile.cues(from: project)
        guard !cues.isEmpty else { statusText = "字幕(ボイスのセリフ)がありません"; return false }
        guard let lang = AIDialogs.chooseTranslateLanguage(count: cues.count) else { return false }
        let prompt: String
        do { prompt = try AITranslatePrompt.build(cues: cues, language: lang) } catch {
            errorTitle = "翻訳できません"
            errorMessage = "字幕が長すぎます(\(AITranslatePrompt.maxInputCharacters) 文字まで)。字幕を分けてから、もう一度試してください。"
            return false
        }
        guard let reply = await askAI(prompt) else { return false }
        let texts: [String]
        do { texts = try AITranslatePrompt.parse(reply, expected: cues.count) } catch { report(error); return false }
        let srt = SubtitleFile.format(AITranslatePrompt.translated(cues, texts: texts), as: .srt)
        // 保存の前に、訳を見て直せる(編集できる)
        guard let r = aiUI.review("翻訳した字幕（\(lang.label)）", "\(cues.count) 件。直してから保存できます。時刻は元のままです。",
                                  srt, true, ["保存…", "キャンセル"]), r.button == 0 else { statusText = "翻訳は保存しませんでした"; return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt")].compactMap { $0 }
        panel.nameFieldStringValue = documentName + "-" + lang.fileSuffix + ".srt"
        panel.canCreateDirectories = true
        panel.title = "翻訳した字幕を書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { statusText = "翻訳は保存しませんでした"; return false }
        do { try r.text.write(to: url, atomically: true, encoding: .utf8) } catch { report(error); return false }
        statusText = "翻訳した字幕(\(lang.label))を書き出しました: \(url.lastPathComponent)"
        return true
    }

    // MARK: c) セリフの言い換え・短縮

    /// クリップ ▸ AIでセリフを直す…(選んでいる 1 つのボイスクリップ)
    func openAIRewrite() {
        guard !isLocked, let c = selectedClip, c.type == .voice, let text = c.text, !text.isEmpty else { statusText = "セリフのあるボイスクリップを選んでください"; return }
        guard let mode = AIDialogs.chooseRewriteMode(original: text) else { return }
        Task { await rewriteVoiceWithAI(clipId: c.id, mode: mode) }
    }

    /// 直した案を前後で見せ、「適用」で音声ごと作り直す(Undo は 1 回)。
    @discardableResult
    func rewriteVoiceWithAI(clipId: String, mode: AIRewritePrompt.Mode) async -> Bool {
        guard let c = clip(clipId), c.type == .voice, let before = c.text, !before.isEmpty else { return false }
        let who = project.characters.first { $0.id == c.charId }?.name
        guard let reply = await askAI(AIRewritePrompt.build(text: before, characterName: who, mode: mode)) else { return false }
        let after: String
        do { after = try AIRewritePrompt.parse(reply) } catch { report(error); return false }
        guard let r = aiUI.review("セリフの \(mode.title)", "直した案は、直してから適用できます。適用すると、音声も作り直します(元に戻すのは 1 回)。\n\n元: \(before)",
                                  after, true, ["適用", "キャンセル"]) else { statusText = "セリフは変えませんでした"; return false }
        let final = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { return false }
        return await setVoiceText(final, clipId: clipId)
    }
}

/// AI 連携の画面部品の差し替え口(テストでは確認・結果の画面を偽物にする)。
struct AIUI {
    var makeProvider: () throws -> AIProvider = { try AISettings.load().makeProvider() }
    var destination: () -> String = { AISettings.load().destinationDescription }
    var confirmSend: (_ destination: String, _ prompt: String) -> Bool = { d, p in MainActor.assumeIsolated { AIDialogs.confirmSend(destination: d, prompt: p) } }
    var review: (_ title: String, _ message: String, _ text: String, _ editable: Bool, _ buttons: [String]) -> AIDialogs.Review? = { t, m, x, e, b in
        MainActor.assumeIsolated { AIDialogs.review(title: t, message: m, text: x, editable: e, buttons: b) }
    }
}
