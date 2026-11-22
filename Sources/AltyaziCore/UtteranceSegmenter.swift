import Foundation

/// Konuşma tanımanın akan (sürekli uzayan ve düzeltilen) dökümünü gösterilecek cümlelere böler.
///
/// Tanıyıcı konuşma sürdükçe dökümü günceller ve son kelimeleri sık sık düzeltir. Ekranda gösterilen
/// yazı sonradan değişmemeli; bu yüzden bir cümle ancak bittiği belli olunca (noktalamadan sonra konuşma
/// devam edince) ya da konuşma durunca verilir.
public struct UtteranceSegmenter: Sendable {
    /// Bu kadar süre yeni kelime gelmezse konuşma bitmiş sayılır ve kalan kısım verilir.
    public var pause: TimeInterval = 0.9
    private var words: [String] = []
    private var emitted = 0
    private var lastChange = Date.distantPast

    public init() {}

    /// Henüz verilmemiş kelime var mı?
    public var hasPending: Bool { emitted < words.count }

    public mutating func reset() {
        words = []
        emitted = 0
        lastChange = .distantPast
    }

    /// Tanıyıcının o anki tam dökümü verilir. Dönen değer: artık kesinleşmiş, gösterilebilecek cümleler.
    public mutating func update(_ transcript: String, at now: Date = Date()) -> [String] {
        let current = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        if current != words {
            words = current
            lastChange = now
        }
        // Tanıyıcı baştaki kelimeleri sildiyse (nadiren) sayaç taşmasın.
        emitted = min(emitted, words.count)

        // Cümle sonu: noktalamayla biten kelime; ardından en az bir kelime daha gelmiş olmalı
        // (son kelimedeki nokta sık sık geri alınır).
        var sentences: [String] = []
        var start = emitted
        var index = emitted
        while index < words.count - 1 {
            if let last = words[index].last, ".?!".contains(last) {
                sentences.append(words[start...index].joined(separator: " "))
                start = index + 1
            }
            index += 1
        }
        emitted = start
        return sentences.filter(Self.isSpeech)
    }

    /// Konuşma durduysa kalan kısmı verir. Düzenli aralıkla çağrılır.
    public mutating func flushIfSilent(at now: Date = Date()) -> String? {
        guard hasPending, now.timeIntervalSince(lastChange) >= pause else { return nil }
        let rest = words[emitted...].joined(separator: " ")
        emitted = words.count
        return Self.isSpeech(rest) ? rest : nil
    }

    /// Tek harflik ya da harfsiz parçalar (gürültüden çıkan "uh", "-") gösterilmez.
    static func isSpeech(_ text: String) -> Bool {
        text.filter(\.isLetter).count >= 3
    }
}
