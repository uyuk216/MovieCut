import Foundation
import Compression

/// PSD(Photoshop 形式)の読み取り。外部ライブラリなし。
/// 対応: RGB・8 ビット / 16 ビット(上位バイトだけ使う)、チャンネルは RAW と RLE(PackBits)。
/// 読むもの: ヘッダー、レイヤー記録(名前・範囲・不透明度・表示フラグ・ブレンドモードのキー・グループの印)、レイヤーごとの画素、統合済みの合成画像。
/// ZIP 圧縮(予測あり・なし)も読む(Compression フレームワークの zlib)。
/// 読まないもの: 画像リソース、カラーモードデータ、レイヤーマスク、調整レイヤー、レイヤー効果。
public enum PSDError: Error, Equatable, CustomStringConvertible {
    case notPSD
    case truncated
    case unsupported(String)
    case corrupt(String)

    public var description: String {
        switch self {
        case .notPSD: return "PSD ファイルではありません"
        case .truncated: return "ファイルが途中で切れています"
        case .unsupported(let s): return "未対応の PSD です(\(s))"
        case .corrupt(let s): return "PSD が壊れています(\(s))"
        }
    }
}

/// 8 ビット RGBA(非プリマルチプライド)の画素。
public struct PSDRaster: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// 行ごとに R G B A。`width * height * 4` バイト(大きさが 0 なら空)。
    public var rgba: [UInt8]

    public init(width: Int = 0, height: Int = 0, rgba: [UInt8] = []) {
        self.width = width; self.height = height; self.rgba = rgba
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// (x, y) の画素 [R, G, B, A]。範囲外は nil。
    public func pixel(_ x: Int, _ y: Int) -> [UInt8]? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return Array(rgba[i..<(i + 4)])
    }
}

public enum PSDGroupKind: Equatable, Sendable {
    case none
    /// 開いたフォルダ(グループの先頭 = ファイルでは上端の記録)
    case openFolder
    /// 閉じたフォルダ
    case closedFolder
    /// グループの終わりの印(ファイルでは下端の記録。画素なし)
    case divider
}

public struct PSDLayer: Equatable, Sendable {
    public var name: String
    public var top: Int
    public var left: Int
    public var bottom: Int
    public var right: Int
    /// 0...255
    public var opacity: Int
    /// レイヤー自身の表示フラグ
    public var visible: Bool
    /// グループの目まで含めた、実際に見えるか
    public var effectivelyVisible: Bool
    /// ブレンドモードのキー(例 "norm" "mul " "scrn")。名前を持つだけで、合成には使わない。
    public var blendKey: String
    public var group: PSDGroupKind
    public var raster: PSDRaster

    public var width: Int { max(0, right - left) }
    public var height: Int { max(0, bottom - top) }
    public var isGroupMarker: Bool { group != .none }
}

public struct PSDDocument: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int
    public var channels: Int
    public var colorMode: Int
    /// ファイルの並び順(下のレイヤーが先)。グループの印も含む。
    public var layers: [PSDLayer]
    /// レイヤーの読み取りに失敗した理由(成功なら nil)。
    public var layerError: String?
    /// 統合済みの合成画像(読めなければ nil)
    public var composite: PSDRaster?

    /// 画素を持つ実レイヤー(グループの印を除く)
    public var contentLayers: [PSDLayer] { layers.filter { !$0.isGroupMarker } }
}

public enum PSDParser {
    static let maxDimension = 30000
    static let maxPixels = 120_000_000

