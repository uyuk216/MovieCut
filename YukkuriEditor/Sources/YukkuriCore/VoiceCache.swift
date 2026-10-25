import Foundation
import CryptoKit

/// 合成した WAV のキャッシュ。Electron 版と同じフォルダ名(Application Support/yukkuri-editor/voices)を使う。
/// ファイル名 = 引数の JSON 配列の SHA-256(小文字 16 進)+ ".wav"。
public struct VoiceCache {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    /// 既定の保存先 `~/Library/Application Support/yukkuri-editor/voices/`。
    public static var standard: VoiceCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return VoiceCache(directory: base.appendingPathComponent("yukkuri-editor/voices", isDirectory: true))
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
