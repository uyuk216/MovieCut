import Foundation

// MARK: - VST3 バンドルのスキャン(検出のみ。バイナリは読み込まない)
//
// VST3 プラグインの「検出とメタ情報の読み取り」だけを行う。プラグインのバイナリは
// **一切ロード・実行しない**(dlopen しない)ので、壊れた/署名が変なプラグインがあっても
// アプリは落ちないし、起動も重くならない。読むのは次の 3 つだけ:
//   - `Contents/Info.plist`(名前・バンドル ID・バージョン・実行ファイル名)
//   - `Contents/Resources/moduleinfo.json`(VST 3.7 以降の任意ファイル。クラス一覧)
//   - 実行ファイルの先頭数 KB(Mach-O ヘッダ。対応アーキテクチャの判定だけに使う)
// 音声処理そのもの(ホスティング)は未実装。調査と理由は `docs/VST3プラグイン調査と到達範囲.md`。
// 境界(プロトコルと未ロード時の扱い)は `PluginAudioEffect.swift`。

/// moduleinfo.json のクラス 1 件分(読み取れた分だけ。欠けた項目は nil)。
public struct VST3ModuleClass: Equatable, Sendable {
    /// クラス種別(例: "Audio Module Class" / "Component Controller Class")。
    public var category: String?
    public var name: String?
    public var vendor: String?
    public var version: String?
    /// クラス ID(CID。16 バイトの GUID を 32 桁の 16 進で表したもの)。
    public var cid: String?

    public init(category: String? = nil, name: String? = nil, vendor: String? = nil, version: String? = nil, cid: String? = nil) {
        self.category = category; self.name = name; self.vendor = vendor; self.version = version; self.cid = cid
    }

    /// 音声モジュール本体のクラスか(VST3 エフェクト/楽器の実体)。
    public var isAudioModule: Bool { category?.contains("Audio Module Class") ?? false }
}

/// 検出した .vst3 バンドル 1 件分のメタ情報。バイナリ本体は読んでいない。
public struct VST3BundleInfo: Equatable, Sendable {
    /// バンドルの場所(`....vst3`)。
    public var bundleURL: URL
    /// 表示名(Info.plist の CFBundleName → CFBundleDisplayName → フォルダ名の順)。
    public var name: String
    /// バンドル ID(Info.plist の CFBundleIdentifier)。無ければ nil。
    public var bundleIdentifier: String?
    /// バージョン(Info.plist の CFBundleShortVersionString → CFBundleVersion の順)。
    public var version: String?
    /// 実行ファイル名(Info.plist の CFBundleExecutable)。無ければ nil。
    public var executableName: String?
    /// 実行ファイルの場所(`Contents/MacOS/<実行ファイル名>`)。実在しなければ nil。
    public var executableURL: URL?
    /// 実行ファイルの Mach-O ヘッダから読んだ対応アーキテクチャ(例: ["arm64", "x86_64"])。読めなければ空。
    public var architectures: [String]
    /// moduleinfo.json のトップレベルのモジュール名/ベンダー(無ければ nil)。
    public var moduleName: String?
    public var moduleVendor: String?
    /// moduleinfo.json のクラス一覧(ファイルが無い/読めないときは空)。
    public var moduleClasses: [VST3ModuleClass]
    /// 構造上の問題(人間向けの短い文)。空 = 問題なし。
    public var issues: [String]

    public init(bundleURL: URL, name: String, bundleIdentifier: String? = nil, version: String? = nil,
                executableName: String? = nil, executableURL: URL? = nil, architectures: [String] = [],
                moduleName: String? = nil, moduleVendor: String? = nil, moduleClasses: [VST3ModuleClass] = [],
                issues: [String] = []) {
        self.bundleURL = bundleURL; self.name = name; self.bundleIdentifier = bundleIdentifier
        self.version = version; self.executableName = executableName; self.executableURL = executableURL
        self.architectures = architectures; self.moduleName = moduleName; self.moduleVendor = moduleVendor
        self.moduleClasses = moduleClasses; self.issues = issues
    }

    /// 構造が揃っているか(Info.plist が読めて、実行ファイルが実在し、Mach-O として読めた)。
    public var hasUsableStructure: Bool { issues.isEmpty }
    /// 音声モジュールとして宣言されているか(moduleinfo.json がある場合のみ確かめられる。無い場合は true 扱いにしない)。
    public var declaresAudioModule: Bool { moduleClasses.contains { $0.isAudioModule } }
    /// この Mac のアーキテクチャ向けのビルドを含むか。アーキテクチャが読めなかったときは false。
    public var supportsHostArchitecture: Bool {
        let host = VST3Scanner.hostArchitecture
        if architectures.contains(host) { return true }
        // arm64e 専用バイナリは arm64 の Mac で動く
        return host == "arm64" && architectures.contains("arm64e")
    }
    /// プロジェクトに保存するときの安定した識別子(バンドル ID。無ければフォルダ名から作る)。
    public var slotIdentifier: String {
        if let id = bundleIdentifier, !id.isEmpty { return id }
        return "folder." + bundleURL.deletingPathExtension().lastPathComponent
    }
    /// 音声エフェクト識別子(`AudioFx` ではなくプラグイン解決用の文字列)。
    public var audioEffectID: String { "vst3." + slotIdentifier.lowercased() }
}

