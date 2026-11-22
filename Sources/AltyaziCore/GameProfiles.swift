import CoreGraphics
import Foundation

/// Bir oyuna özgü ayarlar: altyazının ve görev yazılarının ekrandaki yeri oyundan oyuna değişir.
public struct GameProfile: Codable, Equatable, Sendable {
    /// Konuşma altyazısının arandığı bölge: x, y, genişlik, yükseklik (0…1, sol üstten).
    public var region: [Double]
    /// Görev/ipucu yazılarının arandığı bölge.
    public var hudRegion: [Double]
    public var hudEnabled: Bool
    /// Çevrilmeyecek adlar (karakter, yer, silah): çeviride olduğu gibi kalır. Eski kayıtlarda yoktur.
    public var keptTerms: [String]?

    public init(region: CGRect, hudRegion: CGRect, hudEnabled: Bool, keptTerms: [String] = []) {
        self.region = Self.numbers(region)
        self.hudRegion = Self.numbers(hudRegion)
        self.hudEnabled = hudEnabled
        self.keptTerms = keptTerms
    }

    public var regionRect: CGRect? { Self.rect(region) }
    public var hudRegionRect: CGRect? { Self.rect(hudRegion) }

    private static func numbers(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
    }

    private static func rect(_ numbers: [Double]) -> CGRect? {
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}

/// Oyun ayarlarını oyunun kimliğine göre saklar (PS5 çalışan oyunun kimliğini bildirir).
public struct GameProfileStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func profile(for titleID: String) -> GameProfile? {
        guard let data = defaults.data(forKey: key(titleID)) else { return nil }
        return try? JSONDecoder().decode(GameProfile.self, from: data)
    }

    public func save(_ profile: GameProfile, for titleID: String) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key(titleID))
    }

    private func key(_ titleID: String) -> String { "game." + titleID }
}
