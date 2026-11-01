import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// QR コードの画像(PNG)。Core Image の CIQRCodeGenerator を使う(外部ライブラリなし)。白地に黒の正方形。
public enum QRCode {
    public static let maxTextLength = 300
    public static let defaultSide = 800

    /// 文字から QR コードの PNG を作る。空・長すぎる文字は nil。`side` は画素数(一辺)。
    public static func pngData(text: String, side: Int = defaultSide) -> Data? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxTextLength, side >= 64 else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(t.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage, out.extent.width > 0 else { return nil }
        let scale = CGFloat(side) / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        // 透明な部分を白で埋める(書き出しの背景に依らず読めるように)
        let w = Int(scaled.extent.width.rounded()), h = Int(scaled.extent.height.rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 作った QR コードを読み直す(検証用。CIDetector)。
    public static func readBack(pngData: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil) else { return nil }
        let features = detector.features(in: CIImage(cgImage: cg))
        return (features.first as? CIQRCodeFeature)?.messageString
    }
}
