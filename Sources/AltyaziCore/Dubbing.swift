import Foundation

/// Dublaj (DENEME): çevrilen replik Türkçe seslendirilir. Oyunun kendi sesi kapanmaz; Türkçe ses onun
/// üstüne, replik ekrana geldikten kısa süre sonra okunur (belgesellerdeki üstüne okuma gibi).
///
/// Bu dosya ses motorundan bağımsız kısmı tutar: hangi karakter hangi sesle konuşur, hangi yazı okunur,
/// ElevenLabs isteği nasıl kurulur. Sesi çalmak uygulamanın işidir.

public enum DubGender: String, Sendable, Codable, CaseIterable {
    case male, female, unknown
}

/// ElevenLabs'in herkese açık hazır seslerinden biri (kimlikleri bütün hesaplarda aynıdır).
public struct DubVoice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Sesin karakteri (kullanıcıya gösterilir).
    public let note: String
}

/// Karakterlere ses dağıtımı. Aynı karakter hep aynı sesle konuşur; aynı cinsiyetten karakterler
/// olabildiğince farklı ses alır. Cinsiyeti bilinmeyen ya da adı yazmayan konuşan "anlatıcı" sesiyle okunur.
public struct VoiceCast: Sendable, Equatable {
    /// Adı ya da cinsiyeti bilinmeyen konuşanlar: düz, sakin, Türkçe için doğrulanmış bir ses.
    public static let narrator = DubVoice(id: "onwK4e9ZLuTAKqWW03F9", name: "Daniel", note: "sakin anlatıcı")

    /// Sıra, birbirinden en kolay ayırt edilen seslerden başlar: ilk karakterler en farklı sesleri alır.
    public static let men: [DubVoice] = [
        DubVoice(id: "nPczCjzI2devNBz1zQrb", name: "Brian", note: "derin, tok"),
        DubVoice(id: "TX3LPaxmHKxFdv7VOQHJ", name: "Liam", note: "genç, enerjik"),
        DubVoice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam", note: "sert, baskın"),
        DubVoice(id: "N2lVS1w4EtoT3dr4eOWO", name: "Callum", note: "boğuk, kurnaz"),
        DubVoice(id: "pqHfZKP75CvOlQylNhV4", name: "Bill", note: "yaşlı, bilge"),
        DubVoice(id: "SOYHLrjzK2X1ezoPC6cr", name: "Harry", note: "hırçın savaşçı"),
        DubVoice(id: "IKne3meq5aSn9XLyUdCD", name: "Charlie", note: "genç, canlı"),
        DubVoice(id: "cjVigY5qzO86Huf0OWal", name: "Eric", note: "yumuşak, güven veren"),
    ]

