import XCTest
@testable import MovieCutCore

final class FontScaleTests: XCTestCase {
    func testTable() {
        let expected: [(FontScaleStep, CGFloat, CGFloat)] = [
            (.small, 13, 12), (.mediumSmall, 15, 13), (.standard, 17, 14), (.large, 18, 16), (.extraLarge, 20, 18)
        ]
        XCTAssertEqual(FontScaleStep.allCases.count, expected.count)
        for (s, h, b) in expected {
            XCTAssertEqual(s.headingSize, h); XCTAssertEqual(s.bodySize, b)
        }
    }

    func testDefaultIsStandard() {
        XCTAssertEqual(FontScaleStep.default, .standard)
        XCTAssertEqual(FontScaleStep.default.headingSize, 17)
        XCTAssertEqual(FontScaleStep.default.bodySize, 14)
        XCTAssertEqual(FontScaleStep.allCases.first, .small)
        XCTAssertEqual(FontScaleStep.small.headingSize, 13)
        XCTAssertEqual(FontScaleStep.small.bodySize, 12)
    }

    func testMonotonic() {
        let all = FontScaleStep.allCases
        for (a, b) in zip(all, all.dropFirst()) {
            XCTAssertLessThanOrEqual(a.headingSize, b.headingSize)
            XCTAssertLessThanOrEqual(a.bodySize, b.bodySize)
        }
    }

    func testScaling() {
        for s in FontScaleStep.allCases {
            XCTAssertEqual(s.bodyScaled(base: 12), s.bodySize, accuracy: 1e-9)
            XCTAssertEqual(s.headingScaled(base: 13), s.headingSize, accuracy: 1e-9)
        }
        for base: CGFloat in [10, 11, 12, 13, 15, 17, 22, 26] {
            XCTAssertEqual(FontScaleStep.small.bodyScaled(base: base), base, accuracy: 1e-9)
            XCTAssertEqual(FontScaleStep.small.headingScaled(base: base), base, accuracy: 1e-9)
        }
    }
}
