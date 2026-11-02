import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 機能追加後の掃除(2026-11-02): メニューの項目を、いろいろな種類のクリップを含む試験プロジェクトで 1 つずつ実行する。
/// - 落ちないこと
/// - 1 回の Undo で、書類の JSON がバイト一致で元に戻ること
/// - Redo で、実行直後と同じ JSON に戻ること
/// - 書き出し中(ロック中)に有効に見える項目は、書類を変えないこと
/// 書類を開く・保存パネル・非同期の音声生成・ファイルへの書き込みを伴う項目は対象から外す(それぞれ専用の試験がある)。
@MainActor
final class MenuUndoSweepTests: XCTestCase {
    static func clip(_ id: String, _ type: ClipType, start: Double, dur: Double, src: String? = nil) -> Clip {
        var c = Clip()
        c.id = id; c.type = type; c.start = start; c.duration = dur
        if let src { c.src = src; c.srcDuration = 60 }
        return c
    }

    /// 映像・画像・文字(カウントダウン)・図形・調整・ビジュアライザ・複合・ボイス・音声・ロックされたレイヤーを 1 つずつ持つ。
    static func richProject() -> Project {
        var p = Project.new()
        var video = clip("video", .video, start: 0, dur: 4, src: "/nonexistent/sweep-a.mov")
        video.effects = [Effect(.sepia), Effect(.colorWheels)]
        var image = clip("image", .image, start: 4, dur: 2, src: "/nonexistent/sweep-b.png")
        image.mask = ClipMask(shape: "ellipse", x: 0.1, y: 0.1, w: 0.8, h: 0.8, feather: 0.1)
        var text = clip("text", .text, start: 6, dur: 2)
        text.text = "テスト"
        text.counter = TextCounter(from: 5, to: 0)
        var shape = ClipEditing.makeShapeClip(.star, at: 8, project: p)
        shape.id = "shape"
        let adj = clip("adjust", .adjustment, start: 11, dur: 2)
        var vis = clip("visual", .visualizer, start: 13, dur: 3, src: "/nonexistent/sweep-c.wav")
        vis.visualizer = Visualizer(style: nil, color: "#ff0000", count: 16)
        var comp = clip("compound", .compound, start: 16, dur: 4)
        var kt = Track(name: "中")
        kt.clips = [clip("kid", .audio, start: 0, dur: 4, src: "/nonexistent/sweep-d.wav")]
        comp.tracks = [kt]
        var voice = clip("voice", .voice, start: 0, dur: 1.5, src: "/nonexistent/sweep-e.wav")
        voice.charId = p.characters[0].id
        voice.text = "こんにちは"
        let audio = clip("audio", .audio, start: 1.5, dur: 4, src: "/nonexistent/sweep-f.wav")
        let locked = clip("locked", .image, start: 0, dur: 2, src: "/nonexistent/sweep-g.png")
        var t0 = Track(name: "映像"); t0.clips = [video, image, text, shape, adj, vis, comp]
        var t1 = Track(name: "音声"); t1.clips = [voice, audio]
        var t2 = Track(name: "ロック"); t2.clips = [locked]; t2.locked = true
        p.tracks = [t0, t1, t2]
        p.markers = [Marker(time: 2.0, name: "印")]
        return p
    }

    static func makeModel(selection: String?, time: Double, project: Project? = nil) -> ProjectModel {
        let m = ProjectModel(project: project ?? richProject())
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        m.notices = OneTimeNotices()
        m.clipPasteboard = NSPasteboard(name: NSPasteboard.Name("moviecut.sweep.\(UUID().uuidString)"))
        m.selectedClipId = selection
        m.currentTime = time
        return m
    }

    /// 対象外の項目(開く・保存する・外部に出る・非同期・全体の設定)。
    static func isExcluded(_ c: MenuCommand) -> Bool {
        switch c {
        case .about, .settings, .videoSettings, .addMedia, .export, .exportPreset, .exportCustomPreset, .saveCustomPreset,
             .fanMaxToggle, .fanInstall, .fanUninstall, .importSubtitles, .exportSubtitles, .translateSubtitles,
             .transcribeSubtitles, .relinkMedia, .toggleRangeLoop, .aiScript, .aiChapters, .aiTitles, .aiRewrite, .aiSettings,
             .exportStill, .exportSequence, .exportThumbnail, .exportGIF, .queueExport, .showExportQueue, .audioLibrary,
             .measureLoudness, .showScopes, .saveTemplate, .newFromTemplate, .makeProxies, .lutLoad, .autoWhiteBalance, .regenerateVoice,
             .makeVoices, .layerDelete, .copyChapters, .copyChaptersColor(.red), .jumpToTime, .renameMarker, .fpsCustom, .addQRCode, .aiImage, .generateSubtitles,
             .helpShortcuts, .helpVoicevox, .helpAquestalk, .helpLicense, .helpThirdParty, .previewBackground, .guide,
             .dockPanel, .dockLayout, .previewProxyToggle, .fullScreen:
            return true
        default:
            return false
        }
    }

    private func label(_ item: MenuItemSpec, selection: String?, time: Double) -> String {
        "[\(selection ?? "選択なし") @\(time)] \(item.title)"
    }

    func testEveryMenuCommandUndoesToIdenticalJSONAndRedoes() throws {
        try assertSweep(project: nil, minRan: 100, minEdited: 30)
    }

