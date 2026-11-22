import CoreGraphics
import Foundation

/// Ekranın sabit bir köşesindeki kalıcı yazıları (görev, hedef, ipucu) izler.
///
/// Konuşma altyazısından farkı: bu yazılar uzun süre yerinde durur. Bu yüzden
/// bir yazı ancak art arda iki okumada görülünce "var" sayılır (tek karelik yanlış okumalar
/// ekrana çıkmaz) ve art arda iki okumada görülmeyince kalkar (titremez).
struct HUDTracker {
    struct Entry: Equatable {
        var source: String
        /// Karenin tamamına göre (0…1, sol üstten).
        var x: Double
        var top: Double
        var width: Double
        var height: Double
        var lineHeight: Double
        var lines: Int
        /// Yazının içindeki tuş simgeleri (metinde "⬚" ile işaretli), sırayla.
        var icons: [String] = []
        var seen = 1
        var missed = 0
    }

    /// Bir yazının "var" sayılması için gereken art arda okuma sayısı.
    var appearAfter = 2
    /// Bir yazının kalkması için gereken art arda kaçırma sayısı (okuma sıklaştığı için üç: titremesin).
    var disappearAfter = 3
    /// Bundan küçük yazılar (kare yüksekliğine oranla) arayüz yazısı değil, oyun dünyasındaki
    /// tabela/etiket sayılır. 1080p'de yaklaşık 22 piksel.
    var minimumLineHeight = 0.021
    /// Arayüz yazısı yerinde durur; okumalar arasında bundan çok kayan yazı oyun dünyasına aittir
    /// (kamera döndükçe kayan tabela) ve sayımı baştan başlar.
    var maximumDrift = 0.012
    private(set) var entries: [Entry] = []

    /// Yeterince görülmüş (gösterilmeye aday) yazılar, yukarıdan aşağıya.
    var stable: [Entry] {
        entries.filter { $0.seen >= appearAfter }.sorted { ($0.top, $0.x) < ($1.top, $1.x) }
    }

    mutating func reset() {
        entries = []
    }

    /// Bir okumanın sonucunu işler. `lines` okunan bölgeye görelidir; `region` o bölgenin karedeki yeridir.
    mutating func update(lines: [RecognizedLine], region: CGRect) {
        var matched = Set<Int>()
        for block in Self.blocks(from: lines) {
            let source = block.map(\.text).joined(separator: " ")
            guard Self.isWorthTranslating(source) else { continue }
            let left = block.map(\.x).min()!
            let right = block.map { $0.x + $0.width }.max()!
            let top = block.map { $0.y - $0.height / 2 }.min()!
            let bottom = block.map { $0.y + $0.height / 2 }.max()!
            let heights = block.map(\.height).sorted()
            let lineHeight = Double(heights[heights.count / 2] * region.height)
            guard lineHeight >= minimumLineHeight else { continue }
            let frameX = Double(region.minX + left * region.width)
            let frameTop = Double(region.minY + top * region.height)

            if let index = entries.indices.first(where: {
                !matched.contains($0) && SubtitleTracker.similarity(entries[$0].source, source) >= 0.85
            }) {
                matched.insert(index)
                entries[index].missed = 0
                if abs(entries[index].x - frameX) > maximumDrift || abs(entries[index].top - frameTop) > maximumDrift {
                    // Yazı kaydı: arayüz yazısı değil. Yeni yerinde durursa yeniden sayılır.
                    entries[index].seen = 1
                    entries[index].x = frameX
                    entries[index].top = frameTop
                } else {
                    // Aynı yazı, aynı yerde: yeri ve çevirisi oynamasın diye ilk okunan hâli korunur.
                    entries[index].seen += 1
                }
                // Tek istisna: bu okumada daha çok simge bulunduysa o hâli alınır. Kutu belirirken
                // (soluk ilk karede) simgeler kaçabiliyor; sonraki net karede yakalanıyor.
                // Yazı gösterilmeye başladıktan sonra artık değişmez (ekranda oynayan çeviri kötü görünür).
                let icons = block.flatMap(\.icons)
                if icons.count > entries[index].icons.count, entries[index].seen <= appearAfter {
                    entries[index].source = source
                    entries[index].icons = icons
                }
            } else {
                entries.append(Entry(source: source,
                                     x: frameX,
                                     top: frameTop,
                                     width: Double((right - left) * region.width),
                                     height: Double((bottom - top) * region.height),
                                     lineHeight: lineHeight,
                                     lines: block.count,
                                     icons: block.flatMap(\.icons)))
                matched.insert(entries.count - 1)
            }
        }
        for index in entries.indices where !matched.contains(index) {
            entries[index].missed += 1
            // Henüz "var" sayılmamış bir yazı bir kez bile kaçarsa baştan sayılır.
            if entries[index].seen < appearAfter { entries[index].missed = disappearAfter }
        }
        entries.removeAll { $0.missed >= disappearAfter }
        // Kutu belirirken önce bir parçası okunur ("radio frequencies and will be"), sonra tamamı.
        // Tamamı gelince parça atılır; yoksa ikisi birden çevrilip aynı cümle iki kez görünür.
        let sources = entries.map { Self.normalized($0.source) }
        let fragments = Set(entries.indices.filter { index in
            sources.indices.contains { $0 != index && sources[$0].count > sources[index].count && sources[$0].contains(sources[index]) }
        })
        if !fragments.isEmpty {
            entries = entries.enumerated().filter { !fragments.contains($0.offset) }.map(\.element)
        }
    }

