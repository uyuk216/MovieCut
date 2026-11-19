import XCTest
import AVFoundation
import CoreAudio
@testable import MovieCutCore

final class MultichannelProbe2Tests: XCTestCase {
    static func descs(of lay: UnsafePointer<AudioChannelLayout>) -> [AudioChannelDescription] {
        var out: [AudioChannelDescription] = []
        let raw = UnsafeRawPointer(lay)
        for i in 0..<Int(lay.pointee.mNumberChannelDescriptions) {
            out.append(raw.load(fromByteOffset: 16 + i * MemoryLayout<AudioChannelDescription>.stride, as: AudioChannelDescription.self))
        }
        return out
    }
    func dumpDescriptions(tag: AudioChannelLayoutTag, bitmap: AudioChannelBitmap, descs: [AudioChannelDescription]) {
        print("PROBE2 tag=0x\(String(tag, radix: 16)) bitmap=0x\(String(bitmap.rawValue, radix: 16)) nDesc=\(descs.count)")
        for (i, d) in descs.enumerated() {
            print("PROBE2   desc[\(i)] label=0x\(String(d.mChannelLabel, radix: 16)) (\(d.mChannelLabel)) flags=0x\(String(d.mChannelFlags.rawValue, radix: 16))")
        }
    }
    func dumpAVLayout(_ fmt: AVAudioFormat, label: String) {
        guard let cl = fmt.channelLayout else { print("PROBE2 \(label): ch=\(fmt.channelCount) no-layout"); return }
        print("PROBE2 \(label): ch=\(fmt.channelCount) sr=\(fmt.sampleRate)")
        dumpDescriptions(tag: cl.layoutTag, bitmap: cl.layout.pointee.mChannelBitmap, descs: Self.descs(of: cl.layout))
    }
    func testProbeLayouts() {
        for path in ["/tmp/mc-probe51.wav", "/tmp/mc-probe71.wav"] {
            print("PROBE2 === \(path)")
            if let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
                dumpAVLayout(f.processingFormat, label: "processing")
                dumpAVLayout(f.fileFormat, label: "file")
            } else { print("PROBE2 cannot open \(path)") }
        }
        let path = "/tmp/mc-probe51.mp4"
        print("PROBE2 === \(path)")
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .audio).first else { print("PROBE2 no track"); return }
        for fdAny in track.formatDescriptions {
            let fd = fdAny as! CMAudioFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                print("PROBE2 track ASBD ch=\(asbd.pointee.mChannelsPerFrame) sr=\(asbd.pointee.mSampleRate)")
            }
            var size = 0
            if let ptr = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &size) {
                let lay = ptr.pointee
                var descs: [AudioChannelDescription] = []
                if lay.mNumberChannelDescriptions > 0 {
                    let raw = UnsafeRawPointer(ptr)
                    for i in 0..<Int(lay.mNumberChannelDescriptions) {
                        descs.append(raw.load(fromByteOffset: 16 + i * MemoryLayout<AudioChannelDescription>.stride, as: AudioChannelDescription.self))
                    }
                }
                dumpDescriptions(tag: lay.mChannelLayoutTag, bitmap: lay.mChannelBitmap, descs: descs)
            } else { print("PROBE2 track no layout size=\(size)") }
        }
        for reqCh in [2, 6, 0] {
            guard let reader = try? AVAssetReader(asset: asset) else { continue }
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000.0,
            ]
            if reqCh > 0 { settings[AVNumberOfChannelsKey] = reqCh }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(out)
            guard reader.startReading(), let sb = out.copyNextSampleBuffer() else { print("PROBE2 reader req=\(reqCh) failed \(String(describing: reader.error))"); continue }
            if let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                print("PROBE2 reader req=\(reqCh) sample ASBD ch=\(asbd.pointee.mChannelsPerFrame) bytesPerFrame=\(asbd.pointee.mBytesPerFrame) numSamples=\(CMSampleBufferGetNumSamples(sb))")
                var sz = 0
                if let lp = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &sz) {
                    print("PROBE2 reader req=\(reqCh) sample layout tag=0x\(String(lp.pointee.mChannelLayoutTag, radix: 16)) bitmap=0x\(String(lp.pointee.mChannelBitmap.rawValue, radix: 16)) nDesc=\(lp.pointee.mNumberChannelDescriptions)")
                }
            }
            if let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb)
                var data = [Float](repeating: 0, count: len / 4)
                data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                print("PROBE2 reader req=\(reqCh) first 18 floats: \(data.prefix(18).map { String(format: "%.3f", $0) }.joined(separator: " "))")
            }
        }
    }
}
