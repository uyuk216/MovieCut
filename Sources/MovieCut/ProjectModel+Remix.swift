import Foundation
import MovieCutCore

/// Remix の解析結果(シートが使う)。候補はクリップの頭からの秒。
struct RemixScan: Equatable {
    var candidates: [Double]
    var usedFallback: Bool
    var bpm: Double?
}

/// Remix の解析ができない理由(シートに表示する)。
enum RemixScanError: LocalizedError {
    case remix(RemixError)
    var errorDescription: String? {
        switch self { case .remix(let e): return e.message }
    }
}

/// Remixツール: 音楽クリップを目標の尺へ、ビート(取れなければ音の切り替わり点)を候補に
/// 区間を選び直してつなぎ直す。計算は Core(`Remix`)。ここは解析・Undo(1 回)・状態欄だけ。元クリップは変えない。
extension ProjectModel {
    static let remixUndoName = "Remix"

    /// 選んだクリップが Remix の対象なら、シートを開く。
    func openRemixSheet() {
        guard !isLocked, let c = selectedClip, Remix.supports(c) else { return }
        remixClipId = c.id
        showRemixSheet = true
    }

    /// シートの読み込み: 音を解析して候補を作る。ビートの信頼度が低ければフォールバック候補を使う。
    /// どちらも取れなければ理由を持つエラーを投げる(黙って進めない)。
    func scanRemix() async throws -> RemixScan {
        guard let id = remixClipId, let c = clip(id), Remix.supports(c) else { throw RemixScanError.remix(.unsupportedClip) }
        let profile: LevelProfile? = await Task.detached(priority: .userInitiated) { SilenceDetector.analyze(clip: c) }.value
        guard let profile else { throw RemixScanError.remix(.noAudio) }
        if let grid = BeatDetector.analyze(profile: profile), grid.confidence >= 0.2 {
            return RemixScan(candidates: grid.beats, usedFallback: false, bpm: grid.bpm)
        }
        let fallback = RemixFallback.candidates(profile: profile)
        guard !fallback.isEmpty else { throw RemixScanError.remix(.noCandidates) }
        return RemixScan(candidates: fallback, usedFallback: true, bpm: nil)
    }

    /// 候補と目標尺からクリップ列を作って、元クリップのレイヤーの末尾へ置く(全体で 1 回の Undo)。
    /// 作れなければ理由を状態欄に出して何もしない(false)。
    @discardableResult
    func applyRemix(clipId: String, candidates: [Double], usedFallback: Bool, params: RemixParams) -> Bool {
        guard !isLocked else { return false }
        switch Remix.assemble(in: project, sourceClipId: clipId, candidates: candidates, params: params, usedFallback: usedFallback) {
        case .failure(let e):
            statusText = e.message
            return false
        case .success(let r):
            guard edit(Self.remixUndoName, { $0 = r.project }) else { return false }
            selectedClipId = r.clipIds.first
            let diff = r.plan.totalDuration - params.targetDuration
            statusText = String(format: L10n.t("Remix: %d 区間で %.1f 秒のクリップ列を作りました(目標 %.1f 秒、差 %+.1f 秒)%@"),
                                r.plan.segments.count, r.plan.totalDuration, params.targetDuration, diff,
                                r.plan.usedFallback ? "。ビートが取れなかったため、音の切り替わり点で区切りました" : "")
            return true
        }
    }
}
