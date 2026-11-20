import Foundation
import AVFoundation
import CoreMedia
import CoreAudio

// MARK: - 5.1 書き出しの部品(改善ラウンド5 Phase B)
//
// 設計の全文は docs/マルチチャンネル音声.md「5.1 書き出し」。
// 中間形式(`AudioMixer.mixdownSurround51` の出力)は canonical 順 L R C LFE Ls Rs(MPEG_5_1_A)。
// AAC エンコーダが確実に受けるのは AAC 5.1 レイアウト(C L R Ls Rs LFE = `kAudioChannelLayoutTag_AAC_5_1`。
// Mp4AAC51ExportTests が実測で使っているタグ)なので、エンコード直前にサンプルをその並びへ入れ替え、
// 形式記述にも AAC_5_1 のレイアウトを付けて渡す(AVFoundation の自動並べ替えに頼らず、並びとラベルを両方そろえる)。

/// `AudioChannelLayout` をそのまま `Data` にしたもの(`AVChannelLayoutKey` 用)。
enum Surround51Layout {
    static func data(tag: AudioChannelLayoutTag) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        layout.mNumberChannelDescriptions = 0
        return withUnsafeBytes(of: &layout) { Data($0) }
    }
}

enum Surround51AAC {
    /// AAC 5.1 の並び(C L R Ls Rs LFE)の c 番目が、canonical 順(L R C LFE Ls Rs)の何番目か。
    static let canonicalIndexForAAC: [Int] = [2, 0, 1, 4, 5, 3]
    static let bitRate = 384_000

    /// 6ch AAC の書き出し設定(mp4 / m4a 共通)。
    static var writerSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 6,
            AVEncoderBitRateKey: bitRate,
            AVChannelLayoutKey: Surround51Layout.data(tag: kAudioChannelLayoutTag_AAC_5_1),
        ]
    }

    /// 中間ファイル(canonical 順 6ch)を読む設定。レイアウトを MPEG_5_1_A に指定して、読み出し側が
    /// どんな並びで返しても canonical 順にそろえる(中間ファイル自体がその並びなので通常は恒等)。
    static var readerSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 6,
            AVChannelLayoutKey: Surround51Layout.data(tag: kAudioChannelLayoutTag_MPEG_5_1_A),
        ]
    }

    /// AAC_5_1 レイアウトつきの 6ch Float32 インターリーブの形式記述(並べ替え後のサンプル用)。
    static func makeFormatDescription() -> CMAudioFormatDescription? {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_AAC_5_1
        layout.mNumberChannelDescriptions = 0
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 24, mFramesPerPacket: 1,
            mBytesPerFrame: 24, mChannelsPerFrame: 6, mBitsPerChannel: 32, mReserved: 0)
        var out: CMAudioFormatDescription?
        let size = MemoryLayout<AudioChannelLayout>.size
        let st = withUnsafePointer(to: &layout) { lp in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: size, layout: lp,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &out)
        }
        return st == noErr ? out : nil
    }

    /// canonical 順(インターリーブ 6ch Float32)のサンプルバッファを、AAC 5.1 の並びに入れ替えた新しいバッファにする。
    /// 空のバッファはそのまま返す。形が想定外(6ch Float32 インターリーブでない)のときは nil。
    static func reordered(_ sb: CMSampleBuffer, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let frames = CMSampleBufferGetNumSamples(sb)
        if frames == 0 { return sb }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let bytes = CMBlockBufferGetDataLength(bb)
        guard bytes == frames * 24 else { return nil }
        var src = [Float](repeating: 0, count: frames * 6)
        let copied = src.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var dst = [Float](repeating: 0, count: frames * 6)
        for i in 0..<frames {
            for c in 0..<6 { dst[i * 6 + c] = src[i * 6 + canonicalIndexForAAC[c]] }
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let replaced = dst.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard replaced == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                           sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: [24], sampleBufferOut: &out)
        return st == noErr ? out : nil
    }
}
