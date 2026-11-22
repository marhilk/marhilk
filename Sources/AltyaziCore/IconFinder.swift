import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bir yazı satırının içindeki tuş simgelerini (✕ ○ □ △, L1, R2…) bulur.
///
/// Yazı okuyucu simgeleri tanımaz: ya atlar ya da "•", "O" gibi rastgele bir harfe çevirir.
/// Simgeler harflerden ayırt edilebilir: satırın tam yüksekliğini kaplayan, eni boyuna yakın,
/// tek parça şekillerdir (harfler daha kısa ya da daha dardır).
enum IconFinder {
    /// Çeviride simgenin yerini tutan işaret (k'inci simge "[k]" olarak yazılır).
    static let placeholder: Character = "⬚"

    /// `lineRect`: satırın görüntüdeki yeri (piksel, başlangıç sol üst). Dönen kutular soldan sağa sıralıdır.
    static func icons(in image: CGImage, lineRect: CGRect) -> [CGRect] {
        guard lineRect.height >= 8, lineRect.width >= 8 else { return [] }
        // Simgeler satır kutusundan biraz taşar: şeridi dikeyde genişlet.
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Yatayda da genişlet: satırın başındaki ya da sonundaki simge yazı kutusunun dışında kalır.
        let strip = lineRect.insetBy(dx: -lineRect.height * 1.8, dy: -lineRect.height * 0.3).intersection(bounds).integral
        guard !strip.isEmpty, let cropped = image.cropping(to: strip) else { return [] }

        // Küçük, gri bir kopya üzerinde çalış (satır yüksekliği ~26 piksel olacak şekilde).
        let height = 42
        let scale = CGFloat(height) / strip.height
        let width = max(8, Int((strip.width * scale).rounded()))
        guard width <= 4000 else { return [] }
        // Renkli çiz, her pikselin EN PARLAK kanalını al: koyu zemindeki kırmızı/mavi simgeler gri tonda
        // zeminle karışır, en parlak kanalda ise beyaz yazı kadar belirgindir.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            pixels[index] = max(rgba[index * 4], rgba[index * 4 + 1], rgba[index * 4 + 2])
        }
        guard drawn else { return [] }

        // Yazı ile zemini ayır (Otsu eşiği); azınlıkta kalan taraf "mürekkep"tir.
        let threshold = otsu(pixels)
        let bright = pixels.reduce(0) { $0 + ($1 > threshold ? 1 : 0) }
        let inkIsBright = bright * 2 < pixels.count
        var ink = pixels.map { ($0 > threshold) == inkIsBright }
        let inkMap = ink   // bağlı parça taraması `ink`i tüketir; zemin ölçümü için kopyası
        // Mürekkep neredeyse yoksa ya da her yer mürekkepse ayrım güvenilmezdir.
        let inkCount = ink.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard inkCount > 20, inkCount * 3 < pixels.count * 2 else { return [] }

        // Her sütunun ne kadarı mürekkep? Neredeyse tamamı mürekkep olan sütun bir kenarlıktır ya da
        // kutunun dışındaki parlak zemindir: yazı ile simge arasında böyle bir sütun varsa o şekil
        // bu yazıya ait değildir (kutunun dışındadır).
        var columnInk = [Int](repeating: 0, count: width)
        for index in 0..<ink.count where ink[index] { columnInk[index % width] += 1 }
        let wall = columnInk.map { $0 * 10 >= height * 8 }
        let textStart = Int(((lineRect.minX - strip.minX) * scale).rounded())
        let textEnd = Int(((lineRect.maxX - strip.minX) * scale).rounded())
        func clear(from: Int, to: Int) -> Bool {
            guard from <= to else { return true }
            return !(max(0, from)...min(width - 1, to)).contains { wall[$0] }
        }

