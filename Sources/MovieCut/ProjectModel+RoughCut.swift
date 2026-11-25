import Foundation
import MovieCutCore

/// AIラフカット(第 1 版)の画面側の流れ。
/// 生成そのものは Core(`RoughCutProvider`)、検証と組み立ても Core
/// (`RoughCutValidation` / `RoughCutBuilder`)。ここは対象の収集(文字起こしの
/// 保存庫を引く)・進み表示・シーンへの反映(Undo 1 回)だけを持つ。
/// 接続は AIテキスト生成の設定を共有し、未設定のときは
/// `TextGenerationSettings.makeRoughCutProvider()` がエラーを返して画面に出る。
/// 元のタイムラインは変えず、結果は新しいシーンとして足す。
extension ProjectModel {
    /// シートを開く(クリップメニューの入口)。
    func openAIRoughCutSheet() {
        guard !isLocked else { return }
        guard editingSceneId == nil, compoundPath.isEmpty else {
            statusText = "AIラフカットは、いちばん上のタイムラインで使ってください"
            return
        }
        showAIRoughCutSheet = true
    }

    /// いまの設定で生成できるか(シートの有効・無効と案内に使う)。
    var roughCutConfigured: Bool { TextGenerationSettings.load().isConfigured }

    /// 対象クリップと、その素材の文字起こしを集める。対象が無ければ空。
    func roughCutSources() -> [RoughCutSourceClip] {
        RoughCutSources.collect(project: project) { clip in roughCutUI.transcripts(self, clip) }
    }

    /// ラフカットを生成する。未設定・失敗はエラー画面に出して nil。キャンセルは状態欄。
    /// プロジェクトは変えない(反映は `applyAIRoughCut`)。
    @discardableResult
    func generateAIRoughCut(instruction: String, targetDuration: Double?, sources: [RoughCutSourceClip]) async -> RoughCutPlan? {
        guard !isLocked else { return nil }
        guard !sources.isEmpty else {
            errorTitle = "AIラフカットを使えません"
            errorMessage = RoughCutError.noSources.localizedDescription
            return nil
        }
        let provider: RoughCutProvider
        do { provider = try roughCutUI.makeProvider() } catch {
            errorTitle = "AIラフカットを使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        let request = RoughCutRequest(instruction: instruction, targetDuration: targetDuration, clips: sources)
        playback?.pause()
        busyMessage = "ラフカットを考えています…"
        let task = Task { try await provider.generateRoughCut(request) }
        roughCutCancel = { task.cancel() }
        defer { roughCutCancel = nil; busyMessage = nil }
        do {
            return try await task.value
        } catch {
            if (error as? TextGenerationError) == .cancelled || error is CancellationError {
                statusText = "ラフカットの生成をキャンセルしました"
                return nil
            }
            errorTitle = "ラフカットを作れませんでした"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func cancelRoughCut() { roughCutCancel?() }

    /// プランを新しいシーンとして足す(Undo 1 回)。元のタイムラインは変えない。
    /// 作れたらシーンを開いて中を見せ、シーン名を返す。
    @discardableResult
    func applyAIRoughCut(_ plan: RoughCutPlan) -> String? {
        guard !isLocked, editingSceneId == nil, compoundPath.isEmpty else { return nil }
        let name = roughCutSceneName()
        var madeId: String?
        let ok = edit("AIラフカットを作成", enforcesLock: false) { p in
            if let scene = RoughCutBuilder.makeScene(plan: plan, in: p, name: name) {
                p.scenes.append(scene)
                madeId = scene.id
            }
        }
        guard ok, let madeId else { statusText = "ラフカットを作成できませんでした"; return nil }
        var note = "AIラフカット「\(name)」を作りました(区間 \(plan.segments.count) 件・合計 \(Self.mediaTimeText(plan.totalDuration)))"
        if plan.droppedCount > 0 { note += "。検証で \(plan.droppedCount) 件の区間を落としました" }
        statusText = note
        _ = enterScene(madeId)
        return name
    }

    /// 「AIラフカット」「AIラフカット 2」…のうち、まだ使われていない最初の名前。
    func roughCutSceneName() -> String {
        let names = Set(project.scenes.map(\.name))
        if !names.contains("AIラフカット") { return "AIラフカット" }
        var i = 2
        while names.contains("AIラフカット \(i)") { i += 1 }
        return "AIラフカット \(i)"
    }
}

/// AIラフカットの画面部品の差し替え口(テストではプロバイダと文字起こしを偽物にする)。
struct RoughCutUI {
    var makeProvider: () throws -> RoughCutProvider = { try TextGenerationSettings.load().makeRoughCutProvider() }
    /// クリップの素材の文字起こし(素材時刻)を保存庫から引く。
    var transcripts: (ProjectModel, Clip) -> [TranscriptSegment]? = { m, clip in
        guard let src = clip.src, !src.isEmpty else { return nil }
        let path = MediaResolver.resolve(src: src, projectDir: m.mirror.projectFolder) ?? src
        return m.mediaTranscriptStore.segments(forPath: path)
    }
}
