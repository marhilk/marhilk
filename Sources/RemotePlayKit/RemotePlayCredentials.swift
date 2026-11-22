import CChiaki
import Foundation

/// Bir PS5 ile eşleşmenin kalıcı sonucu. Bunlar olmadan oturum açılamaz;
/// gizli tutulmalıdır (telefonda Anahtar Zinciri'nde saklanır).
public struct RemotePlayCredentials: Codable, Equatable, Sendable {
    public var host: String
    public var nickname: String
    public var mac: String
    public var registKey: Data   // 16 bayt
    public var morning: Data     // 16 bayt
    public var accountID: Data   // 8 bayt

    public init(host: String, nickname: String, mac: String, registKey: Data, morning: Data, accountID: Data) {
        self.host = host
        self.nickname = nickname
        self.mac = mac
        self.registKey = registKey
        self.morning = morning
        self.accountID = accountID
    }
}

public struct RemotePlayError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
    init(code: Int32, doing action: String) {
        self.message = "\(action): \(String(cString: arp_error_string(code)))"
    }
}

public typealias RemotePlayLog = @Sendable (_ level: Int, _ message: String) -> Void

/// C tarafına taşınan günlük kutusu.
final class LogBox {
    let log: RemotePlayLog?
    init(_ log: RemotePlayLog?) { self.log = log }

    static let callback: arp_log_cb = { level, message, user in
        guard let user, let message else { return }
        Unmanaged<LogBox>.fromOpaque(user).takeUnretainedValue().log?(Int(level), String(cString: message))
    }
}

public enum RemotePlayPairing {
    /// PS5'te Ayarlar › Sistem › Uzaktan Oynama › Cihaz Bağla ekranındaki 8 haneli kodla eşleşir.
    /// Bekleyen (blocking) çağrı; ana iş parçacığında çağırmayın.
    public static func pair(host: String, accountID: Data, pin: String, log: RemotePlayLog? = nil) throws -> RemotePlayCredentials {
        let digits = pin.filter(\.isNumber)
        guard digits.count == 8, let pinValue = UInt32(digits) else {
            throw RemotePlayError("Kod 8 haneli olmalı.")
        }
        guard accountID.count == 8 else {
            throw RemotePlayError("PSN hesap kimliği geçersiz.")
        }

        let box = LogBox(log)
        var result = arp_registered_host()
        let code = accountID.withUnsafeBytes { account in
            arp_register(host, account.bindMemory(to: UInt8.self).baseAddress, pinValue,
                         LogBox.callback, Unmanaged.passUnretained(box).toOpaque(), &result)
        }
        guard code == 0 else {
            throw RemotePlayError("Eşleşme başarısız. Kod doğru mu, süresi dolmadı mı, PSN hesabı bu PS5'te oturum açmış mı? (\(String(cString: arp_error_string(code))))")
        }

        let registKey = withUnsafeBytes(of: result.regist_key) { Data($0) }
        let morning = withUnsafeBytes(of: result.morning) { Data($0) }
        let mac = withUnsafeBytes(of: result.mac) { $0.map { String(format: "%02x", $0) }.joined(separator: ":") }
        let nickname = withUnsafeBytes(of: result.nickname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return RemotePlayCredentials(host: host, nickname: nickname.isEmpty ? "PS5" : nickname, mac: mac,
                                     registKey: registKey, morning: morning, accountID: accountID)
    }

    /// Dinlenme modundaki PS5'i uyandırır (PS5'te "ağ üzerinden açma" açık olmalı).
    public static func wake(_ credentials: RemotePlayCredentials) throws {
        let code = credentials.registKey.withUnsafeBytes {
            arp_wakeup(credentials.host, $0.bindMemory(to: UInt8.self).baseAddress)
        }
        guard code == 0 else { throw RemotePlayError(code: code, doing: "PS5 uyandırılamadı") }
    }
}