    public static func parse(_ data: Data) throws -> PSDDocument {
        var r = PSDReader(bytes: [UInt8](data))
        guard try r.bytes4() == "8BPS" else { throw PSDError.notPSD }
        let version = try r.u16()
        if version == 2 { throw PSDError.unsupported("PSB(大型ドキュメント)") }
        guard version == 1 else { throw PSDError.notPSD }
        try r.skip(6)
        let channels = try r.u16()
        let height = Int(try r.u32())
        let width = Int(try r.u32())
        let depth = try r.u16()
        let mode = try r.u16()
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension, width * height <= maxPixels else {
            throw PSDError.corrupt("大きさ \(width)×\(height)")
        }
        guard channels >= 1, channels <= 56 else { throw PSDError.corrupt("チャンネル数 \(channels)") }
        guard depth == 8 || depth == 16 else { throw PSDError.unsupported("\(depth) ビット") }
        guard mode == 3 else { throw PSDError.unsupported("カラーモード \(mode)(RGB のみ対応)") }

        var doc = PSDDocument(width: width, height: height, depth: depth, channels: channels, colorMode: mode,
                              layers: [], layerError: nil, composite: nil)
        // カラーモードデータ、画像リソース: 読み飛ばす
        try r.skip(Int(try r.u32()))
        try r.skip(Int(try r.u32()))

        // レイヤーとマスク情報
        let miscLen = Int(try r.u32())
        let miscEnd = r.pos + miscLen
        guard miscEnd <= r.count else { throw PSDError.truncated }
        if miscLen > 0 {
            do {
                var sub = PSDReader(bytes: r.slice(r.pos, miscEnd))
                doc.layers = try parseLayerInfo(&sub, depth: depth)
                resolveVisibility(&doc.layers)
            } catch {
                doc.layers = []
                doc.layerError = (error as? PSDError)?.description ?? "\(error)"
            }
        }
        r.pos = miscEnd

        // 統合済みの画像(レイヤーが読めなかったときの代わり)
        do {
            doc.composite = try parseComposite(&r, width: width, height: height, channels: channels, depth: depth)
        } catch {
            if doc.layers.isEmpty && doc.layerError != nil { throw error }
            doc.composite = nil
        }
        if doc.layers.isEmpty && doc.layerError == nil && doc.composite == nil { throw PSDError.corrupt("画像データがありません") }
        return doc
    }

    // MARK: レイヤー

    private struct ChannelInfo { var id: Int; var length: Int }

