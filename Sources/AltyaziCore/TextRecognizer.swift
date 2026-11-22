import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox
import Vision

/// Ekranda yan yana duran yazı parçalarından oluşan tek bir satır.
public struct RecognizedLine: Equatable, Sendable {
    /// Satırdaki parçalar, soldan sağa (oyunlar konuşanın adını çoğu zaman ayrı parça olarak çizer).
    public var parts: [String]
    /// Satırın dikey ortası (0 = üst, 1 = alt), okunan bölgeye göre.
    public var y: CGFloat
    /// Satırın yüksekliği, aynı ölçüde. Alt alta satırların aynı cümlenin devamı olup olmadığını anlamaya yarar.
    public var height: CGFloat
    /// Satırın sol kenarı ve genişliği (0…1), okunan bölgeye göre. Yazıyı yerinde çevirirken kullanılır.
    public var x: CGFloat
    public var width: CGFloat
    /// Satırdaki tuş simgelerinin resimleri (`data:` adresi), soldan sağa. Metinde her biri "⬚" ile işaretlidir.
    /// Yalnız simge araması istenen okumalarda doldurulur.
    public var icons: [String] = []

    public var text: String { parts.joined(separator: " ") }

    public init(parts: [String], y: CGFloat, height: CGFloat = 0.05, x: CGFloat = 0, width: CGFloat = 1, icons: [String] = []) {
        self.icons = icons
        self.parts = parts
        self.y = y
        self.height = height
        self.x = x
        self.width = width
    }
}

/// Görüntünün seçili bölgesindeki yazıyı cihaz üstünde (Apple Vision) okur.
/// Görüntü hiçbir yere gönderilmez.
public struct TextRecognizer {
    public var languages: [String] = ["en-US"]
    public var minimumConfidence: Float = 0.4

    public init() {}

    /// Süren bir okumayı dışarıdan iptal etmeye yarar (sistemin yazı okuyucusu kilitlenirse).
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var request: VNRequest?

        public init() {}

        func attach(_ request: VNRequest) {
            lock.lock()
            self.request = request
            lock.unlock()
        }

