import XCTest
import MovieCutCore
@testable import MovieCut

@MainActor
final class ImportLimitsAppTests: XCTestCase {
    func testScriptCSVOversizeRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csvlimit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(InputLimits.maxScriptCSVBytes) + 1)
        try h.close()
        XCTAssertThrowsError(try ProjectModel.readCSVText(from: url)) {
            guard case InputLimits.Failure.tooLarge = $0 else { return XCTFail("\($0)") }
        }
    }
}
