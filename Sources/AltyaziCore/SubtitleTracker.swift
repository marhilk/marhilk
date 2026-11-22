import Foundation

/// Ekranda o an duran bir altyazı satırı.
public struct SubtitleLine: Equatable, Sendable, Identifiable {
    public let id: Int
    /// Konuşanın adı (oyun gösteriyorsa).
    public var speaker: String?
    /// Konuşanın adı çıkarılmış metin.
    public var text: String

    /// Çeviri önbelleğinin anahtarı ve yapay zekâya giden ham satır.
    public var raw: String { speaker.map { "\($0): \(text)" } ?? text }

    public init(id: Int, speaker: String?, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

/// Kare kare okunan satırları izler ve o an GÖSTERİLMESİ gereken satırları verir.
///
/// Kurallar:
/// - Satırlar GELİŞ SIRASIYLA verilir (en yeni en sonda): ekranda alt alta akan bir konuşma dökümü
///   gibi gösterilmek içindir; oyunun satırları ekranda nereye koyduğu sırayı etkilemez.
/// - Bir replik, oyun onu gösterdiği sürece kalır; yeni replikler gelip sınır aşılınca en eskisi çıkar.
/// - Aynı replik, okuma oynasa ya da konuşanın adı cümleye yapışsa da TEK satırdır (yeniden
///   çevrilmez, ekranda iki kez görünmez).
/// - İki satıra bölünmüş uzun cümle TEK cümle olarak çevrilir.
/// - Oyun bir repliği çok çabuk kaldırırsa çeviri okunacak kadar ekranda bekletilir.
/// - Oyunun arayüz yazıları ve karakterlerin başındaki ad etiketleri ayıklanır.
public struct SubtitleTracker {
    /// Okuma bu kadar süre kaçırılırsa satır "şu an ekranda değil" sayılır.
    public var holdAfterLastSeen: TimeInterval = 0.45
    /// İki okuma bu oranın üstünde benziyorsa aynı satırdır.
    public var similarityThreshold = 0.8
    /// Çevirinin ekranda kalacağı en kısa süre: taban + harf başına süre, üst sınırla.
    public var minimumDisplayBase: TimeInterval = 1.5
    public var minimumDisplayPerCharacter: TimeInterval = 0.06
    public var minimumDisplayCap: TimeInterval = 6.0
    /// Aynı anda ekranda duracak en çok satır. Aşılırsa en eski gelen çıkar.
    public var maximumLines = 4
    /// Ekrandan kalkan satır bu kadar süre hatırlanır; bu sürede yeniden okunursa yeni replik sayılmaz.
    public var memory: TimeInterval = 3.0
    /// Hatırlanan satır bu kadar süre görünmedikten sonra yeniden belirirse yeniden söylenmiş sayılır.
    public var repeatGap: TimeInterval = 1.0

    private struct Entry {
        let id: Int
        var speaker: String?
        var text: String
        var y: Double
        var lastSeen: Date
        var seenCount: Int
        var ready: Bool
        var readySince: Date?
        /// Dökümdeki sırası: ekranda ilk görüldüğü an (gösterilmeye hazır olduğu an değil; yoksa aynı
        /// anda beliren iki satırdan noktasız biteni bir kare geç hazır olup sırayı bozar).
        var arrived: Date
    }

    private var entries: [Entry] = []
    private var nextID = 1
    private var lastEmitted: [SubtitleLine] = []
    /// Şimdiye dek görülen konuşan adları: yapışık okunan satırlarda adı ayırmaya yarar.
    private var knownSpeakers = Set<String>()

    public init() {}

    /// Gösterilecek satır listesi değiştiyse yenisini, değişmediyse `nil` döndürür.
    public mutating func ingest(_ lines: [RecognizedLine], at now: Date = Date()) -> [SubtitleLine]? {
        var matched = Set<Int>()
        for line in joinWrappedLines(lines) {
            let whole = Self.normalize(line.text)
            guard !Self.isNoise(whole), !Self.isNameTag(whole, known: knownSpeakers) else { continue }
            let split = Self.split(parts: line.parts.map(Self.normalize), known: knownSpeakers)
            guard !split.text.isEmpty, !Self.isNoise(split.text) else { continue }
            if split.learned, let speaker = split.speaker, knownSpeakers.count < 80 { knownSpeakers.insert(speaker) }

            if let (index, kind) = bestMatch(for: split.text, excluding: matched) {
                matched.insert(index)
                // Uzun süre görünmeyip yeniden beliren satır yeniden söylenmiştir: dökümün sonuna yeniden girer.
                if entries[index].ready, now.timeIntervalSince(entries[index].lastSeen) >= repeatGap {
                    entries[index].readySince = now
                    entries[index].arrived = now
                }
                entries[index].lastSeen = now
                entries[index].y = Double(line.y)
                switch kind {
                case .same, .noisyPrefix:
                    // Aynı satır: okuma azıcık oynadı ya da başına ekrandaki başka bir yazı (tabela) karıştı.
                    // İlk oturan hâl korunur; yeniden çevrilmez.
                    entries[index].seenCount += 1
                case .changed:
                    // Satır harf harf yazılıyor ya da daha temiz okundu.
                    entries[index].text = split.text
                    entries[index].seenCount = 1
                    entries[index].ready = false
                    entries[index].readySince = nil
                }
                if entries[index].speaker == nil { entries[index].speaker = split.speaker }
            } else {
                entries.append(Entry(id: nextID, speaker: split.speaker, text: split.text, y: Double(line.y),
                                     lastSeen: now, seenCount: 1, ready: false, readySince: nil, arrived: now))
                matched.insert(entries.count - 1)
                nextID += 1
            }
        }

        for index in entries.indices where !entries[index].ready {
            // Cümle bitmiş görünüyorsa hemen göster; değilse bir kare daha bekle (harf harf yazılıyor olabilir).
            entries[index].ready = entries[index].seenCount >= 2 || Self.looksComplete(entries[index].text)
            if entries[index].ready { entries[index].readySince = now }
        }
        entries.removeAll { now.timeIntervalSince($0.lastSeen) > max(memory, minimumDisplayCap) }

        // Geliş sırası: önce gelen üstte, en yeni en altta. Aynı anda gelenlerde oyundaki üstten alta sıra.
        var showing = entries.filter { isShowing($0, at: now) }.sorted {
            $0.arrived != $1.arrived ? $0.arrived < $1.arrived : $0.y < $1.y
        }
        if showing.count > maximumLines { showing = Array(showing.suffix(maximumLines)) }
        let visible = showing.map { SubtitleLine(id: $0.id, speaker: $0.speaker, text: $0.text) }
        guard visible != lastEmitted else { return nil }
        lastEmitted = visible
        return visible
    }

    public mutating func reset() {
        entries.removeAll()
        lastEmitted = []
    }

    private func isShowing(_ entry: Entry, at now: Date) -> Bool {
        guard entry.ready, let since = entry.readySince else { return false }
        // Oyunda duruyorsa göster; oyundan kalktıysa okunacak kadar kalmış olana dek beklet.
        if now.timeIntervalSince(entry.lastSeen) <= holdAfterLastSeen { return true }
        let needed = min(minimumDisplayCap, minimumDisplayBase + minimumDisplayPerCharacter * Double(entry.text.count))
        return now.timeIntervalSince(since) < needed
    }

    /// Oyun uzun cümleyi alt satıra böler. Alt satır, üsttekinin hemen altındaysa, bir konuşan adıyla
    /// başlamıyorsa ve küçük harfle başlıyorsa (ya da üst satır bağlaçla / virgülle bitiyorsa) devamıdır.
    private func joinWrappedLines(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        var result: [RecognizedLine] = []
        var lastRowY: CGFloat = 0
        for line in lines.sorted(by: { $0.y < $1.y }) {
            guard var previous = result.last else {
                result.append(line)
                lastRowY = line.y
                continue
            }
            let adjacent = line.y - lastRowY <= max(previous.height, line.height) * 1.8
            let text = Self.normalize(line.text)
            let startsNewSpeaker = Self.split(parts: line.parts.map(Self.normalize), known: knownSpeakers).speaker != nil
            let above = Self.normalize(previous.text)
            let startsLowercase = text.first?.isLowercase ?? false
            let aboveDangles = [",", "-", " and", " or", " but", " the", " a", " an", " to", " of", " with", " for", " that"]
                .contains { above.lowercased().hasSuffix($0) }
            if adjacent, !startsNewSpeaker, !text.isEmpty, !Self.looksComplete(above) || startsLowercase,
               startsLowercase || aboveDangles {
                previous.parts[previous.parts.count - 1] += " " + text
                result[result.count - 1] = previous
            } else {
                result.append(line)
            }
            lastRowY = line.y
        }
        return result
    }

    private enum MatchKind { case same, noisyPrefix, changed }

    private func bestMatch(for text: String, excluding used: Set<Int>) -> (Int, MatchKind)? {
        var best: (index: Int, score: Double, kind: MatchKind)?
        for (index, entry) in entries.enumerated() where !used.contains(index) {
            let whole = Self.similarity(text, entry.text)
            var score = whole
            var kind: MatchKind = whole >= 0.93 ? .same : .changed
            if whole < similarityThreshold, entry.text.count >= 6 {
                if text.count > entry.text.count {
                    // Yeni okuma daha uzun: ya satır harf harf yazılıyor (eski, yeninin BAŞI)
                    // ya da başına başka bir yazı karışmış (eski, yeninin SONU).
                    if Self.similarity(String(text.suffix(entry.text.count)), entry.text) >= 0.9 {
                        score = similarityThreshold
                        kind = .noisyPrefix
                    } else if Self.similarity(String(text.prefix(entry.text.count)), entry.text) >= 0.85 {
                        score = similarityThreshold
                        kind = .changed
                    }
                } else if text.count >= 6, Self.similarity(String(entry.text.suffix(text.count)), text) >= 0.9 {
                    // İlk okuma kirliydi, bu temiz: temizine geç.
                    score = similarityThreshold
                    kind = .changed
                }
            }
            if score >= similarityThreshold, score > (best?.score ?? 0) { best = (index, score, kind) }
        }
        return best.map { ($0.index, $0.kind) }
    }

    // MARK: - Metin yardımcıları

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func looksComplete(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?…]\"'”’)".contains(last)
    }

    /// Altyazı olmayan yazılar: çok kısa, Latin dışı (yanlış okunmuş süsleme), arayüz etiketleri.
    static func isNoise(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 3 else { return true }
        let ascii = letters.filter { $0.isASCII }.count
        if Double(ascii) / Double(letters.count) < 0.7 { return true }

        // TAMAMI BÜYÜK HARF ve cümle gibi bitmiyor: menü / bölüm başlığı / kayıt bildirimi.
        let hasLowercase = letters.contains { CharacterSet.lowercaseLetters.contains($0) }
        if !hasLowercase, !looksComplete(text) {
            let words = text.split(separator: " ").count
            if words <= 5 || text.contains(where: \.isNumber) { return true }
        }
        return false
    }

    static let rankWords: Set<String> = ["pvt", "pfc", "cpl", "sgt", "ssgt", "lt", "capt", "maj", "col", "gen",
                                         "cmdr", "adm", "dr", "mr", "mrs", "ms", "prof"]

    /// Karakterin başının üstünde duran ad etiketi ("Col. Dunn", "Sgt. Jae"): replik değildir.
    /// Okuma noktayı iki nokta ya da virgül sanabildiği için ("Cpl: Dunn", "Sgt, Dunn") noktalama yok sayılır.
    static func isNameTag(_ text: String, known: Set<String>) -> Bool {
        let words = text.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;")) }.filter { !$0.isEmpty }
        guard (1...4).contains(words.count) else { return false }
        let rest = words.drop { rankWords.contains($0.lowercased()) }
        guard !rest.isEmpty, rest.count <= 3 else { return false }
        let name = rest.joined(separator: " ")
        if rest.count < words.count { return isStrictName(name) || known.contains(name) }   // rütbe + ad
        return known.contains(name)                                                         // yalnız bilinen ad
    }

    /// Olağan yazılmış ad: her sözcük büyük harfle başlar, gerisi küçük harftir ("Dunn", "Ju Kwon", "Cashier").
    /// Simge/amblem yanlış okumalarını ("HEaRd", "JEÑ", "a€") dışarıda bırakır.
    static func isStrictName(_ candidate: String) -> Bool {
        let words = candidate.split(separator: " ")
        guard (1...3).contains(words.count), candidate.count <= 24 else { return false }
        return words.allSatisfy { word in
            guard word.count >= 2, let first = word.first, first.isASCII, first.isUppercase else { return false }
            return word.dropFirst().allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "-" || $0 == "'") }
        }
    }

    /// Aday ad bilinen bir adla bitiyorsa (önüne simge karışmışsa) bilinen adı verir.
    private static func resolve(_ candidate: String, known: Set<String>) -> String? {
        if known.contains(candidate) { return candidate }
        return known.filter { candidate.hasSuffix(" " + $0) }.max { $0.count < $1.count }
    }

    /// Konuşanın adını metinden ayırır. `learned`: bu ad güvenle öğrenilebilir mi.
    static func split(parts: [String], known: Set<String>) -> (speaker: String?, text: String, learned: Bool) {
        let parts = parts.filter { !$0.isEmpty }
        let whole = parts.joined(separator: " ")

        // "Jae: [Yeah.]"
        if let colon = whole.firstIndex(of: ":") {
            let name = String(whole[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(whole[whole.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                if let resolved = resolve(name, known: known) { return (resolved, rest, false) }
                if looksLikeName(name) { return (name, rest, true) }
            }
        }
        // Ad ayrı bir parça olarak çizilmiş: ["Jae", "[We're very sorry.]"]
        if parts.count >= 2 {
            let rest = parts.dropFirst().joined(separator: " ")
            if let resolved = resolve(parts[0], known: known) { return (resolved, rest, false) }
            if isStrictName(parts[0]) { return (parts[0], rest, true) }
            // Baştaki parça ad değil, kısa bir yanlış okuma (simge): at, cümleyi koru.
            if parts[0].count <= 6, rest.count >= 6 { return (nil, rest, false) }
        }
        // "Cho [Why? We're your best customers!]"
        if let bracket = whole.firstIndex(of: "["), bracket != whole.startIndex {
            let name = String(whole[..<bracket]).trimmingCharacters(in: .whitespaces)
            let rest = String(whole[bracket...])
            if let resolved = resolve(name, known: known) { return (resolved, rest, false) }
            if isStrictName(name) { return (name, rest, true) }
        }
        // Ad cümleye yapışık okunmuş ("Dunn Got it.") ya da önüne ekrandaki başka bir yazı karışmış
        // ("WELCOME Jae Pack it up."): bilinen ad satırın başlarında geçiyorsa oradan böl, öncesini at.
        let padded = " " + whole
        for name in known.sorted(by: { $0.count > $1.count }) {
            guard let range = padded.range(of: " " + name + " "),
                  padded.distance(from: padded.startIndex, to: range.lowerBound) <= 24 else { continue }
            let rest = String(padded[range.upperBound...])
            if let first = rest.first, first.isUppercase || first == "[" || first.isNumber, rest.count >= 3 {
                return (name, rest, false)
            }
        }
        return (nil, whole, false)
    }

    static func looksLikeName(_ candidate: String) -> Bool {
        let words = candidate.split(separator: " ")
        guard (1...3).contains(words.count), candidate.count <= 24 else { return false }
        // "LAST CHECKPOINT" gibi tamamı büyük harfli çok sözcüklü etiketler ad değil, menü başlığıdır.
        if words.count > 1, !candidate.contains(where: \.isLowercase) { return false }
        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase else { return false }
            return word.allSatisfy { $0.isLetter || $0 == "." || $0 == "'" || $0 == "’" || $0 == "-" }
        }
    }

    /// 0…1 arası benzerlik (harf/rakam üzerinden Levenshtein).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(300))
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(300))
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(Swift.max(x.count, y.count))
    }
}
