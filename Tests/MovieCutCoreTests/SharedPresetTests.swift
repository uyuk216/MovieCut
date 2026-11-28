import XCTest
@testable import MovieCutCore

/// プリセット共有ファイル(.mcpreset): 5 種のラウンドトリップ・互換検査・既存の適用経路。
final class SharedPresetTests: XCTestCase {
    private func roundTrip(_ c: SharedPresetContent) throws -> SharedPreset {
        let data = SharedPresetFormat.encode(SharedPreset(name: "テスト", author: "me", description: "d", content: c), appVersion: "1.0")
        return try SharedPresetFormat.decode(data)
    }
    private var tmp: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sp-\(UUID().uuidString)")
    }

    // MARK: ラウンドトリップ

    func testExportPresetRoundTrip() throws {
        let p = CustomExportPreset(name: "縦動画", width: 1080, height: 1920, codec: "hevc", fps: 30, bitrateMbps: 12)
        let r = try roundTrip(.exportPreset(p))
        XCTAssertEqual(r.content, .exportPreset(p))
        XCTAssertEqual(r.name, "テスト"); XCTAssertEqual(r.author, "me"); XCTAssertEqual(r.description, "d")
    }

    func testVoicePresetRoundTrip() throws {
        let p = VoicePreset(id: "v1", name: "元気", note: "ひとこと", engine: "voicevox", speaker: 3, speed: 1.2, pitch: 0.05, intonation: 1.1, volume: 1)
        guard case .voicePreset(let q) = try roundTrip(.voicePreset(p)).content else { return XCTFail() }
        XCTAssertEqual(q, p)
    }

    func testItemTemplateRoundTripKeepsClipSettings() throws {
        var c = Clip(); c.type = .text; c.text = "見出し"; c.fontSize = 96; c.color = "#ff0000"
        let t = ItemTemplate(id: "x", name: "赤見出し", clip: c)
        guard case .itemTemplate(let q) = try roundTrip(.itemTemplate(t)).content else { return XCTFail() }
        XCTAssertEqual(q.name, "赤見出し"); XCTAssertEqual(q.clip, c)
        XCTAssertNotEqual(q.id, "x") // 読み込み側で付け替える
    }

    func testColorCorrectionRoundTrip() throws {
        var e = Effect(.colorWheels); e.params["liftAngle"] = 40; e.params["liftAmount"] = 0.5
        guard case .colorCorrection(let q) = try roundTrip(.colorCorrection(e)).content else { return XCTFail() }
        XCTAssertEqual(q, e)
        var c = Effect(.colorCurves); c.params = c.params.mapValues { $0 }
        guard case .colorCorrection(let q2) = try roundTrip(.colorCorrection(c)).content else { return XCTFail() }
        XCTAssertEqual(q2, c)
    }

    func testGradeNodesRoundTrip() throws {
        var n1 = GradeNode(.colorWheels); n1.opacity = 0.6
        let n2 = GradeNode(name: "暗め", enabled: false, opacity: 1, effects: [Effect(kind: "exposure", params: ["amount": -0.5])])
        guard case .gradeNodes(let q) = try roundTrip(.gradeNodes([n1, n2])).content else { return XCTFail() }
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.map(\.effects), [n1, n2].map(\.effects))
        XCTAssertEqual(q.map(\.opacity), [0.6, 1]); XCTAssertEqual(q.map(\.enabled), [true, false])
    }

    func testFileWriteAndRead() throws {
        let url = tmp.appendingPathExtension(SharedPresetFormat.fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = SharedPreset(name: "a", content: .exportPreset(CustomExportPreset(name: "a", width: 1280, height: 720, codec: "h264")))
        try SharedPresetFormat.write(p, to: url)
        XCTAssertEqual(try SharedPresetFormat.read(from: url).content, p.content)
    }

    // MARK: 互換検査

    private func expectFailure(_ json: String, _ f: SharedPresetFormat.Failure, line: UInt = #line) {
        XCTAssertThrowsError(try SharedPresetFormat.decode(Data(json.utf8)), line: line) {
            XCTAssertEqual($0 as? SharedPresetFormat.Failure, f, line: line)
            XCTAssertFalse(($0 as? LocalizedError)?.errorDescription?.isEmpty ?? true, line: line)
        }
    }

    func testRejectsBrokenAndIncompatible() {
        expectFailure("{not json", .broken)
        expectFailure("[1,2]", .broken)
        expectFailure(#"{"kind":"export-preset","name":"a","payload":{}}"#, .missingField("formatVersion"))
        expectFailure(#"{"formatVersion":1,"name":"a","payload":{}}"#, .missingField("kind"))
        expectFailure(#"{"formatVersion":1,"kind":"export-preset","payload":{}}"#, .missingField("name"))
        expectFailure(#"{"formatVersion":1,"kind":"export-preset","name":"a"}"#, .missingField("payload"))
        expectFailure(#"{"formatVersion":99,"kind":"export-preset","name":"a","payload":{}}"#, .newerFormat(99))
        expectFailure(#"{"formatVersion":1,"kind":"plugin","name":"a","payload":{}}"#, .unknownKind("plugin"))
        expectFailure(#"{"formatVersion":1,"compat":{"app":"Other"},"kind":"export-preset","name":"a","payload":{}}"#, .notThisApp("Other"))
        expectFailure(#"{"formatVersion":1,"compat":{"minFormatVersion":2},"kind":"export-preset","name":"a","payload":{}}"#, .newerFormat(2))
    }

    func testRejectsBadPayloadsWithReason() {
        let bad = [
            #"{"formatVersion":1,"kind":"export-preset","name":"a","payload":{"presets":[{"name":"a","width":13,"height":10,"codec":"h264"}]}}"#,
            #"{"formatVersion":1,"kind":"voice-preset","name":"a","payload":{"name":"a","engine":"nope"}}"#,
            #"{"formatVersion":1,"kind":"item-template","name":"a","payload":{"x":1}}"#,
            #"{"formatVersion":1,"kind":"color-correction","name":"a","payload":{"kind":"blur","params":{}}}"#,
            #"{"formatVersion":1,"kind":"grade-nodes","name":"a","payload":[{"effects":[{"kind":"blur","params":{}}]}]}"#,
            #"{"formatVersion":1,"kind":"grade-nodes","name":"a","payload":[]}"#,
        ]
        for j in bad {
            XCTAssertThrowsError(try SharedPresetFormat.decode(Data(j.utf8)), j) {
                guard case SharedPresetFormat.Failure.invalidPayload = $0 else { return XCTFail("\($0) \(j)") }
            }
        }
    }

    func testRejectsTooLarge() {
        let big = Data(repeating: 0x20, count: SharedPresetFormat.maxBytes + 1)
        XCTAssertThrowsError(try SharedPresetFormat.decode(big)) { XCTAssertEqual($0 as? SharedPresetFormat.Failure, .tooLarge) }
    }

    func testFilePathIsNotShared() throws {
        var e = Effect(.colorCurves); e.path = "/Users/x/secret.cube"
        let s = String(decoding: SharedPresetFormat.encode(SharedPreset(name: "a", content: .colorCorrection(e))), as: UTF8.self)
        XCTAssertFalse(s.contains("secret.cube"))
        let json = #"{"formatVersion":1,"kind":"color-correction","name":"a","payload":{"kind":"colorCurves","path":"/etc/passwd","params":{}}}"#
        guard case .colorCorrection(let q) = try SharedPresetFormat.decode(Data(json.utf8)).content else { return XCTFail() }
        XCTAssertNil(q.path)
    }

    // MARK: 読み込み後に既存の適用経路で使える

    func testImportedExportPresetAppearsInExistingStoreAndSpec() throws {
        let url = tmp.appendingPathExtension("json"); defer { try? FileManager.default.removeItem(at: url) }
        let p = CustomExportPreset(name: "共有", width: 1920, height: 1080, codec: "h264", fps: 60)
        guard case .exportPreset(let q) = try roundTrip(.exportPreset(p)).content else { return XCTFail() }
        XCTAssertTrue(SharedPresetLibrary.add(q, toExportPresetsAt: url))
        let list = CustomExportPresetStore.load(from: url)
        XCTAssertEqual(list.map(\.name), ["共有"]); XCTAssertEqual(list[0].spec.width, 1920)
    }

    func testImportedVoicePresetAppliesToCharacter() throws {
        let p = VoicePreset(id: "v", name: "元気", engine: "voicevox", speaker: 8, speed: 1.3)
        guard case .voicePreset(let q) = try roundTrip(.voicePreset(p)).content else { return XCTFail() }
        let c = VoicePresetCatalog.applying(q, to: Character())
        XCTAssertEqual(c.speaker, 8); XCTAssertEqual(c.speed, q.speed)
    }

    func testImportedItemTemplateAppearsInStoreAndApplies() throws {
        let dir = tmp; defer { try? FileManager.default.removeItem(at: dir) }
        var src = Clip(); src.type = .text; src.text = "元"; src.fontSize = 77; src.color = "#00ff00"
        guard case .itemTemplate(let t) = try roundTrip(.itemTemplate(ItemTemplate(id: "i", name: "緑", clip: src))).content else { return XCTFail() }
        let store = ItemTemplateStore(directory: dir)
        XCTAssertTrue(SharedPresetLibrary.add(t, to: store))
        let loaded = try XCTUnwrap(store.load().first)
        var target = Clip(); target.type = .text; target.text = "先"
        XCTAssertTrue(loaded.apply(to: &target))
        XCTAssertEqual(target.fontSize, 77); XCTAssertEqual(target.text, "先")
    }

    func testImportedColorCorrectionAndNodesApplyToClip() throws {
        var e = Effect(.colorWheels); e.params["gainAmount"] = 0.7
        guard case .colorCorrection(let q) = try roundTrip(.colorCorrection(e)).content else { return XCTFail() }
        var clip = Clip(); clip.type = .image
        XCTAssertTrue(SharedPresetFormat.apply(colorCorrection: q, to: &clip))
        XCTAssertEqual(clip.effects.last, e)

        guard case .gradeNodes(let nodes) = try roundTrip(.gradeNodes([GradeNode(.colorCurves)])).content else { return XCTFail() }
        XCTAssertTrue(SharedPresetFormat.apply(gradeNodes: nodes, to: &clip))
        XCTAssertTrue(clip.hasActiveGradeNodes || clip.gradeNodes?.count == 1)
        XCTAssertEqual(clip.gradeNodes?.count, 1)
    }
}
