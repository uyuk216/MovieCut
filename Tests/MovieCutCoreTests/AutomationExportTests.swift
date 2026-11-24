import XCTest
@testable import MovieCutCore

/// 外部自動化(X-4)の入力変換: 計画の組み立て・プリセット解決・範囲・出力先・要約・新規作成。
/// Shortcuts / AppleScript のどちらも、この変換を通る。
final class AutomationExportTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("automation-tests-\(UUID().uuidString)")

    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func saveProject(name: String = "テスト", marks: Bool = false) throws -> URL {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var t = Clip(); t.type = .text; t.text = "A"; t.start = 0; t.duration = 4; t.fontSize = 60; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        if marks { p.rangeIn = 1; p.rangeOut = 3 }
        let url = tmp.appendingPathComponent(name).appendingPathExtension(ProjectFileExtension.current)
        try p.save(to: url)
        return url
    }

    func testPlanDefaults() throws {
        let url = try saveProject()
        let plan = try AutomationExport.plan(.init(projectPath: url.path))
        XCTAssertNil(plan.preset)
        XCTAssertNil(plan.spec)
        XCTAssertNil(plan.range)
        XCTAssertEqual(plan.outputURL.deletingLastPathComponent().path, tmp.path)
        XCTAssertEqual(plan.outputURL.lastPathComponent, "テスト-書き出し.mp4")
        XCTAssertNotEqual(plan.outputURL, url)
    }

    /// プリセット無し・出力先省略のとき、既定の拡張子はプロジェクトのコーデックに従うこと
    /// (ProRes なのに .mp4 名で .mov の中身が書かれていた不具合の回帰)。
    func testPlanDefaultOutputExtensionFollowsProjectCodec() throws {
        var p = Project.new()
        p.codec = "prores422"
        let url = tmp.appendingPathComponent("prores").appendingPathExtension(ProjectFileExtension.current)
        try p.save(to: url)
        let plan = try AutomationExport.plan(.init(projectPath: url.path))
        XCTAssertEqual(plan.outputURL.pathExtension, "mov")
    }

    func testPlanPreset() throws {
        let url = try saveProject()
        let plan = try AutomationExport.plan(.init(projectPath: url.path, presetName: "youtube1080"))
        XCTAssertEqual(plan.preset, .youtube1080)
        XCTAssertEqual(plan.outputURL.lastPathComponent, "テスト-youtube1080.mp4")
        let audio = try AutomationExport.plan(.init(projectPath: url.path, presetName: "audio"))
        XCTAssertEqual(audio.outputURL.pathExtension, "m4a")
    }

    func testPlanUnknownPreset() throws {
        let url = try saveProject()
        XCTAssertThrowsError(try AutomationExport.plan(.init(projectPath: url.path, presetName: "存在しない"))) {
            XCTAssertEqual($0 as? AutomationError, .unknownPreset("存在しない"))
        }
    }

    func testPlanMissingProject() {
        XCTAssertThrowsError(try AutomationExport.plan(.init(projectPath: tmp.appendingPathComponent("無い.mcpjc").path))) {
            guard case .projectNotFound = $0 as? AutomationError ?? .emptyProjectPath else { return XCTFail() }
        }
        XCTAssertThrowsError(try AutomationExport.plan(.init(projectPath: "  "))) {
            XCTAssertEqual($0 as? AutomationError, .emptyProjectPath)
        }
    }

    func testPlanRangeText() throws {
        let url = try saveProject()
        let plan = try AutomationExport.plan(.init(projectPath: url.path, rangeText: "1:2.5"))
        XCTAssertEqual(plan.range?.start, 1)
        XCTAssertEqual(plan.range?.end, 2.5)
        XCTAssertThrowsError(try AutomationExport.plan(.init(projectPath: url.path, rangeText: "3:2"))) {
            guard case .badRange = $0 as? AutomationError ?? .emptyProjectPath else { return XCTFail() }
        }
    }

    func testPlanRangeProject() throws {
        let marked = try saveProject(name: "範囲あり", marks: true)
        let plan = try AutomationExport.plan(.init(projectPath: marked.path, rangeText: "project"))
        XCTAssertEqual(plan.range?.start, 1)
        XCTAssertEqual(plan.range?.end, 3)
        let plain = try saveProject(name: "範囲なし")
        XCTAssertThrowsError(try AutomationExport.plan(.init(projectPath: plain.path, rangeText: "project"))) {
            guard case .badRange = $0 as? AutomationError ?? .emptyProjectPath else { return XCTFail() }
        }
    }

    func testPlanOutputSameAsProjectRejected() throws {
        let url = try saveProject()
        XCTAssertThrowsError(try AutomationExport.plan(.init(projectPath: url.path, outputPath: url.path))) {
            XCTAssertEqual($0 as? AutomationError, .sameAsProject)
        }
        let explicit = try AutomationExport.plan(.init(projectPath: url.path, outputPath: tmp.appendingPathComponent("別名.mp4").path))
        XCTAssertEqual(explicit.outputURL.lastPathComponent, "別名.mp4")
    }

    func testProjectInfoSummary() throws {
        let url = try saveProject()
        let summary = try AutomationExport.projectInfoSummary(projectPath: url.path)
        XCTAssertTrue(summary.contains("320×180"))
        XCTAssertTrue(summary.contains("クリップ: 1"))
        XCTAssertThrowsError(try AutomationExport.projectInfoSummary(projectPath: "")) {
            XCTAssertEqual($0 as? AutomationError, .emptyProjectPath)
        }
    }

    func testCreateNewProject() throws {
        let url = try AutomationProjectFile.createNew(folder: tmp, name: "新規")
        XCTAssertEqual(url.pathExtension, ProjectFileExtension.current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let loaded = try Project.load(from: url)
        XCTAssertEqual(loaded.allClips.count, 0)
        XCTAssertThrowsError(try AutomationProjectFile.createNew(folder: tmp, name: "新規"))  // 同名は上書きしない
        let withExt = AutomationProjectFile.outputURL(folder: tmp, name: "x.\(ProjectFileExtension.current)")
        XCTAssertEqual(withExt.lastPathComponent, "x.\(ProjectFileExtension.current)")
    }

    /// 実際の書き出しまで通す(小さいプロジェクト。書き出し経路は ExportJob と同一)。
    func testRunExportsFile() async throws {
        let url = try saveProject(name: "書き出し元")
        let out = tmp.appendingPathComponent("自動化書き出し.mp4")
        let result = try await AutomationExport.run(.init(projectPath: url.path, outputPath: out.path, rangeText: "0:1"))
        XCTAssertEqual(result, out)
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 0)
    }

    func testOutputURLStaysInsideFolder() {
        for name in ["../evil", "a/b", "..", ".", "/", "..\\x", "   "] {
            let url = AutomationProjectFile.outputURL(folder: tmp, name: name)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, tmp.standardizedFileURL.path, name)
        }
        XCTAssertEqual(AutomationProjectFile.outputURL(folder: tmp, name: "..").lastPathComponent,
                       "名称未設定." + ProjectFileExtension.current)
        XCTAssertEqual(AutomationProjectFile.outputURL(folder: tmp, name: "私の動画").lastPathComponent,
                       "私の動画." + ProjectFileExtension.current)
    }
}
