import Foundation
import Security

/// ASN.1 DER kodlaması için gereken birkaç yapı taşı (sertifika isteği üretmek için).
enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var length: [UInt8]
        if content.count < 128 {
            length = [UInt8(content.count)]
        } else {
            var bytes: [UInt8] = []
            var value = content.count
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            length = [0x80 | UInt8(bytes.count)] + bytes
        }
        return [tag] + length + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static let zero: [UInt8] = [0x02, 0x01, 0x00]
    static let null: [UInt8] = [0x05, 0x00]
    static func utf8(_ text: String) -> [UInt8] { tlv(0x0C, Array(text.utf8)) }
    static func ia5(_ text: String) -> [UInt8] { tlv(0x16, Array(text.utf8)) }
    static func octets(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func bits(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }

    static func oid(_ arcs: [UInt]) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var value = arc >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            bytes += chunk
        }
        return tlv(0x06, bytes)
    }
}

/// Samsung TV'ye uygulama kurmak için gereken sertifika isteklerini (CSR) üretir.
public enum SamsungCSR {
    private static let commonName: [UInt] = [2, 5, 4, 3]
    private static let emailAddress: [UInt] = [1, 2, 840, 113549, 1, 9, 1]
    private static let rsaEncryption: [UInt] = [1, 2, 840, 113549, 1, 1, 1]
    private static let sha512WithRSA: [UInt] = [1, 2, 840, 113549, 1, 1, 13]
    private static let extensionRequest: [UInt] = [1, 2, 840, 113549, 1, 9, 14]
    private static let subjectAltName: [UInt] = [2, 5, 29, 17]

    public static func generateKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SigningError("Anahtar üretilemedi: \(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        return key
    }

    /// Gizli anahtarı saklanabilir veriye çevirir / veriden geri kurar.
    public static func export(_ key: SecKey) throws -> Data {
        guard let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { throw SigningError("Anahtar dışa aktarılamadı.") }
        return data
    }

    public static func importKey(_ data: Data) throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil) else {
            throw SigningError("Saklanan anahtar okunamadı.")
        }
        return key
    }

    /// Yazar sertifikası isteği. `name`: sertifikada görünecek ad.
    public static func author(name: String, key: SecKey) throws -> String {
        let subject = DER.sequence([rdn(commonName, DER.utf8(name))])
        return try request(subject: subject, attributes: [], key: key)
    }

    /// Dağıtıcı sertifikası isteği. Sertifika yalnız `duids` içindeki televizyonlarda geçerli olur.
    public static func distributor(email: String, duids: [String], key: SecKey) throws -> String {
        let subject = DER.sequence([rdn(commonName, DER.utf8("TizenSDK")), rdn(emailAddress, DER.ia5(email))])
        // subjectAltName: URN:tizen:packageid= (boş) ve her televizyon için URN:tizen:deviceid=<DUID>
        let names = (["URN:tizen:packageid="] + duids.map { "URN:tizen:deviceid=\($0)" }).map { DER.tlv(0x86, Array($0.utf8)) }
        let alternative = DER.sequence([DER.oid(subjectAltName), DER.octets(DER.sequence(names))])
        let attribute = DER.sequence([DER.oid(extensionRequest), DER.set([DER.sequence([alternative])])])
        return try request(subject: subject, attributes: attribute, key: key)
    }

    private static func rdn(_ type: [UInt], _ value: [UInt8]) -> [UInt8] {
        DER.set([DER.sequence([DER.oid(type), value])])
    }

    private static func request(subject: [UInt8], attributes: [UInt8], key: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw SigningError("Açık anahtar alınamadı.")
        }
        let keyInfo = DER.sequence([DER.sequence([DER.oid(rsaEncryption), DER.null]), DER.bits([UInt8](publicData))])
        let info = DER.sequence([DER.zero, subject, keyInfo, DER.tlv(0xA0, attributes)])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA512, Data(info) as CFData, &error) as Data? else {
            throw SigningError("Sertifika isteği imzalanamadı: \(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        let csr = DER.sequence([info, DER.sequence([DER.oid(sha512WithRSA), DER.null]), DER.bits([UInt8](signature))])
        let body = Data(csr).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE REQUEST-----\n\(body)\n-----END CERTIFICATE REQUEST-----\n"
    }
}

/// Samsung hesabına girişten dönen bilgi.
public struct SamsungToken: Sendable, Equatable {
    public var accessToken: String
    public var userID: String
    public var email: String

    public init(accessToken: String, userID: String, email: String) {
        self.accessToken = accessToken
        self.userID = userID
        self.email = email
    }

    /// Tarayıcının açacağı giriş adresi. Samsung yalnız bu geri dönüş adresini kabul eder.
    public static let callbackPort: UInt16 = 4794
    public static var loginURL: URL {
        var components = URLComponents(string: "https://account.samsung.com/mobile/account/check.do")!
        components.queryItems = [
            URLQueryItem(name: "serviceID", value: "v285zxnl3h"),
            URLQueryItem(name: "actionID", value: "StartOAuth2"),
            URLQueryItem(name: "accessToken", value: "Y"),
            URLQueryItem(name: "redirect_uri", value: "http://localhost:\(callbackPort)/signin/callback"),
        ]
        return components.url!
    }

    /// Giriş sonunda Samsung'un geri dönüş adresine gönderdiği form gövdesini çözer: `code=<JSON>`.
    public static func parse(callbackBody: String) -> SamsungToken? {
        for pair in callbackBody.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "code",
                  let decoded = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let object = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any],
                  let access = object["access_token"] as? String, let user = object["userId"] as? String else { continue }
            return SamsungToken(accessToken: access, userID: user, email: (object["inputEmailID"] as? String) ?? "")
        }
        return nil
    }
}

