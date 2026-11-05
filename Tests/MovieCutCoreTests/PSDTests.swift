import XCTest
import ImageIO
import Compression
@testable import MovieCutCore

/// テスト用に PSD をバイト列から組み立てる(RAW / RLE / 16 ビット / グループ / 非表示)。
struct PSDBuilder {
    struct L {
        var name: String
        var rect: (top: Int, left: Int, bottom: Int, right: Int)
        var rgba: [[UInt8]] = []           // 画素ごとの [R,G,B,A](行順)
        var opacity: UInt8 = 255
        var visible = true
        var rle = false
        var blend = "norm"
        var section: UInt32? = nil         // 1 開く / 2 閉じる / 3 終わり
        var zip = false                    // 壊れた ZIP(読めない → 統合画像に戻る確認用)
        var zipKind: Int? = nil            // 本物の ZIP(2 = 予測なし、3 = 予測あり)
        var unicodeName: String? = nil
    }
    var width: Int, height: Int
    var depth = 8
    var layers: [L] = []
    var compositeRLE = false
    var compositeZip: Int? = nil
    var composite: [[UInt8]]? = nil        // 無ければ全面 白

    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func be32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return (0..<4).map { UInt8((u >> UInt32(24 - 8 * $0)) & 0xff) } }

    static func packBits(_ row: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < row.count {
            var run = 1
            while i + run < row.count, row[i + run] == row[i], run < 128 { run += 1 }
            if run >= 2 { out.append(UInt8(bitPattern: Int8(1 - run))); out.append(row[i]); i += run }
            else {
                var lit = 1
                while i + lit < row.count, lit < 128, !(i + lit + 1 < row.count && row[i + lit] == row[i + lit + 1]) { lit += 1 }
                out.append(UInt8(lit - 1)); out.append(contentsOf: row[i..<(i + lit)]); i += lit
            }
        }
        return out
    }

    /// 1 チャンネル(圧縮方式 + 本体)
    /// 圧縮前の行(必要なら予測の差分にして)を zlib 形式(2 バイトのヘッダー + deflate + 4 バイト)にする
    func zipBytes(_ rows: [[UInt8]], kind: Int) -> [UInt8] {
        var raw: [UInt8] = []
        for r in rows {
            if kind == 3 {
                var d = r
                if depth == 16 {
                    var i = r.count - 2
                    while i >= 2 {
                        let cur = Int(r[i]) << 8 | Int(r[i + 1]), prev = Int(r[i - 2]) << 8 | Int(r[i - 1])
                        let v = (cur - prev) & 0xFFFF
                        d[i] = UInt8(v >> 8); d[i + 1] = UInt8(v & 0xFF); i -= 2
                    }
                } else {
                    var i = r.count - 1
                    while i >= 1 { d[i] = r[i] &- r[i - 1]; i -= 1 }
                }
                raw += d
            } else { raw += r }
        }
        var out = [UInt8](repeating: 0, count: raw.count + 1024)
        let n = raw.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
            compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB) } }
        return [0x78, 0x9C] + out.prefix(n) + [0, 0, 0, 0]
    }

    func channelData(plane: [UInt8], w: Int, h: Int, rle: Bool, zip: Bool = false, zipKind: Int? = nil) -> [UInt8] {
        let rows: [[UInt8]] = (0..<h).map { y in
            let r = Array(plane[(y * w)..<((y + 1) * w)])
            return depth == 16 ? r.flatMap { [$0, $0 &* 0] } : r      // 16 ビットは上位バイト = 値
        }
        if let k = zipKind { return Self.be16(k) + zipBytes(rows, kind: k) }
        if zip { return Self.be16(2) + [1, 2, 3] }
        if !rle { return Self.be16(0) + rows.flatMap { $0 } }
        let packed = rows.map { Self.packBits($0) }
        return Self.be16(1) + packed.flatMap { Self.be16($0.count) } + packed.flatMap { $0 }
    }

    func build() -> Data {
        var d: [UInt8] = Array("8BPS".utf8) + Self.be16(1) + [UInt8](repeating: 0, count: 6)
        d += Self.be16(4) + Self.be32(height) + Self.be32(width) + Self.be16(depth) + Self.be16(3)
        d += Self.be32(0) + Self.be32(0)     // カラーモードデータ、画像リソース
        // レイヤー
        var recs: [UInt8] = []
        var chData: [UInt8] = []
        for l in layers {
            let w = l.rect.right - l.rect.left, h = l.rect.bottom - l.rect.top
            var chans: [(Int, [UInt8])] = []
            if w > 0, h > 0 {
                for (k, id) in [0, 1, 2, -1].enumerated() {
                    let plane = l.rgba.map { $0[k] }
                    chans.append((id, channelData(plane: plane, w: w, h: h, rle: l.rle, zip: l.zip && id == 0, zipKind: l.zipKind)))
                }
            } else {
                for id in [0, 1, 2, -1] { chans.append((id, Self.be16(0))) }
            }
            recs += Self.be32(l.rect.top) + Self.be32(l.rect.left) + Self.be32(l.rect.bottom) + Self.be32(l.rect.right)
            recs += Self.be16(chans.count)
            for (id, data) in chans { recs += Self.be16(id < 0 ? 0x10000 + id : id) + Self.be32(data.count) }
            recs += Array("8BIM".utf8) + Array(l.blend.utf8) + [l.opacity, 0, l.visible ? 0 : 2, 0]
            var extra: [UInt8] = Self.be32(0) + Self.be32(0)         // マスク、ブレンド範囲
            let nm = Array(l.name.utf8)
            extra += [UInt8(nm.count)] + nm
            let padded = 1 + nm.count
            extra += [UInt8](repeating: 0, count: (4 - padded % 4) % 4)
            if let u = l.unicodeName {
                let units = Array(u.utf16)
                var body = Self.be32(units.count) + units.flatMap { Self.be16(Int($0)) }
                if body.count % 2 == 1 { body.append(0) }
                extra += Array("8BIM".utf8) + Array("luni".utf8) + Self.be32(body.count) + body
            }
            if let s = l.section {
                extra += Array("8BIM".utf8) + Array("lsct".utf8) + Self.be32(4) + Self.be32(Int(s))
            }
            recs += Self.be32(extra.count) + extra
            for (_, data) in chans { chData += data }
        }
        var info = Self.be16(layers.count) + recs + chData
        if info.count % 2 == 1 { info.append(0) }
        let misc = Self.be32(info.count) + info
        d += Self.be32(misc.count) + misc
        // 統合済み画像
        let comp = composite ?? [[UInt8]](repeating: [255, 255, 255, 255], count: width * height)
        var planes: [[UInt8]] = []
        for k in 0..<4 { planes.append(comp.map { $0[k] }) }
        if let k = compositeZip {
            let rows: [[UInt8]] = planes.flatMap { p in (0..<height).map { y in
                let r = Array(p[(y * width)..<((y + 1) * width)]); return depth == 16 ? r.flatMap { [$0, 0] } : r } }
            d += Self.be16(k) + zipBytes(rows, kind: k)
        } else if compositeRLE {
            let rows: [[UInt8]] = planes.flatMap { p in (0..<height).map { y in
                let r = Array(p[(y * width)..<((y + 1) * width)]); return Self.packBits(depth == 16 ? r.flatMap { [$0, 0] } : r) } }
            d += Self.be16(1) + rows.flatMap { Self.be16($0.count) } + rows.flatMap { $0 }
        } else {
            d += Self.be16(0)
            for p in planes { d += depth == 16 ? p.flatMap { [$0, 0] } : p }
        }
        return Data(d)
    }
}

