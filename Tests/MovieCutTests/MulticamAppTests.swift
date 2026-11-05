import XCTest
import AVFoundation
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// マルチカメラ編集のアプリ側: 項目表・無効の理由・ショートカットなし、実際の音ファイルでのずれ検出(合成の音)、作成と切り替えが 1 回ずつの Undo、配置の確認。
@MainActor
final class MulticamAppTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("multicam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 長さの違う音の塊と無音の並び。`lead` 秒の無音を頭に足す(= その分だけ後ろにずれて録れたカメラ)。
    private func writeWav(_ name: String, lead: Double) throws -> String {
        let pattern: [(Double, Float)] = [(0.5, 0.3), (0.4, 0), (0.2, 0.5), (0.3, 0), (0.9, 0.2), (0.6, 0),
                                          (0.3, 0.4), (0.2, 0), (0.7, 0.1), (0.5, 0), (0.4, 0.5), (0.3, 0)]
        let segments = (lead > 0 ? [(lead, Float(0))] : []) + pattern
        let url = tmp.appendingPathComponent(name)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = segments.reduce(0) { $0 + Int($1.0 * 48000) }
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        var i = 0
        for (d, a) in segments { for _ in 0..<Int(d * 48000) { buf.floatChannelData![0][i] = a * Float(sin(2 * .pi * 300 * Double(i) / 48000)); i += 1 } }
        try file.write(from: buf)
        return url.path
    }

    private func cam(_ id: String, _ file: String, track: Int, start: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = file; c.start = start; c.duration = 5.3; c.srcDuration = 5.67 + 2
        return c
    }

    /// cam1(基準・遅れなし)/ cam2(0.37 秒遅れ)/ cam3(1.23 秒遅れ)。
    private func makeModel() throws -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [cam("cam1", try writeWav("c1.wav", lead: 0), track: 0)]
        p.tracks[1].clips = [cam("cam2", try writeWav("c2.wav", lead: 0.37), track: 1)]
        p.tracks[2].clips = [cam("cam3", try writeWav("c3.wav", lead: 1.23), track: 2)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func state(_ m: ProjectModel) -> MenuState { MenuState(model: m) }
    private func spec(_ m: ProjectModel, _ c: MenuCommand) -> MenuItemSpec { AppMenuSpec.all(state(m)).first { $0.command == c }! }

    // MARK: 項目表

    func testMenuItemsAreInTheTableWithoutShortcutsAndWithReasons() throws {
        let m = try makeModel(); defer { m.shutdown() }
        for c in [MenuCommand.multicamCreate, .multicamSwitch] + (0..<9).map({ MenuCommand.multicamCut($0) }) {
            XCTAssertNil(spec(m, c).shortcut, "\(c) は全体のショートカットを持たない")
            XCTAssertFalse(spec(m, c).enabled, "最初は無効")
            let r = AppMenuSpec.disabledReason(for: spec(m, c), state: state(m))
            XCTAssertNotNil(r); XCTAssertNotEqual(r, "今の状態では使えません", "\(c)")
        }
        XCTAssertEqual(spec(m, .multicamCreate).title, "マルチカメラを作る…")
        XCTAssertEqual(spec(m, .multicamSwitch).title, "マルチカメラ切替…")
        XCTAssertEqual(spec(m, .multicamCut(2)).title, "再生位置からアングル 3 に切り替え")
        XCTAssertTrue(AppMenuSpec.multicamItems(state(m)).count == 11)
        // 映像クリップを 2 つ以上選ぶと「作る…」が使える
        m.setSelection(ClipSelection(ids: ["cam1", "cam2"], primary: "cam1"))
        XCTAssertTrue(spec(m, .multicamCreate).enabled)
        m.selectOnly("cam1")
        XCTAssertFalse(spec(m, .multicamCreate).enabled)
    }

    func testNoDuplicateAcceleratorsWithNewItems() throws {
        let m = try makeModel(); defer { m.shutdown() }
        let used = AppMenuSpec.all(state(m)).compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count)
        // 1〜9 の素のキーはメニューのショートカットにしない
        XCTAssertTrue(used.allSatisfy { !$0.modifiers.isEmpty })
    }

    // MARK: 同期(実際の音ファイル)

    func testMeasuredLagsRecoverKnownShiftsWithin10ms() async throws {
        let m = try makeModel(); defer { m.shutdown() }
        let lags = await m.measureMulticamLags(ids: ["cam1", "cam2", "cam3"])
        let l2 = try XCTUnwrap(try XCTUnwrap(lags["cam2"]))
        let l3 = try XCTUnwrap(try XCTUnwrap(lags["cam3"]))
        XCTAssertEqual(l2, 0.37, accuracy: 0.0101)
        XCTAssertEqual(l3, 1.23, accuracy: 0.0101)
    }

    func testUnrelatedAudioIsReportedAsNotSyncedAndManualFallbackWorks() async throws {
        let m = try makeModel(); defer { m.shutdown() }
        // cam2 を無音のファイルにする
        let silent = tmp.appendingPathComponent("silent.wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        let f = try AVAudioFile(forWriting: silent, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 48000 * 6)!; b.frameLength = 48000 * 6
        try f.write(from: b)
        m.edit("x") { $0.tracks[1].clips[0].src = silent.path }
        let lags = await m.measureMulticamLags(ids: ["cam1", "cam2"])
        XCTAssertNotNil(lags["cam2"], "測った結果はある")
        XCTAssertNil(lags["cam2"]!, "合わせられなかった")
        // 手動のずれでグループを作れる
        XCTAssertTrue(m.createMulticam(ids: ["cam1", "cam2"], localLags: ["cam2": 0.5]))
        XCTAssertEqual(m.project.multicams[0].angles[1].syncOffset, 0.5, accuracy: 1e-9)
    }

    // MARK: 作る・切り替える

    func testCreateIsOneUndoAndCutsAreOneUndoEachWithLayout() async throws {
        let m = try makeModel(); defer { m.shutdown() }
        let um = m.effectiveUndoManager
        let baseJSON = try m.project.encoded()
        let lags = await m.measureMulticamLags(ids: ["cam1", "cam2", "cam3"])
        var dict: [String: Double] = [:]
        for (k, v) in lags { dict[k] = v ?? 0 }
        m.setSelection(ClipSelection(ids: ["cam1", "cam2", "cam3"], primary: "cam1"))
        AppMenu.perform(.multicamCreate, model: m)
        XCTAssertTrue(m.showMulticamCreateSheet, "シートを開くだけでは履歴に載せない")
        XCTAssertFalse(um.canUndo)
        m.showMulticamCreateSheet = false
        XCTAssertTrue(m.createMulticam(ids: ["cam1", "cam2", "cam3"], localLags: dict))
        XCTAssertEqual(um.undoActionName, "マルチカメラを作る")
        let g = try XCTUnwrap(m.project.multicams.first)
        XCTAssertEqual(m.project.tracks.last?.id, g.targetTrackId)
        XCTAssertEqual(g.angles[1].syncOffset, 0.37, accuracy: 0.0101)
        XCTAssertEqual(g.angles[2].syncOffset, 1.23, accuracy: 0.0101)
        // 切替シートは開くだけ
        AppMenu.perform(.multicamSwitch, model: m)
        XCTAssertTrue(m.showMulticamSwitchSheet); m.showMulticamSwitchSheet = false

        // 2 秒でカメラ2、4 秒でカメラ3、5 秒でカメラ1 に切り替え(メニューの項目)
        m.currentTime = 2
        XCTAssertTrue(spec(m, .multicamCut(1)).enabled); XCTAssertFalse(spec(m, .multicamCut(3)).enabled)
        AppMenu.perform(.multicamCut(1), model: m)
        XCTAssertEqual(um.undoActionName, "アングル2に切り替え")
        m.currentTime = 4
        AppMenu.perform(.multicamCut(2), model: m)
        m.currentTime = 5
        AppMenu.perform(.multicamCut(0), model: m)
        let cuts = try XCTUnwrap(m.project.tracks.first { $0.id == g.targetTrackId }).clips
        XCTAssertEqual(cuts.map(\.src), [g.angles[1].clip.src, g.angles[2].clip.src, g.angles[0].clip.src])
        XCTAssertEqual(cuts.map(\.start), [2, 4, 5])
        XCTAssertEqual(cuts[0].duration, 2, accuracy: 1e-9); XCTAssertEqual(cuts[1].duration, 1, accuracy: 1e-9)
        XCTAssertEqual(cuts[2].duration, 0.3, accuracy: 1e-9, "基準の終わり(5.3)まで")
        // 配置: 隙間も重なりもない / 同期のずれが素材の頭に入っている
        XCTAssertEqual(cuts[0].start + cuts[0].duration, cuts[1].start, accuracy: 1e-9)
        XCTAssertEqual(cuts[1].start + cuts[1].duration, cuts[2].start, accuracy: 1e-9)
        XCTAssertEqual(cuts[0].offset, 2 + g.angles[1].syncOffset, accuracy: 1e-9)
        XCTAssertEqual(cuts[1].offset, 4 + g.angles[2].syncOffset, accuracy: 1e-9)
        XCTAssertEqual(cuts[2].offset, 5, accuracy: 1e-9)
        XCTAssertTrue(cuts.allSatisfy { $0.volume == 0 && $0.type == .video }, "普通のクリップ。音は基準のクリップから")
        // 同じ角度への切り替えは何も登録しない
        um.removeAllActions()
        m.currentTime = 5.1
        AppMenu.perform(.multicamCut(0), model: m)
        XCTAssertFalse(um.canUndo)
        // Undo は 1 回ずつ。全部戻すと最初の状態にぴったり戻る
        m.currentTime = 2.5
        AppMenu.perform(.multicamCut(2), model: m)
        XCTAssertEqual(um.undoActionName, "アングル3に切り替え")
        um.undo()
        XCTAssertEqual(m.project.tracks.first { $0.id == g.targetTrackId }!.clips.count, 3)
        XCTAssertFalse(um.canUndo)
        _ = baseJSON
    }

    func testUndoAllReturnsToIdenticalJSON() async throws {
        let m = try makeModel(); defer { m.shutdown() }
        let um = m.effectiveUndoManager
        let baseJSON = try m.project.encoded()
        XCTAssertTrue(m.createMulticam(ids: ["cam1", "cam2"], localLags: ["cam2": 0.37]))
        m.currentTime = 1
        XCTAssertTrue(m.multicamCut(angle: 1))
        m.currentTime = 3
        XCTAssertTrue(m.multicamCut(angle: 0))
        um.undo(); um.undo(); um.undo()
        XCTAssertEqual(try m.project.encoded(), baseJSON)
        XCTAssertFalse(String(decoding: try m.project.encoded(), as: UTF8.self).contains("multicams"))
    }

    func testCutRefusedWhenLockedOrOutsideOrNoGroup() async throws {
        let m = try makeModel(); defer { m.shutdown() }
        let um = m.effectiveUndoManager
        m.currentTime = 1
        XCTAssertFalse(m.multicamCut(angle: 1), "グループがない")
        XCTAssertEqual(m.statusText, "再生位置にマルチカメラのグループがありません")
        XCTAssertTrue(m.createMulticam(ids: ["cam1", "cam2"], localLags: ["cam2": 0.37]))
        um.removeAllActions()
        m.currentTime = 9
        XCTAssertFalse(m.multicamCut(angle: 1, groupId: m.project.multicams[0].id))
        XCTAssertFalse(um.canUndo)
        m.edit("lock") { $0.tracks[$0.tracks.count - 1].locked = true }
        um.removeAllActions()
        m.currentTime = 1
        XCTAssertFalse(m.multicamCut(angle: 1))
        XCTAssertEqual(m.statusText, ProjectModel.lockedNotice)
        XCTAssertFalse(um.canUndo)
    }

    func testCreateRefusesLockedClipAndTooFew() throws {
        let m = try makeModel(); defer { m.shutdown() }
        m.edit("lock") { $0.tracks[1].locked = true }
        m.effectiveUndoManager.removeAllActions()
        XCTAssertFalse(m.createMulticam(ids: ["cam1", "cam2"], localLags: [:]))
        XCTAssertEqual(m.statusText, ProjectModel.lockedNotice)
        XCTAssertFalse(m.createMulticam(ids: ["cam1"], localLags: [:]))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertTrue(m.project.multicams.isEmpty)
    }

    // MARK: シートの寸法

    func testSheetsFitTheirContentWithoutOverflow() throws {
        let m = try makeModel(); defer { m.shutdown() }
        XCTAssertTrue(m.createMulticam(ids: ["cam1", "cam2", "cam3"], localLags: ["cam2": 0.37, "cam3": 1.23]))
        m.multicamCreateIds = ["cam1", "cam2", "cam3"]
        for (name, view): (String, AnyView) in [("作る", AnyView(MulticamCreateSheet(model: m))), ("切替", AnyView(MulticamSwitchSheet(model: m)))] {
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            XCTAssertGreaterThan(size.width, 200, name); XCTAssertLessThan(size.width, 520, name)
            XCTAssertGreaterThan(size.height, 100, name); XCTAssertLessThan(size.height, 420, name)
        }
        // 9 個のボタンを並べても幅が収まる(1 個 62pt + 余白)
        var many = m.project.multicams[0]
        many.angles = (0..<9).map { MulticamAngle(name: "カメラ\($0 + 1)", clip: many.angles[0].clip, syncOffset: 0) }
        m.edit("x") { $0.multicams = [many] }
        let host = NSHostingView(rootView: MulticamSwitchSheet(model: m))
        XCTAssertLessThan(host.fittingSize.width, 640)
    }
}
