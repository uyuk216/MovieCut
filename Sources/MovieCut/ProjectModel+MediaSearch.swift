import Foundation
import MovieCutCore

/// 出力 ▸ 素材の内容を検索…(メディアインテリジェンス検索 第 1 段)。
/// 索引と検索は Core(`MediaSearch`)、文字起こしの保存は Core(`MediaTranscriptStore`)。
/// ここは保存庫への登録・索引の組み立て・ヒットへのジャンプだけ。
/// 文字起こしは勝手に始めない(登録されるのは、利用者が実行した文字起こしの結果だけ)。
extension ProjectModel {
    /// 文字起こし結果を検索用の保存庫へ登録するためのクロージャを作る。
    /// 認識の時刻はクリップの使う範囲の頭からなので、素材の頭からの秒へ直して(`offset` を足して)登録する。
    /// 戻り値はスレッドセーフ(保存庫がスレッドセーフで、捕まえるのは値だけ)。
    func mediaTranscriptRecorder(for clip: Clip) -> @Sendable ([TranscriptSegment]) -> Void {
        let store = mediaTranscriptStore
        guard let src = clip.src, !src.isEmpty else { return { _ in } }
        let path = MediaResolver.resolve(src: src, projectDir: mirror.projectFolder) ?? src
        let offset = clip.offset
        return { segments in
            store.register(path: path, segments: segments.map {
                TranscriptSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            })
        }
    }

    /// 文字起こし結果(クリップの使う範囲の頭からの秒)を、検索用の保存庫へ登録する。
    func registerTranscript(for clip: Clip, segments: [TranscriptSegment]) {
        mediaTranscriptRecorder(for: clip)(segments)
    }

    /// いまのプロジェクトの検索索引を組み立てる(保存庫にある文字起こしだけが対象)。
    func mediaSearchIndex() -> MediaSearch.Index {
        let dir = mirror.projectFolder
        var transcripts: [String: [TranscriptSegment]] = [:]
        for src in MediaFingerprintCollector.referencedSources(in: project) {
            let path = MediaResolver.resolve(src: src, projectDir: dir) ?? src
            if let segments = mediaTranscriptStore.segments(forPath: path) {
                transcripts[path] = segments
            }
        }
        return MediaSearch.buildIndex(project: project, projectDir: dir, transcripts: transcripts)
    }

    /// 出力 ▸ 素材の内容を検索…(書き出し中・音声生成中は開かない)。
    func openMediaSearch() {
        guard !isLocked else { return }
        showMediaSearchSheet = true
    }

    /// ヒットの位置へジャンプする: 対応するクリップを選んで、再生ヘッドをその文の開始位置へ動かす。
    /// タイムラインへ対応づけられないとき(未配置・使う範囲の外)は何もせず false。
    @discardableResult
    func jumpToMediaHit(_ hit: MediaSearch.Hit) -> Bool {
        guard let loc = MediaSearch.timelineLocation(for: hit, in: project) else { return false }
        playback.pause()
        selectOnly(loc.clipId)
        currentTime = loc.time
        showMediaSearchSheet = false
        statusText = "「\(hit.mediaName)」の \(Self.mediaTimeText(hit.start)) の文へ移動しました"
        return true
    }

    /// 素材内時刻の表示(分:秒)。
    static func mediaTimeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
