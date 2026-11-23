import Foundation
import CoreGraphics
import AVFoundation
import CryptoKit

// プロキシ編集(軽量な 540p の映像コピー)。プレビューの描画だけに使う。
// 書き出しは元の素材を読む(`RenderAssets` が書き出しモードでは差し替えない)。
// 置き場所: Application Support/MovieCut/Proxies。名前は 元のパス・更新日時・サイズ から決まる(素材が変われば別の名前になる)。

public enum ProxyError: Error, LocalizedError, Equatable {
    case noVideoTrack
    case exportFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "映像のない素材はプロキシにできません。"
        case .exportFailed(let m): return "プロキシを作れませんでした: \(m)"
        case .cancelled: return "プロキシの作成をキャンセルしました。"
        }
    }
}

public enum ProxyStore {
    /// 短い辺の上限(540p)。これより小さい素材は大きくしない。
    public static let shortSide: CGFloat = 540

    /// 既定の置き場所(Application Support/MovieCut/Proxies)。
    public static func defaultDirectory() -> URL {
        DataLocations.current.proxies
    }

    /// 元ファイルの指紋から決まる名前(パス・更新日時(ミリ秒)・バイト数)。同じ入力なら同じ名前。
    public static func key(path: String, modified: Date, size: Int64) -> String {
        let ms = Int64((modified.timeIntervalSince1970 * 1000).rounded())
        let text = "\(path)\n\(ms)\n\(size)"
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 元ファイルのプロキシの場所(存在しなくても返す)。ファイルが無ければ nil。
    public static func proxyURL(for source: URL, directory: URL) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        let name = key(path: source.standardizedFileURL.path, modified: modified, size: size)
        return directory.appendingPathComponent(name + ".mp4")
    }

    /// 作成済みのプロキシがあればその場所。無ければ nil。
    public static func existingProxy(for source: URL, directory: URL = defaultDirectory()) -> URL? {
        guard let u = proxyURL(for: source, directory: directory),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// 映像の大きさ(向きを直した後)から、プロキシの大きさを決める。短い辺を 540 に縮め(拡大はしない)、偶数にそろえる。
    public static func outputSize(for displayed: CGSize) -> CGSize {
        let w = displayed.width, h = displayed.height
        guard w > 0, h > 0 else { return CGSize(width: 2, height: 2) }
        let scale = min(1, shortSide / min(w, h))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(w), height: even(h))
    }

    /// プロキシを作る(映像だけ・H.264・mp4)。作成済みならそれを返す。
    /// `progress` は 0〜1。キャンセルは Task のキャンセル(`AVAssetExportSession.cancelExport`)。途中のファイルは残さない。
    public static func make(source: URL, directory: URL = defaultDirectory(),
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        if let done = existingProxy(for: source, directory: directory) { progress(1); return done }
        guard let dest = proxyURL(for: source, directory: directory) else { throw ProxyError.exportFailed("元の素材が読めません") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 作成途中ファイルは生成ごとに一意な名前にする(同じ素材の同時生成で、互いの途中ファイルを消し合わない)。
        let part = dest.deletingPathExtension().appendingPathExtension("part-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: part)

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProxyError.noVideoTrack }
        let transform = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        // 向きを直した後の大きさ
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let displayed = CGSize(width: abs(rect.width), height: abs(rect.height))
        let out = outputSize(for: displayed)

        let comp = AVMutableVideoComposition()
        comp.renderSize = out
        let rate = fps > 0 ? min(60, Int32(fps.rounded())) : 30
        comp.frameDuration = CMTime(value: 1, timescale: max(1, rate))
        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let sx = displayed.width > 0 ? out.width / displayed.width : 1
        let sy = displayed.height > 0 ? out.height / displayed.height : 1
        // 向きを直してから縮める(translation は preferredTransform に含まれる)
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: sx, y: sy)), at: .zero)
        instr.layerInstructions = [layer]
        comp.instructions = [instr]

        guard let session0 = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProxyError.exportFailed("書き出しの設定を作れませんでした")
        }
        nonisolated(unsafe) let session = session0
        session.videoComposition = comp
        session.outputURL = part
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let poll = Task {
            while !Task.isCancelled {
                progress(min(0.99, Double(session.progress)))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poll.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously {
                        switch session.status {
                        case .completed: cont.resume()
                        case .cancelled: cont.resume(throwing: ProxyError.cancelled)
                        default: cont.resume(throwing: ProxyError.exportFailed(session.error?.localizedDescription ?? "不明なエラー"))
                        }
                    }
                }
            } onCancel: {
                session.cancelExport()
            }
        } catch {
            try? FileManager.default.removeItem(at: part)
            if Task.isCancelled { throw ProxyError.cancelled }
            throw (error as? ProxyError) ?? ProxyError.exportFailed(error.localizedDescription)
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: part)
            throw ProxyError.cancelled
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
        progress(1)
        return dest
    }
}