func solid(_ w: Int, _ h: Int, _ c: [UInt8]) -> [[UInt8]] { [[UInt8]](repeating: c, count: w * h) }

final class PSDTests: XCTestCase {
    private func sample(rle: Bool) -> PSDBuilder {
        var b = PSDBuilder(width: 8, height: 6)
        // 下から: 背景(全面 赤)、四角(中ほど 緑・不透明度 128)、隠し(青)、グループ(開く)の中に 1 枚
        b.layers = [
            .init(name: "背景", rect: (0, 0, 6, 8), rgba: solid(8, 6, [255, 0, 0, 255]), rle: rle),
            .init(name: "緑", rect: (1, 2, 3, 6), rgba: solid(4, 2, [0, 255, 0, 255]), opacity: 128, rle: rle, blend: "mul "),
            .init(name: "隠し", rect: (0, 0, 2, 2), rgba: solid(2, 2, [0, 0, 255, 255]), visible: false, rle: rle),
        ]
        return b
    }

    func testRawLayersParse() throws {
        let doc = try PSDParser.parse(sample(rle: false).build())
        XCTAssertEqual(doc.width, 8); XCTAssertEqual(doc.height, 6); XCTAssertEqual(doc.depth, 8)
        XCTAssertEqual(doc.layers.map(\.name), ["背景", "緑", "隠し"])
        XCTAssertNil(doc.layerError)
        let g = doc.layers[1]
        XCTAssertEqual([g.top, g.left, g.bottom, g.right], [1, 2, 3, 6])
        XCTAssertEqual(g.opacity, 128)
        XCTAssertEqual(g.blendKey, "mul ")
        XCTAssertEqual(g.raster.pixel(0, 0), [0, 255, 0, 255])
        XCTAssertEqual(g.raster.pixel(3, 1), [0, 255, 0, 255])
        XCTAssertNil(g.raster.pixel(4, 0))
        XCTAssertEqual(doc.layers[0].raster.pixel(7, 5), [255, 0, 0, 255])
        XCTAssertFalse(doc.layers[2].visible)
        XCTAssertEqual(doc.composite?.pixel(3, 3), [255, 255, 255, 255])
    }

