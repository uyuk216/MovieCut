import XCTest
@testable import MovieCutCore

final class AppEditionTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/tmp/mc-support-test", isDirectory: true)

    func testResolveDefaultsToPersonal() {
        XCTAssertEqual(AppEdition.resolve(infoDictionary: nil), .personal)
        XCTAssertEqual(AppEdition.resolve(infoDictionary: [:]), .personal)
        XCTAssertEqual(AppEdition.resolve(infoDictionary: ["MovieCutEdition": "???"]), .personal)
        XCTAssertEqual(AppEdition.resolve(infoDictionary: ["MovieCutEdition": 3]), .personal)
        XCTAssertEqual(AppEdition.resolve(infoDictionary: ["MovieCutEdition": "personal"]), .personal)
        XCTAssertEqual(AppEdition.resolve(infoDictionary: ["MovieCutEdition": "public"]), .public)
        XCTAssertEqual(AppEdition.resolve(infoDictionary: ["MovieCutEdition": " Public "]), .public)
    }

    func testTestProcessIsPersonal() {
        XCTAssertEqual(AppEdition.current, .personal)
        XCTAssertEqual(AppEdition.personal.bundleIdentifier, "jp.local.moviecut")
        XCTAssertEqual(AppEdition.public.bundleIdentifier, "jp.local.moviecut.public")
    }

    /// personal は従来の場所と完全に同じ(既存のデータを動かさない)。
    func testPersonalPathsAreExactlyTheLegacyOnes() {
        let d = DataLocations(edition: .personal, applicationSupport: support)
        let base = support.appendingPathComponent("MovieCut")
        XCTAssertEqual(d.root.path, base.path)
        XCTAssertEqual(d.fonts.path, base.path + "/Fonts")
        XCTAssertEqual(d.proxies.path, base.path + "/Proxies")
        XCTAssertEqual(d.voices.path, base.path + "/voices")
        XCTAssertEqual(d.templates.path, base.path + "/Templates")
        XCTAssertEqual(d.exportPresets.path, base.path + "/export-presets.json")
        XCTAssertEqual(d.recovery.path, base.path + "/Recovery")
        XCTAssertEqual(d.qrCodes.path, base.path + "/QRCodes")
        XCTAssertEqual(d.aiImages.path, base.path + "/AIImages")
        XCTAssertEqual(d.psdCache.path, base.path + "/PSDCache")
        XCTAssertEqual(d.cutouts.path, base.path + "/Cutouts")
        XCTAssertTrue(d.defaults === UserDefaults.standard)
    }

    /// 既定の入口(FontLibrary など)が DataLocations を通っている。
    func testCoreEntryPointsRouteThroughDataLocations() {
        let d = DataLocations.current
        XCTAssertEqual(FontLibrary.defaultDirectory().path, d.fonts.path)
        XCTAssertEqual(ProxyStore.defaultDirectory().path, d.proxies.path)
        XCTAssertEqual(AIImageStore.directory().path, d.aiImages.path)
        XCTAssertEqual(VoiceCache.standard.directory.path, d.voices.path)
        XCTAssertEqual(TemplateStore.standard()?.directory.path, d.templates.path)
    }

    func testPersonalAndPublicNeverOverlap() {
        let p = DataLocations(edition: .personal, applicationSupport: support)
        let q = DataLocations(edition: .public, applicationSupport: support)
        XCTAssertNotEqual(p.supportFolderName, q.supportFolderName)
        XCTAssertFalse(q.supportFolderName.contains("ゆっくり"))
        let all = p.allPaths + q.allPaths
        XCTAssertEqual(Set(all.map(\.path)).count, all.count, "同じパスが 2 回出ている")
        for a in p.allPaths + [p.root] {
            for b in q.allPaths + [q.root] {
                XCTAssertFalse(a.path == b.path || a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/"),
                               "\(a.path) と \(b.path) が重なっている")
            }
        }
        XCTAssertNotEqual(p.edition.bundleIdentifier, q.edition.bundleIdentifier)
        XCTAssertFalse(q.edition.bundleIdentifier.contains("yukkuri"))
    }

    func testPublicPathsStayUnderOwnRoot() {
        let q = DataLocations(edition: .public, applicationSupport: support)
        for u in q.allPaths { XCTAssertTrue(u.path.hasPrefix(q.root.path + "/"), u.path) }
    }

    func testPublicDefaultsAreSeparateFromStandard() {
        let q = DataLocations(edition: .public, applicationSupport: support)
        XCTAssertFalse(q.defaults === UserDefaults.standard)
        let key = "mc.edition.test.\(UUID().uuidString)"
        q.defaults.set("x", forKey: key)
        defer { q.defaults.removeObject(forKey: key) }
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }
}

/// 配布物に個人のパス・名前が入らないことを、ソースを読んで確かめる。
final class DistributionGuardTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func textFiles(under dir: String) -> [URL] {
        let root = packageRoot.appendingPathComponent(dir)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let exts: Set<String> = ["swift", "sh", "plist", "md", "json", "strings"]
        return e.compactMap { $0 as? URL }.filter { exts.contains($0.pathExtension) }
    }

    func testNoPersonalPathsOrNamesInShippedSources() throws {
        let forbidden = ["/Users/", "uyu", "mycodex"]
        var files: [URL] = []
        // make-app.sh は検査用に禁止語そのものを、release.sh は公開先のリポジトリ名(uyuk216)を書いている開発用スクリプトで、配布物には入らないので除く
        for d in ["Sources", "Resources", "Scripts"] { files += textFiles(under: d).filter { !["make-app.sh", "release.sh"].contains($0.lastPathComponent) } }
        for f in ["LICENSE.ja.md", "docs/第三者の規約.md"] { files.append(packageRoot.appendingPathComponent(f)) }
        XCTAssertGreaterThan(files.count, 50, "ソースが見つからない(場所の取り違え)")
        var hits: [String] = []
        for f in files {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for w in forbidden where s.contains(w) { hits.append("\(f.lastPathComponent): \(w)") }
        }
        XCTAssertTrue(hits.isEmpty, "個人情報の疑い: \(hits)")
    }

    func testNoApplicationSupportLiteralsOutsideDataLocations() throws {
        var hits: [String] = []
        for d in ["Sources/MovieCut", "Sources/MovieCutCore"] {
            for f in textFiles(under: d) where f.lastPathComponent != "AppEdition.swift" && f.lastPathComponent != "DebugHooks.swift" && f.pathExtension == "swift" {
                let s = try String(contentsOf: f, encoding: .utf8)
                for line in s.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    if line.contains("applicationSupportDirectory") && !f.lastPathComponent.hasPrefix("VoiceCache") { hits.append("\(f.lastPathComponent): \(line)") }
                    if line.contains("UserDefaults.standard") || line.contains("defaults: .standard") { hits.append("\(f.lastPathComponent): \(line)") }
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "DataLocations を通っていない保存先: \(hits)")
    }

    func testMakeAppScriptKnowsEditionsAndScans() throws {
        let s = try String(contentsOf: packageRoot.appendingPathComponent("Scripts/make-app.sh"), encoding: .utf8)
        for w in ["--edition", "MovieCutEdition", "jp.local.moviecut.public", "scan_bundle", "--dry-run"] {
            XCTAssertTrue(s.contains(w), w)
        }
    }
}
