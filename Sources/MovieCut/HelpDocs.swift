import Foundation
import AppKit

/// アプリの情報(About パネル)。
enum AppInfo {
    static let name = "Movie Cut"
    static let fallbackVersion = "0.2.0"
    static let notBundledNote = "VOICEVOX と AquesTalk は同梱していません。利用者がインストールしたものを呼び出します。"
    static let subtitle = "動画編集ソフト for Mac"
    static let tagline = "VOICEVOX / ゆっくり音声(AquesTalk)対応の動画編集ソフトです。"

    /// .app の中なら Info.plist の値、SwiftPM から動かしているときは 0.2.0。
    static func version(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        (info?["CFBundleShortVersionString"] as? String) ?? fallbackVersion
    }

    /// About パネルの説明文。ライセンスのファイルが見つかれば「ライセンス」の語がリンクになる。
    static func credits(licenseURL: URL?) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        let out = NSMutableAttributedString(string: "\(subtitle)\n\(tagline)\n\(notBundledNote)\n", attributes: base)
        out.append(NSAttributedString(string: "詳しくは「ヘルプ」メニューの ", attributes: base))
        var link = base
        if let u = licenseURL { link[.link] = u }
        out.append(NSAttributedString(string: "ライセンス", attributes: link))
        out.append(NSAttributedString(string: " と「第三者の規約」をご覧ください。", attributes: base))
        return out
    }

    @MainActor
    static func showAboutPanel() {
        let license = HelpDocs.resolve(.license)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: name,
            .applicationVersion: version(),
            .version: "",
            .credits: credits(licenseURL: license),
        ])
    }
}

/// ヘルプメニューで開く文書。
enum HelpDoc: CaseIterable {
    case license, thirdParty

    /// .app の Resources の中でのファイル名。
    var fileName: String { self == .license ? "LICENSE.ja.md" : "第三者の規約.md" }
    /// リポジトリ(SwiftPM から動かすとき)でのパス。
    var repoRelativePath: String { self == .license ? "LICENSE.ja.md" : "docs/第三者の規約.md" }
    var title: String { self == .license ? "ライセンス" : "第三者の規約" }
}

enum HelpDocs {
    /// 探す場所の出発点(上へたどってリポジトリの直下を探す): このソースの場所、実行ファイルの場所、作業ディレクトリ。
    static func defaultSearchRoots(sourceFile: String = #filePath) -> [URL] {
        var roots = [URL(fileURLWithPath: sourceFile).deletingLastPathComponent()]
        if let exe = Bundle.main.executableURL { roots.append(exe.deletingLastPathComponent()) }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return roots
    }

    /// .app の Resources にあればそれ、無ければ(SwiftPM から動かしているとき)リポジトリのファイル。見つからなければ nil。
    static func resolve(_ doc: HelpDoc,
                        resourceDir: URL? = Bundle.main.resourceURL,
                        searchRoots: [URL]? = nil,
                        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        if let dir = resourceDir {
            let u = dir.appendingPathComponent(doc.fileName)
            if fileExists(u.path) { return u }
        }
        for root in searchRoots ?? defaultSearchRoots() {
            var dir = root
            for _ in 0..<8 {
                let u = dir.appendingPathComponent(doc.repoRelativePath)
                if fileExists(u.path) { return u }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    /// 既定のアプリで開く。見つからなければ案内を出す。
    @MainActor
    static func open(_ doc: HelpDoc) {
        guard let url = resolve(doc) else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "「\(doc.title)」のファイルが見つかりません"
            a.informativeText = "\(doc.fileName) がアプリの中にもリポジトリにもありませんでした。"
            a.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
