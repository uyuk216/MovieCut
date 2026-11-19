import XCTest
import CoreGraphics
@testable import MovieCutCore

final class ProxyWorkflowTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func clip(_ id: String, _ type: ClipType, src: String? = nil) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = src; c.start = 0; c.duration = 1
        return c
    }
    private func compound(_ id: String, _ kids: [Clip]) -> Clip {
        var c = clip(id, .compound)
        var t = Track(name: "inner"); t.clips = kids
        c.tracks = [t]
        return c
    }
    private func project(_ clips: [Clip]) -> Project {
        var p = Project()
        p.tracks = [Track(name: "main")]
        p.tracks[0].clips = clips
        return p
    }

    // MARK: 収集

    func testCollectTopLevelCompoundNestedAndSceneExcludingAudioImage() {
        var p = project([
            clip("v1", .video, src: "/m/top.mp4"),
            clip("a1", .audio, src: "/m/sound.wav"),
            clip("i1", .image, src: "/m/pic.png"),
            compound("c1", [clip("v2", .video, src: "/m/comp.mp4"),
                            compound("c2", [clip("v3", .video, src: "/m/nested.mp4")])]),
            clip("s1", .scene),
        ])
        var scene = SceneDefinition(); scene.name = "S"
        var t = Track(name: "t"); t.clips = [clip("v4", .video, src: "/m/scene.mp4")]
        scene.tracks = [t]
        p.scenes = [scene]
        p.tracks[0].clips[4].sceneId = scene.id

        let got = Dictionary(uniqueKeysWithValues: ProxySources.collect(in: p).map { ($0.path, $0.contexts) })
        XCTAssertEqual(Set(got.keys), ["/m/top.mp4", "/m/comp.mp4", "/m/nested.mp4", "/m/scene.mp4"])
        XCTAssertEqual(got["/m/top.mp4"], [.topLevel])
        XCTAssertEqual(got["/m/comp.mp4"], [.compound])
        XCTAssertEqual(got["/m/nested.mp4"], [.compound])
        XCTAssertEqual(got["/m/scene.mp4"], [.scene])
        XCTAssertEqual(ProxySources.videoPaths(in: p), ProxySources.videoPaths(in: p).sorted(), "パス昇順")
    }

    func testCollectUnionsContextsForSamePath() {
        let p = project([clip("v1", .video, src: "/m/same.mp4"), compound("c1", [clip("v2", .video, src: "/m/same.mp4")])])
        let r = ProxySources.collect(in: p)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].contexts, [.topLevel, .compound])
    }

    func testCollectTerminatesOnCyclicCompoundAndScene() {
        // 同じ id の複合の入れ子
        let inner = compound("same", [clip("v", .video, src: "/m/x.mp4")])
        let outer = compound("same", [inner])
        XCTAssertEqual(ProxySources.videoPaths(in: project([outer])), [])  // 同じ id の入れ子は辿らない(終わることが目的)
        // 深すぎる入れ子でも終わる
        var deep = clip("d0", .video, src: "/m/deep.mp4")
        for i in 1...(CompoundEditing.maxDepth + 3) { deep = compound("d\(i)", [deep]) }
        XCTAssertEqual(ProxySources.videoPaths(in: project([deep])), [])
        // シーンが自分自身を参照
        var p = project([clip("s", .scene)])
        var sc = SceneDefinition(); sc.id = "S1"
        var t = Track(name: "t"); var self_ = clip("s2", .scene); self_.sceneId = "S1"
        t.clips = [self_, clip("v", .video, src: "/m/in-scene.mp4")]
        sc.tracks = [t]
        p.scenes = [sc]
        p.tracks[0].clips[0].sceneId = "S1"
        XCTAssertEqual(ProxySources.videoPaths(in: p), ["/m/in-scene.mp4"])
    }

    // MARK: 判定

    func testAutoCreateDecideAllBranches() {
        typealias D = ProxyAutoCreate
        XCTAssertEqual(D.decide(enabled: false, isVideo: true, hasExistingProxy: false, displayedShortSide: 1080), .skip(.disabled))
        XCTAssertEqual(D.decide(enabled: false, isVideo: false, hasExistingProxy: true, displayedShortSide: 100), .skip(.disabled), "無効が最優先")
        XCTAssertEqual(D.decide(enabled: true, isVideo: false, hasExistingProxy: true, displayedShortSide: 1080), .skip(.notVideo))
        XCTAssertEqual(D.decide(enabled: true, isVideo: true, hasExistingProxy: true, displayedShortSide: 100), .skip(.alreadyExists))
        XCTAssertEqual(D.decide(enabled: true, isVideo: true, hasExistingProxy: false, displayedShortSide: 540), .skip(.smallEnough))
        XCTAssertEqual(D.decide(enabled: true, isVideo: true, hasExistingProxy: false, displayedShortSide: 541), .create)
        XCTAssertEqual(D.decide(enabled: true, isVideo: true, hasExistingProxy: false, displayedShortSide: nil), .create)
    }

    // MARK: 関連付け

    func testAttachDetachAndInvalidInputs() throws {
        let p = project([clip("v1", .video, src: "/m/a.mp4"), compound("c", [clip("v2", .video, src: "/m/b.mp4")])])
        let q = try XCTUnwrap(ProxyLinks.attach(to: p, source: "/m/a.mp4", proxy: "/px/a.mp4"))
        XCTAssertEqual(q.proxyLinks, ["/m/a.mp4": "/px/a.mp4"])
        XCTAssertTrue(p.proxyLinks.isEmpty, "元は変わらない")
        XCTAssertEqual(ProxyLinks.linkedProxy(for: "/m/a.mp4", in: q), "/px/a.mp4")
        let inCompound = try XCTUnwrap(ProxyLinks.attach(to: q, source: "/m/b.mp4", proxy: "/px/b.mp4"))
        XCTAssertEqual(inCompound.proxyLinks.count, 2)
        let re = try XCTUnwrap(ProxyLinks.attach(to: q, source: "/m/a.mp4", proxy: "/px/a2.mp4"))
        XCTAssertEqual(re.proxyLinks["/m/a.mp4"], "/px/a2.mp4", "再関連付けは上書き")

        XCTAssertNil(ProxyLinks.attach(to: p, source: "/m/unknown.mp4", proxy: "/px/x.mp4"))
        XCTAssertNil(ProxyLinks.attach(to: p, source: "/m/a.mp4", proxy: "/m/a.mp4"))
        XCTAssertNil(ProxyLinks.attach(to: p, source: "/m/a.mp4", proxy: ""))

        let d = ProxyLinks.detach(from: q, source: "/m/a.mp4")
        XCTAssertTrue(d.proxyLinks.isEmpty)
        XCTAssertEqual(ProxyLinks.detach(from: p, source: "/m/a.mp4"), p, "無ければ同じ値")
    }

    func testResolveAndStatusPriority() throws {
        let src = dir.appendingPathComponent("src.mp4")
        try Data("src".utf8).write(to: src)
        let external = dir.appendingPathComponent("external.mp4")
        try Data("ext".utf8).write(to: external)
        var p = project([clip("v", .video, src: src.path)])
        p.proxyLinks[src.path] = external.path
        let pxDir = dir.appendingPathComponent("px", isDirectory: true)
        try FileManager.default.createDirectory(at: pxDir, withIntermediateDirectories: true)

        // 外部のみ
        XCTAssertEqual(ProxyLinks.status(for: src.path, in: p, directory: pxDir), .external(external.path))
        XCTAssertEqual(ProxyLinks.resolve(for: src.path, in: p, directory: pxDir), external.path)

        // 生成済みも有る → 外部優先
        let gen = try XCTUnwrap(ProxyStore.proxyURL(for: src, directory: pxDir))
        try Data("gen".utf8).write(to: gen)
        XCTAssertEqual(ProxyLinks.resolve(for: src.path, in: p, directory: pxDir), external.path)

        // 外部ファイルが消える → 生成済みへフォールバック
        try FileManager.default.removeItem(at: external)
        XCTAssertEqual(ProxyLinks.status(for: src.path, in: p, directory: pxDir), .generated(gen.path))
        XCTAssertEqual(ProxyLinks.resolve(for: src.path, in: p, directory: pxDir), gen.path)

        // どちらも無い
        try FileManager.default.removeItem(at: gen)
        XCTAssertEqual(ProxyLinks.status(for: src.path, in: p, directory: pxDir), .none)
        XCTAssertNil(ProxyLinks.resolve(for: src.path, in: p, directory: pxDir))

        // fileExists 注入
        XCTAssertEqual(ProxyLinks.status(for: src.path, in: p, directory: pxDir, fileExists: { _ in true }), .external(external.path))
    }

    // MARK: 形式

    func testProxyLinksEncodedOnlyWhenNonEmptyAndRoundTrips() throws {
        let enc = JSONEncoder()
        let empty = try String(decoding: enc.encode(Project()), as: UTF8.self)
        XCTAssertFalse(empty.contains("proxyLinks"))

        var p = Project()
        p.proxyLinks = ["/m/a.mp4": "/px/a.mp4"]
        let data = try enc.encode(p)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("proxyLinks"))
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.proxyLinks, p.proxyLinks)
        XCTAssertNil(back.extra["proxyLinks"], "既知のキーとして読む(未知キー扱いにしない)")
    }

    // MARK: 削除・一覧

    func testDeleteListAndTotalBytes() throws {
        let pxDir = dir.appendingPathComponent("px", isDirectory: true)
        XCTAssertEqual(ProxyStore.listProxyFiles(in: pxDir), [], "フォルダが無ければ空")
        XCTAssertEqual(ProxyStore.totalBytes(in: pxDir), 0)
        try FileManager.default.createDirectory(at: pxDir, withIntermediateDirectories: true)

        let s1 = dir.appendingPathComponent("one.mov"), s2 = dir.appendingPathComponent("two.mov")
        try Data("1".utf8).write(to: s1); try Data("22".utf8).write(to: s2)
        let p1 = try XCTUnwrap(ProxyStore.proxyURL(for: s1, directory: pxDir))
        let p2 = try XCTUnwrap(ProxyStore.proxyURL(for: s2, directory: pxDir))
        try Data(count: 100).write(to: p1)
        try Data(count: 50).write(to: p2)
        let part = pxDir.appendingPathComponent("zzz.part.mp4"); try Data(count: 7).write(to: part)
        let other = pxDir.appendingPathComponent("note.txt"); try Data(count: 5).write(to: other)

        XCTAssertEqual(Set(ProxyStore.listProxyFiles(in: pxDir).map(\.lastPathComponent)), [p1.lastPathComponent, p2.lastPathComponent])
        XCTAssertEqual(ProxyStore.totalBytes(in: pxDir), 150)

        XCTAssertTrue(ProxyStore.deleteProxy(for: s1, directory: pxDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s1.path), "素材は消えない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertFalse(ProxyStore.deleteProxy(for: s1, directory: pxDir), "もう無い")

        let missing = dir.appendingPathComponent("missing.mov")
        XCTAssertEqual(ProxyStore.deleteProxies(for: [s1, s2, missing], directory: pxDir), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s2.path))
    }

    func testAutoCreateSettingDefaultsOffAndRoundTrips() {
        let d = UserDefaults(suiteName: "proxy-workflow-\(UUID().uuidString)")!
        XCTAssertFalse(ProxySettings.autoCreateEnabled(d))
        ProxySettings.setAutoCreate(true, d)
        XCTAssertTrue(ProxySettings.autoCreateEnabled(d))
        ProxySettings.setAutoCreate(false, d)
        XCTAssertFalse(ProxySettings.autoCreateEnabled(d))
    }

    func testDisplayedSizeReadsVideoAndNilForMissing() async throws {
        let v = dir.appendingPathComponent("v.mp4")
        try TestVideo.write(to: v, size: (320, 240), frames: 3, rgb: (1, 2, 3))
        let s = await ProxyStore.displayedSize(source: v)
        XCTAssertEqual(s, CGSize(width: 320, height: 240))
        let none = await ProxyStore.displayedSize(source: dir.appendingPathComponent("nope.mp4"))
        XCTAssertNil(none)
    }
}
