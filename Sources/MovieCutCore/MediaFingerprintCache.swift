import Foundation

/// 素材フィンガープリントのキャッシュ。保存のたびに全素材のハッシュを読み直さないためのもの。
///
/// 解決済みのパスごとに「サイズと更新日時」と「フィンガープリント」を持つ。
/// サイズと更新日時が前回と同じなら前回の値を返し、違えば計算し直す。
/// 読めない素材は結果に入れず、前の記録も捨てる(次に読めたとき改めて計算する)。
/// 保存(主スレッド以外)と自動保存の両方から呼ばれるので、スレッドセーフにしてある。
public final class MediaFingerprintCache: @unchecked Sendable {
    /// ファイルの「変わったかどうか」を見る目印。
    public struct FileStamp: Equatable, Sendable {
        public var size: Int64
        public var modified: Date?
        public init(size: Int64, modified: Date?) {
            self.size = size; self.modified = modified
        }
    }

    private struct Entry {
        var stamp: FileStamp
        var fingerprint: MediaFingerprint
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let stamp: (String) -> FileStamp?
    private let compute: (String) -> MediaFingerprint?

    /// `stamp` と `compute` は差し替えられる(テスト用。既定はファイルを実際に読む)。
    public init(stamp: @escaping (String) -> FileStamp? = MediaFingerprintCache.fileStamp(atPath:),
                compute: @escaping (String) -> MediaFingerprint? = { MediaFingerprint.compute(atPath: $0) }) {
        self.stamp = stamp
        self.compute = compute
    }

    /// パスのフィンガープリント。ファイルが無い・読めないときは nil(記録も捨てる)。
    public func fingerprint(atPath path: String) -> MediaFingerprint? {
        guard let now = stamp(path) else {
            lock.withLock { entries[path] = nil }
            return nil
        }
        if let hit = lock.withLock({ entries[path] }), hit.stamp == now {
            return hit.fingerprint
        }
        // ハッシュ計算はロックの外で行う(大きな素材で他の保存を待たせないため)
        guard let fp = compute(path) else {
            lock.withLock { entries[path] = nil }
            return nil
        }
        lock.withLock { entries[path] = Entry(stamp: now, fingerprint: fp) }
        return fp
    }

    /// 記録している素材の数(確認・テスト用)。
    public var count: Int { lock.withLock { entries.count } }

    /// 既定の目印: ファイルのサイズと更新日時。読めなければ nil。
    public static func fileStamp(atPath path: String) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        return FileStamp(size: size, modified: attrs[.modificationDate] as? Date)
    }
}
