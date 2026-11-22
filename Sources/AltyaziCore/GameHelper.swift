import Foundation

/// "Takıldım" yardımcısı (DENEME): oyuncunun o an gördüğü ekranı ve son konuşmaları Claude'a gösterip
/// kısa, kademeli bir Türkçe ipucu alır.
///
/// Çeviriden farkı: buraya ekranın GÖRÜNTÜSÜ de gider (çeviride yalnız metin gider). Bu yüzden yalnız
/// kullanıcı düğmeye bastığında, tek bir kare için çalışır; kendiliğinden hiçbir şey göndermez.
public final class GameHelper: @unchecked Sendable {
    /// İpucunun ne kadar açık olacağı: oyuncu çözmenin keyfini kaybetmesin diye üç kademe.
    public enum Depth: Int, Sendable, CaseIterable {
        case nudge = 1, clearer, full
        public var next: Depth { Depth(rawValue: rawValue + 1) ?? .full }
    }

    public struct Context: Sendable {
        /// Kullanıcının seçtiği oyun; boşsa model ekrandan anlamaya çalışır.
        public var game: String
        /// Kullanıcının yazdığı soru (isteğe bağlı).
        public var question: String
        /// Ekranda o an duran görev/ipucu yazıları (İngilizce, okunduğu gibi).
        public var objective: String
        /// Son konuşma satırları, eskiden yeniye (İngilizce).
        public var recentLines: [String]
        public var depth: Depth
        /// Bu takılma için daha önce verilen ipuçları (kademe ilerledikçe tekrar etmesin).
        public var earlierHints: [String]

        public init(game: String = "", question: String = "", objective: String = "", recentLines: [String] = [],
                    depth: Depth = .nudge, earlierHints: [String] = []) {
            self.game = game
            self.question = question
            self.objective = objective
            self.recentLines = recentLines
            self.depth = depth
            self.earlierHints = earlierHints
        }
    }

    public struct Answer: Equatable, Sendable {
        public var text: String
        public var inputTokens: Int
        public var outputTokens: Int
        /// Bu sorunun yaklaşık bedeli (ABD doları), modelin liste fiyatıyla.
        public var cost: Double {
            (Double(inputTokens) * GameHelper.inputPricePerMillion + Double(outputTokens) * GameHelper.outputPricePerMillion) / 1_000_000
        }
    }

    /// Ekrana bakıp oyun bilgisiyle akıl yürütmek gerekiyor: en yetenekli Opus. Hız burada ikinci planda
    /// (oyuncu zaten durmuş, birkaç saniye bekler).
    public static let defaultModel = "claude-opus-5-5"
    /// Claude Opus 5.5 liste fiyatı (milyon belirteç başına dolar); yalnız deneme sırasında bedeli göstermek için.
    static let inputPricePerMillion = 4.0
    static let outputPricePerMillion = 20.0

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let systemPrompt = """
    You are the in-game helper inside Marhilk, an app that Turkish-speaking players use while playing PlayStation 5 games in English. The player just pressed "I'm stuck". You receive a screenshot of what is on their TV right now, the name of the game if they told us, the objective text currently on screen, the most recent subtitle lines, and sometimes a question they typed.

    Your answer is shown as an overlay on the TV while the game keeps running, so the player reads it at a glance from the sofa. Write natural, friendly Turkish in plain text: no markdown, no lists, no headings, at most about 60 words. Address the player as "sen".

    Work out what they are stuck on from the screenshot and the context, then help with that specific moment. When you mention something that appears on screen in English (a menu entry, a button prompt, a place name), keep the English wording and give its Turkish meaning in parentheses the first time, so they can find it on screen. Name controller buttons the PlayStation way (✕, ○, □, △, L1, R2 and so on).

    Hints are graded so the player keeps the fun of solving things. Level 1 is a nudge: point them in the right direction without giving the solution away. Level 2 is clearer: say what to do, briefly, step by step. Level 3 is the full solution. The request states the level and lists the hints already given; build on those instead of repeating them.

    Do not reveal story events the player has not reached yet. Help with how to get past this moment, not with what happens next.

    The player acts on what you say, so being right matters more than sounding sure. Base the answer on what is visible plus what you reliably know about this game. If you do not recognise the game or the place, or the screenshot does not show enough to tell, say so plainly in one sentence and then give the best general suggestion you can from what is visible. Never invent mission details, locations or item names.
    """

    public init(apiKey: String, model: String = GameHelper.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// `jpeg`: oyuncunun o an gördüğü kare (JPEG).
    public func ask(jpeg: Data, context: Context) async throws -> Answer {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Güvenlik sınıflandırıcısı bir isteği geri çevirirse sunucu aynı isteği yedek modelde yeniden dener.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(jpeg: jpeg, context: context))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeTranslator.Failure(message: "Yardımcının yanıtı okunamadı (HTTP \(status)).")
        }
        guard status == 200 else {
            let detail = ((object["error"] as? [String: Any])?["message"] as? String) ?? "bilinmeyen hata"
            throw ClaudeTranslator.Failure(message: "Yardımcı yanıt vermedi (HTTP \(status)): \(detail)")
        }
        return try Self.parse(object)
    }

    func body(jpeg: Data, context: Context) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 16000,
            // Düşünme bu modelde hep açık; derinliği "effort" belirler. Orta: ekrana bakıp akıl yürütmeye yeter,
            // oyuncuyu uzun bekletmez.
            "output_config": ["effort": "medium"],
            "fallbacks": "default",
            "system": Self.systemPrompt,
            "messages": [[
                "role": "user",
                // Görüntü metinden önce gelir (model böyle daha iyi çalışıyor).
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": Self.prompt(for: context)],
                ] as [[String: Any]],
            ] as [String: Any]],
        ]
    }

    static func prompt(for context: Context) -> String {
        let game = context.game.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = context.question.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            "Game: \(game.isEmpty ? "not specified (work it out from the screenshot if you can)" : game)",
            "Hint level: \(context.depth.rawValue) of \(Depth.allCases.count)",
        ]
        let objective = context.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !objective.isEmpty { lines.append("Objective text on screen (as read by OCR): \(objective)") }
        if !context.recentLines.isEmpty {
            lines.append("Recent subtitle lines, oldest first:")
            lines += context.recentLines.suffix(10).map { "- \($0)" }
        }
        lines.append("Player's question: \(question.isEmpty ? "(none; they only pressed \"I'm stuck\")" : question)")
        if !context.earlierHints.isEmpty {
            lines.append("Hints already given for this:")
            lines += context.earlierHints.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }
        return lines.joined(separator: "\n")
    }

    static func parse(_ object: [String: Any]) throws -> Answer {
        if object["stop_reason"] as? String == "refusal" {
            throw ClaudeTranslator.Failure(message: "Yardımcı bu soruyu yanıtlamadı.")
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeTranslator.Failure(message: "Yardımcı boş yanıt verdi.") }
        let usage = object["usage"] as? [String: Any] ?? [:]
        return Answer(text: text, inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: usage["output_tokens"] as? Int ?? 0)
    }
}
