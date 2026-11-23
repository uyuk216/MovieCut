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
        // ミキサーの展開(複合・シーンの中身 + レイヤーの音量・パンを畳み込んだゲイン)。
        // 最上位の項目の並びと形式は従来のまま保ち(既存のキャッシュが無効にならないように)、
        // 入れ子の中の音・トラックミキサー・チャンネル選択・無効化は、あるときだけ材料に足す。
        let expansion = CompoundEditing.audibleClipsWithTrackMix(in: project)
        var mixById: [String: TrackMixGains] = [:]
        for (c, m) in expansion where mixById[c.id] == nil { mixById[c.id] = m }
        func extras(for c: Clip, mix: TrackMixGains?) -> String {
            var extras = ""
            if let fx = c.audioFx, fx.isActive { extras += "|fx=\(fx.cacheToken)" }
            // VST3 は従来の cacheToken には含めない設計のまま、鍵材料 vst3CacheToken をここで足す
            if let fx = c.audioFx, !fx.vst3CacheToken.isEmpty { extras += "|vst3=\(fx.vst3CacheToken)" }
            if c.hasPan { extras += "|pan=\(c.panOrDefault)" }
            if c.hasDuck, Clip.supportsDuck(c) { extras += "|duck=\(c.duck!.cacheToken)" }
            if c.type == .audio, c.isTreatedAsVoice { extras += "|voice" }   // 声の指定は BGM のダッキングを変えるので鍵に入れる
            if c.hasVolumeKeys { extras += "|vk=" + (c.keyframes["volume"] ?? []).map { "\($0.t):\($0.v):\($0.ease.token)" }.joined(separator: ",") }
            if let mix, !mix.isIdentity { extras += "|mix=\(mix.l),\(mix.r)" }
            if c.channelModeOrDefault != .downmix { extras += "|ch=\(c.channelModeOrDefault.rawValue)" }
            return extras
        }
        func itemLine(for c: Clip, mix: TrackMixGains?) -> String? {
            guard let src = c.src, !src.isEmpty, c.duration > 0, !c.isFreeze else { return nil }
            let date = fileDate(src).map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
            let fade = c.hasAudioFade ? "|fade=\(c.fadeInOrDefault),\(c.fadeOutOrDefault),\(c.fadeCurve ?? "linear")" : ""
            var remap = ""
            if c.hasAudioRemap {
                remap = "|rate=\(c.effectiveSpeed),rev=\(c.effectiveReverse ? 1 : 0)"
                if c.effectiveSpeed != 1 && !c.keepPitchOrDefault { remap += ",pitch=0" }
                if let r = c.rampPoints { remap += "|ramp=" + r.map { "\($0.t):\($0.v):\($0.ease.token)" }.joined(separator: ",") }
            }
            if let vs = c.voiceStretchSpeed { remap += "|vspeed=\(vs)" }
            return "\(c.type.rawValue)|\(src)|\(c.start)|\(c.duration)|\(c.offset)|\(c.volumeOrDefault)|\(date)\(fade)\(remap)\(extras(for: c, mix: mix))"
        }
        var lines: [String] = []
        var topIds = Set<String>()
        for (i, tr) in project.tracks.enumerated() {
            var items: [String] = []
            for c in tr.clips where c.type == .audio || c.type == .voice || c.type == .video {
                // ミキサーが読み飛ばすもの(src なし・長さ 0 以下)は音に関係しない
                guard let src = c.src, !src.isEmpty, c.duration > 0, !c.isFreeze else { continue }   // フリーズフレームは無音
                if c.isMuted { continue }   // クリップ単位の消音は、無いのと同じ(鍵は消音の切り替えで変わる)
                var line = itemLine(for: c, mix: mixById[c.id])
                if line == nil { continue }
                if c.isDisabled { line! += "|disabled" }   // 無効化はミキサーが読み飛ばすので、鍵も変わらなければならない
                topIds.insert(c.id)
                items.append(line!)
            }
            if items.isEmpty { continue }   // 音のないレイヤー(消音や追加を含む)は鍵に影響しない
            items.sort()
            lines.append("T\(i)|muted=\(tr.isMuted ? 1 : 0)" + (tr.isSolo ? "|solo=1" : ""))
            lines.append(contentsOf: items)
        }
        // 複合・シーンの中の音(最上位の項目には現れないもの)も鍵に入れる
        var nested: [String] = []
        for (c, mix) in expansion where !topIds.contains(c.id) && (c.type == .audio || c.type == .voice || c.type == .video) {
            if let line = itemLine(for: c, mix: mix) { nested.append(line) }
        }
        if !nested.isEmpty {
            nested.sort()
            lines.append("NESTED")
            lines.append(contentsOf: nested)
        }
        // ソロがあるときだけ鍵に足す(音のないソロのレイヤーでも、ほかのレイヤーが消えるので)
        let solos = project.tracks.indices.filter { project.tracks[$0].isSolo }
        if !solos.isEmpty { lines.append("SOLO|" + solos.map(String.init).joined(separator: ",")) }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return AudioCacheKey(value: digest.map { String(format: "%02x", $0) }.joined())
    }
}
