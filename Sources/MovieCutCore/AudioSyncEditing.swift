import Foundation

// MARK: - クリップ ▸ 音声で映像と音声を自動同期(別録りの音を、映像に入っている音に合わせる)
//
// 選んだ「動画」と「音声」の 2 クリップの音(使っている範囲)の包絡を相互相関で合わせ、音声クリップの開始位置だけを動かす。
// 計算は純粋(ファイルの読み出しは呼び出し側)。ずれの精度は包絡の窓 = 10 ms。

public enum AudioSyncEditing {
    /// 探すずれの最大(秒)。
    public static let maxShiftSeconds = 10.0
    /// これ未満の一致度は「合わせられなかった」とする。
    public static let minScore = 0.2
    /// 合わせに使う長さの上限(秒。クリップの頭から)。
    public static let maxAnalysisSeconds = 60.0

    /// 同期の対象にできる組(動画 1 つ + 音声 1 つだけを選んでいるとき)。
    public static func pair(in project: Project, ids: Set<String>) -> (video: Clip, audio: Clip)? {
        guard ids.count == 2 else { return nil }
        let picked = project.allClips.filter { ids.contains($0.id) }
        guard picked.count == 2,
              let v = picked.first(where: { $0.type == .video }),
              let a = picked.first(where: { $0.type == .audio }),
              SilenceDetector.supports(v), SilenceDetector.supports(a) else { return nil }
        return (v, a)
    }

    public static func isAvailable(in project: Project, ids: Set<String>) -> Bool { pair(in: project, ids: ids) != nil }

    /// 使えないときの理由(使えるなら nil)。
    public static let selectionHint = "動画のクリップと音声のクリップを 1 つずつ選んでください(速度変更・逆再生のないもの)"
    public static func disabledReason(in project: Project, ids: Set<String>) -> String? {
        isAvailable(in: project, ids: ids) ? nil : selectionHint
    }

    /// 音量の列(dBFS、10 ms ごと)を、相関に使う線形の包絡にする(上限の長さで切る)。
    public static func envelope(from profile: LevelProfile) -> [Float] {
        let n = min(profile.levels.count, Int(maxAnalysisSeconds / LevelProfile.windowSeconds))
        return profile.levels.prefix(n).map { $0 <= -119 ? 0 : Float(pow(10.0, Double($0) / 20)) }
    }

    /// 音声の包絡 `audio` を、映像の包絡 `video` に合わせるための、音声クリップの動かす量の元になるずれ(秒)。
    /// 正 = 音声のほうが後ろにずれている(音声を前へ動かす)。合わせられなければ nil。
    public static func lagSeconds(video: [Float], audio: [Float]) -> Double? {
        // 重なりが短いと偶然よく合うので、短いほうの長さの半分以上は重ねる範囲だけを探す
        let maxLag = min(Int(maxShiftSeconds / LevelProfile.windowSeconds), min(video.count, audio.count) / 2)
        guard let r = AudioSync.lag(reference: video, target: audio, maxLag: maxLag), r.score >= minScore else { return nil }
        return Double(r.lag) * LevelProfile.windowSeconds
    }

    public enum Outcome: Equatable {
        case moved(Project, newStart: Double)
        case alreadySynced
        case beforeZero(newStart: Double)
        case locked
        case invalid
    }

    /// ずれ `lag`(秒、`lagSeconds` の値)に従って、音声クリップの開始位置を動かす。
    /// 音声の時刻 t は映像の時刻 t − lag と同じ音なので、新しい開始 = 映像の開始 − lag。
    public static func apply(to project: Project, videoId: String, audioId: String, lag: Double) -> Outcome {
        guard let v = project.allClips.first(where: { $0.id == videoId && $0.type == .video }),
              let a = project.allClips.first(where: { $0.id == audioId && $0.type == .audio }), lag.isFinite else { return .invalid }
        guard !LayerEditing.isLockedClip(audioId, in: project) else { return .locked }
        let newStart = ((v.start - lag) * 1000).rounded() / 1000
        if newStart < 0 { return .beforeZero(newStart: newStart) }
        if abs(newStart - a.start) < 1e-6 { return .alreadySynced }
        var p = project
        for ti in p.tracks.indices {
            if let ci = p.tracks[ti].clips.firstIndex(where: { $0.id == audioId }) { p.tracks[ti].clips[ci].start = newStart }
        }
        return .moved(p, newStart: newStart)
    }
}
