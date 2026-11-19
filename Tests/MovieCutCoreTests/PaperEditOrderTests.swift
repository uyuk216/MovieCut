import XCTest
@testable import MovieCutCore

/// Paper Edit の並べ替え(Core): 組み立て列の移動(ドラッグ相当・隣との入れ替え・先頭/末尾)と、
/// 並べ替えた順で組み立てられること。
final class PaperEditOrderTests: XCTestCase {

    // MARK: 移動(ドラッグ相当)

    func testMovingTakesElementOutAndInsertsAtDestination() {
        XCTAssertEqual(PaperEdit.moving([0, 1, 2, 3], from: 0, to: 2), [1, 2, 0, 3])
        XCTAssertEqual(PaperEdit.moving([0, 1, 2, 3], from: 3, to: 0), [3, 0, 1, 2])
        XCTAssertEqual(PaperEdit.moving([0, 1, 2], from: 1, to: 1), [0, 1, 2], "同じ位置はそのまま")
        XCTAssertEqual(PaperEdit.moving([0, 1, 2], from: 9, to: 0), [0, 1, 2], "範囲外はそのまま")
        XCTAssertEqual(PaperEdit.moving([0, 1, 2], from: 0, to: -1), [0, 1, 2])
        XCTAssertEqual(PaperEdit.moving([], from: 0, to: 0), [])
    }

    func testReorderedMatchesOnMoveSemantics() {
        // 1 件を後ろへ(ドラッグで 0 番を 3 番の位置へ)
        XCTAssertEqual(PaperEdit.reordered([0, 1, 2, 3], fromOffsets: [0], toOffset: 3), [1, 2, 0, 3])
        // 1 件を先頭へ
        XCTAssertEqual(PaperEdit.reordered([0, 1, 2, 3], fromOffsets: [3], toOffset: 0), [3, 0, 1, 2])
        // 複数件をまとめて末尾へ
        XCTAssertEqual(PaperEdit.reordered([0, 1, 2, 3], fromOffsets: [0, 1], toOffset: 4), [2, 3, 0, 1])
        // 不正な指定はそのまま
        XCTAssertEqual(PaperEdit.reordered([0, 1, 2], fromOffsets: [], toOffset: 1), [0, 1, 2])
        XCTAssertEqual(PaperEdit.reordered([0, 1, 2], fromOffsets: [5], toOffset: 1), [0, 1, 2])
        XCTAssertEqual(PaperEdit.reordered([0, 1, 2], fromOffsets: [0], toOffset: 9), [0, 1, 2])
    }

    func testMovingEntrySwapsWithNeighbourAndStopsAtEdges() {
        XCTAssertEqual(PaperEdit.movingEntry([0, 1, 2], at: 1, by: -1), [1, 0, 2], "上へ")
        XCTAssertEqual(PaperEdit.movingEntry([0, 1, 2], at: 1, by: 1), [0, 2, 1], "下へ")
        XCTAssertEqual(PaperEdit.movingEntry([0, 1, 2], at: 0, by: -1), [0, 1, 2], "先頭で上へはそのまま")
        XCTAssertEqual(PaperEdit.movingEntry([0, 1, 2], at: 2, by: 1), [0, 1, 2], "末尾で下へはそのまま")
    }

    func testMovingEntryToEdge() {
        XCTAssertEqual(PaperEdit.movingEntryToEdge([0, 1, 2, 3], at: 2, toEnd: false), [2, 0, 1, 3], "先頭へ")
        XCTAssertEqual(PaperEdit.movingEntryToEdge([0, 1, 2, 3], at: 1, toEnd: true), [0, 2, 3, 1], "末尾へ")
        XCTAssertEqual(PaperEdit.movingEntryToEdge([0, 1, 2], at: 9, toEnd: true), [0, 1, 2], "範囲外はそのまま")
    }

    // MARK: 並べ替え後の組み立て

    func testAssembleUsesReorderedSequence() throws {
        var p = Project.new()
        var c = Clip(); c.id = "a"; c.type = .audio; c.start = 0; c.duration = 6; c.offset = 10; c.src = "/x.wav"
        var tr = Track(name: "音"); tr.clips = [c]
        p.tracks = [tr]
        let sentences = [
            TranscriptSentence(text: "一", start: 0, end: 2),
            TranscriptSentence(text: "二", start: 2, end: 3.5),
            TranscriptSentence(text: "三", start: 4, end: 6),
        ]
        // [0,1,2] の末尾を先頭へ動かす → [2,0,1]
        let order = PaperEdit.movingEntryToEdge([0, 1, 2], at: 2, toEnd: false)
        XCTAssertEqual(order, [2, 0, 1])
        let r = try XCTUnwrap(PaperEdit.assemble(in: p, sourceClipId: "a", sentences: sentences,
                                                 order: order, destination: .appendToTrack(0)))
        let made = r.project.tracks[0].clips.filter { $0.id != "a" }.sorted { $0.start < $1.start }
        XCTAssertEqual(made.map(\.offset), [14, 10, 12], "並べ替えた順(三・一・二)で素材区間が並ぶ")
        XCTAssertEqual(made.map(\.start), [6, 8, 10], "末尾から隙間なく")
        XCTAssertEqual(r.clipIds, made.map(\.id), "返す id も並べ替え後の順")
    }
}
