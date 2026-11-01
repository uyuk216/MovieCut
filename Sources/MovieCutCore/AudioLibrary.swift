import Foundation
import AVFoundation

// MARK: - 素材ブラウザ(BGM・効果音のフォルダ参照)

/// 選んだフォルダの直下にある音声ファイルを一覧にする(純粋な判定と並べ替え + 長さの測定)。
/// 対象の拡張子は `ClipEditing.audioExtensions`(タイムラインへの追加と同じ。ここで一覧に出たものは必ず追加できる)。
/// サブフォルダは見ない。隠しファイル・フォルダ・通常のファイルでないものは飛ばす。
/// 開けないファイル(壊れている・読めない)は一覧に残すが `duration` が nil になり、追加はできない。
public enum AudioLibrary {
    public struct Entry: Equatable, Identifiable {
        public let url: URL
        public let name: String
        /// 長さ(秒)。測れなかったら nil(読めないファイル)。
        public let duration: Double?
        public var id: String { url.path }
        public var isReadable: Bool { duration != nil }

        public init(url: URL, name: String, duration: Double?) {
            self.url = url
            self.name = name
            self.duration = duration
        }
    }

    /// 拡張子で音声ファイルかを決める(大文字小文字は問わない)。
    public static func isAudioFileName(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        return ClipEditing.audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 名前の順(自然順: track2 は track10 より前)。同じ名前は元の順を保たない代わりに path で安定させる。
    public static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.url.path < b.url.path
        }
    }

    /// フォルダを読んで一覧にする。フォルダが無い・読めないときは空の一覧。
    public static func scan(folder: URL) async -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [Entry] = []
        for u in urls where isAudioFileName(u.lastPathComponent) {
            // 通常のファイルでないもの(フォルダ・壊れたリンク)は除く
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out.append(Entry(url: u, name: u.lastPathComponent, duration: await probeDuration(u)))
        }
        return sorted(out)
    }

    /// 音声トラックのある長さ(秒)。開けない・音声がない・長さが 0 以下なら nil。
    public static func probeDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let d = try? await asset.load(.duration) else { return nil }
        let s = CMTimeGetSeconds(d)
        return s.isFinite && s > 0 ? s : nil
    }
}
