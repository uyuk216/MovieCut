import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// U2: ドロップ先のオーバーレイ、プレビューの単色背景、解像度バッジの位置、メニューバー常駐アイコンの撤去。
@MainActor
final class UI2Tests: XCTestCase {
    private static let outDir = ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/ui2"

    private func png<V: View>(_ v: V, size: NSSize, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: v.preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: Self.outDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    // MARK: ドロップ先のオーバーレイ

    func testDropOverlaySnapshotsForEveryZone() throws {
        let targets: [(String, DockDropTarget)] = [("tab", .tab), ("left", .edge(.left)), ("right", .edge(.right)), ("top", .edge(.top)), ("bottom", .edge(.bottom))]
        for (name, t) in targets {
            let v = ZStack {
                Color(white: 0.16)
                Text("プレビュー").foregroundStyle(.secondary)
            }
            .frame(width: 420, height: 300)
            .overlay { DockDropHighlight(zone: t, tabBarHeight: 26) }
            _ = try png(v, size: NSSize(width: 420, height: 300), name: "drop-\(name).png")
        }
        // 外側の端
        for e in DockEdge.allCases {
            let v = Color(white: 0.16).frame(width: 600, height: 360).overlay { DockOuterHighlight(edge: e) }
            let rep = try png(v, size: NSSize(width: 600, height: 360), name: "drop-outer-\(e.rawValue).png")
            // 帯の中は、塗っていない側より明るい青み(アクセント色)になっている
            let inside: (Int, Int), outside: (Int, Int)
            switch e {
            case .left: inside = (30, 180); outside = (500, 180)
            case .right: inside = (570, 180); outside = (100, 180)
            case .top: inside = (300, 30); outside = (300, 300)
            case .bottom: inside = (300, 330); outside = (300, 60)
            }
            let a = pixel(rep, inside.0, inside.1), b = pixel(rep, outside.0, outside.1)
            XCTAssertGreaterThan(abs(a.b - b.b) + abs(a.r - b.r), 0.05, "\(e) の帯が塗られていない")
        }
    }

    // MARK: プレビューの背景

    func testPreviewCanvasUsesSolidBackgroundAndFollowsTheSetting() throws {
        let saved = UserDefaults.standard.string(forKey: PreviewBackground.defaultsKey)
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: PreviewBackground.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: PreviewBackground.defaultsKey) }
        }
        UserDefaults.standard.removeObject(forKey: PreviewBackground.defaultsKey)
        XCTAssertEqual(PreviewBackgroundStore.current, .darkGray)
        let v = PreviewCanvasView()
        v.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        func rgb(_ c: CGColor?) -> [Double] { (c?.components ?? []).prefix(3).map { ($0 * 255).rounded() } }
        // 既定 = #1E1E1E の単色(パターンではない)
        XCTAssertNotEqual(v.backgroundColorForTest?.colorSpace?.model, .pattern)
        XCTAssertEqual(rgb(v.backgroundColorForTest), [30, 30, 30])
        for b in PreviewBackground.allCases {
            PreviewBackgroundStore.set(b)
            XCTAssertEqual(PreviewBackgroundStore.current, b)
            XCTAssertEqual(rgb(v.backgroundColorForTest), rgb(parseHexColor(b.hex)), b.title)
        }
        // アプリ全体の設定で、プロジェクトには入らない
        let m = ProjectModel(project: .new())
        let before = m.project
        AppMenu.perform(.previewBackground(.white), model: m)
        XCTAssertEqual(PreviewBackgroundStore.current, .white)
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        PreviewBackgroundStore.set(.green)
        let rep = try png(CenterPanelFixture(), size: NSSize(width: 700, height: 420), name: "preview-green.png")
        _ = rep
        PreviewBackgroundStore.set(.darkGray)
        _ = try png(CenterPanelFixture(), size: NSSize(width: 700, height: 420), name: "preview-dark.png")
    }

    /// 中央パネル(プレビュー + 再生バー)を単独で描く。
    struct CenterPanelFixture: View {
        @StateObject private var model = ProjectModel(project: .new())
        var body: some View { CenterPanel(model: model).frame(width: 700, height: 420).background(Color(nsColor: .windowBackgroundColor)) }
    }

    // MARK: 解像度バッジ

    func testResolutionBadgeIsInTheTransportBarNotOnThePicture() throws {
        let m = ProjectModel(project: .new())
        // 再生バーを単独で描き、文字のある画素の横の広がりを測る(バッジが無ければ ⏮ ▶ と時刻だけで約 250pt)
        let rep = try png(TransportBar(model: m).frame(width: 700, height: 40).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 700, height: 40), name: "transport.png")
        var minX = Int.max, maxX = 0
        let bg = pixel(rep, 2, 2)
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            let p = pixel(rep, x, y)
            if abs(p.r - bg.r) + abs(p.g - bg.g) + abs(p.b - bg.b) > 0.25 { minX = min(minX, x); maxX = max(maxX, x) }
        } }
        let scale = Double(rep.pixelsWide) / 700
        XCTAssertGreaterThan(Double(maxX - minX) / scale, 290, "バッジが再生バーに出ていない(\(minX)…\(maxX))")
        // プレビューの上には何も重ねない: 中央パネルの ZStack が無く、PreviewView が直接並ぶ
        let src = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/MovieCut/ContentView.swift").path, encoding: .utf8)
        let center = try XCTUnwrap(src.range(of: "struct CenterPanel")).lowerBound
        let transport = try XCTUnwrap(src.range(of: "struct TransportBar")).lowerBound
        XCTAssertFalse(src[center..<transport].contains("VideoText.chip"), "バッジがプレビューの上に残っている")
    }

    // MARK: メニューバー常駐アイコンの撤去

    func testNoStatusItemCodeOrToggleRemains() {
        // 表示メニューに「メニューバーアイコン」の項目が無い
        let titles = AppMenuSpec.all(MenuState()).map(\.title)
        XCTAssertFalse(titles.contains { $0.contains("メニューバーアイコン") })
        XCTAssertTrue(titles.contains("プレビューの背景") == false)     // 親メニューは項目ではない
        XCTAssertTrue(titles.contains("暗い灰色"))
        // ソースにも NSStatusItem が無い
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 50)
        for f in files {
            let s = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            let code = s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            XCTAssertFalse(code.contains("NSStatusItem") || code.contains("NSStatusBar"), f.lastPathComponent)
        }
    }
}
