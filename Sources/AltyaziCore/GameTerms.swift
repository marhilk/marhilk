import Foundation

/// Oyuna özel "çevirme" listesi: karakter, yer ve silah adları çeviride olduğu gibi kalır.
///
/// Cihaz üstü çeviriye sözlük verilemiyor; "Ghost" gibi adları "Hayalet" diye çeviriyor. Bu yüzden
/// ad, çeviriden önce çevirmenin dokunmadığı uydurma bir özel adla değiştirilir ("Ghost" → "Qorvax"),
/// çeviriden sonra geri konur. Uydurma ad çeviride kaybolursa koruma yapılmamış sayılır (`restore` nil
/// döner) ve çağıran, metni korumasız çevirir: en kötü durumda bugünkü davranışa düşülür.
public struct TermProtector: Sendable {
    /// Çevirmenin özel ad sanıp olduğu gibi bıraktığı uydurma adlar.
    static let tokens = ["Qorvax", "Zelkin", "Vymar", "Drexon", "Kuvral", "Yarnek", "Bolvek", "Tazrin",
                         "Hexmor", "Jundal", "Pravik", "Sorvek", "Wendar", "Lumrix", "Garvon", "Nelzor"]

    public struct Protected: Sendable {
        public var text: String
        /// Kullanılan uydurma ad → metindeki özgün yazılış.
        public var replacements: [(token: String, term: String)]
        public var isEmpty: Bool { replacements.isEmpty }
    }

    /// Uzun adlar önce denensin diye uzunluğa göre sıralı ("Captain Price", "Price"den önce).
    private let terms: [String]