    /// 空のプロジェクト(レイヤーもクリップも無い)と、長さ 0 のクリップ・空のレイヤーがあるプロジェクト。
    func testEveryMenuCommandOnEmptyAndZeroLengthProjects() throws {
        try assertSweep(project: Project(), minRan: 5, minEdited: 0)
        var zero = Project()
        var t = Track(name: "映像")
        t.clips = [Self.clip("zero", .image, start: 2, dur: 0, src: "/nonexistent/zero.png")]
        zero.tracks = [t, Track(name: "空")]
        try assertSweep(project: zero, minRan: 5, minEdited: 0)
    }

    private func assertSweep(project: Project?, minRan: Int, minEdited: Int) throws {
        let selections: [String?] = [nil] + (project ?? Self.richProject()).allClips.map(\.id)
        var failures: [String] = []
        var ran = 0, edited = 0
        for sel in selections {
            for time in [0.0, 4.5] {
                let items0 = AppMenuSpec.all(MenuState(model: Self.makeModel(selection: sel, time: time, project: project)))
                for item in items0 where item.enabled && !Self.isExcluded(item.command) {
                    let m = Self.makeModel(selection: sel, time: time, project: project)
                    let um = m.effectiveUndoManager
                    let fresh = AppMenuSpec.all(MenuState(model: m)).first { $0.command == item.command }
                    guard fresh?.enabled == true else { continue }
                    let before = try m.project.encoded()
                    let oldIds = Set(m.project.allClips.map(\.id))   // 手動の移動・微動は重なりを許す。新しく増えたクリップだけ、重ねない
                    ran += 1
                    AppMenu.perform(item.command, model: m)
                    let fresh2 = Set(m.project.allClips.map(\.id)).subtracting(oldIds)
                    let bad = layerOverlaps(m.project).filter { l in fresh2.contains { l.contains($0) } }
                    if !bad.isEmpty { failures.append("新しいクリップがレイヤー内で重なった: \(label(item, selection: sel, time: time)) \(bad.prefix(2))") }
                    let after = try m.project.encoded()
                    guard after != before else { continue }
                    edited += 1
                    let name = label(item, selection: sel, time: time)
                    guard um.canUndo else { failures.append("元に戻せない: \(name)"); continue }
                    um.undo()
                    if try m.project.encoded() != before { failures.append("Undo で元の JSON に戻らない: \(name)") }
                    guard um.canRedo else { failures.append("やり直せない: \(name)"); continue }
                    um.redo()
                    if try m.project.encoded() != after { failures.append("Redo で実行後の JSON に戻らない: \(name)") }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(ran, minRan, "試した項目が少なすぎる")
        XCTAssertGreaterThanOrEqual(edited, minEdited, "書類を変えた項目が少なすぎる")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) 件の失敗(\(ran) 回中・書類を変えた \(edited) 回):\n" + failures.joined(separator: "\n"))
    }

    /// 書き出し中・ロック中は、有効に見える項目でも書類を変えてはいけない。
    func testEnabledItemsWhileBusyNeverEditTheProject() throws {
        for sel in [nil] + Self.richProject().allClips.map(\.id) {
            let m = Self.makeModel(selection: sel, time: 4.5)
            m.isExporting = true
            let items = AppMenuSpec.all(MenuState(model: m))
            for item in items where item.enabled && !Self.isExcluded(item.command) {
                let before = try m.project.encoded()
                AppMenu.perform(item.command, model: m)
                XCTAssertEqual(try m.project.encoded(), before, "書き出し中に書類を変えた: \(label(item, selection: sel, time: 4.5))")
            }
        }
    }

    // MARK: 複製・コピー/貼り付けで、新しい種類のクリップの項目が落ちないこと

    /// id と開始時刻を除いた JSON(複製・貼り付けでは id と位置だけが変わるはず)。
    private func fieldsOnly(_ c: Clip) throws -> Data {
        func strip(_ v: Any) -> Any {
            if var d = v as? [String: Any] {
                d.removeValue(forKey: "id")
                for (k, x) in d { d[k] = strip(x) }
                return d
            }
            if let a = v as? [Any] { return a.map(strip) }
            return v
        }
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any] ?? [:]
        obj.removeValue(forKey: "start")
        return try JSONSerialization.data(withJSONObject: strip(obj), options: [.sortedKeys])
    }

    func testDuplicateAndPasteKeepEveryFieldOfNewClipKinds() throws {
        for id in ["shape", "visual", "adjust", "compound", "text", "image", "video"] {
            let m = Self.makeModel(selection: id, time: 0)
            let original = try XCTUnwrap(m.project.allClips.first { $0.id == id })

            XCTAssertTrue(m.duplicateSelected(), "複製できない: \(id)")
            let dup = try XCTUnwrap(m.project.allClips.first { $0.id == m.selectedClipId })
            XCTAssertNotEqual(dup.id, original.id)
            XCTAssertEqual(try fieldsOnly(dup), try fieldsOnly(original), "複製で項目が変わった: \(id)")

            m.selectedClipId = id
            XCTAssertTrue(m.copySelection(), "コピーできない: \(id)")
            m.currentTime = 30
            XCTAssertTrue(m.pasteClips(), "貼り付けできない: \(id)")
            let pasted = try XCTUnwrap(m.project.allClips.first { $0.id == m.selectedClipId })
            XCTAssertNotEqual(pasted.id, original.id)
            XCTAssertEqual(pasted.start, 30, accuracy: 1e-9, "貼り付けの位置: \(id)")
            XCTAssertEqual(try fieldsOnly(pasted), try fieldsOnly(original), "貼り付けで項目が変わった: \(id)")
            // 複合の中の子の id は元と重ならない
            let ids = m.project.allClips.flatMap { c in [c.id] + (c.tracks ?? []).flatMap { $0.clips.map(\.id) } }
            XCTAssertEqual(ids.count, Set(ids).count, "id が重複: \(id)")
        }
    }
}
