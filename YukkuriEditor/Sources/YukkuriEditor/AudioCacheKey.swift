import Foundation
import CryptoKit
import YukkuriCore

/// 再生用にミックスした音声(CAF)の「どのプロジェクトのものか」を表す鍵。
/// 音に関係する項目(audio / voice / video クリップの src・開始・長さ・オフセット・音量、レイヤーの消音、
/// 素材ファイルの更新日時)だけから作る。文字の色や位置、隠すなどを変えても変わらない。
struct AudioCacheKey: Hashable {
    let value: String

    static func defaultFileDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    static func make(for project: Project, fileDate: (String) -> Date? = AudioCacheKey.defaultFileDate) -> AudioCacheKey {
        var lines: [String] = []
        for (i, tr) in project.tracks.enumerated() {
            var items: [String] = []
            for c in tr.clips where c.type == .audio || c.type == .voice || c.type == .video {
                // ミキサーが読み飛ばすもの(src なし・長さ 0 以下)は音に関係しない
                guard let src = c.src, !src.isEmpty, c.duration > 0 else { continue }
                let date = fileDate(src).map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
                items.append("\(c.type.rawValue)|\(src)|\(c.start)|\(c.duration)|\(c.offset)|\(c.volumeOrDefault)|\(date)")
            }
            if items.isEmpty { continue }   // 音のないレイヤー(消音や追加を含む)は鍵に影響しない
            items.sort()
            lines.append("T\(i)|muted=\(tr.isMuted ? 1 : 0)")
            lines.append(contentsOf: items)
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return AudioCacheKey(value: digest.map { String(format: "%02x", $0) }.joined())
    }
}
