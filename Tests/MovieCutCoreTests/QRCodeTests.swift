import XCTest
import ImageIO
import MovieCutCore

/// QR コードの画像生成(Core Image の CIQRCodeGenerator)。読み直して中身を確かめる。
final class QRCodeTests: XCTestCase {
    func testRoundTripReadsTheSameText() throws {
        let url = "https://example.com/watch?v=abc123"
        let data = try XCTUnwrap(QRCode.pngData(text: url, side: 400))
        XCTAssertEqual(QRCode.readBack(pngData: data), url)
    }

    func testJapaneseTextRoundTrips() throws {
        let data = try XCTUnwrap(QRCode.pngData(text: "動画の概要欄はこちら", side: 300))
        XCTAssertEqual(QRCode.readBack(pngData: data), "動画の概要欄はこちら")
    }

    func testRejectsEmptyTooLongAndTinySizes() {
        XCTAssertNil(QRCode.pngData(text: "   "))
        XCTAssertNil(QRCode.pngData(text: String(repeating: "a", count: QRCode.maxTextLength + 1)))
        XCTAssertNil(QRCode.pngData(text: "a", side: 10))
    }

    func testOutputIsPNGOfRequestedSize() throws {
        let data = try XCTUnwrap(QRCode.pngData(text: "hi", side: 256))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertGreaterThanOrEqual(img.width, 256)
        XCTAssertLessThan(abs(img.width - img.height), 2)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])   // PNG
    }
}