    /// Alt alta, aynı hizada ve aralıksız duran satırları tek yazı sayar (ipucu kutusundaki metin satır kırar).
    /// Alt satır küçük harfle başlıyorsa kesin devamdır. Büyük harfle başlıyorsa, üst satır cümleyi
    /// bitirmemişse ve kutuyu dolduracak kadar uzunsa yine devam sayılır; kısa satırlar alt alta duran
    /// ayrı maddelerdir ("Mangayı takip et" / "Kuleyi yok et").
    static func blocks(from lines: [RecognizedLine]) -> [[RecognizedLine]] {
        var result: [[RecognizedLine]] = []
        for line in lines.sorted(by: { $0.y < $1.y }) {
            if let block = result.last, let last = block.last, let first = line.text.first,
               abs(line.x - last.x) < 0.02,
               line.y - last.y < max(last.height, line.height) * 1.7 {
                let widest = max(block.map(\.width).max() ?? 0, line.width)
                let lastFinished = last.text.last.map { ".!?:".contains($0) } ?? false
                if first.isLowercase || (!lastFinished && last.width >= widest * 0.6) {
                    result[result.count - 1].append(line)
                    continue
                }
            }
            result.append([line])
        }
        return result
    }

    /// Karşılaştırma için: küçük harf, simge işaretsiz, tek boşluklu.
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0 != IconFinder.placeholder }.split(separator: " ").joined(separator: " ")
    }

    /// Sayaç, mesafe, cephane gibi yazılar ve tek kelimelik parçalar (çoğu tabela kırıntısıdır) çevrilmez.
    static func isWorthTranslating(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        let digits = text.filter(\.isNumber).count
        let words = text.split(separator: " ").filter { $0.filter(\.isLetter).count >= 2 }.count
        return letters >= 6 && letters > digits * 2 && words >= 2
    }
}

