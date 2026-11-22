import Foundation
import Network

/// Marhilk'in TV uygulamasını bir Samsung televizyona baştan sona kurar:
/// televizyonun kimliğini okur, o televizyon için Samsung'dan sertifika alır, paketi imzalar, gönderir, kurar, açar.
public enum SamsungTVSetup {
    public enum Step: Sendable, Equatable {
        case connecting, readingTV, requestingCertificates, signing, sending(Double), installing, launching, done
    }

    /// Bu uygulamanın içindeki TV uygulamasının sürümü. Televizyon bağlanınca kendi sürümünü bildirir;
    /// farklıysa televizyondaki kopya eskidir.
    public static var embeddedBuild: String { TVPageAssets.build }

    /// TV uygulamasının dosyaları (uygulamanın içine gömülüdür).
    public static var packageFiles: [WGTSigner.File] {
        [("config.xml", Data(TVPageAssets.configXML.utf8)),
         ("icon.png", Data(base64Encoded: TVPageAssets.iconPNGBase64) ?? Data()),
         ("index.html", Data(TVPageAssets.indexHTML.utf8)),
         ("main.js", Data(TVPageAssets.mainJS.utf8)),
         ("style.css", Data(TVPageAssets.styleCSS.utf8))]
    }

    /// - Parameters:
    ///   - token: Samsung hesabı girişi. Bu televizyon için geçerli sertifika `existing` içinde varsa gerekmez.
    ///   - existing: daha önce alınmış anahtar ve sertifikalar.
    /// - Returns: kullanılan (yeni alınmış ya da eldeki) anahtar ve sertifikalar; saklanmalıdır.
    public static func install(host: String, token: SamsungToken?, existing: SamsungSigningMaterial?,
                               progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> SamsungSigningMaterial {
        progress(.connecting)
        let client = SDBClient(host: host)
        defer { client.close() }
        try await client.connect()

        progress(.readingTV)
        let duid = try await client.shell("0 getduid").trimmingCharacters(in: .whitespacesAndNewlines)
        guard duid.count >= 8, !duid.contains(" ") else {
            throw SDBError("Televizyonun kimliği okunamadı (\(duid.prefix(40))).")
        }
        let toolPath = (try? await client.capabilities()["sdk_toolpath"]) ?? "/home/owner/share/tmp/sdk_tools"

        let material: SamsungSigningMaterial
        if let existing, existing.covers(duid: duid) {
            material = existing
        } else {
            guard let token else { throw SDBError("Bu televizyon için Samsung hesabıyla giriş gerekli.") }
            progress(.requestingCertificates)
            material = try await SamsungCertificateAuthority.issue(token: token, duid: duid, existing: existing)
        }

        progress(.signing)
        let identities = try material.identities()
        let package = try WGTSigner.package(files: packageFiles, author: identities.author, distributor: identities.distributor)

        // Cihaz profili: bazı televizyonlar kurulumdan önce ister; yoksa da kurulum denenir.
        if let profile = material.deviceProfile, profile.contains("<") {
            try? await client.push(Data(profile.utf8), to: "\(toolPath)/device-profile.xml")
        }
        let remote = "\(toolPath)/tmp/marhilk.wgt"
        try await client.push(package, to: remote) { progress(.sending($0)) }

        progress(.installing)
        var output = try await client.shell("0 vd_appinstall \(SamsungTVInfo.marhilkAppID) \(remote)", timeout: 180)
        if output.lowercased().contains("author certificate not match") {
            // Televizyonda başka bir imzayla kurulmuş eski kopya var (ör. başka bir telefondan ya da
            // bilgisayardan kurulmuş): televizyon üstüne yazmayı reddeder. Eskisini kaldırıp yeniden kur.
            _ = try? await client.shell("0 vd_appuninstall \(SamsungTVInfo.marhilkAppID)", timeout: 60)
            output = try await client.shell("0 vd_appinstall \(SamsungTVInfo.marhilkAppID) \(remote)", timeout: 180)
        }
        if let failure = SamsungTVInstaller.installFailure(in: output) { throw SDBError(failure) }

        progress(.launching)
        _ = try? await client.shell("0 was_execute \(SamsungTVInfo.marhilkAppID)", timeout: 20)
        progress(.done)
        return material
    }
}

/// Samsung girişinin geri dönüşünü yakalayan yerel dinleyici.
///
/// Samsung, giriş bitince tarayıcıyı `http://localhost:4794/signin/callback` adresine bir form
/// göndermeye (POST) yönlendirir; giriş bilgisi o formun gövdesindedir. Tarayıcı görünümü gövdeyi
/// uygulamaya vermediği için, uygulama o adresi kendisi dinler. Yalnız bu cihazın kendisinden erişilebilir.
public final class SamsungLoginCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "altyazitr.samsung.login")
    private var listener: NWListener?
    private let onToken: @Sendable (SamsungToken) -> Void

    public init(onToken: @escaping @Sendable (SamsungToken) -> Void) {
        self.onToken = onToken
    }

    public func start(port: UInt16 = SamsungToken.callbackPort) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Yalnız bu cihazdan gelen bağlantılar (ağdaki başka cihazlar erişemez).
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let created = try NWListener(using: parameters)
        created.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: self.queue)
            self.read(connection, collected: Data())
        }
        listener = created
        created.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func read(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = collected
            if let data { buffer.append(data) }
            if let body = Self.body(of: buffer) {
                let token = SamsungToken.parse(callbackBody: body)
                let message = token != nil ? "Giriş tamam. Uygulamaya dönebilirsiniz." : "Giriş bilgisi alınamadı."
                let page = "<html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"></head>"
                    + "<body style=\"font-family:-apple-system,sans-serif;text-align:center;padding:60px 20px\"><h2>\(message)</h2></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let token { self.onToken(token) }
            } else if error != nil || isComplete || buffer.count > 200_000 {
                connection.cancel()
            } else {
                self.read(connection, collected: buffer)
            }
        }
    }

    /// İstek tamamen geldiyse gövdesini verir (başlıklar + Content-Length kadar gövde).
    static func body(of request: Data) -> String? {
        guard let split = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: request[..<split.lowerBound], as: UTF8.self)
        var length = 0
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let available = request.count - split.upperBound
        guard available >= length else { return nil }
        return String(decoding: request[split.upperBound..<(split.upperBound + length)], as: UTF8.self)
    }
}
