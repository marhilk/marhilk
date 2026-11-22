import Foundation
import Network

/// TV sayfasını yerel ağda sunan küçük HTTP sunucusu.
///
/// Uygulama kurulamayan televizyonlar (LG) sayfayı kendi tarayıcılarında
/// `http://<telefonun adresi>:8080` yazarak açar. Yalnız gömülü üç dosyayı verir.
public final class TVPageServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 8080

    /// Gömülü dosyalardan önce sorulan ek yanıtlayıcı (yalnız geliştirme sürümünde teşhis için kullanılır).
    public var extra: (@Sendable (_ path: String) -> (type: String, body: Data)?)?

    private let queue = DispatchQueue(label: "altyazitr.pageserver")
    private var listener: NWListener?

    public init() {}

    /// Sunucu zaten ayaktaysa bir şey yapmaz.
    public func start(port: UInt16 = TVPageServer.defaultPort) {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let created = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!) else { return }
            created.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            created.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.listener?.cancel()
                    self?.listener = nil
                }
            }
            listener = created
            created.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    /// İstenen yol için (durum, içerik türü, gövde). Sorgu kısmı yok sayılır.
    static func response(forPath rawPath: String) -> (status: String, type: String, body: Data) {
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        switch path {
        case "/marhilk":
            // TV uygulaması ağı tararken "burada Marhilk telefonu var mı?" diye bunu sorar.
            return ("200 OK", "text/plain; charset=utf-8", Data("marhilk 1".utf8))
        case "/", "/index.html":
            return ("200 OK", "text/html; charset=utf-8", Data(TVPageAssets.indexHTML.utf8))
        case "/main.js":
            return ("200 OK", "application/javascript; charset=utf-8", Data(TVPageAssets.mainJS.utf8))
        case "/style.css":
            return ("200 OK", "text/css; charset=utf-8", Data(TVPageAssets.styleCSS.utf8))
        default:
            return ("404 Not Found", "text/plain; charset=utf-8", Data("Bulunamadı".utf8))
        }
    }

    /// İstek satırından yolu çıkarır ("GET /main.js HTTP/1.1" → "/main.js"). GET dışındakiler `nil`.
    static func path(fromRequest head: String) -> String? {
        let parts = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, collected: Data())
    }

    private func read(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = collected
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.reply(connection, to: head)
            } else if error != nil || isComplete || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.read(connection, collected: buffer)
            }
        }
    }

    private func reply(_ connection: NWConnection, to head: String) {
        let answer: (status: String, type: String, body: Data)
        if let path = Self.path(fromRequest: head) {
            if let custom = extra?(path) {
                answer = ("200 OK", custom.type, custom.body)
            } else {
                answer = Self.response(forPath: path)
            }
        } else {
            answer = ("405 Method Not Allowed", "text/plain; charset=utf-8", Data())
        }
        var message = Data("""
            HTTP/1.1 \(answer.status)\r
            Content-Type: \(answer.type)\r
            Content-Length: \(answer.body.count)\r
            Cache-Control: no-store\r
            Access-Control-Allow-Origin: *\r
            Connection: close\r
            \r

            """.utf8)
        message.append(answer.body)
        connection.send(content: message, completion: .contentProcessed { _ in connection.cancel() })
    }
}
