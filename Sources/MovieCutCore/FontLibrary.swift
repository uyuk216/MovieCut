import Foundation
import CoreText

/// 利用者が追加したフォント(.ttf / .otf / .ttc)の取り込みと登録。
/// 保存先は `~/Library/Application Support/MovieCut/Fonts`(システムの ~/Library/Fonts には触らない)。
/// 登録は CTFontManager の `.process`(このアプリの中だけ)。アプリ起動時と追加したときに行う。
public enum FontLibrary {
    public static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    public enum Failure: Error, Equatable {
        case unsupportedType(String)
        case unreadable(String)
        case noFamilyName(String)
    }

    /// 取り込んだ結果。`familyNames` は、ファイル内のフォント(.ttc は複数)のファミリー名(重複なし・出現順)。
    public struct Added: Equatable {
        public var file: URL
        public var familyNames: [String]
        /// 同じ中身のファイルが既にあったとき true(コピーはしていない)。
        public var alreadyPresent: Bool
    }

    public static func isFontFile(_ url: URL) -> Bool {
        fontExtensions.contains(url.pathExtension.lowercased())
    }

    /// 既定の保存先(無ければ作る場所を示すだけで、作成はしない)。
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MovieCut/Fonts", isDirectory: true)
    }

    /// フォントファイルとして読め、ファミリー名が取れるかを調べる。読めれば名前の一覧を返す。
    public static func familyNames(of url: URL) throws -> [String] {
        guard isFontFile(url) else { throw Failure.unsupportedType(url.pathExtension) }
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descs.isEmpty else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        var names: [String] = []
        for d in descs {
            guard let n = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String, !n.isEmpty else { continue }
            if !names.contains(n) { names.append(n) }
        }
        guard !names.isEmpty else { throw Failure.noFamilyName(url.lastPathComponent) }
        return names
    }

    /// `source` を検査して `dir` へ写す。同名で中身が違うファイルがあれば「名前 2.ttf」のように番号を付ける。
    /// 同じ中身が既にあれば何もコピーしない(`alreadyPresent`)。
    public static func add(_ source: URL, to dir: URL, fileManager: FileManager = .default) throws -> Added {
        let names = try familyNames(of: source)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Data(contentsOf: source)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.lowercased()
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            if (try? Data(contentsOf: candidate)) == data {
                return Added(file: candidate, familyNames: names, alreadyPresent: true)
            }
            candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        try data.write(to: candidate, options: .atomic)
        return Added(file: candidate, familyNames: names, alreadyPresent: false)
    }

    /// `dir` の中のフォントを登録する。登録できた数を返す(壊れたファイルは飛ばす)。
    @discardableResult
    public static func registerAll(in dir: URL, fileManager: FileManager = .default) -> Int {
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var ok = 0
        for f in files.sorted(by: { $0.path < $1.path }) where isFontFile(f) {
            var err: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(f as CFURL, .process, &err) { ok += 1 }
            err?.release()
        }
        return ok
    }

    /// `dir` にあるフォントのファミリー名(重複なし・ファイル名順)。読めないファイルは含めない。
    public static func families(in dir: URL, fileManager: FileManager = .default) -> [String] {
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for f in files.sorted(by: { $0.path < $1.path }) where isFontFile(f) {
            for n in (try? familyNames(of: f)) ?? [] where !out.contains(n) { out.append(n) }
        }
        return out
    }
}
