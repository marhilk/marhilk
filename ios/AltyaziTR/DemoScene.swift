import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Örnek kipi için oyun benzeri kareler üretir: PS5 ve televizyon olmadan uygulamanın ne yaptığını gösterir.
///
/// Sahne tamamen burada çizilir (hiçbir oyundan görüntü içermez): bir manzara, altta İngilizce altyazı,
/// sol üstte bir ipucu kutusu. Kareler gerçek okuma ve çeviri hattına verilir; yani ekranda görülen
/// çeviri, uygulamanın gerçekten yaptığı iştir.
final class DemoScene {
    struct Line {
        let speaker: String
        let text: String
    }

    static let width = 1280
    static let height = 720

    /// Sırayla gösterilen replikler (özgün; hiçbir oyundan alınmadı).
    static let script: [Line] = [
        Line(speaker: "Reyes", text: "We need to cross the bridge before sunrise."),
        Line(speaker: "Nova", text: "The bridge is guarded. There must be another way."),
        Line(speaker: "Reyes", text: "Then we take the old tunnel under the river."),
        Line(speaker: "Nova", text: "Stay close and keep your light off."),
        Line(speaker: "Reyes", text: "Did you hear that? Someone is following us."),
        Line(speaker: "Nova", text: "Run to the gate. I will hold them here."),
    ]
    static let hints = ["Hold to take cover behind the wall.", "Follow Nova to the old tunnel."]

    /// Örnek sahnedeki yazıların hazır çevirileri. Telefonda Türkçe çeviri dili yoksa (ör. uygulamayı
    /// inceleyen kişinin cihazında) örnek yine çevirisiyle görünür. Dil varsa gerçek çeviri kullanılır.
    static let translations: [(source: String, turkish: String)] = [
        ("We need to cross the bridge before sunrise.", "Gün doğmadan köprüyü geçmemiz gerek."),
        ("The bridge is guarded. There must be another way.", "Köprü tutulmuş. Başka bir yol olmalı."),
        ("Then we take the old tunnel under the river.", "O zaman nehrin altındaki eski tünelden geçeriz."),
        ("Stay close and keep your light off.", "Yakınımda kal ve ışığını kapalı tut."),
        ("Did you hear that? Someone is following us.", "Duydun mu? Biri bizi takip ediyor."),
        ("Run to the gate. I will hold them here.", "Kapıya koş. Onları burada oyalarım."),
        ("Hold [1] to take cover behind the wall.", "Duvarın arkasına siper almak için [1] tuşunu basılı tut."),
        ("Hold to take cover behind the wall.", "Duvarın arkasına siper almak için tuşu basılı tut."),
        ("Follow Nova to the old tunnel.", "Nova'yı eski tünele kadar takip et."),
    ]

