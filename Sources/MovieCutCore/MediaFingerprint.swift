import Foundation
import CryptoKit

/// 素材ファイルのフィンガープリント: SHA-256 ハッシュ + サイズ + ファイル名。
///
/// 同名でも中身が違えばハッシュが違うので、再リンクで誤って別ファイルを
/// つなぐことを防げる。プロジェクトファイルには省略可能な追加フィールド
/// `mediaFingerprints`(キー = 元の `src`)として保存され、無いプロジェクトも
/// そのまま読める(後方互換)。
public struct MediaFingerprint: Codable, Equatable, Hashable, Sendable {
    public var fileName: String
    public var size: Int64
    /// SHA-256 の小文字 hex(64 文字)。
    public var sha256: String

    public init(fileName: String, size: Int64, sha256: String) {
        self.fileName = fileName
        self.size = size
        self.sha256 = sha256.lowercased()
    }

    /// ファイル実体からフィンガープリントを作る。読めなければ nil。
    /// 大きなファイルでもチャンク読みでメモリを膨らませない。
    public static func compute(atPath path: String, chunkSize: Int = 1 << 20) -> MediaFingerprint? {
        compute(url: URL(fileURLWithPath: path), chunkSize: chunkSize)
    }

    public static func compute(url: URL, chunkSize: Int = 1 << 20) -> MediaFingerprint? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: chunkSize) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return MediaFingerprint(fileName: url.lastPathComponent, size: total, sha256: hex)
    }

    /// Data から直接作る(テスト・小さい素材用)。
    public static func compute(data: Data, fileName: String) -> MediaFingerprint {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return MediaFingerprint(fileName: fileName, size: Int64(data.count), sha256: hex)
    }

    /// パスのファイルがこのフィンガープリントと一致するか(サイズを先に見て、違えばハッシュを読まない)。
    public func matches(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize, Int64(fileSize) != size { return false }
        guard let other = Self.compute(url: url) else { return false }
        return other.sha256 == sha256 && other.size == size
    }
}

/// プロジェクト内の素材参照からフィンガープリントを収集する仕組み。
public enum MediaFingerprintCollector {
    /// プロジェクトが参照する distinct な `src` の一覧(クリップ順 + mediaPool)。
    public static func referencedSources(in project: Project) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for clip in project.allClips {
            if let src = clip.src, !src.isEmpty, seen.insert(src).inserted { out.append(src) }
        }
        for src in project.mediaPool where !src.isEmpty && seen.insert(src).inserted {
            out.append(src)
        }
        return out
    }

    /// 存在する素材についてだけフィンガープリントを集める。
    /// `resolve` で src → 実パスへの解決を差し替えられる(既定はプロジェクト相対解決つき)。
    public static func collect(from project: Project, projectDir: String? = nil,
                               resolve: (String) -> String? = { _ in nil },
                               compute: (String) -> MediaFingerprint? = { MediaFingerprint.compute(atPath: $0) }) -> [String: MediaFingerprint] {
        var out: [String: MediaFingerprint] = [:]
        for src in referencedSources(in: project) {
            let path = MediaResolver.resolve(src: src, projectDir: projectDir) ?? resolve(src)
            guard let path, let fp = compute(path) else { continue }
            out[src] = fp
        }
        return out
    }

    /// プロジェクトにフィンガープリントを埋め込んだコピーを返す(元は変更しない)。
    /// `compute` を差し替えると、キャッシュ経由などでハッシュの計算を省ける。
    public static func attaching(to project: Project, projectDir: String? = nil,
                                 compute: (String) -> MediaFingerprint? = { MediaFingerprint.compute(atPath: $0) }) -> Project {
        var p = project
        p.mediaFingerprints = collect(from: project, projectDir: projectDir, compute: compute)
        return p
    }
}