        public func cancel() {
            lock.lock()
            let request = self.request
            lock.unlock()
            request?.cancel()
        }
    }

    /// `roi`: Vision'ın normalize koordinatları (0…1, başlangıç SOL ALT köşe).
    public func recognizeLines(pixelBuffer: CVPixelBuffer, roi: CGRect, cancellation: Cancellation? = nil) throws -> [RecognizedLine] {
        try run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]), roi: roi, cancellation: cancellation)
    }

    public func recognizeLines(cgImage: CGImage, roi: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> [RecognizedLine] {
        try run(VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]), roi: roi, cancellation: nil)
    }

    /// Satırları okur ve içlerindeki tuş simgelerini de bulur: simgenin yeri metinde "⬚" ile işaretlenir,
    /// resmi `icons` içinde verilir. Görev/ipucu yazıları için kullanılır ("□ tuşunu basılı tut").
    public func recognizeLinesWithIcons(cgImage: CGImage, roi: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> [RecognizedLine] {
        let lines = try recognizeLines(cgImage: cgImage, roi: roi)
        let imageWidth = CGFloat(cgImage.width), imageHeight = CGFloat(cgImage.height)
        return lines.map { line in
            // Satır, okunan bölgeye görelidir; bölge Vision ölçüsündedir (başlangıç sol alt).
            let left = (roi.minX + line.x * roi.width) * imageWidth
            let width = line.width * roi.width * imageWidth
            let top = (1 - roi.maxY + (line.y - line.height / 2) * roi.height) * imageHeight
            let height = line.height * roi.height * imageHeight
            let found = IconFinder.icons(in: cgImage, lineRect: CGRect(x: left, y: top, width: width, height: height))
            guard !found.isEmpty, found.count <= 6 else {
                // Simge bulunamadıysa, okuyucunun satır sonuna uydurduğu işaret ("-", "&") çeviriye girmesin.
                var words = line.text.split(separator: " ").map(String.init)
                guard words.count > 1, let last = words.last, last.count == 1, let mark = last.first,
                      !mark.isLetter, !mark.isNumber, !".!?".contains(mark) else { return line }
                words.removeLast()
                var cleaned = line
                cleaned.parts = [words.joined(separator: " ")]
                return cleaned
            }
            // Simge satır kutusunun dışına taşabilir: satırı simgeleri de kapsayacak biçimde ölç.
            let start = min(left, found.first!.minX), end = max(left + width, found.last!.maxX)
            let marked = IconFinder.mark(text: line.text, lineStart: start, lineEnd: end,
                                         icons: found.map { ($0.midX, $0.width) })
            let images = found.compactMap { IconFinder.dataURL(of: cgImage, rect: $0) }
            guard images.count == found.count else { return line }
            var result = line
            result.parts = [marked]
            result.icons = images
            // Satırın yeri simgeleri de kapsasın: baştaki simge yüzünden satır içeriden başlamış görünüp
            // kutudaki öteki satırlardan ayrı sayılmasın.
            result.x = (start / imageWidth - roi.minX) / roi.width
            result.width = (end - start) / imageWidth / roi.width
            return result
        }
    }

    /// Aynısı, akıştan gelen kare için.
    public func recognizeLinesWithIcons(pixelBuffer: CVPixelBuffer, roi: CGRect) throws -> [RecognizedLine] {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return try recognizeLines(pixelBuffer: pixelBuffer, roi: roi) }
        return try recognizeLinesWithIcons(cgImage: image, roi: roi)
    }

    /// Tüm satırlar tek metin olarak (yukarıdan aşağıya).
    public func recognize(cgImage: CGImage, roi: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> String {
        try recognizeLines(cgImage: cgImage, roi: roi).map(\.text).joined(separator: " ")
    }

    private func run(_ handler: VNImageRequestHandler, roi: CGRect, cancellation: Cancellation?) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        cancellation?.attach(request)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.regionOfInterest = roi
        try handler.perform([request])

        struct Piece { let text: String; let box: CGRect }
        let pieces: [Piece] = (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= minimumConfidence else { return nil }
            return Piece(text: best.string, box: observation.boundingBox)
        }

        // Dikey ortası bir satırın İLK parçasına yakın olan parça o satırdadır (Vision'da y yukarı doğru artar).
        // Zincirleme karşılaştırma yapılmaz: yoksa iki satırın arasına düşen bir etiket ikisini birleştirir.
        var rows: [[Piece]] = []
        for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            let match = rows.indices.min { abs(rows[$0][0].box.midY - piece.box.midY) < abs(rows[$1][0].box.midY - piece.box.midY) }
            if let match, abs(rows[match][0].box.midY - piece.box.midY) < min(rows[match][0].box.height, piece.box.height) * 0.5 {
                rows[match].append(piece)
            } else {
                rows.append([piece])
            }
        }
        // Aynı hizada ama birbirinden UZAK parçalar ayrı yazılardır (soldaki menü ile sağdaki görev gibi);
        // yalnız yan yana duranlar (konuşanın adı + cümlesi) tek satırda birleşir.
        var lines: [RecognizedLine] = []
        for row in rows {
            var group: [Piece] = []
            func flush() {
                guard !group.isEmpty else { return }
                let middle = group.map(\.box.midY).reduce(0, +) / CGFloat(group.count)
                let height = group.map(\.box.height).max() ?? 0.05
                let left = group.map(\.box.minX).min() ?? 0
                let right = group.map(\.box.maxX).max() ?? 1
                lines.append(RecognizedLine(parts: group.map(\.text), y: 1 - middle, height: height, x: left, width: right - left))
                group = []
            }
            for piece in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                // Görüntü 16:9 olduğundan yatay ölçüyü dikeye çevirirken en-boy oranı hesaba katılır.
                if let last = group.last, (piece.box.minX - last.box.maxX) * 16 / 9 > max(last.box.height, piece.box.height) * 2.5 {
                    flush()
                }
                group.append(piece)
            }
            flush()
        }
        return lines.sorted { $0.y < $1.y }
    }
}