/// Görev/ipucu yazılarını çevirir ve TV'de özgün yazının HEMEN ALTINDA gösterilecek öğelere dönüştürür.
/// Özgün yazı ekranda durdukça çevirisi de durur; yazı kalkınca çeviri de kalkar.
/// Bir yazı bir kez çevrilir; gösterilen çeviri sonradan değişmez.
public actor HUDTranslator {
    public typealias Translate = @Sendable (String) async -> String?

    private var tracker = HUDTracker()
    private var translate: Translate?
    /// Özgün yazı → çeviri. `nil` değer: çevirmeye değmez (ad, marka; çeviri özgünle aynı).
    private var cache: [String: String?] = [:]
    private var lastSent: [ScreenItem] = []
    private var pending: Set<String> = []
    private var tasks: [Task<Void, Never>] = []
    private let send: @Sendable ([ScreenItem]) -> Void
    /// Özgün yazı ile çevirisi arasındaki boşluk (kare yüksekliğine oranla).
    static let gap = 0.008

    public init(send: @escaping @Sendable ([ScreenItem]) -> Void) {
        self.send = send
    }

    public func setTranslator(_ translate: Translate?) {
        self.translate = translate
    }

    /// Ekrandaki öğeleri kaldırır ve izlemeyi sıfırlar (bağlantı koptuğunda, özellik kapatıldığında).
    public func reset() {
        tracker.reset()
        if !lastSent.isEmpty {
            lastSent = []
            send([])
        }
    }

    /// Şu an izlenen (yeterince görülmüş) özgün yazılar; teşhis için.
    public var current: [String] { tracker.stable.map(\.source) }

    /// "⬚" işaretlerini sırayla "[1]", "[2]"… yapar.
    static func numbered(_ source: String) -> (text: String, count: Int) {
        var count = 0
        var text = ""
        for character in source {
            if character == IconFinder.placeholder {
                count += 1
                text += "[\(count)]"
            } else {
                text.append(character)
            }
        }
        return (text, count)
    }

    /// Çeviri bir simge işaretini düşürdüyse simge kaybolmasın: eksikler başa eklenir.
    static func restoringMarkers(in translated: String, count: Int) -> String {
        guard count > 0 else { return translated }
        let missing = (1...count).filter { !translated.contains("[\($0)]") }
        return missing.isEmpty ? translated : missing.map { "[\($0)]" }.joined(separator: " ") + " " + translated
    }

    public func ingest(_ lines: [RecognizedLine], region: CGRect) {
        tracker.update(lines: lines, region: region)
        // Çeviri ayrı yürür: yavaş ya da takılan bir çeviri okuma döngüsünü bekletmez
        // (bekletseydi ekrandaki yazı kalkması gerekirken takılı kalırdı).
        for entry in tracker.stable where cache[entry.source] == nil && !pending.contains(entry.source) {
            guard let translate else { break }
            let source = entry.source
            let numbered = Self.numbered(source)
            pending.insert(source)
            let task = Task {
                let translated = await translate(numbered.text)?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.translated(source: source, numbered: numbered, result: translated)
            }
            tasks.append(task)
        }
        if cache.count > 400 { cache.removeAll() }   // çok uzun oturumda bellek büyümesin
        publish()
    }

    /// Süren çevirilerin bitmesini bekler (testler için).
    func waitForTranslations() async {
        let running = tasks
        tasks = []
        for task in running { await task.value }
    }

    private func translated(source: String, numbered: (text: String, count: Int), result: String?) {
        pending.remove(source)
        // Çeviri alınamadıysa (dil paketi henüz hazır değil) sonraki okumada yeniden denenir.
        guard let result, !result.isEmpty else { return }
        let same = SubtitleTracker.similarity(numbered.text, result) >= 0.95
        cache[source] = .some(same ? nil : Self.restoringMarkers(in: result, count: numbered.count))
        publish()
    }

    private func publish() {
        // Aynı kutuya ait yazılar (alt alta, bitişik) tek öğe olarak, kutunun EN ALT satırının altına konur.
        // Her parçanın çevirisi kendi altına konsaydı, bir sonraki özgün satırın üstünü kapatırdı.
        var items: [ScreenItem] = []
        for cluster in Self.clusters(of: tracker.stable) {
            var text = ""
            var icons: [String] = []
            for entry in cluster {
                guard let known = cache[entry.source], let translation = known else { continue }
                if !text.isEmpty { text += "\n" }
                text += Self.shiftingMarkers(in: translation, by: icons.count)
                icons += entry.icons
            }
            guard !text.isEmpty else { continue }
            let left = cluster.map(\.x).min()!
            let right = cluster.map { $0.x + $0.width }.max()!
            let bottom = cluster.map { $0.top + $0.height }.max()!
            let heights = cluster.map(\.lineHeight).sorted()
            let lines = cluster.reduce(0) { $0 + $1.lines }
            items.append(ScreenItem(x: left, y: min(bottom + Self.gap, 0.97), width: right - left, height: 0,
                                    lineHeight: heights[heights.count / 2],
                                    // Birden çok parça varsa satır kırılabilmeli (her parça kendi satırında).
                                    lines: max(lines, cluster.count > 1 ? 2 : 1), text: text, icons: icons))
        }
        if items != lastSent {
            lastSent = items
            send(items)
        }
    }

    /// Yukarıdan aşağıya sıralı yazıları kutulara ayırır: dikeyde bitişik ve yatayda örtüşenler aynı kutudadır.
    static func clusters(of entries: [HUDTracker.Entry]) -> [[HUDTracker.Entry]] {
        var result: [[HUDTracker.Entry]] = []
        for entry in entries.sorted(by: { $0.top < $1.top }) {
            if let last = result.last?.last,
               entry.top - (last.top + last.height) < max(last.lineHeight, entry.lineHeight) * 1.6,
               entry.x < last.x + last.width, last.x < entry.x + entry.width {
                result[result.count - 1].append(entry)
            } else {
                result.append([entry])
            }
        }
        return result
    }

    /// "[1]", "[2]"… işaretlerini `offset` kadar kaydırır (birleştirilen parçaların simgeleri karışmasın).
    static func shiftingMarkers(in text: String, by offset: Int) -> String {
        guard offset > 0 else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            result += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "]"), let number = Int(after[..<close]) {
                result += "[\(number + offset)]"
                rest = after[after.index(after: close)...]
            } else {
                result += "["
                rest = after
            }
        }
        return result + rest
    }
}