    /// Okunan yazıya karşılık gelen hazır çeviri (okuma küçük farklarla gelebilir: harfler karşılaştırılır).
    static func translation(for text: String) -> String? {
        func letters(_ value: String) -> String { String(value.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let wanted = letters(text)
        guard wanted.count >= 6 else { return nil }
        return translations.first { letters($0.source) == wanted }?.turkish
    }

    /// Her replik bu kadar saniye ekranda kalır, ardından kısa bir boşluk gelir.
    static let lineDuration = 3.4
    static let gap = 0.7

    /// Verilen ana ait kare. `time`: örnek başladığından beri geçen saniye.
    func frame(at time: TimeInterval) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                                           kCVPixelBufferCGImageCompatibilityKey: true,
                                           kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, Self.width, Self.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Self.width, height: Self.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        drawLandscape(in: context, time: time)

        let cycle = Self.lineDuration + Self.gap
        let index = Int(time / cycle) % Self.script.count
        if time.truncatingRemainder(dividingBy: cycle) < Self.lineDuration {
            drawSubtitle(Self.script[index], in: context)
        }
        // İpucu kutusu her iki replikte bir değişir ve arada bir kaybolur.
        let hintIndex = Int(time / (cycle * 2)) % (Self.hints.count + 1)
        if hintIndex < Self.hints.count { drawHint(Self.hints[hintIndex], in: context) }
        return buffer
    }

    // MARK: - Çizim (CoreGraphics: başlangıç sol alt)

    private func drawLandscape(in context: CGContext, time: TimeInterval) {
        let w = CGFloat(Self.width), h = CGFloat(Self.height)
        let colors = [CGColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1), CGColor(red: 0.22, green: 0.2, blue: 0.36, alpha: 1),
                      CGColor(red: 0.62, green: 0.36, blue: 0.3, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.3), options: [])
        }
        // Ay
        context.setFillColor(CGColor(red: 0.95, green: 0.92, blue: 0.8, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: w * 0.72, y: h * 0.66, width: 70, height: 70))
        // Uzak ve yakın tepeler
        func hills(_ points: [CGPoint], _ color: CGColor) {
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: 0))
            points.forEach { context.addLine(to: $0) }
            context.addLine(to: CGPoint(x: w, y: 0))
            context.closePath()
            context.setFillColor(color)
            context.fillPath()
        }
        hills([CGPoint(x: 0, y: h * 0.42), CGPoint(x: w * 0.18, y: h * 0.56), CGPoint(x: w * 0.36, y: h * 0.44),
               CGPoint(x: w * 0.58, y: h * 0.6), CGPoint(x: w * 0.8, y: h * 0.46), CGPoint(x: w, y: h * 0.54)],
              CGColor(red: 0.12, green: 0.13, blue: 0.24, alpha: 1))
        hills([CGPoint(x: 0, y: h * 0.3), CGPoint(x: w * 0.25, y: h * 0.38), CGPoint(x: w * 0.5, y: h * 0.28),
               CGPoint(x: w * 0.75, y: h * 0.4), CGPoint(x: w, y: h * 0.3)],
              CGColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1))
        // Köprü: iki ayak ve tabliye
        context.setFillColor(CGColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1))
        context.fill(CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.4, height: 10))
        context.fill(CGRect(x: w * 0.36, y: h * 0.18, width: 14, height: h * 0.13))
        context.fill(CGRect(x: w * 0.63, y: h * 0.18, width: 14, height: h * 0.13))
        // Köprüde hafifçe yanıp sönen bir ışık (sahne canlı görünsün)
        let glow = 0.5 + 0.5 * sin(time * 2)
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.4, alpha: 0.5 + 0.4 * glow))
        context.fillEllipse(in: CGRect(x: w * 0.5 - 6, y: h * 0.32, width: 12, height: 12))
    }

    private func drawSubtitle(_ line: Line, in context: CGContext) {
        let text = "\(line.speaker): \(line.text)"
        let attributed = attributedString(text, size: 34, weight: "Helvetica-Bold")
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(ctLine, .useOpticalBounds)
        let x = (CGFloat(Self.width) - bounds.width) / 2
        let y = CGFloat(Self.height) * 0.1
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        context.fill(CGRect(x: x - 16, y: y - 12, width: bounds.width + 32, height: bounds.height + 22))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(ctLine, context)
    }

    private func drawHint(_ text: String, in context: CGContext) {
        let h = CGFloat(Self.height)
        let box = CGRect(x: 40, y: h - 150, width: 470, height: 84)
        context.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 0.9))
        context.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        // "Hold ◯ to …": kelimeler arasına bir tuş simgesi çizilir.
        let words = text.split(separator: " ", maxSplits: 1).map(String.init)
        let first = CTLineCreateWithAttributedString(attributedString(words[0] + " ", size: 27, weight: "Helvetica"))
        let firstWidth = CTLineGetBoundsWithOptions(first, .useOpticalBounds).width
        let baseline = box.midY - 9
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.textPosition = CGPoint(x: box.minX + 22, y: baseline)
        CTLineDraw(first, context)
        var x = box.minX + 22 + firstWidth + 10
        if text.hasPrefix("Hold") {
            let ring = CGRect(x: x, y: baseline - 6, width: 30, height: 30)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.setLineWidth(4)
            context.strokeEllipse(in: ring)
            context.fillEllipse(in: ring.insetBy(dx: 9, dy: 9))
            x = ring.maxX + 12
        }
        if words.count > 1 {
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributedString(words[1], size: 27, weight: "Helvetica")), context)
        }
    }

    private func attributedString(_ text: String, size: CGFloat, weight: String) -> CFAttributedString {
        let font = CTFontCreateWithName(weight as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
    }
}
