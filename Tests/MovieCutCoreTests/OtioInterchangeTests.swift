import XCTest
@testable import MovieCutCore

/// OTIO(JSON)の書き出し構造・往復・外部製 OTIO の読み込み・変換レポートの検証。
final class OtioInterchangeTests: XCTestCase {

    private func clip(_ type: ClipType, src: String?, start: Double, duration: Double, offset: Double = 0) -> Clip {
        var c = Clip(); c.type = type; c.src = src; c.start = start; c.duration = duration; c.offset = offset
        return c
    }

    private func sample(fps: Double = 30) -> Project {
        var p = Project()
        p.width = 1280; p.height = 720; p.fps = fps
        var v = Track(name: "映像"); v.clips = [
            clip(.video, src: "/media/a.mp4", start: 0, duration: 2, offset: 1),
            clip(.video, src: "/media/b 日本語.mp4", start: 3, duration: 2),   // 2〜3 秒は Gap
        ]
        var a = Track(name: "音声"); a.clips = [clip(.audio, src: "/media/bgm.wav", start: 0, duration: 5)]
        p.tracks = [v, a]
        return p
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testExportStructure() {
        let out = OtioExporter.export(project: sample(), name: "T")
        let root = json(out.data)
        XCTAssertEqual(root["OTIO_SCHEMA"] as? String, "Timeline.1")
        let stack = root["tracks"] as! [String: Any]
        XCTAssertEqual(stack["OTIO_SCHEMA"] as? String, "Stack.1")
        let tracks = stack["children"] as! [[String: Any]]
        XCTAssertEqual(tracks.map { $0["kind"] as? String }, ["Video", "Audio"])
        XCTAssertEqual(tracks[0]["OTIO_SCHEMA"] as? String, "Track.1")
        let kids = tracks[0]["children"] as! [[String: Any]]
        XCTAssertEqual(kids.map { $0["OTIO_SCHEMA"] as? String }, ["Clip.1", "Gap.1", "Clip.1"])
        let sr = kids[0]["source_range"] as! [String: Any]
        XCTAssertEqual(sr["OTIO_SCHEMA"] as? String, "TimeRange.1")
        let st = sr["start_time"] as! [String: Any], du = sr["duration"] as! [String: Any]
        XCTAssertEqual(st["OTIO_SCHEMA"] as? String, "RationalTime.1")
        XCTAssertEqual(st["value"] as? Double, 30); XCTAssertEqual(du["value"] as? Double, 60); XCTAssertEqual(du["rate"] as? Double, 30)
        let gap = (kids[1]["source_range"] as! [String: Any])["duration"] as! [String: Any]
        XCTAssertEqual(gap["value"] as? Double, 30)
        let ref = kids[0]["media_reference"] as! [String: Any]
        XCTAssertEqual(ref["OTIO_SCHEMA"] as? String, "ExternalReference.1")
        XCTAssertEqual(ref["target_url"] as? String, "file://localhost/media/a.mp4")
        XCTAssertEqual(out.report.clipCount, 3)
        XCTAssertFalse(out.report.hasLoss)
    }

    func testFractionalRate() {
        let out = OtioExporter.export(project: sample(fps: 29.97), name: "T")
        let tracks = (json(out.data)["tracks"] as! [String: Any])["children"] as! [[String: Any]]
        let kids = tracks[0]["children"] as! [[String: Any]]
        let du = (kids[0]["source_range"] as! [String: Any])["duration"] as! [String: Any]
        XCTAssertEqual(du["rate"] as! Double, 30000.0 / 1001.0, accuracy: 1e-9)
    }

    func testRoundTrip() throws {
        let p = sample()
        let back = try OtioImporter.parse(data: OtioExporter.export(project: p).data)
        XCTAssertFalse(back.report.hasLoss)
        let q = back.project
        XCTAssertEqual(q.fps, 30); XCTAssertEqual(q.width, 1280); XCTAssertEqual(q.height, 720)
        XCTAssertEqual(q.tracks.map { $0.name }, ["映像", "音声"])
        XCTAssertEqual(q.tracks[0].clips.count, 2)
        for (a, b) in zip(p.tracks.flatMap { $0.clips }, q.tracks.flatMap { $0.clips }) {
            XCTAssertEqual(a.src, b.src); XCTAssertEqual(a.type, b.type)
            XCTAssertEqual(a.start, b.start, accuracy: 1e-6); XCTAssertEqual(a.duration, b.duration, accuracy: 1e-6)
            XCTAssertEqual(a.offset, b.offset, accuracy: 1e-6)
        }
    }

    func testRoundTripOverlapAndSpeedAndMixedTrack() throws {
        var p = Project(); p.fps = 30
        var t = Track(name: "混在")
        var fast = clip(.video, src: "/m/x.mp4", start: 0, duration: 2); fast.speed = 2
        t.clips = [fast, clip(.video, src: "/m/y.mp4", start: 1, duration: 2), clip(.audio, src: "/m/z.wav", start: 0, duration: 4)]
        p.tracks = [t]
        let q = try OtioImporter.parse(data: OtioExporter.export(project: p).data).project
        XCTAssertEqual(q.tracks.count, 1)
        XCTAssertEqual(q.tracks[0].clips.count, 3)
        let x = q.tracks[0].clips.first { $0.src == "/m/x.mp4" }!
        XCTAssertEqual(x.duration, 2, accuracy: 1e-6); XCTAssertEqual(x.speed, 2)
    }

    func testImportExternalMinimal() throws {
        let text = """
        {"OTIO_SCHEMA":"Timeline.1","name":"ext","tracks":{"OTIO_SCHEMA":"Stack.1","children":[
         {"OTIO_SCHEMA":"Track.1","kind":"Video","children":[
          {"OTIO_SCHEMA":"Clip.1","name":"c1","source_range":{"OTIO_SCHEMA":"TimeRange.1","start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24,"value":24},"duration":{"OTIO_SCHEMA":"RationalTime.1","rate":24,"value":48}},
           "media_reference":{"OTIO_SCHEMA":"ExternalReference.1","target_url":"file:///tmp/a%20b.mov"}},
          {"OTIO_SCHEMA":"Gap.1","source_range":{"OTIO_SCHEMA":"TimeRange.1","start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24,"value":0},"duration":{"OTIO_SCHEMA":"RationalTime.1","rate":24,"value":24}}},
          {"OTIO_SCHEMA":"Transition.1","name":"dis","transition_type":"SMPTE_Dissolve"},
          {"OTIO_SCHEMA":"Clip.1","name":"c2","source_range":{"OTIO_SCHEMA":"TimeRange.1","start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24,"value":0},"duration":{"OTIO_SCHEMA":"RationalTime.1","rate":24,"value":24}},
           "media_reference":{"OTIO_SCHEMA":"MissingReference.1"}}]},
         {"OTIO_SCHEMA":"Track.1","kind":"Audio","children":[
          {"OTIO_SCHEMA":"Clip.1","name":"s","source_range":{"OTIO_SCHEMA":"TimeRange.1","start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24,"value":0},"duration":{"OTIO_SCHEMA":"RationalTime.1","rate":24,"value":24}},
           "media_reference":{"OTIO_SCHEMA":"ExternalReference.1","target_url":"/tmp/s.wav"}}]}]}}
        """
        let out = try OtioImporter.parse(data: Data(text.utf8))
        let p = out.project
        XCTAssertEqual(p.fps, 24)
        XCTAssertEqual(p.tracks.count, 2)
        let c = p.tracks[0].clips
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].src, "/tmp/a b.mov"); XCTAssertEqual(c[0].start, 0)
        XCTAssertEqual(c[0].duration, 2, accuracy: 1e-9); XCTAssertEqual(c[0].offset, 1, accuracy: 1e-9)
        XCTAssertEqual(p.tracks[1].clips[0].type, .audio)
        // Transition と MissingReference は落ちてレポートに出る
        XCTAssertEqual(Set(out.report.unsupported.map { $0.element }), ["Transition", "Clip"])
        XCTAssertTrue(out.report.hasLoss)
    }

    func testNotOtioAndMalformed() {
        XCTAssertThrowsError(try OtioImporter.parse(data: Data("{\"a\":1}".utf8)))
        XCTAssertThrowsError(try OtioImporter.parse(data: Data("nope".utf8)))
    }

    func testExportReportDroppedElements() {
        var p = Project(); p.fps = 30
        var t = Track(name: "L")
        var v = clip(.video, src: "/m/a.mp4", start: 0, duration: 2)
        v.transitionIn = Transition(kind: "fade")
        v.keyframes = ["x": [Keyframe(t: 0, v: 0)]]
        t.clips = [v, clip(.text, src: nil, start: 2, duration: 1), clip(.voice, src: nil, start: 3, duration: 1)]
        p.tracks = [t]
        let out = OtioExporter.export(project: p)
        XCTAssertTrue(out.report.hasLoss)
        XCTAssertEqual(out.report.dropped.count, 2)
        XCTAssertEqual(out.report.droppedFeatures["トランジション"], 1)
        XCTAssertEqual(out.report.droppedFeatures["キーフレーム"], 1)
        let mc = (json(out.data)["metadata"] as! [String: Any])["moviecut"] as! [String: Any]
        XCTAssertEqual((mc["droppedClips"] as! [String: Int])["text"], 1)
        XCTAssertTrue(out.report.summaryLines.joined().contains("トランジション"))
    }
}
