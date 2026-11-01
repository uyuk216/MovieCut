import Foundation

/// ユーザーが保存した書き出しプリセット(Application Support の JSON)。
/// 読むときは何が書いてあっても落ちない: 壊れた項目・範囲外の値・組み込みと同じ名前は、その項目だけ捨てる(または既定にする)。
public struct CustomExportPreset: Equatable, Sendable {
    public static let maxCount = 50
    public static let maxNameLength = 40

    public var name: String
    public var width: Int
    public var height: Int
    public var codec: String
    /// nil ならプロジェクトのまま。
    public var fps: Double?
    /// nil なら解像度から決まる既定値。
    public var bitrateMbps: Double?

    public init(name: String, width: Int, height: Int, codec: String, fps: Double? = nil, bitrateMbps: Double? = nil) {
        self.name = name; self.width = width; self.height = height; self.codec = codec; self.fps = fps; self.bitrateMbps = bitrateMbps
    }

    public var spec: ExportSpec {
        ExportSpec(name: name, stem: name, width: width, height: height, codec: codec,
                   fps: fps.map { ExportFPS.fixed($0) } ?? .keep, bitrateMbps: bitrateMbps)
    }

    /// 名前として使えるか(空でない・長すぎない・ファイル名に使えない記号がない・組み込みと同じでない)。
    public static func isValidName(_ raw: String) -> Bool {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= maxNameLength else { return false }
        if n.contains(where: { "/:\\\n\r\t".contains($0) }) { return false }
        if ExportPreset.allCases.contains(where: { $0.rawValue.caseInsensitiveCompare(n) == .orderedSame }) { return false }
        return true
    }

    /// 解像度として使えるか(偶数で、範囲内)。
    public static func isValidSide(_ v: Int) -> Bool { ExportSpec.sideRange.contains(v) && v % 2 == 0 }
}

/// 保存・読み込み。ファイルは `{"version":1,"presets":[...]}`。読み込みは寛容に、書き出しは決まった形で。
public enum CustomExportPresetStore {
    public static let fileName = "export-presets.json"

    /// 既定の保存先: ~/Library/Application Support/MovieCut/export-presets.json
    public static func defaultURL() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("MovieCut", isDirectory: true).appendingPathComponent(fileName)
    }

    /// JSON から読む。形が違えば空。項目ごとに検査し、通らないものは捨てる。同じ名前は先に出た方だけ残す。
    public static func decode(_ data: Data) -> [CustomExportPreset] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        let items: [Any]
        if let arr = root as? [Any] { items = arr }
        else if let dict = root as? [String: Any], let arr = dict["presets"] as? [Any] { items = arr }
        else { return [] }
        var out: [CustomExportPreset] = []
        var seen = Set<String>()
        for item in items {
            guard out.count < CustomExportPreset.maxCount, let d = item as? [String: Any] else { continue }
            guard let rawName = d["name"] as? String, CustomExportPreset.isValidName(rawName) else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seen.contains(name.lowercased()) else { continue }
            guard let w = int(d["width"]), let h = int(d["height"]),
                  CustomExportPreset.isValidSide(w), CustomExportPreset.isValidSide(h) else { continue }
            guard let codec = (d["codec"] as? String)?.lowercased(), ["h264", "hevc"].contains(codec) else { continue }
            let fps: Double? = {
                guard let v = number(d["fps"]), v.isFinite, (1...240).contains(v) else { return nil }
                return v
            }()
            let mbps = ExportSpec.validBitrate(number(d["bitrateMbps"]))
            seen.insert(name.lowercased())
            out.append(CustomExportPreset(name: name, width: w, height: h, codec: codec, fps: fps, bitrateMbps: mbps))
        }
        return out
    }

    /// 書き出し用の JSON。任意の項目は、値があるときだけ書く。
    public static func encode(_ presets: [CustomExportPreset]) -> Data {
        var items: [[String: Any]] = []
        for p in presets.prefix(CustomExportPreset.maxCount) {
            var d: [String: Any] = ["name": p.name, "width": p.width, "height": p.height, "codec": p.codec]
            if let f = p.fps { d["fps"] = f }
            if let b = p.bitrateMbps { d["bitrateMbps"] = b }
            items.append(d)
        }
        let root: [String: Any] = ["version": 1, "presets": items]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
    }

    /// 読み込み。ファイルが無い・壊れている・読めないときは空。
    public static func load(from url: URL?) -> [CustomExportPreset] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    /// 保存(一時ファイルを経由して置き換える)。
    public static func save(_ presets: [CustomExportPreset], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(presets).write(to: url, options: .atomic)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, !(n is Bool) { return n.doubleValue }
        return nil
    }
    private static func int(_ v: Any?) -> Int? {
        guard let d = number(v), d.isFinite, d == d.rounded(), abs(d) < 100_000 else { return nil }
        return Int(d)
    }
}

extension CustomExportPresetStore {
    /// 同じ名前(大文字小文字は問わない)があれば置き換え、無ければ末尾に足す。上限を超えるときは nil。
    public static func upserting(_ preset: CustomExportPreset, into list: [CustomExportPreset]) -> [CustomExportPreset]? {
        var out = list
        if let i = out.firstIndex(where: { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) {
            out[i] = preset
        } else {
            guard out.count < CustomExportPreset.maxCount else { return nil }
            out.append(preset)
        }
        return out
    }
}