/// スキャンで読み飛ばした場所と、その理由。
public struct VST3ScanFailure: Equatable, Sendable {
    public var url: URL
    public var reason: String
    public init(url: URL, reason: String) { self.url = url; self.reason = reason }
}

/// スキャン結果。検出分と失敗分を分けて返す(1 個壊れていても他は使えるように)。
public struct VST3ScanResult: Sendable {
    public var plugins: [VST3BundleInfo]
    public var failures: [VST3ScanFailure]
    public init(plugins: [VST3BundleInfo], failures: [VST3ScanFailure]) {
        self.plugins = plugins; self.failures = failures
    }
    /// 構造が揃ったものだけ。
    public var usablePlugins: [VST3BundleInfo] { plugins.filter { $0.hasUsableStructure } }
    public func plugin(forSlotIdentifier id: String) -> VST3BundleInfo? {
        plugins.first { $0.slotIdentifier == id }
    }
}

/// .vst3 バンドルの探索。バイナリには触らない(先頭ヘッダの読み取りを除く)。
public enum VST3Scanner {
    public static let bundlePathExtension = "vst3"

    /// このプロセスのアーキテクチャ名(Mach-O の表記に合わせたもの)。
    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// VST3 の標準の置き場(システム全体 + ユーザー)。存在しないものは含めない。
    public static func standardDirectories(fileManager: FileManager = .default) -> [URL] {
        var out: [URL] = []
        let system = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3", isDirectory: true)
        if fileManager.fileExists(atPath: system.path) { out.append(system) }
        let user = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3", isDirectory: true)
        if fileManager.fileExists(atPath: user.path) { out.append(user) }
        return out
    }

    /// 標準の置き場を走査する。置き場自体が無いのは失敗に数えない(普通の状態なので)。
    public static func scanStandard(fileManager: FileManager = .default) -> VST3ScanResult {
        scan(directories: standardDirectories(fileManager: fileManager), fileManager: fileManager)
    }

    /// 指定ディレクトリの直下にある `.vst3` を走査する。読めないディレクトリは失敗として記録して続行する。
    /// `.vst3` でないものは無視する(失敗にも数えない)。並びは名前順で決定的。
    public static func scan(directories: [URL], fileManager: FileManager = .default) -> VST3ScanResult {
        var plugins: [VST3BundleInfo] = []
        var failures: [VST3ScanFailure] = []
        for root in directories {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            } catch {
                failures.append(VST3ScanFailure(url: root, reason: "ディレクトリを読めない: \(error.localizedDescription)"))
                continue
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where child.pathExtension.lowercased() == bundlePathExtension {
                plugins.append(inspect(bundleAt: child, fileManager: fileManager))
            }
        }
        return VST3ScanResult(plugins: plugins, failures: failures)
    }

