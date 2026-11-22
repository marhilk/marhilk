import Foundation

/// Isınma koruması: telefon ısındıkça ekran okuma işinin ne kadar hafifletileceği.
///
/// Telefonu en çok ısıtan iş, kareleri saniyede birçok kez okumaktır. Konuşma altyazısı işin kendisidir;
/// görev yazıları, konuşma seçenekleri ve altyazının yerini arama ise yan okumalardır. Telefon ısınınca
/// önce yan okumalar seyreltilir; konuşma okuması yalnız son kademede (telefon kendini korumaya almak
/// üzereyken) yavaşlar.
public enum ReadingLoad: Int, Sendable, Comparable, CaseIterable {
    /// Her şey olağan hızda.
    case full
    /// Telefon ılık: yan okumalar biraz seyrek (fark edilmez).
    case eased
    /// Telefon sıcak: yan okumalar üçte bir hızda.
    case light
    /// Telefon çok sıcak: yan okumalar durur, konuşma okuması yarı hıza iner.
    case minimal

    public static func < (left: ReadingLoad, right: ReadingLoad) -> Bool { left.rawValue < right.rawValue }

    /// Telefonun bildirdiği ısı durumundan kademe. Düşük Güç Modu bir kademe hafifletir ama tek başına
    /// yan okumaları durdurmaz (durdurmak yalnız ısı gerektirdiğinde yapılır).
    public static func level(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> ReadingLoad {
        let base: ReadingLoad
        switch thermal {
        case .nominal: base = .full
        case .fair: base = .eased
        case .serious: base = .light
        case .critical: base = .minimal
        @unknown default: base = .light
        }
        if lowPower, base < .light { return ReadingLoad(rawValue: base.rawValue + 1) ?? base }
        return base
    }

    /// Konuşma altyazısı okuyucusunun iki okuma arasındaki sürenin çarpanı.
    public var speechSlowdown: Double { self == .minimal ? 2 : 1 }

    /// Yan okuyucuların (görev yazıları, seçenekler, altyazı yeri arama) çarpanı; `nil` = okuma durur.
    public var sideSlowdown: Double? {
        switch self {
        case .full: return 1
        case .eased: return 1.5
        case .light: return 3
        case .minimal: return nil
        }
    }
}

/// Tek dokunuşluk hazır görünümler: kaydırıcılarla uğraşmak istemeyenler ve yazıyı okumakta zorlananlar için.
/// Yazının yeri (üst/alt) ve konuşan renkleri hazır görünümün dışındadır; kullanıcının seçtiği gibi kalır.
public struct SubtitlePreset: Identifiable, Equatable, Sendable {
    public let name: String
    public let scale: Double
    public let color: SubtitleAppearance.TextColor
    public let background: Double
    public let bold: Bool
    public var id: String { name }

    public static let all: [SubtitlePreset] = [
        SubtitlePreset(name: "Olağan", scale: 1.0, color: .white, background: 0.62, bold: false),
        SubtitlePreset(name: "Büyük ve kalın", scale: 1.4, color: .white, background: 0.7, bold: true),
        SubtitlePreset(name: "Yüksek kontrast", scale: 1.2, color: .yellow, background: 0.9, bold: true),
        SubtitlePreset(name: "Zeminsiz", scale: 1.0, color: .white, background: 0, bold: true),
    ]

    /// Bu hazır görünümü uygular; `speakerColors` olduğu gibi kalır.
    public func applied(to appearance: SubtitleAppearance) -> SubtitleAppearance {
        SubtitleAppearance(color: color, background: background, bold: bold, speakerColors: appearance.speakerColors)
    }

    /// Şimdiki ayarlar bu hazır görünümle aynı mı?
    public func matches(_ appearance: SubtitleAppearance, scale current: Double) -> Bool {
        appearance.color == color && appearance.bold == bold
            && abs(appearance.background - background) < 0.05 && abs(current - scale) < 0.05
    }
}
