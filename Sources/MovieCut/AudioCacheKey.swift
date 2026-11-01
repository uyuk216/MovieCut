import Foundation
import CryptoKit
import MovieCutCore

/// 再生用にミックスした音声(CAF)の「どのプロジェクトのものか」を表す鍵。
/// 音に関係する項目(audio / voice / video クリップの src・開始・長さ・オフセット・音量・速度・逆再生、レイヤーの消音、
/// 素材ファイルの更新日時、音声エフェクト・パン・音量のキー)だけから作る。文字の色や位置、隠すなどを変えても変わらない。
struct AudioCacheKey: Hashable {
    let value: String

    static func defaultFileDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    static func make(for project: Project, fileDate: (String) -> Date? = AudioCacheKey.defaultFileDate) -> AudioCacheKey {
        var lines: [String] = []
        for (i, tr) in project.tracks.enumerated() {
            var items: [String] = []
            for c in tr.clips where c.type == .audio || c.type == .voice || c.type == .video {
                // ミキサーが読み飛ばすもの(src なし・長さ 0 以下)は音に関係しない
                guard let src = c.src, !src.isEmpty, c.duration > 0, !c.isFreeze else { continue }   // フリーズフレームは無音
                let date = fileDate(src).map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
                // フェードがあるときだけ鍵に足す(無いプロジェクトの鍵は従来と同じ)
                let fade = c.hasAudioFade ? "|fade=\(c.fadeInOrDefault),\(c.fadeOutOrDefault),\(c.fadeCurve ?? "linear")" : ""
                // 速度・逆再生・音程を保たない、のときだけ鍵に足す(どれも無いクリップの鍵は従来と同じ)
                var remap = ""
                if c.hasAudioRemap {
                    remap = "|rate=\(c.effectiveSpeed),rev=\(c.effectiveReverse ? 1 : 0)"
                    if c.effectiveSpeed != 1 && !c.keepPitchOrDefault { remap += ",pitch=0" }
                    if let r = c.rampPoints { remap += "|ramp=" + r.map { "\($0.t):\($0.v)" }.joined(separator: ",") }   // 速度ランプの点(あるときだけ)
                }
                // 音声エフェクト・パン・音量のキーも、あるときだけ鍵に足す(どれも無いクリップの鍵は従来と同じ)
                var extras = ""
                if let fx = c.audioFx, fx.isActive { extras += "|fx=\(fx.cacheToken)" }
                if c.hasPan { extras += "|pan=\(c.panOrDefault)" }
                if c.hasDuck, Clip.supportsDuck(c) { extras += "|duck=\(c.duck!.cacheToken)" }
                if c.hasVolumeKeys { extras += "|vk=" + (c.keyframes["volume"] ?? []).map { "\($0.t):\($0.v):\($0.ease.token)" }.joined(separator: ",") }
                items.append("\(c.type.rawValue)|\(src)|\(c.start)|\(c.duration)|\(c.offset)|\(c.volumeOrDefault)|\(date)\(fade)\(remap)\(extras)")
            }
            if items.isEmpty { continue }   // 音のないレイヤー(消音や追加を含む)は鍵に影響しない
            items.sort()
            lines.append("T\(i)|muted=\(tr.isMuted ? 1 : 0)" + (tr.isSolo ? "|solo=1" : ""))
            lines.append(contentsOf: items)
        }
        // ソロがあるときだけ鍵に足す(音のないソロのレイヤーでも、ほかのレイヤーが消えるので)
        let solos = project.tracks.indices.filter { project.tracks[$0].isSolo }
        if !solos.isEmpty { lines.append("SOLO|" + solos.map(String.init).joined(separator: ",")) }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return AudioCacheKey(value: digest.map { String(format: "%02x", $0) }.joined())
    }
}
