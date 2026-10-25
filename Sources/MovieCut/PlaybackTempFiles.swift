import Foundation

/// 再生用のミックス(`playback.warmUp` ほか)が作る一時ファイルの置き場。
/// 以前は一時フォルダの直下にばらまいて、起動のたびに数個残っていた。
/// いまは専用のサブフォルダ 1 つにまとめ、(1) 起動時に 1 日より古いものを消し、(2) 書類を閉じるとき・終了するときに自分の分を消す。
enum PlaybackTempFiles {
    static let folderName = "MovieCut-playback"
    /// 旧版が一時フォルダの直下に作っていたファイル名の頭。
    static let legacyPrefix = "moviecut-playback-"
    /// 古いとみなす秒数(1 日)。
    static let staleAge: TimeInterval = 24 * 60 * 60

    static func prefix(pid: Int32) -> String { "\(legacyPrefix)\(pid)-" }

    static func folderURL(base: URL = FileManager.default.temporaryDirectory) -> URL {
        base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// 新しい一時ファイルの場所(フォルダが無ければ作る)。
    static func newFileURL(base: URL = FileManager.default.temporaryDirectory, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> URL {
        let dir = folderURL(base: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(prefix(pid: pid) + UUID().uuidString + ".caf")
    }

    /// 起動時の掃除: サブフォルダと、旧版の置き場(一時フォルダ直下)にある、`age` 秒より古い再生用ファイルを消す。消した数を返す。
    @discardableResult
    static func removeStale(base: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = staleAge, now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        func sweep(_ dir: URL) {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
            for u in urls where u.lastPathComponent.hasPrefix(legacyPrefix) && u.pathExtension == "caf" {
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(m) > age, (try? fm.removeItem(at: u)) != nil { removed += 1 }
            }
        }
        sweep(folderURL(base: base))
        sweep(base)
        return removed
    }

    /// このプロセスが作った一時ファイルを全部消す(書類を閉じたあと・終了時)。消した数を返す。空になったフォルダも消す。
    @discardableResult
    static func removeCurrent(base: URL = FileManager.default.temporaryDirectory, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Int {
        let fm = FileManager.default
        let dir = folderURL(base: base)
        var removed = 0
        for d in [dir, base] {
            guard let urls = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: []) else { continue }
            for u in urls where u.lastPathComponent.hasPrefix(prefix(pid: pid)) {
                if (try? fm.removeItem(at: u)) != nil { removed += 1 }
            }
        }
        if let left = try? fm.contentsOfDirectory(atPath: dir.path), left.isEmpty { try? fm.removeItem(at: dir) }
        return removed
    }
}