    public static let women: [DubVoice] = [
        DubVoice(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", note: "olgun, kendinden emin"),
        DubVoice(id: "cgSgspJ2msm6clMCkdW9", name: "Jessica", note: "genç, neşeli"),
        DubVoice(id: "pFZP5JQG7iQjIQuC4Bku", name: "Lily", note: "kadife, ağırbaşlı"),
        DubVoice(id: "FGY2WhTYpPnrIDTdsKH5", name: "Laura", note: "genç, alaycı"),
        DubVoice(id: "XrExE9yKIg1WjnnlVkGX", name: "Matilda", note: "bilgili, düzgün"),
    ]

    public static func voice(id: String) -> DubVoice? {
        ([narrator] + men + women).first { $0.id == id }
    }

    /// Konuşan (küçük harfle) → ses kimliği. Oyun başına saklanır: karakter her oturumda aynı sesi alır.
    public private(set) var assigned: [String: String]

    public init(assigned: [String: String] = [:]) {
        self.assigned = assigned
    }

    public mutating func voice(for speaker: String?, gender: DubGender) -> DubVoice {
        let key = (speaker ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, gender != .unknown else { return Self.narrator }
        let pool = gender == .female ? Self.women : Self.men
        if let id = assigned[key], let kept = pool.first(where: { $0.id == id }) { return kept }
        // En az kullanılan ses (eşitlikte sıradaki ilk ses): kalabalık oyunda sesler dengeli dağılır.
        let usage = Dictionary(grouping: assigned.values, by: { $0 }).mapValues(\.count)
        let chosen = pool.enumerated().min { left, right in
            let a = usage[left.element.id] ?? 0, b = usage[right.element.id] ?? 0
            return a != b ? a < b : left.offset < right.offset
        }?.element ?? Self.narrator
        assigned[key] = chosen.id
        return chosen
    }

    /// Konuşanın cinsiyeti: önce kullanıcının seçimi, sonra oyunun hazır paketi; ikisi de yoksa bilinmiyor.
    public static func gender(of speaker: String?, pack: GamePack?, overrides: [String: DubGender]) -> DubGender {
        let name = (speaker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .unknown }
        if let chosen = overrides[name.lowercased()], chosen != .unknown { return chosen }
        guard let pack else { return .unknown }
        // "Captain Price" gibi etiketlerde adın kendisi kelimelerden biridir.
        let words = Set([name.lowercased()] + name.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init))
        if pack.women.contains(where: { words.contains($0.lowercased()) }) { return .female }
        if pack.terms.contains(where: { words.contains($0.lowercased()) }) { return .male }
        return .unknown
    }
}

public enum DubText {
    /// Okunacak yazı: tuş işaretleri ("[1]") ve köşeli etiketler ("[Yalan]") atılır, boşluklar toplanır.
    /// Okunacak bir şey kalmıyorsa `nil`.
    public static func clean(_ text: String) -> String? {
        var result = ""
        var depth = 0
        for character in text {
            if character == "[" { depth += 1; continue }
            if character == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = result.first, first == "-" || first == "–" || first == "—" || first == " " { result.removeFirst() }
        guard result.filter(\.isLetter).count >= 2 else { return nil }
        // Çok uzun bir satır (belge, mektup) dublajı tıkamasın.
        return result.count > 320 ? String(result.prefix(320)) : result
    }
}

/// Sırada bekleyen replikler: konuşma hızlanınca dublaj geride kalmasın diye yalnız en yeni birkaç replik
/// tutulur; daha eskisi okunmadan atılır (altyazısı zaten ekrandadır).
public struct LatestQueue<Element> {
    public private(set) var items: [Element] = []
    public let limit: Int

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Yeni öğeyi ekler; sınır aşılırsa atılan en eski öğeleri döner.
    @discardableResult
    public mutating func push(_ element: Element) -> [Element] {
        items.append(element)
        guard items.count > limit else { return [] }
        let dropped = Array(items.prefix(items.count - limit))
        items.removeFirst(items.count - limit)
        return dropped
    }

    public mutating func pop() -> Element? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() {
        items = []
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// ElevenLabs ile seslendirme. İnternet ve bir ElevenLabs anahtarı gerektirir; yalnız okunacak
/// Türkçe METİN gönderilir.
public final class ElevenLabsSpeech: @unchecked Sendable {
    public enum Failure: LocalizedError, Equatable {
        /// Hesabın karakter hakkı bitti.
        case quota
        /// Anahtar geçersiz.
        case unauthorized
        case other(String)

        public var errorDescription: String? {
            switch self {
            case .quota: return "ElevenLabs hesabının aylık hakkı bitti."
            case .unauthorized: return "ElevenLabs anahtarı geçersiz."
            case .other(let message): return message
            }
        }
    }

    /// Düşük gecikmeli ve karakter başına yarı fiyatlı model; Türkçeyi destekler.
    public static let model = "eleven_flash_v2_5"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func request(text: String, voice: String) throws -> URLRequest {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_64")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": Self.model,
            // Dil açıkça verilir: kısa repliklerde ("OK.", "Hadi!") model dili yanlış tahmin etmesin.
            "language_code": "tr",
            // Biraz hızlı okuma: Türkçe ses, oyundaki özgün repliğin gerisinde kalmasın.
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.75, "speed": 1.1],
        ] as [String: Any])
        return request
    }

    /// Okunmuş ses (MP3).
    public func synthesize(text: String, voice: String) async throws -> Data {
        let (data, response) = try await session.data(for: try request(text: text, voice: voice))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else { throw Self.failure(status: status, body: data) }
        return data
    }

    static func failure(status: Int, body: Data) -> Failure {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail = object?["detail"] as? [String: Any]
        let code = (detail?["status"] as? String) ?? ""
        let message = (detail?["message"] as? String) ?? (object?["detail"] as? String) ?? ""
        if code.contains("quota") || message.lowercased().contains("quota") { return .quota }
        if status == 401 { return .unauthorized }
        return .other("ElevenLabs yanıt vermedi (HTTP \(status))\(message.isEmpty ? "" : ": \(message)")")
    }
}
