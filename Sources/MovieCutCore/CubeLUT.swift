import Foundation
import CoreImage

/// .cube 形式の LUT(1D / 3D)。純粋な読み取りだけを持ち、壊れた入力は throw で安全に断る。
public struct CubeLUT: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case d1, d3 }
    public enum ParseError: Error, Equatable {
        case empty, tooLarge, noSize, badSize, dataCountMismatch, badNumber, badDomain
    }

    public var title: String?
    public var kind: Kind
    public var size: Int
    public var domainMin: [Float]
    public var domainMax: [Float]
    /// R,G,B の並び(3D は赤が最も速く変わる順 = .cube の規約)。
    public var table: [Float]

    /// 3D の 1 辺の上限 / 1D の点数の上限 / 読み込むファイルの上限(バイト)。
    public static let max3DSize = 65
    public static let max1DSize = 65536
    public static let maxFileBytes = 48 * 1024 * 1024
    /// 1D を 3D に変換するときの 1 辺。
    static let cubeSizeFor1D = 33

    public var hasCustomDomain: Bool { domainMin != [0, 0, 0] || domainMax != [1, 1, 1] }

    // MARK: 読み取り

    public static func parse(_ text: String) throws -> CubeLUT {
        guard !text.isEmpty else { throw ParseError.empty }
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard text.utf8.count <= maxFileBytes else { throw ParseError.tooLarge }
        var title: String?
        var size1 = 0, size3 = 0
        var dmin: [Float] = [0, 0, 0], dmax: [Float] = [1, 1, 1]
        var values: [Float] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = Substring(rawLine)
            if let h = line.firstIndex(of: "#") { line = line[line.startIndex..<h] }
            line = line.drop(while: { $0 == " " || $0 == "\t" })
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            if let first = head.first, first.isLetter {
                // キーワード行
                switch head.uppercased() {
                case "TITLE":
                    title = line.dropFirst(head.count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "LUT_1D_SIZE":
                    guard parts.count >= 2, let n = Int(parts[1]), n >= 2, n <= max1DSize else { throw ParseError.badSize }
                    size1 = n
                case "LUT_3D_SIZE":
                    guard parts.count >= 2, let n = Int(parts[1]), n >= 2, n <= max3DSize else { throw ParseError.badSize }
                    size3 = n
                case "DOMAIN_MIN":
                    dmin = try triple(parts, skip: 1)
                case "DOMAIN_MAX":
                    dmax = try triple(parts, skip: 1)
                default:
                    continue // LUT_1D_INPUT_RANGE などは無視
                }
            } else {
                let t = try triple(parts, skip: 0)
                values.append(contentsOf: t)
                if values.count > max(max1DSize, max3DSize * max3DSize * max3DSize) * 3 { throw ParseError.tooLarge }
            }
        }
        if size1 > 0 && size3 > 0 { throw ParseError.badSize }
        guard size1 > 0 || size3 > 0 else { throw ParseError.noSize }
        let kind: Kind = size3 > 0 ? .d3 : .d1
        let n = size3 > 0 ? size3 : size1
        let expected = (kind == .d3 ? n * n * n : n) * 3
        guard values.count == expected else { throw ParseError.dataCountMismatch }
        for i in 0..<3 where !(dmax[i] > dmin[i]) { throw ParseError.badDomain }
        return CubeLUT(title: title, kind: kind, size: n, domainMin: dmin, domainMax: dmax, table: values)
    }

    private static func triple(_ parts: [Substring], skip: Int) throws -> [Float] {
        guard parts.count == skip + 3 else { throw ParseError.badNumber }
        var out: [Float] = []
        for s in parts.dropFirst(skip) {
            guard let v = Float(s), v.isFinite else { throw ParseError.badNumber }
            out.append(v)
        }
        return out
    }

    public static func load(from url: URL) throws -> CubeLUT {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let sz = attrs?[.size] as? NSNumber, sz.intValue > maxFileBytes { throw ParseError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileBytes, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw ParseError.badNumber }
        return try parse(text)
    }

    // MARK: Core Image 用の立方体

    /// CIColorCube 用の (1 辺, RGBA float の Data)。1D は 3 チャンネル独立の補間で 3D にする。
    /// 入力の範囲(DOMAIN)は含めない(`domainScale` で別に正規化する)。
    public func cubeData() -> (dimension: Int, data: Data) {
        switch kind {
        case .d3:
            var out = [Float](); out.reserveCapacity(size * size * size * 4)
            for i in 0..<(size * size * size) {
                out.append(table[i * 3]); out.append(table[i * 3 + 1]); out.append(table[i * 3 + 2]); out.append(1)
            }
            return (size, out.withUnsafeBufferPointer { Data(buffer: $0) })
        case .d1:
            let n = Self.cubeSizeFor1D
            var out = [Float](); out.reserveCapacity(n * n * n * 4)
            // 1D の点は domain 内の等間隔。入力 0..1 を正規化値として扱う
            func sample(_ ch: Int, _ x: Float) -> Float {
                let pos = min(max(x, 0), 1) * Float(size - 1)
                let i0 = Int(pos.rounded(.down)), i1 = min(size - 1, i0 + 1)
                let f = pos - Float(i0)
                return table[i0 * 3 + ch] * (1 - f) + table[i1 * 3 + ch] * f
            }
            let tab = (0..<3).map { ch in (0..<n).map { sample(ch, Float($0) / Float(n - 1)) } }
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                out.append(tab[0][r]); out.append(tab[1][g]); out.append(tab[2][b]); out.append(1)
            } } }
            return (n, out.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }

    /// 画素に直接かける(テスト・確認用の参照実装)。入力は 0..1 の RGB。三線形補間。
    public func sample(_ rgb: [Float]) -> [Float] {
        var t = [Float](repeating: 0, count: 3)
        for c in 0..<3 { t[c] = min(max((rgb[c] - domainMin[c]) / (domainMax[c] - domainMin[c]), 0), 1) }
        switch kind {
        case .d1:
            return (0..<3).map { ch in
                let pos = t[ch] * Float(size - 1)
                let i0 = Int(pos.rounded(.down)), i1 = min(size - 1, i0 + 1)
                let f = pos - Float(i0)
                return table[i0 * 3 + ch] * (1 - f) + table[i1 * 3 + ch] * f
            }
        case .d3:
            let m = Float(size - 1)
            let p = t.map { $0 * m }
            let i0 = p.map { Int($0.rounded(.down)) }
            let i1 = i0.map { min(size - 1, $0 + 1) }
            let f = (0..<3).map { p[$0] - Float(i0[$0]) }
            func at(_ r: Int, _ g: Int, _ b: Int) -> [Float] { let k = (b * size + g) * size + r; return [table[k * 3], table[k * 3 + 1], table[k * 3 + 2]] }
            var out = [Float](repeating: 0, count: 3)
            for db in 0...1 { for dg in 0...1 { for dr in 0...1 {
                let w = (dr == 0 ? 1 - f[0] : f[0]) * (dg == 0 ? 1 - f[1] : f[1]) * (db == 0 ? 1 - f[2] : f[2])
                let v = at(dr == 0 ? i0[0] : i1[0], dg == 0 ? i0[1] : i1[1], db == 0 ? i0[2] : i1[2])
                for c in 0..<3 { out[c] += w * v[c] }
            } } }
            return out
        }
    }
}