    public init(terms: [String]) {
        var seen = Set<String>()
        self.terms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && seen.insert($0.lowercased()).inserted }
            .sorted { $0.count > $1.count }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Listedeki adları uydurma adlarla değiştirir. Ad, kelime olarak ve baş harfi büyük (ya da tümü
    /// büyük) yazıldığında eşleşir: "Ghost" korunur, cümle içindeki küçük harfli "ghost" (hayalet) çevrilir.
    public func protect(_ text: String) -> Protected {
        var result = text
        var replacements: [(token: String, term: String)] = []
        for term in terms where replacements.count < Self.tokens.count {
            var searchFrom = result.startIndex
            while replacements.count < Self.tokens.count,
                  let range = result.range(of: term, options: [.caseInsensitive], range: searchFrom..<result.endIndex) {
                let found = String(result[range])
                let startsUpper = found.first?.isUppercase ?? false
                let before = range.lowerBound == result.startIndex ? nil : result[result.index(before: range.lowerBound)]
                let after = range.upperBound == result.endIndex ? nil : result[range.upperBound]
                let wholeWord = !(before?.isLetter ?? false) && !(before?.isNumber ?? false)
                    && !(after?.isLetter ?? false) && !(after?.isNumber ?? false)
                guard wholeWord, startsUpper else {
                    searchFrom = range.upperBound
                    continue
                }
                // Aynı ad metinde yine geçiyorsa aynı uydurma adı kullan.
                let token = replacements.first { $0.term == found }?.token ?? Self.tokens[replacements.count]
                if !replacements.contains(where: { $0.token == token }) { replacements.append((token, found)) }
                result.replaceSubrange(range, with: token)
                searchFrom = result.index(range.lowerBound, offsetBy: token.count)
            }
        }
        return Protected(text: result, replacements: replacements)
    }

    /// Çevrilmiş metinde uydurma adların yerine özgün adları koyar. Bir uydurma ad çeviride yoksa
    /// (çevirmen onu değiştirdi ya da attı) `nil` döner.
    public func restore(_ translated: String, from protected: Protected) -> String? {
        var result = translated
        for (token, term) in protected.replacements {
            guard result.range(of: token, options: [.caseInsensitive]) != nil else { return nil }
            while let range = result.range(of: token, options: [.caseInsensitive]) {
                result.replaceSubrange(range, with: term)
            }
        }
        return result
    }
}

/// Oyun menülerinde tek başına duran kısa girişler. Cihaz üstü çeviri bunları bağlamsız çevirince
/// saçmalıyor ("Resume" → "Özgeçmiş", "Save" → "Kurtarmak"); Türkçe oyunların kullandığı karşılıklar
/// buradan verilir. Yalnız girişin TAMAMI eşleşirse kullanılır; cümle içindeki kelimelere dokunulmaz.
public enum MenuGlossary {
    static let entries: [String: String] = [
        "resume": "Devam Et", "continue": "Devam Et", "resume game": "Oyuna Dön", "back to game": "Oyuna Dön",
        "new game": "Yeni Oyun", "new game+": "Yeni Oyun+", "load": "Yükle", "load game": "Oyun Yükle",
        "save": "Kaydet", "save game": "Oyunu Kaydet", "quick save": "Hızlı Kayıt", "autosave": "Otomatik Kayıt",
        "options": "Seçenekler", "settings": "Ayarlar", "controls": "Kontroller", "audio": "Ses", "video": "Görüntü",
        "graphics": "Grafik", "display": "Ekran", "gameplay": "Oynanış", "accessibility": "Erişilebilirlik",
        "language": "Dil", "subtitles": "Altyazılar", "difficulty": "Zorluk", "brightness": "Parlaklık",
        "quit": "Çık", "quit game": "Oyundan Çık", "exit": "Çıkış", "exit game": "Oyundan Çık",
        "quit to main menu": "Ana Menüye Dön", "exit to main menu": "Ana Menüye Dön", "main menu": "Ana Menü",
        "quit to title": "Başlık Ekranına Dön", "return to title": "Başlık Ekranına Dön",
        "restart": "Yeniden Başlat", "restart checkpoint": "Kontrol Noktasından Başla",
        "restart from checkpoint": "Kontrol Noktasından Başla", "load checkpoint": "Kontrol Noktasını Yükle",
        "last checkpoint": "Son Kontrol Noktası", "checkpoint": "Kontrol Noktası", "restart mission": "Görevi Yeniden Başlat",
        "back": "Geri", "next": "İleri", "previous": "Önceki", "confirm": "Onayla", "cancel": "Vazgeç",
        "accept": "Kabul Et", "decline": "Reddet", "apply": "Uygula", "reset": "Sıfırla", "default": "Varsayılan",
        "defaults": "Varsayılanlar", "select": "Seç", "close": "Kapat", "skip": "Geç", "yes": "Evet", "no": "Hayır",
        "ok": "Tamam", "on": "Açık", "off": "Kapalı", "enabled": "Açık", "disabled": "Kapalı",
        "easy": "Kolay", "normal": "Normal", "hard": "Zor", "very hard": "Çok Zor", "low": "Düşük", "medium": "Orta",
        "high": "Yüksek", "inventory": "Envanter", "map": "Harita", "world map": "Dünya Haritası", "journal": "Günlük",
        "quests": "Görevler", "quest": "Görev", "missions": "Görevler", "mission": "Görev", "objectives": "Hedefler",
        "objective": "Hedef", "main quests": "Ana Görevler", "side quests": "Yan Görevler", "side missions": "Yan Görevler",
        "skills": "Yetenekler", "skill tree": "Yetenek Ağacı", "abilities": "Yetenekler", "perks": "Avantajlar",
        "upgrades": "Geliştirmeler", "upgrade": "Geliştir", "crafting": "Üretim", "craft": "Üret", "equipment": "Ekipman",
        "equip": "Kuşan", "unequip": "Çıkar", "weapons": "Silahlar", "weapon": "Silah", "armor": "Zırh", "items": "Eşyalar",
        "item": "Eşya", "character": "Karakter", "stats": "İstatistikler", "collectibles": "Koleksiyon Parçaları",
        "trophies": "Kupalar", "achievements": "Başarımlar", "store": "Mağaza", "shop": "Dükkân", "buy": "Satın Al",
        "sell": "Sat", "use": "Kullan", "drop": "Bırak", "discard": "At", "inspect": "İncele", "examine": "İncele",
        "open": "Aç", "take": "Al", "take all": "Hepsini Al", "talk": "Konuş", "leave": "Ayrıl", "goodbye": "Hoşça kal",
        "attack": "Saldır", "defend": "Savun", "run": "Kaç", "wait": "Bekle", "rest": "Dinlen", "sleep": "Uyu",
        "fast travel": "Hızlı Yolculuk", "photo mode": "Fotoğraf Modu", "credits": "Emeği Geçenler", "extras": "Ekstralar",
        "online": "Çevrimiçi", "multiplayer": "Çok Oyunculu", "single player": "Tek Oyunculu", "campaign": "Hikâye",
        "story": "Hikâye", "play": "Oyna", "start": "Başla", "start game": "Oyunu Başlat", "paused": "Duraklatıldı",
        "pause": "Duraklat", "loading": "Yükleniyor", "saving": "Kaydediliyor", "game over": "Oyun Bitti",
        "you died": "Öldün", "mission failed": "Görev Başarısız", "mission complete": "Görev Tamamlandı",
        "level up": "Seviye Atladın", "level": "Seviye", "health": "Can", "stamina": "Dayanıklılık", "damage": "Hasar",
        "tutorial": "Öğretici", "tutorials": "Öğreticiler", "help": "Yardım", "hint": "İpucu", "hints": "İpuçları",
        "codex": "Kodeks", "notes": "Notlar", "documents": "Belgeler", "messages": "Mesajlar", "loadout": "Teçhizat",
    ]

    /// Girişin Türkçesi; büyük-küçük harf düzeni özgün yazıdaki gibi olur. Listede yoksa `nil`.
    public static func lookup(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".:…"))
        guard let turkish = entries[key] else { return nil }
        return isAllCaps(trimmed) ? turkish.uppercased(with: Locale(identifier: "tr")) : turkish
    }

    /// Yazının tamamı büyük harfle mi yazılmış (en az iki harf)?
    public static func isAllCaps(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// Tümü büyük harfli yazıyı çevirmene vermeden önce cümle düzenine getirir ("ACCEPT THE CONTRACT" →
    /// "Accept the contract"): çevirmen büyük harfli yazıda daha çok yanılıyor.
    public static func sentenceCased(_ text: String) -> String {
        let lower = text.lowercased()
        guard let first = lower.first else { return lower }
        return first.uppercased() + lower.dropFirst()
    }
}
