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

            let left = members.map(\.x).min()!
            let right = members.map { $0.x + $0.width }.max()!
            let top = members.map { $0.y - $0.height / 2 }.min()!
            let bottom = members.map { $0.y + $0.height / 2 }.max()!
            let heights = members.map(\.height).sorted()
            return ScreenItem(x: Double(left), y: Double(top), width: Double(right - left), height: Double(bottom - top),
                              lineHeight: Double(heights[heights.count / 2]), lines: members.count, text: translation)
        }
    }
}

/// "Ekranı çevir" düğmesinin davranışı: bas → çevir ve göster, yeniden bas → kaldır.
/// Telefondaki düğme ve TV kumandası aynı denetleyiciyi kullanır.
public final class ScreenTranslationController: @unchecked Sendable {
    private let server: SubtitleServer
    private let frame: () -> CVPixelBuffer?
    private let lock = NSLock()
    private var translator: ScreenTranslator?
    private var showing = false
    private var generation = 0

    /// Durum değişince çağrılır (telefon arayüzü için): "working", "done", "clear", "error".
    public var onState: (@Sendable (String, String?) -> Void)?

    public init(server: SubtitleServer, frame: @escaping () -> CVPixelBuffer?) {
        self.server = server
        self.frame = frame
    }

    public func setTranslator(_ translator: ScreenTranslator?) {
        lock.lock()
        self.translator = translator
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
        onState?("clear", nil)
    }

    private func run() {
        lock.lock()
        let translator = self.translator
        showing = true
        generation += 1
        let mine = generation
        lock.unlock()

        guard let translator else {
            return fail("Ekranı çevirmek için yapay zekâ anahtarı gerekli (telefondaki ayarlardan girilir).", mine)
        }
        guard let frame = frame() else { return fail("PS5 görüntüsü henüz gelmedi.", mine) }

        server.sendScreen(state: "working")
        onState?("working", nil)
        Task {
            do {
                let items = try await translator.translate(frame: frame)
                guard self.isCurrent(mine) else { return }
                if items.isEmpty { return self.fail("Ekranda çevrilecek yazı bulunamadı.", mine) }
                self.server.sendScreen(state: "done", items: items.map(\.json))
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
