import XCTest
import CoreText
@testable import MovieCutCore

/// フォントの取り込み(検査・コピー・同名の扱い)と登録。実フォントはシステムのものを一時フォルダへ写して使う(読むだけ)。
final class FontLibraryTests: XCTestCase {
    private var root: URL!
    private let sampleTTF = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Academy Engraved LET Fonts.ttf")

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mc-font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let real = base.path.withCString { p -> String in
            guard let r = realpath(p, nil) else { return base.path }
            defer { free(r) }
            return String(cString: r)
        }
        root = URL(fileURLWithPath: real, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 取り込みのテストに使う。システムのフォントが無い環境では飛ばす。
    private func sampleCopy(named name: String = "sample.ttf") throws -> URL {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sampleTTF.path), "システムフォントが無い環境")
        let u = root.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sampleTTF, to: u)
        return u
    }

    func testOnlyTTFOTFTTCAreFontFiles() {
        XCTAssertTrue(FontLibrary.isFontFile(URL(fileURLWithPath: "/a/b.TTF")))
        XCTAssertTrue(FontLibrary.isFontFile(URL(fileURLWithPath: "/a/b.otf")))
        XCTAssertTrue(FontLibrary.isFontFile(URL(fileURLWithPath: "/a/b.ttc")))
        XCTAssertFalse(FontLibrary.isFontFile(URL(fileURLWithPath: "/a/b.woff2")))
        XCTAssertFalse(FontLibrary.isFontFile(URL(fileURLWithPath: "/a/b.mp4")))
    }

    func testDefaultDirectoryIsInApplicationSupportNotLibraryFonts() {
        let d = FontLibrary.defaultDirectory().path
        XCTAssertTrue(d.hasSuffix("/MovieCut/Fonts"))
        XCTAssertTrue(d.contains("Application Support"))
        XCTAssertFalse(d.contains("/Library/Fonts"))
    }

    func testRejectsWrongExtensionEvenIfReadable() throws {
        let src = try sampleCopy(named: "notes.txt")
        XCTAssertThrowsError(try FontLibrary.familyNames(of: src)) { e in
            XCTAssertEqual(e as? FontLibrary.Failure, .unsupportedType("txt"))
        }
    }

    func testRejectsBrokenFileNamedAsFont() throws {
        let bad = root.appendingPathComponent("broken.ttf")
        try Data("this is not a font".utf8).write(to: bad)
        XCTAssertThrowsError(try FontLibrary.familyNames(of: bad)) { e in
            XCTAssertEqual(e as? FontLibrary.Failure, .unreadable("broken.ttf"))
        }
        let dir = root.appendingPathComponent("fonts")
        XCTAssertThrowsError(try FontLibrary.add(bad, to: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "壊れたファイルはコピーしない")
    }

    func testAddCopiesIntoDirectoryAndReportsFamilies() throws {
        let src = try sampleCopy()
        let dir = root.appendingPathComponent("fonts")
        let a = try FontLibrary.add(src, to: dir)
        XCTAssertEqual(a.file, dir.appendingPathComponent("sample.ttf"))
        XCTAssertFalse(a.alreadyPresent)
        XCTAssertFalse(a.familyNames.isEmpty)
        XCTAssertEqual(try Data(contentsOf: a.file), try Data(contentsOf: src))
    }

    func testSameBytesAgainIsNotCopiedTwice() throws {
        let src = try sampleCopy()
        let dir = root.appendingPathComponent("fonts")
        _ = try FontLibrary.add(src, to: dir)
        let again = try FontLibrary.add(src, to: dir)
        XCTAssertTrue(again.alreadyPresent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }

    func testSameNameDifferentBytesGetsNumberedName() throws {
        let src = try sampleCopy()
        let dir = root.appendingPathComponent("fonts")
        _ = try FontLibrary.add(src, to: dir)
        // 同じ名前で中身の違うファイル(末尾に余計なバイトを足す。フォントとしては読める)
        let other = root.appendingPathComponent("other/sample.ttf")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (try Data(contentsOf: src) + Data([0, 0, 0, 0])).write(to: other)
        let b = try FontLibrary.add(other, to: dir)
        XCTAssertEqual(b.file.lastPathComponent, "sample 2.ttf")
        XCTAssertFalse(b.alreadyPresent)
    }

    func testRegisterAllCountsOnlyReadableFontsAndFamiliesList() throws {
        let src = try sampleCopy()
        let dir = root.appendingPathComponent("fonts")
        let added = try FontLibrary.add(src, to: dir)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("junk.otf"))
        try Data("not a font".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        XCTAssertEqual(FontLibrary.registerAll(in: dir), 1, "読めるフォント 1 件だけ登録")
        XCTAssertEqual(FontLibrary.families(in: dir), added.familyNames)
    }

    func testRegisteredFamilyAppearsInFontChoices() throws {
        let src = try sampleCopy()
        let dir = root.appendingPathComponent("fonts")
        let added = try FontLibrary.add(src, to: dir)
        let saved = FontChoices.userFamilies
        defer { FontChoices.userFamilies = saved }
        FontLibrary.registerAll(in: dir)
        FontChoices.userFamilies = FontLibrary.families(in: dir)
        XCTAssertTrue(FontChoices.all.contains(added.familyNames[0]))
        XCTAssertEqual(FontChoices.all.prefix(defaultFonts.count).map { $0 }, defaultFonts, "既定の一覧は先頭のまま")
        XCTAssertEqual(FontChoices.all.filter { $0 == added.familyNames[0] }.count, 1, "重複は出さない")
    }
}
