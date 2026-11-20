import Foundation
import MovieCutCore

/// AIテキスト生成(W3-08 / 監査 #74)の画面側の流れ。
/// 生成そのものは Core(`TextGenerationProvider`)。ここはシート開閉・進み表示・
/// 台本欄への取り込み(Undo 1 回)だけを持つ。
/// 未設定のときは `TextGenerationSettings.makeProvider()` がエラーを返し、
/// 画面にその旨が出る(機能は無効)。認証情報はここでも扱わない(設定画面で
/// ユーザー自身が入れたものが UserDefaults にあるだけ)。
extension ProjectModel {
    /// シートを開く(台本欄・台本編集ウィンドウ・クリップメニューの入口)。
    func openDialogueSuggestionSheet() {
        guard !isLocked else { return }
        showDialogueSuggestionSheet = true
    }

    /// 台本編集ウィンドウから開く(台本編集シートを閉じてから出す)。
    func openDialogueSuggestionsFromScriptTable() {
        guard !isLocked else { return }
        showScriptTableSheet = false
        showDialogueSuggestionSheet = true
    }

    /// いまの設定で生成できるか(シートの有効・無効と案内に使う)。
    var textGenerationConfigured: Bool { TextGenerationSettings.load().isConfigured }

    /// セリフ案を生成する。未設定・失敗はエラー画面に出して nil。キャンセルは状態欄。
    @discardableResult
    func generateDialogueSuggestions(theme: String, keywords: [String], count: Int) async -> [DialogueSuggestion]? {
        guard !isLocked else { return nil }
        let trimmedTheme = theme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTheme.isEmpty else { statusText = "テーマを入れてください"; return nil }
        let provider: TextGenerationProvider
        do { provider = try textGenUI.makeProvider() } catch {
            errorTitle = "AIテキスト生成を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        let request = DialogueGenerationRequest(
            theme: trimmedTheme,
            keywords: keywords,
            characterNames: project.characters.map(\.name),
            count: count,
            contextLines: scriptText.components(separatedBy: .newlines))
        playback?.pause()
        busyMessage = "セリフ案を作っています…"
        let task = Task { try await provider.generateDialogue(request) }
        textGenCancel = { task.cancel() }
        defer { textGenCancel = nil; busyMessage = nil }
        do {
            return try await task.value
        } catch {
            if (error as? TextGenerationError) == .cancelled || error is CancellationError {
                statusText = "セリフ案の生成をキャンセルしました"
                return nil
            }
            errorTitle = "セリフ案を作れませんでした"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func cancelTextGeneration() { textGenCancel?() }

    /// 選んだセリフ案を台本欄へ取り込む(Undo 1 回)。取り込んだ行数を返す。
    @discardableResult
    func importDialogueSuggestions(_ suggestions: [DialogueSuggestion]) -> Int {
        appendScriptLinesWithUndo(DialogueImport.lines(from: suggestions), name: "AIのセリフ案を取り込む")
    }

    /// 台本欄の末尾へ行を足し、Undo を 1 回だけ登録する。
    /// 台本欄の文字そのものは通常 Undo の対象外(文字の Undo は TextEditor が持つ)が、
    /// AI 生成文や話者分離結果の「取り込み」は一括操作なので、台本編集ウィンドウの
    /// 保存と同じく 1 回で戻せるようにする。既にある行と重なるものは足さない。
    @discardableResult
    func appendScriptLinesWithUndo(_ lines: [String], name: String) -> Int {
        let existing = Set(scriptText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        let fresh = lines.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && !existing.contains($0.trimmingCharacters(in: .whitespaces))
        }
        guard !fresh.isEmpty else { return 0 }
        let old = scriptText
        let add = fresh.joined(separator: "\n")
        scriptText = old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? add
            : old.trimmingCharacters(in: .newlines) + "\n" + add
        registerScriptUndo(restoreTo: old, name: name)
        statusText = String(format: L10n.t("台本欄へ %d 行を足しました(1 回で元に戻せます)"), fresh.count)
        return fresh.count
    }

    /// 台本欄を `value` に戻す Undo/Redo の登録(登録し直すことで Redo も 1 回になる)。
    private func registerScriptUndo(restoreTo value: String, name: String) {
        let um = effectiveUndoManager
        um.beginUndoGrouping()
        um.registerUndo(withTarget: self) { m in
            MainActor.assumeIsolated { m.restoreScriptText(value, name: name) }
        }
        um.setActionName(L10n.t(name))
        um.endUndoGrouping()
    }

    private func restoreScriptText(_ value: String, name: String) {
        let current = scriptText
        guard current != value else { return }
        scriptText = value
        registerScriptUndo(restoreTo: current, name: name)
    }
}

/// AIテキスト生成の画面部品の差し替え口(テストではプロバイダを偽物にする)。
struct TextGenUI {
    var makeProvider: () throws -> TextGenerationProvider = { try TextGenerationSettings.load().makeProvider() }
}