/// 読み込んだ LUT の置き場(パス + 更新日時 + サイズで見分ける。壊れたファイルも覚えて、毎フレーム読み直さない)。
public final class LUTCache: @unchecked Sendable {
    public static let shared = LUTCache()
    struct Key: Hashable { var path: String; var mtime: Double; var size: Int }
    private let lock = NSLock()
    private var luts: [Key: CubeLUT?] = [:]
    private var cubes: [Key: (Int, Data)] = [:]

    private func key(_ path: String) -> Key? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Key(path: path, mtime: m, size: (a[.size] as? NSNumber)?.intValue ?? 0)
    }

    /// 読めたら LUT。無い・壊れているときは nil。
    public func lut(atPath path: String) -> CubeLUT? {
        guard let k = key(path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = luts[k] { return hit }
        let l = try? CubeLUT.load(from: URL(fileURLWithPath: path))
        if luts.count > 16 { luts.removeAll(); cubes.removeAll() }
        luts[k] = .some(l)
        if let l { cubes[k] = l.cubeData() }
        return l
    }

    func cube(atPath path: String) -> (lut: CubeLUT, dimension: Int, data: Data)? {
        guard let l = lut(atPath: path), let k = key(path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let c = cubes[k] else { return nil }
        return (l, c.0, c.1)
    }

    /// そのパスのファイルが LUT として読めるか(インスペクタの表示用)。
    public func status(atPath path: String) -> Status {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        return lut(atPath: path) == nil ? .invalid : .ok
    }
    public enum Status: Equatable, Sendable { case ok, missing, invalid }
}