    private static func parseLayerInfo(_ r: inout PSDReader, depth: Int) throws -> [PSDLayer] {
        let layerInfoLen = Int(try r.u32())
        if layerInfoLen == 0 { return [] }
        let infoEnd = r.pos + layerInfoLen
        guard infoEnd <= r.count else { throw PSDError.truncated }
        var count = Int(try r.i16())
        if count < 0 { count = -count }   // 先頭のアルファは統合画像の透明度(レイヤー数には関係ない)
        if count == 0 { return [] }
        guard count <= 20000 else { throw PSDError.corrupt("レイヤー数 \(count)") }

        var layers: [PSDLayer] = []
        var channelLists: [[ChannelInfo]] = []
        for _ in 0..<count {
            let top = Int(try r.i32()), left = Int(try r.i32()), bottom = Int(try r.i32()), right = Int(try r.i32())
            let nch = try r.u16()
            guard nch <= 56 else { throw PSDError.corrupt("レイヤーのチャンネル数") }
            var chs: [ChannelInfo] = []
            for _ in 0..<nch { chs.append(ChannelInfo(id: try r.i16(), length: Int(try r.u32()))) }
            guard try r.bytes4() == "8BIM" else { throw PSDError.corrupt("レイヤー記録の署名") }
            let blend = try r.bytes4()
            let opacity = Int(try r.u8())
            _ = try r.u8()   // クリッピング
            let flags = Int(try r.u8())
            _ = try r.u8()
            let extraLen = Int(try r.u32())
            let extraEnd = r.pos + extraLen
            guard extraEnd <= r.count else { throw PSDError.truncated }
            // レイヤーマスク、ブレンド範囲: 読み飛ばす
            try r.skip(Int(try r.u32()))
            try r.skip(Int(try r.u32()))
            let nameLen = Int(try r.u8())
            var name = String(decoding: try r.take(nameLen), as: UTF8.self)
            // パスカル文字列は(長さ 1 バイト + 名前)を 4 の倍数に揃える
            try r.skip((4 - (1 + nameLen) % 4) % 4)
            var group: PSDGroupKind = .none
            // 追加情報(タグ付きブロック)
            while r.pos + 12 <= extraEnd {
                let sig = try r.bytes4()
                guard sig == "8BIM" || sig == "8B64" else { break }
                let key = try r.bytes4()
                let len = Int(try r.u32())
                let blockEnd = r.pos + len
                guard blockEnd <= extraEnd else { break }
                if key == "luni", len >= 4 {
                    let n = Int(try r.u32())
                    if n > 0, 4 + n * 2 <= len {
                        var units: [UInt16] = []
                        for _ in 0..<n { units.append(UInt16(try r.u16())) }
                        let decoded = String(utf16CodeUnits: units, count: units.count)
                        if !decoded.isEmpty { name = decoded }
                    }
                } else if key == "lsct" || key == "lsdk", len >= 4 {
                    switch try r.u32() {
                    case 1: group = .openFolder
                    case 2: group = .closedFolder
                    case 3: group = .divider
                    default: break
                    }
                }
                r.pos = blockEnd
                // 長さの端数合わせ(2〜4 バイト)を飛ばす
                var pad = 0
                while pad < 3, r.pos + 4 <= extraEnd, let s = r.peek4(), s != "8BIM", s != "8B64" { r.pos += 1; pad += 1 }
            }
            r.pos = extraEnd
            layers.append(PSDLayer(name: name, top: top, left: left, bottom: bottom, right: right, opacity: opacity,
                                   visible: flags & 0x02 == 0, effectivelyVisible: flags & 0x02 == 0, blendKey: blend,
                                   group: group, raster: PSDRaster()))
            channelLists.append(chs)
        }

        // チャンネルの画素(レイヤーの順に、記録されたチャンネルの順に並んでいる)
        for i in 0..<layers.count {
            var planes: [Int: [UInt8]] = [:]
            let w = layers[i].width, h = layers[i].height
            guard w * h <= maxPixels else { throw PSDError.corrupt("レイヤーの大きさ") }
            for ch in channelLists[i] {
                let end = r.pos + ch.length
                guard end <= r.count else { throw PSDError.truncated }
                if (0...2).contains(ch.id) || ch.id == -1, w > 0, h > 0, ch.length >= 2 {
                    var sub = PSDReader(bytes: r.slice(r.pos, end))
                    planes[ch.id] = try decodePlane(&sub, width: w, height: h, depth: depth)
                }
                r.pos = end
            }
            if w > 0, h > 0, !layers[i].isGroupMarker {
                layers[i].raster = PSDRaster(width: w, height: h, rgba: interleave(planes, count: w * h))
            }
        }
        return layers
    }

