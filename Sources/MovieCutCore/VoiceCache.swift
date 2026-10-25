import Foundation
import CryptoKit

/// 合成した WAV のキャッシュ(Application Support/MovieCut/voices)。
/// ファイル名 = 引数の JSON 配列の SHA-256(小文字 16 進)+ ".wav"。
public struct VoiceCache {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    /// 既定の Application Support フォルダ。
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
    }

    /// 既定の保存先 `~/Library/Application Support/MovieCut/voices/`。
    /// 初回だけ、旧名のフォルダ(`yukkuri-editor/voices`)が残っていれば中身ごと移して、作った声のキャッシュを引き継ぐ。
    public static var standard: VoiceCache {
        let base = applicationSupport
        migrateLegacyVoices(in: base)
        return VoiceCache(directory: base.appendingPathComponent("MovieCut/voices", isDirectory: true))
    }

    /// 旧名 `yukkuri-editor/voices` があり、新しい `MovieCut/voices` がまだ無いときだけ、`voices` を移す。
    /// 他のものは消さない・触らない。失敗しても致命的ではない(キャッシュなので作り直せる)。戻り値は移したかどうか。
    @discardableResult
    public static func migrateLegacyVoices(in appSupport: URL) -> Bool {
        let fm = FileManager.default
        let old = appSupport.appendingPathComponent("yukkuri-editor/voices", isDirectory: true)
        let new = appSupport.appendingPathComponent("MovieCut/voices", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue,
              !fm.fileExists(atPath: new.path) else { return false }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }

    /// パラメータ(文字列・数・nil)の JSON 配列から作るキー。
    public static func key(_ params: [JSONValue]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? enc.encode(params)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// キーに対応する WAV の場所(フォルダは必要なら作る)。
    public func url(forKey key: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(key).wav")
    }

    /// キャッシュにあればそのパス。
    public func hit(forKey key: String) -> URL? {
        let u = directory.appendingPathComponent("\(key).wav")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

extension JSONValue {
    static func opt(_ d: Double?) -> JSONValue { d.map { .number($0) } ?? .null }
    static func opt(_ i: Int?) -> JSONValue { i.map { .number(Double($0)) } ?? .null }
    static func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
}