    func testRLELayersMatchRaw() throws {
        let raw = try PSDParser.parse(sample(rle: false).build())
        let rle = try PSDParser.parse(sample(rle: true).build())
        XCTAssertEqual(raw.layers, rle.layers)
        // 変化のある行(PackBits のリテラルと繰り返しが混ざる)
        var b = PSDBuilder(width: 5, height: 2)
        let px: [[UInt8]] = [[1, 2, 3, 255], [1, 2, 3, 255], [1, 2, 3, 255], [9, 8, 7, 255], [5, 5, 5, 255],
                             [0, 0, 0, 0], [10, 20, 30, 40], [10, 20, 30, 40], [1, 1, 1, 1], [2, 2, 2, 2]]
        b.layers = [.init(name: "模様", rect: (0, 0, 2, 5), rgba: px, rle: true)]
        b.compositeRLE = true
        let doc = try PSDParser.parse(b.build())
        XCTAssertEqual(doc.layers[0].raster.rgba, px.flatMap { $0 })
        XCTAssertEqual(doc.composite?.pixel(4, 1), [255, 255, 255, 255])
    }

    func testSixteenBit() throws {
        var b = sample(rle: true)
        b.depth = 16
        let doc = try PSDParser.parse(b.build())
        XCTAssertEqual(doc.depth, 16)
        XCTAssertEqual(doc.layers[1].raster.pixel(1, 1), [0, 255, 0, 255])
        XCTAssertEqual(doc.composite?.pixel(0, 0), [255, 255, 255, 255])
    }

    func testGroupVisibilityAndUnicodeName() throws {
        var b = PSDBuilder(width: 4, height: 4)
        b.layers = [
            .init(name: "底", rect: (0, 0, 4, 4), rgba: solid(4, 4, [1, 1, 1, 255])),
            .init(name: "</Layer group>", rect: (0, 0, 0, 0), section: 3),
            .init(name: "中", rect: (0, 0, 2, 2), rgba: solid(2, 2, [2, 2, 2, 255]), unicodeName: "なか"),
            .init(name: "グループ", rect: (0, 0, 0, 0), visible: false, section: 1),
            .init(name: "上", rect: (0, 0, 1, 1), rgba: solid(1, 1, [3, 3, 3, 255])),
        ]
        let doc = try PSDParser.parse(b.build())
        XCTAssertEqual(doc.layers.map(\.name), ["底", "</Layer group>", "なか", "グループ", "上"])
        XCTAssertEqual(doc.layers.map(\.group), [.none, .divider, .none, .openFolder, .none])
        XCTAssertEqual(doc.layers.map(\.effectivelyVisible), [true, false, false, false, true])
        XCTAssertEqual(doc.contentLayers.count, 3)
        // 取り込み: 隠れたグループの中は読み込まない
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psdtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try PSDImporter.prepare(doc, mode: .layers, canvasWidth: 4, canvasHeight: 4, cacheDir: dir)
        XCTAssertEqual(plan.items.map(\.name), ["底", "上"])
        XCTAssertEqual(plan.hiddenSkipped, 1)
    }

