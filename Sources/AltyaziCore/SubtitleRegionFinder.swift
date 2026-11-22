import CoreGraphics
import Foundation

/// Oyunun altyazıyı ekranın neresinde gösterdiğini kendisi bulur; kullanıcının çerçeveyi elle
/// yerleştirmesine gerek kalmaz.
///
/// Ekranın alt bölümü seyrek aralıklarla baştan sona okunur. Altyazıyı öteki yazılardan ayıran şey
/// geçici olmasıdır: birkaç saniye görünür, kaybolur, yerine başka bir cümle gelir; hep aynı yükseklikte
/// çıkar. Uzun süre yerinde duran yazılar (can göstergesi, harita, görev listesi) altyazı değildir.
public struct SubtitleRegionFinder: Sendable {
    /// Karenin tamamına göre bir yazı satırı (0…1, başlangıç sol üst).
    public struct Observation: Sendable, Equatable {
        public var text: String
        public var x: Double
        public var top: Double
        public var width: Double
        public var height: Double

        public init(text: String, x: Double, top: Double, width: Double, height: Double) {
            self.text = text
            self.x = x
            self.top = top
            self.width = width
            self.height = height
        }
    }

    /// Bundan uzun süre ekranda kalan yazı altyazı sayılmaz.
    public var maximumLifetime: TimeInterval = 12
    /// Öneri vermek için gereken farklı altyazı sayısı.
    public var needed = 4
    /// Bu kadar eski gözlemler unutulur (oyun içinde altyazının yeri değişirse yenisine uyulur).
    public var memory: TimeInterval = 180

    private struct Entry: Sendable {
        var text: String
        var box: Observation
        var firstSeen: Date
        var lastSeen: Date
    }

    private var entries: [Entry] = []

    public init() {}

    public mutating func reset() {
        entries = []
    }

    /// Bir taramanın sonucu.
    public mutating func observe(_ lines: [Observation], at now: Date = Date()) {
        for line in lines where Self.looksLikeSentence(line.text) {
            // Harf harf yazılan altyazı her taramada biraz daha uzar: aynı yazı sayılır.
            if let index = entries.firstIndex(where: { Self.sameText($0.text, line.text) && abs($0.box.top - line.top) < 0.05 }) {
                entries[index].lastSeen = now
                if line.text.count > entries[index].text.count {
                    entries[index].text = line.text
                    entries[index].box = line
                }
            } else {
                entries.append(Entry(text: line.text, box: line, firstSeen: now, lastSeen: now))
            }
        }
        entries.removeAll { now.timeIntervalSince($0.lastSeen) > memory }
        if entries.count > 80 { entries.removeFirst(entries.count - 80) }
    }

    /// Altyazının çıktığı bölge için öneri; yeterince gözlem yoksa `nil`.
    public func suggestion() -> CGRect? {
        // Geçici yazılar: ekranda `maximumLifetime`dan kısa kalmış olanlar.
        let transient = entries.filter { $0.lastSeen.timeIntervalSince($0.firstSeen) < maximumLifetime }.map(\.box)
        guard transient.count >= needed else { return nil }

        // Aynı yükseklikte toplananlar altyazıdır; arada bir çıkan başka yazılar (bildirim, tabela) dışarıda kalır.
        let centers = transient.map { $0.top + $0.height / 2 }.sorted()
        let median = centers[centers.count / 2]
        let cluster = transient.filter { abs($0.top + $0.height / 2 - median) < 0.1 }
        guard cluster.count >= needed else { return nil }

        let lineHeight = cluster.map(\.height).sorted()[cluster.count / 2]
        var top = cluster.map(\.top).min()! - lineHeight * 0.9
        var bottom = cluster.map { $0.top + $0.height }.max()! + lineHeight * 0.7
        // İki-üç satırlık altyazılara yer kalsın.
        let minimumHeight = max(0.12, lineHeight * 3.6)
        if bottom - top < minimumHeight {
            let missing = minimumHeight - (bottom - top)
            top -= missing * 0.6
            bottom += missing * 0.4
        }

        // Yatay: ortalanmış altyazı uzadıkça iki yana birden genişler; sola yaslı altyazı yalnız sağa uzar.
        let left = cluster.map(\.x).min()!
        let right = cluster.map { $0.x + $0.width }.max()!
        let lefts = cluster.map(\.x)
        let leftAligned = (lefts.max()! - lefts.min()!) < 0.02
        var minX: Double, maxX: Double
        if leftAligned {
            minX = left - 0.03
            maxX = max(right + 0.15, left + 0.6)
        } else {
            let half = max(max(0.5 - left, right - 0.5) + 0.08, 0.3)
            minX = 0.5 - half
            maxX = 0.5 + half
        }
        minX = max(0.03, minX)
        maxX = min(0.97, maxX)
        top = max(0.02, top)
        bottom = min(0.985, bottom)
        guard maxX - minX > 0.2, bottom - top > 0.05 else { return nil }
        return CGRect(x: minX, y: top, width: maxX - minX, height: bottom - top)
    }

    /// Öneri, şimdiki bölgeden uygulanmaya değecek kadar farklı mı? (Küçük oynamalarda çerçeve kıpırdamasın.)
    public static func differs(_ suggestion: CGRect, from current: CGRect, by tolerance: Double = 0.03) -> Bool {
        abs(suggestion.minX - current.minX) > tolerance || abs(suggestion.maxX - current.maxX) > tolerance
            || abs(suggestion.minY - current.minY) > tolerance || abs(suggestion.maxY - current.maxY) > tolerance
    }

    /// Altyazı cümleye benzer: birkaç kelime, çoğu harf. Sayaç, mesafe ve tek kelimelik etiketler elenir.
    static func looksLikeSentence(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        let digits = text.filter(\.isNumber).count
        let words = text.split(separator: " ").filter { $0.filter(\.isLetter).count >= 2 }.count
        return letters >= 8 && words >= 2 && letters > digits * 3
    }

    static func sameText(_ first: String, _ second: String) -> Bool {
        let a = first.lowercased(), b = second.lowercased()
        return a.hasPrefix(b) || b.hasPrefix(a) || SubtitleTracker.similarity(a, b) >= 0.8
    }
}
