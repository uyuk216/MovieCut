import XCTest
@testable import MovieCutCore

/// 取り込みファイルの大きさの上限。実際に巨大なファイルは作らず、疎なファイル(サイズだけ大きい)で確かめる。
final class ImportSizeLimitTests: XCTestCase {
    private func sparse(_ name: String, size: UInt64) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("importlimit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: size)
        try h.close()
        return url
    }

    private func assertTooLarge(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { e in
            guard case InputLimits.Failure.tooLarge = e else { return XCTFail("\(e)", file: file, line: line) }
            XCTAssertTrue((e as? LocalizedError)?.errorDescription?.contains("大きすぎます") == true, file: file, line: line)
        }
    }

    func testPrprojOversizeRejected() throws {
        let url = try sparse("a.prproj", size: UInt64(InputLimits.maxPrprojBytes) + 1)
        assertTooLarge { _ = try PrprojImporter.read(from: url) }
    }

    func testFcpXmlOversizeRejected() throws {
        let url = try sparse("a.fcpxml", size: UInt64(InputLimits.maxFcpXmlBytes) + 1)
        assertTooLarge { _ = try FcpXmlImporter.read(from: url) }
    }

    func testYmmpOversizeRejected() throws {
        let url = try sparse("a.ymmp", size: UInt64(InputLimits.maxYmmpBytes) + 1)
        assertTooLarge { _ = try YmmpImporter.load(fileAt: url) }
    }

    func testGunzipExpandedLimitIsLowered() {
        XCTAssertEqual(PrprojImporter.maxXMLBytes, 256 << 20)
        // ISIZE が上限を超えると宣言する gzip は、展開せずに断る。
        var gz: [UInt8] = [0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff]
        gz += [UInt8](repeating: 0, count: 8)
        let isize = UInt32(300 << 20)
        gz += [0, 0, 0, 0, UInt8(isize & 0xff), UInt8((isize >> 8) & 0xff), UInt8((isize >> 16) & 0xff), UInt8((isize >> 24) & 0xff)]
        XCTAssertThrowsError(try PrprojImporter.gunzip(Data(gz)))
    }
}