/// 複数の素材をまとめて作った結果。`failed` は素材ごとの理由(存在しない・映像なし・書き出し失敗)。
public struct ProxyBatchResult: Equatable, Sendable {
    public var made: [URL] = []
    public var failed: [(source: URL, reason: String)] = []
    public static func == (a: ProxyBatchResult, b: ProxyBatchResult) -> Bool {
        a.made == b.made && a.failed.map(\.source) == b.failed.map(\.source) && a.failed.map(\.reason) == b.failed.map(\.reason)
    }
}

extension ProxyStore {
    /// 素材を順に作る。1 件の失敗(存在しない・映像なし・書き出しの失敗)で止めず、残りを作って失敗を数える。
    /// キャンセル(Task のキャンセル・`ProxyError.cancelled`)だけは全体を止めて投げる。
    public static func makeAll(sources: [URL], directory: URL = defaultDirectory(),
                               progress: @escaping @Sendable (Int, Int, Double) -> Void = { _, _, _ in }) async throws -> ProxyBatchResult {
        var result = ProxyBatchResult()
        for (i, src) in sources.enumerated() {
            try Task.checkCancellation()
            do {
                let url = try await make(source: src, directory: directory) { v in progress(i + 1, sources.count, v) }
                result.made.append(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch ProxyError.cancelled {
                throw ProxyError.cancelled
            } catch {
                result.failed.append((src, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        return result
    }
}

/// プレビューでプロキシを使うかどうかの設定(アプリ全体。UserDefaults)。既定はオフ。
public enum ProxySettings {
    public static let key = "previewProxyEnabled"
    public static let didChange = Notification.Name("MovieCut.previewProxyDidChange")

    public static func enabled(_ d: UserDefaults = DataLocations.current.defaults) -> Bool { d.bool(forKey: key) }

    public static func set(_ on: Bool, _ d: UserDefaults = DataLocations.current.defaults) {
        d.set(on, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

extension ProxyStore {
    /// 生成済みのプロキシだけを消す。素材・外部ファイルには触らない。消したら true(素材が読めない・プロキシが無いときは false)。
    @discardableResult
    public static func deleteProxy(for source: URL, directory: URL = defaultDirectory()) -> Bool {
        guard let u = existingProxy(for: source, directory: directory) else { return false }
        return (try? FileManager.default.removeItem(at: u)) != nil
    }

    /// 複数の素材の生成済みプロキシを消し、消せた件数を返す。
    @discardableResult
    public static func deleteProxies(for sources: [URL], directory: URL = defaultDirectory()) -> Int {
        sources.reduce(0) { $0 + (deleteProxy(for: $1, directory: directory) ? 1 : 0) }
    }

    /// 置き場所にあるプロキシのファイル(*.mp4。作成途中の *.part.mp4 は除く)。フォルダが無ければ []。
    public static func listProxyFiles(in directory: URL = defaultDirectory()) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "mp4" && !$0.lastPathComponent.lowercased().hasSuffix(".part.mp4") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// プロキシのファイルの合計バイト数。
    public static func totalBytes(in directory: URL = defaultDirectory()) -> Int64 {
        listProxyFiles(in: directory).reduce(Int64(0)) { sum, u in
            let n = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber
            return sum + (n?.int64Value ?? 0)
        }
    }

    /// 映像の表示上の大きさ(preferredTransform を適用した後)。読めなければ nil。自動作成の要否判定に使う。
    public static func displayedSize(source: URL) async -> CGSize? {
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let transform = try? await track.load(.preferredTransform),
              let natural = try? await track.load(.naturalSize) else { return nil }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(rect.width), height: abs(rect.height))
        return size.width > 0 && size.height > 0 ? size : nil
    }
}

extension ProxySettings {
    /// 取り込み時にプロキシを自動で作るか(既定オフ)。重い変換を勝手に始めず、プレビュー設定がオンのときだけ効くプロキシの未使用ファイルを作らないため。
    public static let autoCreateKey = "proxyAutoCreateEnabled"

    public static func autoCreateEnabled(_ d: UserDefaults = DataLocations.current.defaults) -> Bool { d.bool(forKey: autoCreateKey) }

    public static func setAutoCreate(_ on: Bool, _ d: UserDefaults = DataLocations.current.defaults) {
        d.set(on, forKey: autoCreateKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