/// Bir televizyona kurulum yapmak için gereken anahtarlar ve Samsung'un verdiği sertifikalar.
/// Yazar anahtarı aynı kalmalıdır: farklı yazarla imzalanmış güncellemeyi televizyon reddeder.
public struct SamsungSigningMaterial: Codable, Sendable {
    public var authorKey: Data
    public var authorCertificates: [Data]
    public var distributorKey: Data
    public var distributorCertificates: [Data]
    /// Dağıtıcı sertifikasının geçerli olduğu televizyonlar.
    public var duids: [String]
    public var issued: Date
    /// Samsung'un verdiği cihaz profili (bazı televizyonlar kurulumdan önce ister).
    public var deviceProfile: String?

    /// Sertifikalar bir yıl geçerlidir; bitmeye yakınsa yenilenmelidir.
    public func covers(duid: String, at date: Date = Date()) -> Bool {
        duids.contains(duid) && date.timeIntervalSince(issued) < 330 * 24 * 3600
    }

    public func identities() throws -> (author: SigningIdentity, distributor: SigningIdentity) {
        (SigningIdentity(privateKey: try SamsungCSR.importKey(authorKey), certificates: authorCertificates),
         SigningIdentity(privateKey: try SamsungCSR.importKey(distributorKey), certificates: distributorCertificates))
    }
}

/// Samsung'un geliştirici sertifikası servisi (Tizen Studio'nun kullandığı servis).
public enum SamsungCertificateAuthority {
    static let base = "https://svdca.samsungqbe.com"

    /// Verilen televizyon için yazar ve dağıtıcı sertifikası alır. `existing` verilirse yazar anahtarı ve
    /// sertifikası yeniden kullanılır (güncellemelerin kurulabilmesi için yazar aynı kalmalı).
    public static func issue(token: SamsungToken, duid: String, authorName: String = "Marhilk",
                             existing: SamsungSigningMaterial? = nil, session: URLSession = .shared) async throws -> SamsungSigningMaterial {
        var authorKey: Data
        var authorCertificates: [Data]
        if let existing {
            authorKey = existing.authorKey
            authorCertificates = existing.authorCertificates
        } else {
            let key = try SamsungCSR.generateKey()
            let csr = try SamsungCSR.author(name: authorName, key: key)
            let pem = try await post("/apis/v3/authors", fields: ["access_token": token.accessToken, "user_id": token.userID, "platform": "VD"],
                                     fileName: "author.csr", csr: csr, session: session)
            authorKey = try SamsungCSR.export(key)
            authorCertificates = try chain(from: pem, intermediate: SamsungCAs.authorCA)
        }

        let duids = Array(Set((existing?.duids ?? []) + [duid])).sorted().suffix(10)
        let distributorKey = try SamsungCSR.generateKey()
        let csr = try SamsungCSR.distributor(email: token.email, duids: Array(duids), key: distributorKey)
        let fields = ["access_token": token.accessToken, "user_id": token.userID, "privilege_level": "Public", "developer_type": "Individual"]
        // Önce cihaz profili (v1), sonra sertifikanın kendisi (v3): Tizen Studio'nun sırası.
        var withPlatform = fields
        withPlatform["platform"] = "VD"
        let profile = try? await post("/apis/v1/distributors", fields: withPlatform, fileName: "distributor.csr", csr: csr, session: session)
        let pem = try await post("/apis/v3/distributors", fields: fields, fileName: "distributor.csr", csr: csr, session: session)
        return SamsungSigningMaterial(authorKey: authorKey, authorCertificates: authorCertificates,
                                      distributorKey: try SamsungCSR.export(distributorKey),
                                      distributorCertificates: try chain(from: pem, intermediate: SamsungCAs.publicDistributorCA),
                                      duids: Array(duids), issued: Date(), deviceProfile: profile)
    }

    /// PEM metnindeki sertifikaları DER olarak verir; yalnız yaprak geldiyse ara sertifika eklenir.
    static func chain(from pem: String, intermediate: String) throws -> [Data] {
        var certificates: [Data] = []
        for block in pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst() {
            guard let body = block.components(separatedBy: "-----END CERTIFICATE-----").first,
                  let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters), !data.isEmpty else { continue }
            certificates.append(data)
        }
        guard !certificates.isEmpty else {
            throw SigningError("Samsung'dan sertifika yerine beklenmeyen bir yanıt geldi: \(pem.prefix(160))")
        }
        if certificates.count == 1, let ca = Data(base64Encoded: intermediate) { certificates.append(ca) }
        return certificates
    }

    static func multipart(fields: [String: String], fileName: String, csr: String, boundary: String) -> Data {
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"csr\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(Data(csr.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func post(_ path: String, fields: [String: String], fileName: String, csr: String, session: URLSession) async throws -> String {
        let boundary = "----marhilk\(UInt64(Date().timeIntervalSince1970 * 1000))"
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart(fields: fields, fileName: fileName, csr: csr, boundary: boundary)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        if status == 403 {
            throw SigningError("Samsung şu an sertifika vermiyor (çok sık istek). Bir süre sonra yeniden deneyin.")
        }
        guard (200..<300).contains(status), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SigningError("Samsung sertifika servisi hata verdi (HTTP \(status)): \(text.prefix(200))")
        }
        return text
    }
}
