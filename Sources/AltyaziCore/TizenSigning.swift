import Compression
import CryptoKit
import Foundation
import Security

/// İmza için bir anahtar ve onun sertifika zinciri (yaprak sertifika ilk sırada, DER).
public struct SigningIdentity {
    public let privateKey: SecKey
    public let certificates: [Data]

    public init(privateKey: SecKey, certificates: [Data]) {
        self.privateKey = privateKey
        self.certificates = certificates
    }
}

public struct SigningError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Tizen (Samsung TV) uygulama paketini imzalar ve `.wgt` dosyasını üretir.
///
/// Pakette iki imza vardır: yazarın imzası (`author-signature.xml`) ve dağıtıcının imzası
/// (`signature1.xml`). İkisi de W3C "Widget Digital Signatures" biçimindedir: her dosyanın SHA-512 özeti
/// ve bu özet listesinin RSA-SHA512 imzası. Dağıtıcı imzası yazar imzasını da kapsar; o yüzden önce
/// yazar imzası üretilir.
public enum WGTSigner {
    public enum Role {
        case author, distributor

        var id: String { self == .author ? "AuthorSignature" : "DistributorSignature" }
        var fileName: String { self == .author ? "author-signature.xml" : "signature1.xml" }
        var roleURI: String { "http://www.w3.org/ns/widgets-digsig#role-" + (self == .author ? "author" : "distributor") }
    }

    public typealias File = (name: String, data: Data)

    private static let namespace = "http://www.w3.org/2000/09/xmldsig#"

    /// İmzalı paketi (zip) üretir. `files`: uygulamanın dosyaları (imza dosyaları hariç).
    public static func package(files: [File], author: SigningIdentity, distributor: SigningIdentity) throws -> Data {
        let content = files.filter { !isSignature($0.name) }
        let authorSignature = try signature(role: .author, files: content, identity: author)
        let withAuthor = content + [(Role.author.fileName, authorSignature)]
        let distributorSignature = try signature(role: .distributor, files: withAuthor, identity: distributor)
        let all = withAuthor + [(Role.distributor.fileName, distributorSignature)]
        return ZipWriter.archive(all.sorted { $0.name < $1.name })
    }

    static func isSignature(_ name: String) -> Bool {
        name == "author-signature.xml" || (name.hasPrefix("signature") && name.hasSuffix(".xml"))
    }

    /// Bir imza dosyasının içeriği.
    public static func signature(role: Role, files: [File], identity: SigningIdentity) throws -> Data {
        let info = signedInfo(role: role, files: files)
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCreateSignature(identity.privateKey, .rsaSignatureMessagePKCS1v15SHA512,
                                              canonical(info) as CFData, &error) as Data? else {
            throw SigningError("Paket imzalanamadı: \(error?.takeRetainedValue().localizedDescription ?? "bilinmeyen hata")")
        }
        var xml = "<Signature xmlns=\"\(namespace)\" Id=\"\(role.id)\">\n"
        xml += info + "\n"
        xml += "<SignatureValue>\n\(wrapped(raw))\n</SignatureValue>\n"
        xml += "<KeyInfo>\n<X509Data>\n"
        for certificate in identity.certificates {
            xml += "<X509Certificate>\n\(wrapped(certificate))\n</X509Certificate>\n"
        }
        xml += "</X509Data>\n</KeyInfo>\n"
        xml += object(role: role) + "\n"
        xml += "</Signature>"
        return Data(xml.utf8)
    }

    /// `<SignedInfo>`: dosya özetleri. Dosyalar ada göre sıralıdır.
    static func signedInfo(role: Role, files: [File]) -> String {
        var xml = "<SignedInfo>\n"
        xml += "<CanonicalizationMethod Algorithm=\"http://www.w3.org/2001/10/xml-exc-c14n#\"></CanonicalizationMethod>\n"
        xml += "<SignatureMethod Algorithm=\"http://www.w3.org/2001/04/xmldsig-more#rsa-sha512\"></SignatureMethod>\n"
        for file in files.sorted(by: { $0.name < $1.name }) {
            let uri = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name
            xml += "<Reference URI=\"\(uri)\">\n"
            xml += "<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha512\"></DigestMethod>\n"
            xml += "<DigestValue>\(wrapped(Data(SHA512.hash(data: file.data))))</DigestValue>\n"
            xml += "</Reference>\n"
        }
        // Özellikler bölümünün özeti: bölüm kurallı biçimde (ad alanı açıkça yazılı) özetlenir.
        let properties = object(role: role).replacingOccurrences(of: "<Object Id=\"prop\">", with: "<Object xmlns=\"\(namespace)\" Id=\"prop\">")
        xml += "<Reference URI=\"#prop\">\n"
        xml += "<Transforms>\n<Transform Algorithm=\"http://www.w3.org/2006/12/xml-c14n11\"></Transform>\n</Transforms>\n"
        xml += "<DigestMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#sha512\"></DigestMethod>\n"
        xml += "<DigestValue>\(wrapped(Data(SHA512.hash(data: Data(properties.utf8)))))</DigestValue>\n"
        xml += "</Reference>\n"
        xml += "</SignedInfo>"
        return xml
    }

