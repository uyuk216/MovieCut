import XCTest
@testable import MovieCutCore

/// 展開した立ち絵クリップの表情の切り替えを、再生位置で足す・外す(`TachieEditing.setExpression`)。
final class TachieExpressionEditTests: XCTestCase {
    func voice(_ id: String, _ start: Double, _ dur: Double, _ text: String, char: String = "c1") -> Clip {
        var c = Clip(); c.id = id; c.type = .voice; c.start = start; c.duration = dur; c.text = text; c.charId = char; return c
    }

    func project(drive: MouthDrive? = nil) -> Project {
        var p = Project(); p.width = 100; p.height = 100
        var t = Tachie(name: "れいむ"); t.id = "ta"
        var rig = CharacterRig(slots: [RigSlot(name: "体", parts: ["/b.png"])])
        rig.expressions = ["笑顔": ["体": 0], "怒り": ["体": 0]]
        t.rig = rig; t.expressions = ["驚き": "/x.png", "笑顔": "/y.png"]
        p.tachies = [t]
        var tc = Clip(); tc.id = "tc"; tc.type = .tachie; tc.tachieId = "ta"; tc.start = 0; tc.duration = 10; tc.mouthDrive = drive
        var tt = Track(name: "立ち絵"); tt.clips = [tc]
        var vt = Track(name: "声"); vt.clips = [voice("v1", 0, 3, "こんにちは"), voice("v2", 3, 3, "[怒り]やあ"), voice("v3", 7, 2, "また", char: "c2")]
        p.tracks = [tt, vt]
        return p
    }

    func text(_ p: Project, _ id: String) -> String? { p.allClips.first { $0.id == id }?.text }

    func testExpressionNamesAreUnionSorted() {
        let p = project()
        XCTAssertEqual(TachieEditing.expressionNames(of: p.tachies[0]), ["怒り", "笑顔", "驚き"])
        XCTAssertEqual(TachieEditing.expressionNames(of: Tachie(name: "x")), [])
    }

    func testAddSetsTagOnTheVoiceAtThePlayheadAndRemoveStripsIt() {
        let p = project()
        let a = TachieEditing.setExpression(p, clipId: "tc", at: 1.0, tag: "笑顔")
        XCTAssertEqual(text(a, "v1"), "[笑顔]こんにちは")
        XCTAssertEqual(text(a, "v2"), "[怒り]やあ", "ほかの声は触らない")
        // 表情の切り替え一覧に出る(通常 → 笑顔 → 怒り)
        let ch = TachieEditing.expressionChanges(a, clip: a.allClips.first { $0.id == "tc" }!)
        XCTAssertEqual(ch.map(\.tag), ["笑顔", "怒り", nil])
        // 別の表情に付け替え(タグが重ならない)
        let b = TachieEditing.setExpression(a, clipId: "tc", at: 1.0, tag: "怒り")
        XCTAssertEqual(text(b, "v1"), "[怒り]こんにちは")
        // 外す
        let c = TachieEditing.setExpression(b, clipId: "tc", at: 4.0, tag: nil)
        XCTAssertEqual(text(c, "v2"), "やあ")
        XCTAssertEqual(TachieEditing.setExpression(c, clipId: "tc", at: 1.0, tag: nil).allClips.first { $0.id == "v1" }?.text, "こんにちは")
    }

    func testNoOpsReturnTheSameValue() {
        let p = project()
        XCTAssertEqual(TachieEditing.setExpression(p, clipId: "tc", at: 1.0, tag: nil), p, "もともと通常")
        XCTAssertEqual(TachieEditing.setExpression(p, clipId: "tc", at: 4.0, tag: "怒り"), p, "同じ表情")
        XCTAssertEqual(TachieEditing.setExpression(p, clipId: "tc", at: 6.5, tag: "笑顔"), p, "声が出ていない")
        XCTAssertEqual(TachieEditing.setExpression(p, clipId: "tc", at: 1.0, tag: "bad]"), p)
        XCTAssertEqual(TachieEditing.setExpression(p, clipId: "tc", at: 1.0, tag: "  "), p)
        XCTAssertEqual(TachieEditing.setExpression(p, clipId: "v1", at: 1.0, tag: "笑顔"), p, "立ち絵クリップ以外")
        XCTAssertEqual(TachieEditing.setExpression(p, clipId: "none", at: 1.0, tag: "笑顔"), p)
        // 連動しない声(キャラ c2 だけに連動)の時刻では何も起きない
        let q = project(drive: .character("c2"))
        XCTAssertEqual(TachieEditing.setExpression(q, clipId: "tc", at: 1.0, tag: "笑顔"), q)
        XCTAssertEqual(text(TachieEditing.setExpression(q, clipId: "tc", at: 8.0, tag: "笑顔"), "v3"), "[笑顔]また")
        let n = project(drive: MouthDrive.none)
        XCTAssertEqual(TachieEditing.setExpression(n, clipId: "tc", at: 1.0, tag: "笑顔"), n, "動かさない設定では声に連動しない")
    }

    func testSubtitleTextAndOverlappingVoices() {
        var p = project()
        p.tracks[1].clips[0].subtitleText = "字幕だけ"
        let a = TachieEditing.setExpression(p, clipId: "tc", at: 1.0, tag: "笑顔")
        XCTAssertEqual(a.allClips.first { $0.id == "v1" }?.subtitleText, "字幕だけ", "字幕の文は触らない")
        // 声が重なるときは頭が遅い方
        var o = project()
        o.tracks[1].clips.append(voice("v9", 2, 3, "かぶせ"))
        XCTAssertEqual(text(TachieEditing.setExpression(o, clipId: "tc", at: 2.5, tag: "笑顔"), "v9"), "[笑顔]かぶせ")
        // 声の終わりちょうどは次の声
        XCTAssertEqual(TachieEditing.driverVoice(project(), clip: project().allClips.first { $0.id == "tc" }!, at: 3.0)?.id, "v2")
    }
}
