import CoreGraphics
import CoreVideo
import Foundation

/// Ekranda yerinde gösterilecek çevrilmiş bir yazı.
public struct ScreenItem: Equatable, Sendable {
    /// Yazının özgün yeri (0…1, karenin sol üstünden).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Tek satırın yüksekliği (yazı boyutu için).
    public var lineHeight: Double
    /// Kaç özgün satır birleştirildi (1'den büyükse paragraftır, satır kırılabilir).
    public var lines: Int
    public var text: String
    /// Metindeki "[1]", "[2]"… işaretlerinin yerine basılacak tuş simgeleri (`data:` adresi).
    public var icons: [String] = []

    public init(x: Double, y: Double, width: Double, height: Double, lineHeight: Double, lines: Int, text: String, icons: [String] = []) {
        self.icons = icons
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.lineHeight = lineHeight
        self.lines = lines
        self.text = text
    }

    var json: [String: Any] {
        var object: [String: Any] = ["x": x, "y": y, "w": width, "h": height, "lh": lineHeight, "n": lines, "t": text]
        if !icons.isEmpty { object["ic"] = icons }
        return object
    }
}

/// Duraklatılmış ekrandaki TÜM yazıları (menü, görev, mektup, eşya açıklaması) yapay zekâyla çevirir.
/// Canlı altyazıdan farklı olarak burada bir-iki saniye beklemek sorun değildir; karşılığında çeviri
/// bağlamı bilerek yapılır ve aynı cümlenin satırları birleştirilir.
public final class ScreenTranslator: @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let systemPrompt = """
    You translate everything written on a paused video-game screen from English to Turkish, so a player who \
    does not read English can use menus and read documents.

    Input: numbered lines exactly as an OCR engine read them, top to bottom. Lines may contain OCR mistakes.

    Rules:
    - Put lines that belong to the same sentence or paragraph into ONE group (list their numbers in order) and \
    translate the group as a whole, in natural Turkish. Menu entries, labels and buttons are each their own group.
    - Keep the letter case style of the original (ALL CAPS menu entries stay all caps).
    - Use the wording Turkish game localizations use for menus (Resume = Devam Et, Settings = Ayarlar, \
    Objectives = Hedefler, Checkpoint = Kontrol Noktası).
    - Never translate character names, place names, brand names.
    - Leave out lines that need no translation or carry no meaning: numbers, dates, times, lone names, \
    text that is not English, OCR garbage.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "groups": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "lines": ["type": "array", "items": ["type": "integer"]],
                        "tr": ["type": "string"],
                    ],
                    "required": ["lines", "tr"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any],
        ],
        "required": ["groups"],
        "additionalProperties": false,
    ]

    public init(apiKey: String, model: String = ClaudeTranslator.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Tüm ekranı okuyup çevirir.
    public func translate(frame: CVPixelBuffer) async throws -> [ScreenItem] {
        let lines = try TextRecognizer().recognizeLines(pixelBuffer: frame, roi: CGRect(x: 0, y: 0, width: 1, height: 1))
        return try await translate(lines: lines)
    }

    public func translate(lines all: [RecognizedLine]) async throws -> [ScreenItem] {
        // Harf içermeyen okumalar (rakam, simge) çevrilmez; çok kalabalık ekranda ilk 150 satır alınır.
        let lines = Array(all.filter { $0.text.filter(\.isLetter).count >= 2 }.prefix(150))
        guard !lines.isEmpty else { return [] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: lines, request: &request))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeTranslator.Failure(message: "Claude yanıtı okunamadı (HTTP \(status)).")
        }
        guard status == 200 else {
            let detail = ((object["error"] as? [String: Any])?["message"] as? String) ?? "bilinmeyen hata"
            throw ClaudeTranslator.Failure(message: "Claude HTTP \(status): \(detail)")
        }
        return try Self.items(from: object, lines: lines)
    }

    func body(for lines: [RecognizedLine], request: inout URLRequest) -> [String: Any] {
        let prompt = lines.enumerated().map { "\($0.offset + 1): \($0.element.text)" }.joined(separator: "\n")
        var body: [String: Any] = [
            "model": model,
            // Kalabalık bir ekranın tamamı tek yanıtta döner.
            "max_tokens": 16000,
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": Self.schema]] as [String: Any],
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": prompt]],
        ]
        if model.contains("haiku") {
            body["thinking"] = ["type": "disabled"]
        } else {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        return body
    }

    static func items(from object: [String: Any], lines: [RecognizedLine]) throws -> [ScreenItem] {
        let reason = object["stop_reason"] as? String
        if reason == "refusal" { throw ClaudeTranslator.Failure(message: "Model bu ekranı çevirmeyi geri çevirdi.") }
        if reason == "max_tokens" { throw ClaudeTranslator.Failure(message: "Ekranda çok fazla yazı var; çeviri yarıda kaldı.") }
        let text = (object["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let groups = parsed["groups"] as? [[String: Any]] else {
            throw ClaudeTranslator.Failure(message: "Çeviri yanıtı beklenen biçimde değil.")
        }

        return groups.compactMap { group in
            guard let translation = (group["tr"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !translation.isEmpty,
                  let numbers = group["lines"] as? [Int] else { return nil }
            let members = numbers.compactMap { (1...lines.count).contains($0) ? lines[$0 - 1] : nil }
            guard !members.isEmpty else { return nil }
            // Çeviri özgün metinle aynıysa (ad, marka) üstüne yazmanın anlamı yok.
            let source = members.map(\.text).joined(separator: " ")
            if SubtitleTracker.similarity(source, translation) >= 0.95 { return nil }

            return ScreenItem(covering: members, text: translation)
        }
    }
}

extension ScreenItem {
    /// Bir grup özgün satırın kapladığı alana oturan çeviri öğesi.
    init(covering members: [RecognizedLine], text: String) {
        let left = members.map(\.x).min() ?? 0
        let right = members.map { $0.x + $0.width }.max() ?? 0
        let top = members.map { $0.y - $0.height / 2 }.min() ?? 0
        let bottom = members.map { $0.y + $0.height / 2 }.max() ?? 0
        let heights = members.map(\.height).sorted()
        self.init(x: Double(left), y: Double(top), width: Double(right - left), height: Double(bottom - top),
                  lineHeight: Double(heights.isEmpty ? 0 : heights[heights.count / 2]), lines: members.count, text: text)
    }
}

/// "Ekranı çevir"in anahtarsız yolu: yazılar telefonda okunur ve cihaz üstü çeviriyle çevrilir.
/// Hesap, ücret ve internet gerekmez. Menü girişleri sözlükten (`MenuGlossary`) gelir; paragraflar
/// tek parça çevrilir. Yapay zekâ anahtarı girilmişse onun yerine bağlamı bilen yapay zekâ yolu kullanılır.
public struct LocalScreenTranslator: Sendable {
    /// Bir dizi İngilizce yazıyı çevirir; sonuç aynı sırada döner, çevrilemeyen `nil` olur.
    public typealias Batch = @Sendable ([String]) async -> [String?]

    private let translate: Batch

    public init(translate: @escaping Batch) {
        self.translate = translate
    }

    public func translate(frame: CVPixelBuffer) async throws -> [ScreenItem] {
        let lines = try TextRecognizer().recognizeLines(pixelBuffer: frame, roi: CGRect(x: 0, y: 0, width: 1, height: 1))
        return await translate(lines: lines)
    }

    public func translate(lines all: [RecognizedLine]) async -> [ScreenItem] {
        let lines = Array(all.filter { $0.text.filter(\.isLetter).count >= 2 }.prefix(150))
        let blocks = Self.blocks(from: lines).filter { Self.isWorthTranslating($0.map(\.text).joined(separator: " ")) }
        guard !blocks.isEmpty else { return [] }

        // Sözlükte olanlar hemen; kalanlar tek seferde çevirmene.
        var results = [String?](repeating: nil, count: blocks.count)
        var queued: [(index: Int, caps: Bool)] = []
        var requests: [String] = []
        for (index, block) in blocks.enumerated() {
            let source = block.map(\.text).joined(separator: " ")
            if let known = MenuGlossary.lookup(source) {
                results[index] = known
            } else {
                let caps = MenuGlossary.isAllCaps(source)
                queued.append((index, caps))
                requests.append(caps ? MenuGlossary.sentenceCased(source) : source)
            }
        }
        if !requests.isEmpty {
            let translated = await translate(requests)
            for (offset, entry) in queued.enumerated() where offset < translated.count {
                guard let text = translated[offset]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                results[entry.index] = entry.caps ? text.uppercased(with: Locale(identifier: "tr")) : text
            }
        }

        return blocks.enumerated().compactMap { index, block in
            guard let text = results[index] else { return nil }
            // Çeviri özgün yazıyla aynıysa (ad, marka) üstüne yazmanın anlamı yok.
            let source = block.map(\.text).joined(separator: " ")
            if SubtitleTracker.similarity(source, text) >= 0.95 { return nil }
            return ScreenItem(covering: block, text: text)
        }
    }

    /// Sayaç, tarih, tek harf gibi çevrilecek bir şey içermeyen yazıları eler.
    static func isWorthTranslating(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        let digits = text.filter(\.isNumber).count
        return letters >= 2 && letters > digits
    }

    /// Okunan satırları yazı öbeklerine ayırır: aynı paragrafın satırları tek öbek olur, menü girişleri ve
    /// etiketler ayrı ayrı kalır. Ekranda yan yana sütunlar olabildiği için bir satır, kendi sütununda
    /// hemen üstünde duran öbeğe eklenir (yalnız bir önceki satıra bakılmaz).
    static func blocks(from lines: [RecognizedLine]) -> [[RecognizedLine]] {
        var result: [[RecognizedLine]] = []
        for line in lines.sorted(by: { $0.y < $1.y }) {
            if let index = result.indices.last(where: { continues(result[$0], with: line) }) {
                result[index].append(line)
            } else {
                result.append([line])
            }
        }
        return result
    }

    private static func continues(_ block: [RecognizedLine], with line: RecognizedLine) -> Bool {
        guard let last = block.last, let first = line.text.first else { return false }
        // Aynı sütun: sol kenarlar ya da ortalar hizalı.
        let leftAligned = abs(line.x - last.x) < 0.015
        let centered = abs((line.x + line.width / 2) - (last.x + last.width / 2)) < 0.015
        guard leftAligned || centered else { return false }
        // Hemen altında ve aynı boyda yazı.
        let gap = (line.y - line.height / 2) - (last.y + last.height / 2)
        let taller = max(last.height, line.height), shorter = min(last.height, line.height)
        guard gap > -taller * 0.5, gap < taller * 0.9, shorter >= taller * 0.7 else { return false }

        if first.isLowercase { return true }
        // Büyük harfle başlayan satır: üstteki bitmemiş, uzun bir paragraf satırıysa devamıdır.
        // Kısa girişler (menü, liste) alt alta dursa da ayrı ayrı çevrilir.
        let lastFinished = last.text.last.map { ".!?:".contains($0) } ?? false
        let lastWords = last.text.split(separator: " ").count
        let widest = max(block.map(\.width).max() ?? 0, line.width)
        return !lastFinished && lastWords >= 4 && last.width >= widest * 0.6
            && MenuGlossary.lookup(last.text) == nil && MenuGlossary.lookup(line.text) == nil
    }
}

/// "Ekranı çevir" düğmesinin davranışı: bas → çevir ve göster, yeniden bas → kaldır.
/// Telefondaki düğme ve TV kumandası aynı denetleyiciyi kullanır.
public final class ScreenTranslationController: @unchecked Sendable {
    private let server: SubtitleServer
    private let frame: () -> CVPixelBuffer?
    private let lock = NSLock()
    private var translator: ScreenTranslator?
    private var local: LocalScreenTranslator?
    private var showing = false
    private var generation = 0

    /// Durum değişince çağrılır (telefon arayüzü için): "working", "done", "clear", "error".
    public var onState: (@Sendable (String, String?) -> Void)?
    /// Çeviri bitince çevrilen öğeler ve çevrilen kareyle çağrılır (telefon ekranında göstermek için);
    /// kaldırılınca boş liste gelir.
    public var onItems: (@Sendable ([ScreenItem], CVPixelBuffer?) -> Void)?

    public init(server: SubtitleServer, frame: @escaping () -> CVPixelBuffer?) {
        self.server = server
        self.frame = frame
    }

    public func setTranslator(_ translator: ScreenTranslator?) {
        lock.lock()
        self.translator = translator
        lock.unlock()
    }

    /// Anahtarsız (cihaz üstü) çevirmen; yapay zekâ anahtarı yokken bu kullanılır.
    public func setLocalTranslator(_ translator: LocalScreenTranslator?) {
        lock.lock()
        local = translator
        lock.unlock()
    }

    /// TV'den gelen iletiyi işler.
    public func handle(message: [String: Any]) {
        switch message["type"] as? String {
        case "translateScreen": toggle()
        case "clearScreen": clear()
        default: break
        }
    }

    public func toggle() {
        lock.lock()
        let isShowing = showing
        lock.unlock()
        if isShowing { clear() } else { run() }
    }

    public func clear() {
        lock.lock()
        showing = false
        generation += 1
        lock.unlock()
        server.sendScreen(state: "clear")
        onItems?([], nil)
        onState?("clear", nil)
    }

    private func run() {
        lock.lock()
        let translator = self.translator
        let local = self.local
        showing = true
        generation += 1
        let mine = generation
        lock.unlock()

        guard translator != nil || local != nil else {
            return fail("Çeviri henüz hazır değil; birkaç saniye sonra yeniden dene.", mine)
        }
        guard let frame = frame() else { return fail("PS5 görüntüsü henüz gelmedi.", mine) }

        server.sendScreen(state: "working")
        onState?("working", nil)
        Task {
            do {
                // Anahtar varsa bağlamı bilen yapay zekâ, yoksa cihaz üstü çeviri.
                let items: [ScreenItem]
                if let translator {
                    items = try await translator.translate(frame: frame)
                } else {
                    items = try await local!.translate(frame: frame)
                }
                guard self.isCurrent(mine) else { return }
                if items.isEmpty { return self.fail("Ekranda çevrilecek yazı bulunamadı.", mine) }
                self.server.sendScreen(state: "done", items: items.map(\.json))
                self.onItems?(items, frame)
                self.onState?("done", nil)
            } catch {
                self.fail(error.localizedDescription, mine)
            }
        }
    }

    private func isCurrent(_ mine: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mine == generation
    }

    private func fail(_ message: String, _ mine: Int) {
        guard isCurrent(mine) else { return }
        lock.lock()
        showing = false
        lock.unlock()
        server.sendScreen(state: "error", message: message)
        onState?("error", message)
    }
}