    /// İmzalanan baytlar: `<SignedInfo>` kurallı biçimde, yani ad alanı açılış etiketine yazılmış hâlde.
    static func canonical(_ signedInfo: String) -> Data {
        Data(signedInfo.replacingOccurrences(of: "<SignedInfo>", with: "<SignedInfo xmlns=\"\(namespace)\">").utf8)
    }

    static func object(role: Role) -> String {
        "<Object Id=\"prop\"><SignatureProperties xmlns:dsp=\"http://www.w3.org/2009/xmldsig-properties\">"
            + "<SignatureProperty Id=\"profile\" Target=\"#\(role.id)\"><dsp:Profile URI=\"http://www.w3.org/ns/widgets-digsig#profile\"></dsp:Profile></SignatureProperty>"
            + "<SignatureProperty Id=\"role\" Target=\"#\(role.id)\"><dsp:Role URI=\"\(role.roleURI)\"></dsp:Role></SignatureProperty>"
            + "<SignatureProperty Id=\"identifier\" Target=\"#\(role.id)\"><dsp:Identifier></dsp:Identifier></SignatureProperty>"
            + "</SignatureProperties></Object>"
    }

    /// Base64, 76 karakterlik satırlara bölünmüş.
    static func wrapped(_ data: Data) -> String {
        let text = data.base64EncodedString()
        var lines: [Substring] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            lines.append(rest.prefix(76))
            rest = rest.dropFirst(76)
        }
        return lines.joined(separator: "\n")
    }
}

/// Küçük bir zip yazıcı (sıkıştırmalı). `.wgt` dosyası bir zip arşividir.
enum ZipWriter {
    static func archive(_ files: [(name: String, data: Data)], date: Date = Date()) -> Data {
        var output = Data()
        var central = Data()
        let stamp = dosTime(date)
        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let deflated = deflate(file.data)
            let body = deflated ?? file.data
            let method: UInt16 = deflated == nil ? 0 : 8
            let offset = UInt32(output.count)
            let flags: UInt16 = file.name.utf8.allSatisfy { $0 < 128 } ? 0 : 0x0800   // ASCII dışı ad: UTF-8

            var header = Data()
            header.append(le32(0x0403_4B50)); header.append(le16(20)); header.append(le16(flags)); header.append(le16(method))
            header.append(le16(stamp.time)); header.append(le16(stamp.date))
            header.append(le32(crc)); header.append(le32(UInt32(body.count))); header.append(le32(UInt32(file.data.count)))
            header.append(le16(UInt16(name.count))); header.append(le16(0))
            output.append(header); output.append(name); output.append(body)

            central.append(le32(0x0201_4B50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(flags)); central.append(le16(method))
            central.append(le16(stamp.time)); central.append(le16(stamp.date))
            central.append(le32(crc)); central.append(le32(UInt32(body.count))); central.append(le32(UInt32(file.data.count)))
            central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(name)
        }
        let start = UInt32(output.count)
        output.append(central)
        output.append(le32(0x0605_4B50)); output.append(le16(0)); output.append(le16(0))
        output.append(le16(UInt16(files.count))); output.append(le16(UInt16(files.count)))
        output.append(le32(UInt32(central.count))); output.append(le32(start)); output.append(le16(0))
        return output
    }

    /// Ham "deflate" akışı; sıkıştırma kazandırmıyorsa `nil` (dosya olduğu gibi saklanır).
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var destination = [UInt8](repeating: 0, count: data.count)
        let written = data.withUnsafeBytes { source in
            compression_encode_buffer(&destination, destination.count, source.bindMemory(to: UInt8.self).baseAddress!,
                                      data.count, nil, COMPRESSION_ZLIB)
        }
        return written > 0 && written < data.count ? Data(destination.prefix(written)) : nil
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func dosTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16((max((parts.year ?? 1980) - 1980, 0)) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