    private static func interleave(_ planes: [Int: [UInt8]], count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: count * 4)
        for (k, id) in [0, 1, 2, -1].enumerated() {
            guard let p = planes[id] else {
                if id != -1 { for j in 0..<count { out[j * 4 + k] = 0 } }
                continue
            }
            for j in 0..<count { out[j * 4 + k] = p[j] }
        }
        return out
    }

    /// フォルダの目(非表示)を中のレイヤーに反映する。ファイルは下から上の順なので、上から見て深さを数える。
    static func resolveVisibility(_ layers: inout [PSDLayer]) {
        var stack: [Bool] = []   // 外側のグループが見えるか
        for i in stride(from: layers.count - 1, through: 0, by: -1) {
            switch layers[i].group {
            case .openFolder, .closedFolder:
                let outer = stack.last ?? true
                layers[i].effectivelyVisible = outer && layers[i].visible
                stack.append(layers[i].effectivelyVisible)
            case .divider:
                layers[i].effectivelyVisible = stack.last ?? true
                if !stack.isEmpty { stack.removeLast() }
            case .none:
                layers[i].effectivelyVisible = (stack.last ?? true) && layers[i].visible
            }
        }
    }

    // MARK: 画素の復号

    /// 圧縮方式(2 バイト)+ 本体から、1 チャンネルぶんの 8 ビット画素(width × height)を返す。16 ビットは上位バイトだけ。
    static func decodePlane(_ r: inout PSDReader, width: Int, height: Int, depth: Int) throws -> [UInt8] {
        let comp = try r.u16()
        let bpr = width * (depth / 8)
        var out = [UInt8](repeating: 0, count: width * height)
        switch comp {
        case 0:
            let raw = try r.take(bpr * height)
            decodeRows(raw: raw, rowBytes: bpr, width: width, height: height, depth: depth, into: &out)
        case 1:
            var counts: [Int] = []
            for _ in 0..<height { counts.append(try r.u16()) }
            var raw = [UInt8](); raw.reserveCapacity(bpr * height)
            for c in counts {
                let row = try r.take(c)
                try unpackBits(row, expected: bpr, into: &raw)
            }
            decodeRows(raw: raw, rowBytes: bpr, width: width, height: height, depth: depth, into: &out)
        case 2, 3:
            let rest = try r.take(r.count - r.pos)
            var raw = try inflate(rest, expected: bpr * height)
            if comp == 3 { undoPrediction(&raw, rowBytes: bpr, height: height, depth: depth) }
            decodeRows(raw: raw, rowBytes: bpr, width: width, height: height, depth: depth, into: &out)
        default:
            throw PSDError.unsupported("圧縮方式 \(comp)")
        }
        return out
    }

    /// ZIP(zlib 形式: 先頭 2 バイトのヘッダー + deflate + 末尾 4 バイトの検査値)を `expected` バイトに展開する。
    static func inflate(_ data: [UInt8], expected: Int) throws -> [UInt8] {
        guard data.count > 2 else { throw PSDError.corrupt("ZIP のデータが短い") }
        guard expected > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: expected)
        let n = data.withUnsafeBufferPointer { src -> Int in
            out.withUnsafeMutableBufferPointer { dst -> Int in
                compression_decode_buffer(dst.baseAddress!, expected, src.baseAddress! + 2, src.count - 2, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expected else { throw PSDError.corrupt("ZIP の展開結果の大きさ") }
        return out
    }

    /// 予測つき ZIP(方式 3): 各行を左から足し込んで元に戻す(8 ビットはバイト、16 ビットは 2 バイトの語、上位が先)。
    static func undoPrediction(_ raw: inout [UInt8], rowBytes: Int, height: Int, depth: Int) {
        guard rowBytes > 0 else { return }
        for y in 0..<height {
            let base = y * rowBytes
            if depth == 16 {
                var i = 2
                while i + 1 < rowBytes {
                    let prev = Int(raw[base + i - 2]) << 8 | Int(raw[base + i - 1])
                    let cur = Int(raw[base + i]) << 8 | Int(raw[base + i + 1])
                    let v = (prev + cur) & 0xFFFF
                    raw[base + i] = UInt8(v >> 8); raw[base + i + 1] = UInt8(v & 0xFF)
                    i += 2
                }
            } else {
                var i = 1
                while i < rowBytes { raw[base + i] = raw[base + i] &+ raw[base + i - 1]; i += 1 }
            }
        }
    }

    private static func decodeRows(raw: [UInt8], rowBytes: Int, width: Int, height: Int, depth: Int, into out: inout [UInt8]) {
        if depth == 8 { out = raw; return }
        for i in 0..<(width * height) { out[i] = raw[i * 2] }
    }

    /// PackBits を 1 行ぶん(ちょうど `expected` バイト)に展開して `out` に足す。
    static func unpackBits(_ row: [UInt8], expected: Int, into out: inout [UInt8]) throws {
        var produced = 0
        var i = 0
        while i < row.count, produced < expected {
            let n = Int(Int8(bitPattern: row[i])); i += 1
            if n >= 0 {
                let len = n + 1
                guard i + len <= row.count, produced + len <= expected else { throw PSDError.corrupt("RLE の長さ") }
                out.append(contentsOf: row[i..<(i + len)])
                i += len; produced += len
            } else if n != -128 {
                let len = 1 - n
                guard i < row.count, produced + len <= expected else { throw PSDError.corrupt("RLE の長さ") }
                out.append(contentsOf: repeatElement(row[i], count: len))
                i += 1; produced += len
            }
        }
        guard produced == expected else { throw PSDError.corrupt("RLE の行が短い") }
    }

    // MARK: 統合済みの画像

    private static func parseComposite(_ r: inout PSDReader, width: Int, height: Int, channels: Int, depth: Int) throws -> PSDRaster {
        let comp = try r.u16()
        let bpr = width * (depth / 8)
        let used = min(channels, 4)
        guard channels >= 3 else { throw PSDError.unsupported("チャンネルが足りません") }
        var planes: [[UInt8]] = []
        switch comp {
        case 0:
            for c in 0..<channels {
                let raw = try r.take(bpr * height)
                if c < used {
                    var p = [UInt8](repeating: 0, count: width * height)
                    decodeRows(raw: raw, rowBytes: bpr, width: width, height: height, depth: depth, into: &p)
                    planes.append(p)
                }
            }
        case 1:
            var counts: [Int] = []
            for _ in 0..<(channels * height) { counts.append(try r.u16()) }
            var k = 0
            for c in 0..<channels {
                var raw = [UInt8](); raw.reserveCapacity(bpr * height)
                for _ in 0..<height {
                    let row = try r.take(counts[k]); k += 1
                    try unpackBits(row, expected: bpr, into: &raw)
                }
                if c < used {
                    var p = [UInt8](repeating: 0, count: width * height)
                    decodeRows(raw: raw, rowBytes: bpr, width: width, height: height, depth: depth, into: &p)
                    planes.append(p)
                }
            }
        case 2, 3:
            // ZIP: 全チャンネルをひとつづきに圧縮している(予測ありは行ごと)
            let rest = try r.take(r.count - r.pos)
            let all = try inflate(rest, expected: bpr * height * channels)
            for c in 0..<used {
                var raw = Array(all[(c * bpr * height)..<((c + 1) * bpr * height)])
                if comp == 3 { undoPrediction(&raw, rowBytes: bpr, height: height, depth: depth) }
                var p = [UInt8](repeating: 0, count: width * height)
                decodeRows(raw: raw, rowBytes: bpr, width: width, height: height, depth: depth, into: &p)
                planes.append(p)
            }
        default:
            throw PSDError.unsupported("圧縮方式 \(comp)")
        }
        var map: [Int: [UInt8]] = [0: planes[0], 1: planes[1], 2: planes[2]]
        if planes.count > 3 { map[-1] = planes[3] }
        return PSDRaster(width: width, height: height, rgba: interleave(map, count: width * height))
    }
}

/// 境界を確かめながら読む(足りなければ `PSDError.truncated`)。
struct PSDReader {
    let bytes: [UInt8]
    var pos = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    var count: Int { bytes.count }

    func slice(_ a: Int, _ b: Int) -> [UInt8] { Array(bytes[a..<b]) }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= bytes.count else { throw PSDError.truncated }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }
    mutating func skip(_ n: Int) throws {
        guard n >= 0, pos + n <= bytes.count else { throw PSDError.truncated }
        pos += n
    }
    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> Int { let b = try take(2); return Int(b[0]) << 8 | Int(b[1]) }
    mutating func i16() throws -> Int { let v = try u16(); return v >= 0x8000 ? v - 0x10000 : v }
    mutating func u32() throws -> UInt32 { let b = try take(4); return b.reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func bytes4() throws -> String { String(decoding: try take(4), as: UTF8.self) }
    func peek4() -> String? {
        guard pos + 4 <= bytes.count else { return nil }
        return String(decoding: bytes[pos..<(pos + 4)], as: UTF8.self)
    }
}
