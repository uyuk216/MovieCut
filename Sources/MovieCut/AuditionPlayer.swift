import Foundation
import AVFoundation

/// 試聴(重なったクリップの音だけ)の短い音の出口。差し替えてテストできる。
@MainActor
protocol AuditionPlaying: AnyObject {
    /// 音声ファイルを頭から鳴らす(鳴っているものは止めて置き換える)。
    func play(url: URL)
    func stop()
}

/// AVAudioPlayer で鳴らす(全体の再生とは別のプレイヤー。試聴中は全体の再生は止まっている)。
@MainActor
final class AVAuditionPlayer: AuditionPlaying {
    private var player: AVAudioPlayer?

    func play(url: URL) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
