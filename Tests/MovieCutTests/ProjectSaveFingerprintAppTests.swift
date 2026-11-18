import XCTest
@testable import MovieCutCore
@testable import MovieCut

/// 保存データへのフィンガープリント付与(保存の写し・編集中の project は変えない)をアプリ側から確かめる。
@MainActor
final class ProjectSaveFingerprintAppTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-fp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dir = dir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    private func projectWithClip(src: String) -> Project {
        var c = Clip(); c.type = .image; c.src = src; c.duration = 1
        var t = Track(name: "映像"); t.clips = [c]
        var p = Project.new()
        p.tracks = [t]
        return p
    }

    private func makeModel(_ p: Project) -> ProjectModel {
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testSaveAttachesFingerprintsWithoutTouchingEditingProject() throws {
        // 保存先のフォルダ(相対パスの素材の基準)を決める
        let docDir = dir.appendingPathComponent("doc", isDirectory: true)
        let media = docDir.appendingPathComponent("media/a.png")
        try write([1, 2, 3], to: media)
        let m = makeModel(projectWithClip(src: "media/a.png"))
        m.fileURL = docDir.appendingPathComponent("doc.mcpjc")

        // 編集中のプロジェクト本体は書き換えない
        XCTAssertTrue(m.project.mediaFingerprints.isEmpty)

        let data = try ProjectModel.encodeForSave(m.mirror.get(), folder: m.mirror.projectFolder,
                                                  cache: m.fingerprintCache)
        let saved = try Project.decodeMigrating(from: data)
        XCTAssertEqual(saved.mediaFingerprints["media/a.png"], MediaFingerprint.compute(data: Data([1, 2, 3]), fileName: "a.png"))
        XCTAssertTrue(m.project.mediaFingerprints.isEmpty, "保存の写しに付けるだけで、編集中の project は変えない")
    }

    func testUntitledDocumentSavesOnlyAbsoluteExistingMedia() throws {
        let real = dir.appendingPathComponent("abs/a.png")
        try write([7], to: real)
        let m = makeModel(projectWithClip(src: "media/relative.png"))
        XCTAssertNil(m.fileURL)

        var p = m.mirror.get()
        var c = Clip(); c.type = .image; c.src = real.path; c.duration = 1
        p.tracks[0].clips.append(c)
        let data = try ProjectModel.encodeForSave(p, folder: m.mirror.projectFolder, cache: m.fingerprintCache)
        let saved = try Project.decodeMigrating(from: data)
        XCTAssertEqual(Set(saved.mediaFingerprints.keys), [real.path], "未保存では相対パスは解決できないので付けない")
    }
}