        let lineHeight = lineRect.height * scale
        var found: [CGRect] = []
        var outside: [CGRect] = []
        var merged: [CGRect] = []
        var stack: [Int] = []
        for start in 0..<ink.count where ink[start] {
            // Bağlı parçayı gez (8 komşuluk), sınır kutusunu çıkar.
            var minX = width, maxX = 0, minY = height, maxY = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            ink[start] = false
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        if ink[next] {
                            ink[next] = false
                            stack.append(next)
                        }
                    }
                }
            }
            let w = CGFloat(maxX - minX + 1), h = CGFloat(maxY - minY + 1)
            // Şeridin kenarına yapışan parça büyük olasılıkla zemindir (kutu kenarı, manzara).
            guard minX > 0, maxX < width - 1 else { continue }
            let rect = CGRect(x: strip.minX + CGFloat(minX) / scale, y: strip.minY + CGFloat(minY) / scale,
                              width: w / scale, height: h / scale)
            if rect.minX >= lineRect.maxX || rect.maxX <= lineRect.minX {
                // Yazının dışında (satır başında/sonunda) duran şekil: harf olamaz, o yüzden ölçüt gevşektir
                // (yatak, ev gibi basık ya da küçük simgeler). İnce çizgiler (kutu kenarlığı) elenir.
                guard h >= lineHeight * 0.4, w >= lineHeight * 0.4, h <= lineHeight * 1.3, w <= lineHeight * 2.6 else { continue }
                // Şeridin üstüne ya da altına dayanan şekil simge değildir: kutunun yanından görünen
                // manzaradır (simge satırın içinde kalır, çevresi kutu zeminidir).
                guard minY > 0, maxY < height - 1 else { continue }
                // Yazı ile şekil arasında kenarlık/zemin geçişi olmamalı (aynı kutunun içinde olmalı).
                guard maxX < textStart ? clear(from: maxX, to: textStart) : clear(from: textEnd, to: minX) else { continue }
                // Simgenin iki yanındaki zemin aynı olmalı (ikisi de kutunun zemini). Bir yanı kutu, öbür
                // yanı manzara olan şekil, kutunun kenarından görünen manzara parçasıdır.
                guard let leftLevel = background(pixels, isInk: inkMap, width: width, columns: (minX - 4)..<(minX - 1), rows: minY...maxY),
                      let rightLevel = background(pixels, isInk: inkMap, width: width, columns: (maxX + 2)..<(maxX + 5), rows: minY...maxY),
                      abs(leftLevel - rightLevel) <= 18 else { continue }
                outside.append(rect)
            } else {
                // Yazının içinde: satırın tam yüksekliğinde, eni boyuna yakın. Harfler daha kısa
                // (büyük harf ≈ %70) ya da dardır.
                guard h >= lineHeight * 0.88, h <= lineHeight * 1.7, w >= h * 0.75, w <= h * 2.3 else { continue }
                found.append(rect.insetBy(dx: -2, dy: -2).intersection(bounds))
            }
        }
        // Satır dışındaki simge birkaç parçadan oluşabilir (yatak: gövde + yastık): yakın parçaları birleştir.
        let reach = lineRect.height * 0.35
        for piece in outside.sorted(by: { $0.minX < $1.minX }) {
            if let index = merged.indices.last, piece.minX - merged[index].maxX <= reach {
                merged[index] = merged[index].union(piece)
            } else {
                merged.append(piece)
            }
        }
        // Yazıya bitişik olmayan (bir simge boyundan uzak) şekiller başka bir şeye aittir.
        for rect in merged {
            let distance = rect.minX >= lineRect.maxX ? rect.minX - lineRect.maxX : lineRect.minX - rect.maxX
            if distance <= lineRect.height * 0.9 { found.append(rect.insetBy(dx: -2, dy: -2).intersection(bounds)) }
        }
        // İç içe bulunanları at (simgenin içindeki şekil), soldan sağa sırala.
        let outer = found.filter { candidate in !found.contains { $0 != candidate && $0.contains(candidate) } }
        return outer.sorted { $0.minX < $1.minX }
    }

    /// Simgelerin yerine yer tutucu koyar. Yazı okuyucunun simge yerine uydurduğu tek harflik
    /// parçalar ("•", "O", "X") yer tutucuyla değiştirilir; uydurmadıysa en yakın kelime arasına eklenir.
    /// - Parameters:
    ///   - lineStart/lineEnd: satırın sol ve sağ kenarı; `icons` aynı ölçüde (merkez, genişlik), soldan sağa.
    static func mark(text: String, lineStart: CGFloat, lineEnd: CGFloat, icons: [(center: CGFloat, width: CGFloat)]) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard !icons.isEmpty, !words.isEmpty, lineEnd > lineStart else { return text }
        let iconsWidth = icons.reduce(0) { $0 + $1.width }
        // Simgeler satırda yer kaplar ama (çoğu zaman) harf üretmez: konumu yazının genişliğine göre ölç.
        let textWidth = max(lineEnd - lineStart - iconsWidth, (lineEnd - lineStart) * 0.3)
        let length = CGFloat(text.count)

        // Her kelime arası için karakter konumu: 0 = satır başı, son = satır sonu.
        var boundaries: [CGFloat] = [0]
        var offset = 0
        for word in words {
            offset += word.count
            boundaries.append(CGFloat(offset))
            offset += 1
        }

        var replace = Set<Int>()         // yer tutucuya dönüşecek kelimeler
        var insertBefore: [Int: Int] = [:] // kelime sırası → önüne eklenecek yer tutucu sayısı
        var passed: CGFloat = 0
        for icon in icons {
            let position = (icon.center - lineStart - passed - icon.width / 2) / textWidth * length
            passed += icon.width
            let boundary = boundaries.indices.min { abs(boundaries[$0] - position) < abs(boundaries[$1] - position) } ?? 0
            // Sınırın iki yanındaki kelimelerden biri uydurma ise onu değiştir.
            let neighbours = [boundary - 1, boundary].filter { index in
                guard words.indices.contains(index), !replace.contains(index) else { return false }
                // Cümle ortasında tek başına duran büyük harf ("house A Brian") de uydurmadır.
                let midSentence = index > 0 && !(words[index - 1].last.map { ".!?:".contains($0) } ?? false)
                return isStandIn(words[index]) || (midSentence && isLoneCapital(words[index]))
            }
            if let target = neighbours.min(by: { abs(CGFloat($0) + 0.5 - CGFloat(boundary)) < abs(CGFloat($1) + 0.5 - CGFloat(boundary)) }) {
                replace.insert(target)
            } else {
                insertBefore[boundary, default: 0] += 1
            }
        }

        var result: [String] = []
        for index in 0...words.count {
            for _ in 0..<(insertBefore[index] ?? 0) { result.append(String(placeholder)) }
            if index < words.count { result.append(replace.contains(index) ? String(placeholder) : words[index]) }
        }
        // Simgesi bulunan satırda kalan uydurma işaretler ("¿", "•") çeviriye girmesin.
        let marker = String(placeholder)
        words = result.enumerated().filter { index, word in
            guard word.count == 1, let mark = word.first, mark != placeholder else { return true }
            // Simgenin hemen yanındaki tek rakam da uydurmadır ("description 9 ⬚").
            let besideIcon = (index > 0 && result[index - 1] == marker) || (index + 1 < result.count && result[index + 1] == marker)
            if mark.isNumber { return !besideIcon }
            return mark.isLetter
        }.map(\.element)
        return words.joined(separator: " ")
    }

    /// Yazı okuyucunun bir simge yerine yazmış olabileceği tek karakter.
    static func isStandIn(_ word: String) -> Bool {
        guard word.count == 1, let character = word.first else { return false }
        if !character.isLetter && !character.isNumber { return true }   // • © @ ○ ■ × …
        return "OXQD0".contains(character)
    }

    /// Tek başına duran büyük harf ("I" hariç: İngilizcede "ben").
    static func isLoneCapital(_ word: String) -> Bool {
        guard word.count == 1, let character = word.first else { return false }
        return character.isUppercase && character != "I"
    }

    /// Görüntünün bir parçasını `data:` adresi olarak verir (TV sayfası doğrudan resim olarak basar).
    static func dataURL(of image: CGImage, rect: CGRect) -> String? {
        guard let cropped = image.cropping(to: rect.integral) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    /// Verilen sütun ve satır aralığındaki zemin (mürekkep olmayan) piksellerin ortanca parlaklığı.
    private static func background(_ pixels: [UInt8], isInk: [Bool], width: Int, columns: Range<Int>, rows: ClosedRange<Int>) -> Int? {
        var values: [UInt8] = []
        for x in columns where x >= 0 && x < width {
            for y in rows {
                let index = y * width + x
                if !isInk[index] { values.append(pixels[index]) }
            }
        }
        guard values.count >= 4 else { return nil }
        values.sort()
        return Int(values[values.count / 2])
    }

    private static func otsu(_ pixels: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        let total = pixels.count
        let sumAll = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumBelow = 0.0, countBelow = 0, best = 0.0, threshold = 127
        for level in 0..<256 {
            countBelow += histogram[level]
            guard countBelow > 0, countBelow < total else { continue }
            sumBelow += Double(level * histogram[level])
            let meanBelow = sumBelow / Double(countBelow)
            let meanAbove = (sumAll - sumBelow) / Double(total - countBelow)
            let between = Double(countBelow) * Double(total - countBelow) * (meanBelow - meanAbove) * (meanBelow - meanAbove)
            if between > best {
                best = between
                threshold = level
            }
        }
        return UInt8(threshold)
    }
}