    func testZipLayerFallsBackToComposite() throws {
        var b = sample(rle: false)
        b.layers[1].zip = true
        b.composite = solid(8, 6, [10, 20, 30, 255])
        let doc = try PSDParser.parse(b.build())
        XCTAssertNotNil(doc.layerError)
        XCTAssertTrue(doc.layers.isEmpty)
        XCTAssertEqual(doc.composite?.pixel(2, 2), [10, 20, 30, 255])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psdtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try PSDImporter.prepare(doc, mode: .layers, canvasWidth: 1920, canvasHeight: 1080, cacheDir: dir)
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertTrue(plan.usedComposite)
        XCTAssertEqual(plan.items[0].scale, 1); XCTAssertEqual(plan.items[0].x, 0.5)
    }

    /// 8×6 の、行の中で値が大きく動く画素(予測の差分が 0 ばかりにならない)
    private var varied: [[UInt8]] {
        (0..<48).map { (i: Int) -> [UInt8] in
            let r = UInt8((i * 37) % 256), g = UInt8((i * 53 + 7) % 256), b = UInt8((i * i) % 256)
            return [r, g, b, 255]
        }
    }

    func testZipLayersAndCompositeAreDecoded() throws {
        for kind in [2, 3] {
            var b = sample(rle: false)
            b.layers[0].rgba = varied
            b.layers[0].zipKind = kind; b.layers[1].zipKind = kind
            b.compositeZip = kind
            b.composite = solid(8, 6, [10, 20, 30, 255])
            let doc = try PSDParser.parse(b.build())
            XCTAssertNil(doc.layerError, "ZIP(方式 \(kind))のレイヤーを読めた")
            var ref = sample(rle: false); ref.layers[0].rgba = varied
            let plain = try PSDParser.parse(ref.build())
            XCTAssertEqual(doc.layers.map(\.raster), plain.layers.map(\.raster), "ZIP と RAW で画素が同じ(方式 \(kind))")
            XCTAssertEqual(doc.composite?.pixel(2, 2), [10, 20, 30, 255])
        }
    }

    func testZip16BitWithPrediction() throws {
        var b = sample(rle: false)
        b.depth = 16
        b.layers[0].rgba = varied
        b.layers[0].zipKind = 3; b.layers[1].zipKind = 3
        let doc = try PSDParser.parse(b.build())
        var ref = sample(rle: false); ref.depth = 16; ref.layers[0].rgba = varied
        let plain = try PSDParser.parse(ref.build())
        XCTAssertNil(doc.layerError)
        XCTAssertEqual(doc.layers.map(\.raster), plain.layers.map(\.raster))
    }

    func testInflateRejectsGarbageAndWrongSize() {
        XCTAssertThrowsError(try PSDParser.inflate([0x78, 0x9C, 1, 2, 3], expected: 10))
        let good = PSDBuilder(width: 1, height: 1).zipBytes([[1, 2, 3, 4]], kind: 2)
        XCTAssertEqual(try PSDParser.inflate(good, expected: 4), [1, 2, 3, 4])
        XCTAssertThrowsError(try PSDParser.inflate(good, expected: 5))
    }