    /// バンドル 1 件を調べる。失敗しても例外にせず、`issues` に理由を入れて返す。
    public static func inspect(bundleAt url: URL, fileManager: FileManager = .default) -> VST3BundleInfo {
        var issues: [String] = []
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let folderName = url.deletingPathExtension().lastPathComponent

        // Info.plist
        var plist: [String: Any]? = nil
        let plistURL = contents.appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = obj as? [String: Any] {
            plist = dict
        } else {
            issues.append("Info.plist が無い、または読めない")
        }
        func plistString(_ key: String) -> String? {
            guard let v = plist?[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        let name = plistString("CFBundleName") ?? plistString("CFBundleDisplayName") ?? folderName
        let bundleID = plistString("CFBundleIdentifier")
        let version = plistString("CFBundleShortVersionString") ?? plistString("CFBundleVersion")
        let executableName = plistString("CFBundleExecutable")

        // 実行ファイル(存在と Mach-O ヘッダだけ。ロードはしない)
        var executableURL: URL? = nil
        var architectures: [String] = []
        if let executableName {
            let candidate = contents.appendingPathComponent("MacOS", isDirectory: true).appendingPathComponent(executableName)
            if fileManager.fileExists(atPath: candidate.path) {
                executableURL = candidate
                if let head = readHead(candidate, bytes: 8192) {
                    architectures = machOArchitectures(head)
                    if architectures.isEmpty { issues.append("実行ファイルが Mach-O として読めない") }
                } else {
                    issues.append("実行ファイルを読めない")
                }
            } else {
                issues.append("実行ファイルが無い(Contents/MacOS/\(executableName))")
            }
        } else {
            issues.append("Info.plist に実行ファイル名(CFBundleExecutable)が無い")
        }

        // moduleinfo.json(任意)
        var moduleName: String? = nil
        var moduleVendor: String? = nil
        var moduleClasses: [VST3ModuleClass] = []
        let moduleInfoURL = contents.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent("moduleinfo.json")
        if let data = try? Data(contentsOf: moduleInfoURL),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            moduleName = (dict["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            moduleVendor = (dict["Vendor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let classes = dict["Classes"] as? [[String: Any]] {
                moduleClasses = classes.map { c in
                    VST3ModuleClass(category: c["Category"] as? String,
                                    name: c["Name"] as? String,
                                    vendor: c["Vendor"] as? String,
                                    version: c["Version"] as? String,
                                    cid: c["CID"] as? String)
                }
            }
        }

        return VST3BundleInfo(bundleURL: url, name: name, bundleIdentifier: bundleID, version: version,
                              executableName: executableName, executableURL: executableURL,
                              architectures: architectures, moduleName: moduleName, moduleVendor: moduleVendor,
                              moduleClasses: moduleClasses, issues: issues)
    }

    /// ファイルの先頭だけを読む(大きいバイナリ全体は読まない)。
    private static func readHead(_ url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: bytes)
    }

    // MARK: Mach-O ヘッダの解釈(純粋なバイト列処理。テスト可能)

    /// Mach-O(ファット/単一)の先頭バイト列から、含まれるアーキテクチャ名の一覧を返す。Mach-O でなければ空。
    /// ファットは先頭のアーキテクチャ表だけを読むので、小さい断片でも判定できる。
    public static func machOArchitectures(_ data: Data) -> [String] {
        let b = [UInt8](data.prefix(8192))
        guard b.count >= 8 else { return [] }
        func be32(_ off: Int) -> UInt32 { UInt32(b[off]) << 24 | UInt32(b[off + 1]) << 16 | UInt32(b[off + 2]) << 8 | UInt32(b[off + 3]) }
        func le32(_ off: Int) -> UInt32 { UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24 }

        // ファット(ビッグエンディアン): CA FE BA BE / CA FE BA BF(64)
        if b[0] == 0xCA && b[1] == 0xFE && b[2] == 0xBA && (b[3] == 0xBE || b[3] == 0xBF) {
            let is64 = b[3] == 0xBF
            let count = Int(be32(4))
            let stride = is64 ? 32 : 20
            var out: [String] = []
            for i in 0..<count {
                let off = 8 + i * stride
                guard off + 8 <= b.count else { break }
                let cpu = be32(off)
                let sub = be32(off + 4)
                if let name = architectureName(cpuType: cpu, cpuSubtype: sub), !out.contains(name) { out.append(name) }
            }
            return out
        }
        // 単一 Mach-O は CPU 種別と亜種(8〜11 バイト目)まで読む。断片が 12 バイト未満なら
        // 判定しない(8 バイトのガードのままだと、8〜11 バイトの断片で範囲外を読んで落ちる)。
        guard b.count >= 12 else { return [] }
        // 単一 64 ビット: CF FA ED FE(LE) / FE ED FA CF(BE)
        if b[0] == 0xCF && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE {
            return [architectureName(cpuType: le32(4), cpuSubtype: le32(8))].compactMap { $0 }
        }
        if b[0] == 0xFE && b[1] == 0xED && b[2] == 0xFA && b[3] == 0xCF {
            return [architectureName(cpuType: be32(4), cpuSubtype: be32(8))].compactMap { $0 }
        }
        // 単一 32 ビット: CE FA ED FE(LE) / FE ED FA CE(BE)
        if b[0] == 0xCE && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE {
            return [architectureName(cpuType: le32(4), cpuSubtype: le32(8))].compactMap { $0 }
        }
        if b[0] == 0xFE && b[1] == 0xED && b[2] == 0xFA && b[3] == 0xCE {
            return [architectureName(cpuType: be32(4), cpuSubtype: be32(8))].compactMap { $0 }
        }
        return []
    }

    /// CPU 種別(+ arm64 の亜種)から名前へ。知らない種別は "cpu<値>" とする(空にはしない)。
    static func architectureName(cpuType: UInt32, cpuSubtype: UInt32) -> String? {
        switch cpuType {
        case 7: return "i386"
        case 0x0100_0007: return "x86_64"
        case 12: return "arm"
        case 0x0100_000C: return (cpuSubtype & 0x00FF_FFFF) == 2 ? "arm64e" : "arm64"
        case 0x0200_000C: return "arm64_32"
        case 18: return "ppc"
        case 0x0100_0012: return "ppc64"
        default: return "cpu\(cpuType)"
        }
    }
}
