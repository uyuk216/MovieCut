import XCTest
@testable import MovieCutCore

/// 機能追加後の掃除(2026-11-02): 新しい任意項目の保存・読み込みの往復。未知のキーを含めても、保存し直しで失われないこと。
final class NewFieldRoundTripTests: XCTestCase {
    /// 新しい任意項目を全部持つ書類を作る(encode の結果を JSON として書き換えて、未知のキーを足す)。
    private func projectJSON() throws -> [String: Any] {
        var p = Project()
        var t = Track(name: "映像")
        var shape = ClipEditing.makeShapeClip(.arrow, at: 0, project: p)
        shape.id = "shape"
        shape.figure = Figure(kind: "star", fill: "#ff0000", stroke: "#00ff00", strokeWidth: 12, corner: 0.2)
        var image = Clip(); image.id = "image"; image.type = .image; image.src = "/nonexistent/a.png"; image.start = 3; image.duration = 2
        image.mask = ClipMask(shape: "ellipse", x: 0.1, y: 0.2, w: 0.5, h: 0.6, feather: 0.3, invert: true)
        var vis = Clip(); vis.id = "vis"; vis.type = .visualizer; vis.start = 6; vis.duration = 2
        vis.visualizer = Visualizer(style: "bars", color: "#123456", count: 20)
        var txt = Clip(); txt.id = "txt"; txt.type = .text; txt.start = 8; txt.duration = 2; txt.text = "x"
        txt.counter = TextCounter(from: 9, to: 1, format: "%d")
        var comp = Clip(); comp.id = "comp"; comp.type = .compound; comp.start = 10; comp.duration = 2
        var kt = Track(name: "中"); kt.clips = [shape]
        comp.tracks = [kt]
        t.clips = [image, vis, txt, comp]
        p.tracks = [t]
        p.markers = [Marker(time: 1, name: "印")]
        let data = try p.encoded()
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// 配列・辞書を再帰的にたどり、`pred` に合う辞書のすべてに `key: value` を足す。
    private func inject(_ v: Any, when pred: ([String: Any]) -> Bool, key: String, value: Any) -> Any {
        if var d = v as? [String: Any] {
            for (k, x) in d { d[k] = inject(x, when: pred, key: key, value: value) }
            if pred(d) { d[key] = value }
            return d
        }
        if let a = v as? [Any] { return a.map { inject($0, when: pred, key: key, value: value) } }
        return v
    }

    /// 任意の位置の辞書を探す(キーの有無で判定)。
    private func find(_ v: Any, _ pred: ([String: Any]) -> Bool) -> [String: Any]? {
        if let d = v as? [String: Any] {
            if pred(d) { return d }
            for (_, x) in d { if let r = find(x, pred) { return r } }
        }
        if let a = v as? [Any] { for x in a { if let r = find(x, pred) { return r } } }
        return nil
    }

    private func clipObjects(_ root: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if d["id"] is String, d["type"] is String, d["start"] != nil { out.append(d) }
                for (_, x) in d { walk(x) }
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(root)
        return out
    }

    /// 未知のキーを、クリップの直下と、新しい各項目の中に書き込む。
    private func withUnknownKeys() throws -> Data {
        var root: Any = try projectJSON()
        root = inject(root, when: { $0["type"] as? String != nil && $0["start"] != nil }, key: "futureClipKey", value: "keep-me")
        root = inject(root, when: { $0["kind"] as? String == "star" || $0["kind"] as? String == "arrow" }, key: "futureFigureKey", value: "keep-me")
        root = inject(root, when: { $0["feather"] != nil && $0["shape"] != nil }, key: "futureMaskKey", value: "keep-me")
        root = inject(root, when: { $0["count"] != nil && $0["style"] != nil }, key: "futureVisualizerKey", value: "keep-me")
        root = inject(root, when: { $0["format"] != nil && $0["from"] != nil }, key: "futureCounterKey", value: "keep-me")
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// 読んで書き直した JSON に、未知のキーが残っているか。
    func testUnknownKeysSurviveSaveAndReloadAtEveryLevel() throws {
        let data = try withUnknownKeys()
        let loaded = try Project.decode(from: data)
        let saved = try loaded.encoded()
        let root = try JSONSerialization.jsonObject(with: saved)

        let clips = clipObjects(root)
        XCTAssertFalse(clips.isEmpty)
        for c in clips {
            XCTAssertEqual(c["futureClipKey"] as? String, "keep-me", "クリップの未知のキーが消えた: \(c["id"] ?? "")")
        }
        let figure = try XCTUnwrap(find(root) { $0["kind"] as? String == "arrow" || $0["kind"] as? String == "star" })
        XCTAssertEqual(figure["futureFigureKey"] as? String, "keep-me", "figure の未知のキーが消えた")
        let mask = try XCTUnwrap(find(root) { $0["feather"] != nil && $0["shape"] != nil })
        XCTAssertEqual(mask["futureMaskKey"] as? String, "keep-me", "mask の未知のキーが消えた")
        let vis = try XCTUnwrap(find(root) { $0["count"] != nil && $0["style"] != nil })
        XCTAssertEqual(vis["futureVisualizerKey"] as? String, "keep-me", "visualizer の未知のキーが消えた")
        let counter = try XCTUnwrap(find(root) { $0["format"] != nil && $0["from"] != nil })
        XCTAssertEqual(counter["futureCounterKey"] as? String, "keep-me", "counter の未知のキーが消えた")
    }

    /// 保存し直しを繰り返しても JSON が変わらない(安定している)。
    func testSecondSaveIsByteIdentical() throws {
        let data = try withUnknownKeys()
        let once = try Project.decode(from: data).encoded()
        let twice = try Project.decode(from: once).encoded()
        XCTAssertEqual(once, twice)
    }

    /// 既定値のときは新しい項目を書かない(古い版で開いても困らないように)。
    func testDefaultValuesAreNotWritten() throws {
        var p = Project()
        var c = Clip(); c.id = "c"; c.type = .shape; c.start = 0; c.duration = 1
        c.figure = Figure(kind: "rect")
        var t = Track(name: "映像"); t.clips = [c]; p.tracks = [t]
        let root = try JSONSerialization.jsonObject(with: try p.encoded())
        let clip = try XCTUnwrap(clipObjects(root).first)
        XCTAssertNil(clip["figure"], "既定の図形(四角形・何も変えていない)は書かない")
        XCTAssertNil(clip["mask"])
    }
}
