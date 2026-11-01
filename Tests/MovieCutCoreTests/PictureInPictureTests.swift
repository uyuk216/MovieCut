import XCTest
@testable import MovieCutCore

/// 配置プリセット(右上・右下・左上・左下に小さく)。拡大 0.3、余白 3%。既存の x・y・scale だけを書く。
final class PictureInPictureTests: XCTestCase {
    func testCornersOnSixteenByNineCanvasAreInsideMargins() {
        // 16:9 の素材を 16:9 のキャンバスに置くと、拡大 0.3 の幅・高さは 0.3。中心は端から 0.03 + 0.15 の位置。
        let tr = PictureInPicture.pose(corner: .topRight)
        XCTAssertEqual(tr.x, 0.82, accuracy: 1e-9)
        XCTAssertEqual(tr.y, 0.18, accuracy: 1e-9)
        XCTAssertEqual(tr.scale, 0.3, accuracy: 1e-9)
        XCTAssertEqual(PictureInPicture.pose(corner: .bottomRight).x, 0.82, accuracy: 1e-9)
        XCTAssertEqual(PictureInPicture.pose(corner: .bottomRight).y, 0.82, accuracy: 1e-9)
        XCTAssertEqual(PictureInPicture.pose(corner: .topLeft).x, 0.18, accuracy: 1e-9)
        XCTAssertEqual(PictureInPicture.pose(corner: .topLeft).y, 0.18, accuracy: 1e-9)
        XCTAssertEqual(PictureInPicture.pose(corner: .bottomLeft).x, 0.18, accuracy: 1e-9)
        XCTAssertEqual(PictureInPicture.pose(corner: .bottomLeft).y, 0.82, accuracy: 1e-9)
    }

    func testTallSourceOnWideCanvasKeepsItsVisibleWidthInsideTheMargin() {
        // 縦長(9:16)の素材は、高さのぶんだけ小さく見える。右上の端は余白 0.03 のところで止まる。
        let p = PictureInPicture.pose(corner: .topRight, sourceAspect: 9.0 / 16, canvasAspect: 16.0 / 9)
        let k = min((16.0 / 9) / (9.0 / 16), 1) * PictureInPicture.scale
        let halfW = k * (9.0 / 16) / (16.0 / 9) / 2
        XCTAssertEqual(p.x + halfW, 1 - PictureInPicture.margin, accuracy: 1e-9)
        XCTAssertLessThan(p.y, 0.5)
    }

    func testApplyWritesPositionAndScaleAndReportsNoOp() {
        var c = Clip()
        c.type = .video
        XCTAssertTrue(PictureInPicture.apply(&c, corner: .bottomRight))
        XCTAssertEqual(c.x ?? -1, 0.82, accuracy: 1e-9)
        XCTAssertEqual(c.y ?? -1, 0.82, accuracy: 1e-9)
        XCTAssertEqual(c.scale ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertFalse(PictureInPicture.apply(&c, corner: .bottomRight), "同じ配置は変更なし")
    }

    func testOnlyVisualClipsAreSupported() {
        var sound = Clip()
        sound.type = .audio
        XCTAssertFalse(PictureInPicture.apply(&sound, corner: .topLeft))
        XCTAssertNil(sound.x)
        XCTAssertFalse(PictureInPicture.supports(.blur))
        XCTAssertTrue(PictureInPicture.supports(.text))
        XCTAssertTrue(PictureInPicture.supports(.image))
    }

    func testLabelsAreTheFourMenuTitles() {
        XCTAssertEqual(PipCorner.allCases.map(\.label), ["右上に小さく", "右下に小さく", "左上に小さく", "左下に小さく"])
    }
}
