import Foundation

/// PS5 ile eşleşmek için PSN hesabının sayısal kimliği gerekir. Bu kimlik,
/// Sony'nin kendi giriş sayfasında oturum açılarak alınır (chiaki projesindeki
/// `psn-account-id` betiğiyle aynı akış). Parola uygulamaya hiç gelmez; yalnız
/// girişten sonra Sony'nin döndürdüğü tek kullanımlık kod kullanılır.
public enum PSNAccount {
    // Sony'nin resmî Remote Play istemcisinin herkese açık kimliği (chiaki'den).
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let tokenURL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"

    public static let redirectPrefix = "https://remoteplay.dl.playstation.net/remoteplay/redirect"

    public static let loginURL = URL(string:
        "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?service_entity=urn:service-entity:psn"
        + "&response_type=code&client_id=\(clientID)&redirect_uri=\(redirectPrefix)"
        + "&scope=psn:clientapp&request_locale=en_US&ui=pr&service_logo=ps&layout_type=popup"
        + "&smcid=remoteplay&prompt=always&PlatformPrivacyWs1=minimal&")!

    public enum Failure: LocalizedError {
        case noCode
        case server(Int, String)
        case unexpectedResponse

        public var errorDescription: String? {
            switch self {
            case .noCode: return "Giriş adresinde kod yok. Giriş tamamlanmamış olabilir."
            case .server(let status, let body): return "Sony sunucusu \(status) döndürdü: \(body.prefix(200))"
            case .unexpectedResponse: return "Sony sunucusundan beklenmeyen yanıt geldi."
            }
        }
    }

    /// Girişten sonra yönlenilen adres bizim beklediğimiz adres mi?
    public static func isRedirect(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix(redirectPrefix)
    }

    /// Yönlendirme adresindeki koddan 8 baytlık hesap kimliğini alır.
    public static func accountID(fromRedirect url: URL) async throws -> Data {
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw Failure.noCode
        }
        let basic = "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()

        var tokenRequest = URLRequest(url: URL(string: tokenURL)!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue(basic, forHTTPHeaderField: "Authorization")
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = Data("grant_type=authorization_code&code=\(code)&redirect_uri=\(redirectPrefix)&".utf8)
        let token = try await json(tokenRequest)
        guard let accessToken = token["access_token"] as? String,
              let escaped = accessToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let infoURL = URL(string: tokenURL + "/" + escaped) else {
            throw Failure.unexpectedResponse
        }

        var infoRequest = URLRequest(url: infoURL)
        infoRequest.setValue(basic, forHTTPHeaderField: "Authorization")
        let info = try await json(infoRequest)
        guard let userID = info["user_id"] as? String, let id = accountID(fromUserID: userID) else {
            throw Failure.unexpectedResponse
        }
        return id
    }

    /// Ondalık kullanıcı numarasını kütüphanenin beklediği 8 bayta (küçük uçlu) çevirir.
    public static func accountID(fromUserID userID: String) -> Data? {
        guard let value = UInt64(userID) else { return nil }
        return withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.server(status, String(decoding: data, as: UTF8.self))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unexpectedResponse
        }
        return object
    }
}