    func testBadInputs() {
        XCTAssertThrowsError(try PSDParser.parse(Data("hello".utf8)))
        let good = sample(rle: false).build()
        XCTAssertThrowsError(try PSDParser.parse(good.prefix(20)))
        XCTAssertThrowsError(try PSDParser.parse(good.prefix(good.count - 400)))   // 統合画像まで切れていても落ちない
        var bad = [UInt8](good); bad[24] = 0; bad[25] = 1      // 1 ビット
        XCTAssertThrowsError(try PSDParser.parse(Data(bad)))
        // 先頭を壊す乱数(落ちないこと)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var m = [UInt8](good)
            for _ in 0..<4 { m[Int.random(in: 26..<m.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? PSDParser.parse(Data(m))
        }
    }

    func testGeometryAndPNGPixels() throws {
        let doc = try PSDParser.parse(sample(rle: true).build())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psdtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // PSD 8×6 を 16×9 のキャンバスへ: s = min(2, 1.5) = 1.5。横に余白 (16 - 12) / 2 = 2
        let plan = try PSDImporter.prepare(doc, mode: .layers, canvasWidth: 16, canvasHeight: 9, cacheDir: dir)
        XCTAssertEqual(plan.items.map(\.name), ["背景", "緑"])
        XCTAssertEqual(plan.hiddenSkipped, 1)
        let bg = plan.items[0], gr = plan.items[1]
        XCTAssertEqual(bg.scale, 1.5 / min(16.0 / 8, 9.0 / 6), accuracy: 1e-9)   // 背景はキャンバス全体
        XCTAssertEqual(bg.x, 0.5, accuracy: 1e-9); XCTAssertEqual(bg.y, 0.5, accuracy: 1e-9)
        // 緑: 範囲 左 2 上 1 幅 4 高 2 → 中心 (4, 2) → キャンバス x = 2 + 4 * 1.5 = 8 → 0.5、y = (9 - 9) / 2 + 2 * 1.5 = 3 → 1/3
        XCTAssertEqual(gr.x, 8.0 / 16, accuracy: 1e-9); XCTAssertEqual(gr.y, 3.0 / 9, accuracy: 1e-9)
        // 描く大きさ: min(16/4, 9/2) * scale = 4 * scale = 幅 4 * 1.5 = 6 になる scale は 6 / (4 * 4)... 幅で確認
        XCTAssertEqual(4 * min(16.0 / 4, 9.0 / 2) * gr.scale, 6, accuracy: 1e-9)
        XCTAssertEqual(gr.opacity, 128.0 / 255, accuracy: 1e-9)
        // PNG の中身
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: gr.path) as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(img.width, 4); XCTAssertEqual(img.height, 2)
        let back = try XCTUnwrap(PSDImporter.raster(img))
        XCTAssertEqual(back.pixel(3, 1), [0, 255, 0, 255])
        // 同じキャッシュを再利用する(作り直さない)
        let before = try FileManager.default.attributesOfItem(atPath: gr.path)[.modificationDate] as? Date
        _ = try PSDImporter.prepare(doc, mode: .layers, canvasWidth: 16, canvasHeight: 9, cacheDir: dir)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: gr.path)[.modificationDate] as? Date, before)
    }

    func testFlattenedUsesCompositeAndPlacementOrder() throws {
        var b = sample(rle: false)
        b.composite = solid(8, 6, [7, 8, 9, 255])
        let doc = try PSDParser.parse(b.build())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psdtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let flat = try PSDImporter.prepare(doc, mode: .flattened, canvasWidth: 1920, canvasHeight: 1080, cacheDir: dir)
        XCTAssertEqual(flat.items.count, 1)
        XCTAssertEqual(flat.hiddenSkipped, 1)
        // レイヤー: 下から順に別の段へ。既存の段(0 番に別のクリップ)があれば避ける
        let plan = try PSDImporter.prepare(doc, mode: .layers, canvasWidth: 1920, canvasHeight: 1080, cacheDir: dir)
        var p = Project()
        var t0 = Track(name: "既存"); t0.clips = [ClipEditing.makeMediaClip(path: "/x.png", kind: .image, duration: 10, start: 0)]
        p.tracks = [t0]
        let ids = PSDImporter.place(plan.items, at: 2, in: &p)
        XCTAssertEqual(ids.count, 2)
        let rows = ids.map { id in p.tracks.firstIndex { $0.clips.contains { $0.id == id } }! }
        XCTAssertEqual(rows, [1, 2])      // 既存の段は使わず、下のレイヤー = 小さい番号
        let c = p.tracks[1].clips[0]
        XCTAssertEqual(c.start, 2); XCTAssertEqual(c.duration, 5)
        assertNoLayerOverlaps(p)
    }
}
