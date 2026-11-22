import Foundation

/// Oyun altyazısını Claude ile, önceki satırların bağlamını bilerek Türkçeye çevirir.
/// İnternet ve bir Anthropic API anahtarı gerektirir; yalnız METİN gönderilir, görüntü gitmez.
public final class ClaudeTranslator: @unchecked Sendable {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Kullanıcının seçimi (16 Kas 2026): canlı altyazıda hız, en yetenekli modelin doğallığından önemli.
    /// Ölçülen: Haiku 5.5 ≈ 0,9 sn, Opus 5.5 1,1–3,5 sn.
    public static let defaultModel = "claude-haiku-5-5"

    public enum Outcome: Equatable, Sendable {
        case translation(String)
        /// Satır oyuncu için anlam taşımıyor (kayıt bildirimi, rastgele karakterler): gösterilmez.
        case notForPlayer
        /// Model satırı çevirmeyi geri çevirdi: cihaz üstü çeviri kullanılır.
        case declined
    }

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let systemPrompt = """
    You translate video-game on-screen text from English to Turkish for a live overlay shown to a player while they play.

    Each request gives you ONE line exactly as an OCR engine read it from the game screen, preceded by the most recent lines for context.

    Rules:
    - Reply with the Turkish translation only, on a single line. No quotes, no notes, no explanations.
    - Write the natural spoken Turkish a professional game localization would use. Keep the tone, slang and level of profanity of the original. Use the terms the genre uses (military ranks, for example: "Private Park" is "Er Park"; a soldier's "sir" is "komutanım").
    - Never translate character or place names.
    - If the line begins with a speaker label ("Jae: ..." or "Jae [..]"), keep it as "Jae: " (always with the colon) followed by the translation. Keep square brackets when the original has them.
    - Translate short bracketed tags in front of a player choice too ("[Lie] Yes" becomes "[Yalan] Evet").
    - Silently repair obvious OCR mistakes ("|" read for "I", "0" for "o", a missing colon, a stray character).
    - Player choices, questions, objectives, tutorial hints and button prompts ARE worth translating: the player needs them.
    - If the line carries no meaning for the player (a save notice, a timestamp, a lone menu label, random characters), reply with exactly one hyphen: -
    - Stay consistent with how earlier lines were translated (names, terms, formal vs. informal address).
    """

    public init(apiKey: String, model: String = ClaudeTranslator.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func translate(line: String, context: [(source: String, target: String)]) async throws -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(line: line, context: context, request: &request))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Claude yanıtı okunamadı (HTTP \(status)).")
        }
        guard status == 200 else {
            let detail = ((object["error"] as? [String: Any])?["message"] as? String) ?? "bilinmeyen hata"
            throw Failure(message: "Claude HTTP \(status): \(detail)")
        }
        return Self.parse(object)
    }

    func body(line: String, context: [(source: String, target: String)], request: inout URLRequest) -> [String: Any] {
        var prompt = ""
        if !context.isEmpty {
            prompt += "Previous lines:\n"
            for pair in context { prompt += "EN: \(pair.source)\nTR: \(pair.target)\n" }
            prompt += "\n"
        }
        prompt += "Line to translate:\n\(line)"

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            // Kısa, anlık bir iş: düşünme derinliği en düşükte.
            "output_config": ["effort": "low"],
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": prompt]],
        ]
        if model.contains("haiku") {
            // Tek satırlık çeviride düşünme adımı yalnız gecikme katar; Haiku'da kapatılabiliyor.
            body["thinking"] = ["type": "disabled"]
        } else {
            // Güvenlik sınıflandırıcısı bir satırı (ör. sert bir replik) geri çevirirse sunucu aynı isteği
            // yedek modelde yeniden dener. Bu özellik Haiku'da yok; orada cihaz üstü çeviriye dönülür.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        return body
    }

    static func parse(_ object: [String: Any]) -> Outcome {
        if object["stop_reason"] as? String == "refusal" { return .declined }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if text == "-" { return .notForPlayer }
        return text.isEmpty ? .declined : .translation(text)
    }
}
