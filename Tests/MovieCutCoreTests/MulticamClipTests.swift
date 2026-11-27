import XCTest
import AVFoundation
import CoreGraphics
@testable import MovieCutCore

/// マルチカムクリップ(タイムライン上の 1 クリップ): モデルの保存・復元、同期のずれが描画フレームに効くこと、アングル切り替え、音声アングル、旧形式の互換。
final class MulticamClipTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mc-mcclip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: 合成素材(コマ番号 i を灰色の濃さに焼く: カメラ1 = 2i、カメラ2 = 255 − 2i。輝度だけなので圧縮の色ずれに強い)。30fps・4 秒(120 コマ)

    private func writeVideo(_ name: String, channel: Int) async throws -> String {
        let url = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<120 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            let v = UInt8(channel == 0 ? i * 2 : 255 - i * 2)
            for y in 0..<64 { for x in 0..<64 {
                let o = y * bpr + x * 4
                base[o] = v; base[o + 1] = v; base[o + 2] = v; base[o + 3] = 255   // BGRA
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url.path
    }

    private func video(_ id: String, _ src: String, start: Double = 0, dur: Double = 3, offset: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = src; c.start = start; c.duration = dur; c.offset = offset; c.srcDuration = 4
        return c
    }

    /// 2 カメラ: カメラ1(基準)に対し、カメラ2は同じ瞬間が `sync` 秒後ろに写っている。マルチカムクリップにして置いたプロジェクトと、そのクリップ id。
    private func fixture(sync: Double) async throws -> (Project, String) {
        let a = try await writeVideo("a.mp4", channel: 0), b = try await writeVideo("b.mp4", channel: 1)
        var p = Project.new()
        p.width = 64; p.height = 64; p.bg = "#000000"
        p.tracks = [Track(name: "L1"), Track(name: "L2")]
        p.tracks[0].clips = [video("cam1", a)]
        p.tracks[1].clips = [video("cam2", b)]
        guard case .placed(let q, let id) = Multicam.placeClip(in: p, ids: ["cam1", "cam2"], localLags: ["cam2": sync]) else { XCTFail("置けない"); return (p, "") }
        return (q, id)
    }

    private func gray(_ img: CGImage) -> Int {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = (img.height / 2 * img.width + img.width / 2) * 4
        return Int(d[i])
    }

    /// 時刻 t の描画。`export` が true なら書き出しと同じ順次読みのモード。
    private func frame(_ p: Project, _ t: Double, export: Bool) throws -> Int {
        let assets = RenderAssets()
        if export { assets.beginExportMode() }
        defer { if export { assets.endExportMode() } }
        return gray(try XCTUnwrap(Renderer(project: p, assets: assets).renderImage(t: t)))
    }

    private func cam1(_ sec: Double) -> Double { 2 * sec * 30 }
    private func cam2(_ sec: Double) -> Double { 255 - 2 * sec * 30 }

    // MARK: 作る・保存と復元

    func testPlaceClipReplacesOriginalsWithOneClip() async throws {
        let (p, id) = try await fixture(sync: 0.5)
        XCTAssertEqual(p.allClips.count, 1, "基準以外の元クリップは外れて、1 つのクリップだけが残る")
        let c = try XCTUnwrap(p.allClips.first { $0.id == id })
        XCTAssertEqual(c.type, .video)
        let info = try XCTUnwrap(c.multicam)
        XCTAssertEqual(info.angles.count, 2); XCTAssertEqual(info.activeAngle, 0); XCTAssertEqual(info.audioAngle, 0)
        XCTAssertEqual(info.angles[1].syncOffset, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.start, 0); XCTAssertEqual(c.duration, 3)
    }

    func testModelRoundTripKeepsAnglesOffsetsActiveAndAudio() async throws {
        var (p, id) = try await fixture(sync: 0.37)
        let loc = try XCTUnwrap(ClipEditing.locate(id, in: p))
        p.tracks[loc.track].clips[loc.index].multicam?.activeAngle = 1
        p.tracks[loc.track].clips[loc.index].multicam?.audioAngle = 1
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back, p)
        let info = try XCTUnwrap(back.allClips.first?.multicam)
        XCTAssertEqual(info.activeAngle, 1); XCTAssertEqual(info.audioAngle, 1)
        XCTAssertEqual(info.angles.map(\.name), ["カメラ1", "カメラ2"])
        XCTAssertEqual(info.angles[1].syncOffset, 0.37, accuracy: 1e-9)
        XCTAssertTrue(info.angles[0].clip.src?.hasSuffix("a.mp4") == true)
        XCTAssertEqual(try JSONEncoder().encode(back).count, data.count, "2 度目の書き出しでも同じ")
    }

    func testLegacyProjectWithoutMulticamClipsLoadsAndWritesNoKey() throws {
        var p = Project.new()
        p.tracks[0].clips = [video("a", "/x/a.mov"), video("b", "/x/b.mov")]
        // 従来のグループ方式だけのプロジェクト
        guard case .created(let q, _) = Multicam.makeGroup(in: p, ids: ["a", "b"], localLags: ["b": 0.2]) else { return XCTFail() }
        let data = try JSONEncoder().encode(q)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"multicam\":"), "マルチカムクリップが無ければ clip に multicam を書かない")
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back, q)
        XCTAssertEqual(back.multicams.count, 1)
        XCTAssertTrue(back.allClips.allSatisfy { $0.multicam == nil })
    }

    func testUnreadableMulticamIsPreservedInExtra() throws {
        let json = #"{"id":"c","type":"video","start":0,"duration":2,"src":"/x/a.mov","multicam":{"angles":"???","activeAngle":0}}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertNil(c.multicam)
        XCTAssertNotNil(c.extra["multicam"])
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("\"multicam\""), "読めない形は捨てずに書き戻す")
        let bad = #"{"id":"c","type":"video","start":0,"duration":2,"multicam":{"angles":[],"activeAngle":3}}"#
        let c2 = try JSONDecoder().decode(Clip.self, from: Data(bad.utf8))
        XCTAssertNil(c2.multicam)
        XCTAssertNotNil(c2.extra["multicam"])
    }

    // MARK: 描画(同期のずれが素材のコマ選びに効く)

    func testSyncOffsetSelectsTheShiftedSourceFrame() async throws {
        for sync in [0.5, 1.0] {
            var (p, id) = try await fixture(sync: sync)
            let t = 1.0
            for export in [false, true] {
                XCTAssertEqual(Double(try frame(p, t, export: export)), cam1(t), accuracy: 10, "カメラ1(基準) export=\(export)")
            }
            guard case .cut(let q) = Multicam.setActiveAngle(in: p, clipId: id, angle: 1) else { return XCTFail() }
            p = q
            for export in [false, true] {
                // カメラ2の素材の時刻は t + sync
                XCTAssertEqual(Double(try frame(p, t, export: export)), cam2(t + sync), accuracy: 10, "sync \(sync) export=\(export)")
            }
        }
    }

    func testSwitchChangesRenderedAngleAndExportPathAgrees() async throws {
        let (p, id) = try await fixture(sync: 0.5)
        guard case .cut(let q) = Multicam.setActiveAngle(in: p, clipId: id, angle: 1) else { return XCTFail() }
        XCTAssertNotEqual(q.allClips.first?.src, p.allClips.first?.src)
        for export in [false, true] {
            let before = try frame(p, 1.5, export: export), after = try frame(q, 1.5, export: export)
            XCTAssertEqual(Double(before), cam1(1.5), accuracy: 10, "export=\(export)")
            XCTAssertEqual(Double(after), cam2(2.0), accuracy: 10, "export=\(export)")
            XCTAssertGreaterThan(abs(before - after), 30)
        }
        guard case .cut(let back) = Multicam.setActiveAngle(in: q, clipId: id, angle: 0) else { return XCTFail() }
        XCTAssertEqual(back, p, "元に戻すと offset も元通り")
    }

    func testSwitchAtPlayheadSplitsAndOnlyTheRightSideChanges() async throws {
        let (p, id) = try await fixture(sync: 0.5)
        guard case .cut(let q) = Multicam.setActiveAngle(in: p, clipId: id, angle: 1, at: 1.5) else { return XCTFail() }
        let clips = q.tracks.flatMap(\.clips).sorted { $0.start < $1.start }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(clips[0].multicam?.activeAngle, 0); XCTAssertEqual(clips[1].multicam?.activeAngle, 1)
        XCTAssertEqual(clips[1].start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(clips[1].offset, 2.0, accuracy: 1e-9, "基準の素材時刻 1.5 + ずれ 0.5")
        for export in [false, true] {
            XCTAssertEqual(Double(try frame(q, 1.0, export: export)), cam1(1.0), accuracy: 10)
            XCTAssertEqual(Double(try frame(q, 2.0, export: export)), cam2(2.5), accuracy: 10)
        }
        guard case .cut(let r) = Multicam.setActiveAngle(in: q, clipId: clips[1].id, angle: 0) else { return XCTFail() }
        XCTAssertEqual(r.tracks.flatMap(\.clips).first { $0.id == clips[1].id }?.offset ?? -1, 1.5, accuracy: 1e-9)
    }

    func testSwitchRefusalsAndUnchanged() async throws {
        var (p, id) = try await fixture(sync: 0.5)
        XCTAssertEqual(Multicam.setActiveAngle(in: p, clipId: id, angle: 0), .unchanged)
        XCTAssertEqual(Multicam.setActiveAngle(in: p, clipId: id, angle: 5), .invalid)
        XCTAssertEqual(Multicam.setActiveAngle(in: p, clipId: "nope", angle: 1), .invalid)
        let loc = try XCTUnwrap(ClipEditing.locate(id, in: p))
        p.tracks[loc.track].clips[loc.index].offset = 0.6   // 0.6 + 3 + 0.5 > 4 秒
        XCTAssertEqual(Multicam.setActiveAngle(in: p, clipId: id, angle: 1), .noFootage)
        p.tracks[loc.track].clips[loc.index].locked = true
        XCTAssertEqual(Multicam.setActiveAngle(in: p, clipId: id, angle: 1), .locked)
    }

    // MARK: 音声

    func testAudioAngleDefaultsToReferenceAndCanDifferFromVideo() async throws {
        var (p, id) = try await fixture(sync: 0.5)
        guard case .cut(let q) = Multicam.setActiveAngle(in: p, clipId: id, angle: 1) else { return XCTFail() }
        p = q
        var aud = try XCTUnwrap(CompoundEditing.audibleClips(in: p).first)
        XCTAssertTrue(aud.src?.hasSuffix("a.mp4") == true, "既定の音は基準カメラ")
        XCTAssertEqual(aud.offset, 0, accuracy: 1e-9)
        XCTAssertTrue(p.allClips.first?.src?.hasSuffix("b.mp4") == true, "映像は有効アングルのまま")
        let p2 = try XCTUnwrap(Multicam.setAudioAngle(in: p, ids: [id], angle: 1))
        aud = try XCTUnwrap(CompoundEditing.audibleClips(in: p2).first)
        XCTAssertTrue(aud.src?.hasSuffix("b.mp4") == true)
        XCTAssertEqual(aud.offset, 0.5, accuracy: 1e-9)
        XCTAssertNil(Multicam.setAudioAngle(in: p2, ids: [id], angle: 1), "変わらなければ nil")
        XCTAssertNil(Multicam.setAudioAngle(in: p2, ids: [id], angle: 9))
        XCTAssertEqual(p2.allClips.first?.src, p.allClips.first?.src)
        XCTAssertEqual(p2.allClips.first?.offset, p.allClips.first?.offset)
    }

    func testAudioAngleSurvivesSplitAndKeepsSourceContinuity() async throws {
        var (p, id) = try await fixture(sync: 0.5)
        p = try XCTUnwrap(Multicam.setAudioAngle(in: p, ids: [id], angle: 1))
        let (q, rid) = try XCTUnwrap(ClipEditing.split(in: p, clipId: id, at: 1.0))
        let right = try XCTUnwrap(q.allClips.first { $0.id == rid })
        XCTAssertEqual(right.multicam?.audioAngle, 1)
        let aud = try XCTUnwrap(CompoundEditing.audibleClips(in: q).first { $0.id == rid })
        XCTAssertEqual(aud.offset, 1.0 + 0.5, accuracy: 1e-9)
    }

    func testCandidatesExcludeExistingMulticamClips() async throws {
        let (p, id) = try await fixture(sync: 0)
        XCTAssertFalse(Multicam.isAngleCandidate(try XCTUnwrap(p.allClips.first { $0.id == id })))
    }

    func testClipAtFindsTopMostMulticamClip() async throws {
        let (p, id) = try await fixture(sync: 0)
        XCTAssertEqual(Multicam.clip(at: 1, in: p)?.id, id)
        XCTAssertNil(Multicam.clip(at: 3.5, in: p))
    }

    func testRelinkAlsoFixesInactiveAngleSources() async throws {
        var (p, id) = try await fixture(sync: 0.5)
        let loc = try XCTUnwrap(ClipEditing.locate(id, in: p))
        p.tracks[loc.track].clips[loc.index].multicam?.angles[1].clip.src = "/gone/b.mp4"
        let b = dir.appendingPathComponent("b.mp4").path
        let r = MissingMedia.relink(p, candidates: ["b.mp4": [.init(path: b)]], exists: { $0 == b || $0.hasPrefix(self.dir.path) })
        XCTAssertEqual(r.project.allClips.first?.multicam?.angles[1].clip.src, b)
    }
}
