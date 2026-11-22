import Foundation
import Network

public enum SubtitlePosition: String, CaseIterable, Sendable {
    case top
    case bottom
}

/// Televizyondaki altyazının görünümü.
public struct SubtitleAppearance: Equatable, Sendable {
    /// Yazı rengi. Değerler TV'ye olduğu gibi gider (CSS rengi).
    public enum TextColor: String, CaseIterable, Sendable {
        case white = "#ffffff"
        case yellow = "#ffe566"
        case cyan = "#9fe3ff"
        case green = "#b6f09c"
    }

    public var color: TextColor
    /// Yazının arkasındaki koyu zeminin opaklığı (0 = zemin yok, 1 = tam siyah).
    public var background: Double
    public var bold: Bool
    /// Her konuşan kişi kendi rengiyle gösterilsin mi (kapalıysa hepsi sarı).
    public var speakerColors: Bool

    public init(color: TextColor = .white, background: Double = 0.62, bold: Bool = false, speakerColors: Bool = false) {
        self.color = color
        self.background = background
        self.bold = bold
        self.speakerColors = speakerColors
    }

    /// Konuşan adlarına verilen renkler; aynı ad her zaman aynı rengi alır. TV sayfasındaki liste ile aynıdır.
    public static let speakerPalette = ["#ffd84d", "#7fd4ff", "#9be37f", "#ff9f7a", "#d7a6ff", "#ffb3d1"]

    /// Bir konuşanın palet sırası (TV ile telefon aynı sonucu bulsun diye basit ve taşınabilir bir özet).
    public static func paletteIndex(for speaker: String) -> Int {
        var hash = 0
        for unit in speaker.lowercased().utf16 { hash = (hash * 31 + Int(unit)) % 100_003 }
        return hash % speakerPalette.count
    }
}

/// Telefonda çalışan küçük WebSocket sunucusu. TV uygulaması yerel ağda bu
/// porta bağlanır ve çevrilmiş altyazıyı buradan alır. Ağdan dışarı çıkmaz.
///
/// Protokol (JSON, metin çerçevesi):
///   {"type":"hello","app":"altyazitr","v":1}
///   {"type":"style","position":"top|bottom","scale":1.0}
///   {"type":"lines","lines":[{"i":7,"s":"Konuşan","t":"Çeviri"}, …]}   (geliş sırasıyla; boş liste = temizle)
///   {"type":"hud","items":[{"x","y","w","h","lh","n","t"}, …]}          (görev yazıları, yerinde; boş liste = temizle)
public final class SubtitleServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 8765

    /// Ana kuyrukta çağrılır.
    public var onClientCountChange: ((Int) -> Void)?
    /// Ana kuyrukta çağrılır; `nil` = sorun yok.
    public var onStatus: ((String?) -> Void)?
    /// TV'den gelen ileti (ör. kumandadan "ekranı çevir"). Ana kuyrukta çağrılır.
    public var onClientMessage: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "altyazitr.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var lastStyle: Data?
    private var lastSubtitle: Data?
    private var lastHUD: Data?

    public init() {}

    /// Sunucu zaten ayaktaysa bir şey yapmaz; uygulama öne her geldiğinde çağrılabilir.
    public func start(port: UInt16 = SubtitleServer.defaultPort) {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let ws = NWProtocolWebSocket.Options()
                ws.autoReplyPing = true
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

                let l = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
                l.service = NWListener.Service(name: "AltyaziTR", type: "_altyazitr._tcp")
                l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                l.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.report(nil)
                    case .failed(let error):
                        self.listener?.cancel()
                        self.listener = nil
                        self.report("Sunucu durdu: \(error.localizedDescription)")
                    case .waiting(let error):
                        self.report("Ağ bekleniyor: \(error.localizedDescription)")
                    default:
                        break
                    }
                }
                listener = l
                l.start(queue: queue)
            } catch {
                report("Sunucu başlatılamadı: \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            clients.values.forEach { $0.cancel() }
            clients.removeAll()
            notifyCount()
        }
    }

    /// Ekranda gösterilecek satırlar, geliş sırasıyla (en yeni en sonda). Boş liste ekranı temizler.
    /// `id`, TV'nin aynı satırı tanıyıp yerinde tutmasını (yeniden çizmemesini) sağlar.
    public func sendLines(_ lines: [(id: Int, speaker: String?, text: String)]) {
        let payload: [[String: Any]] = lines.map { line in
            var item: [String: Any] = ["i": line.id, "t": line.text]
            if let speaker = line.speaker, !speaker.isEmpty { item["s"] = speaker }
            return item
        }
        broadcast(["type": "lines", "lines": payload], remember: \.lastSubtitle)
    }

    /// "Ekranı çevir" katmanı. `state`: "working" (çevriliyor), "done" (`items` gösterilir),
    /// "clear" (kaldır), "error" (`message` gösterilir). Kalıcı değildir: sonradan bağlanan TV'ye yollanmaz.
    public func sendScreen(state: String, items: [[String: Any]] = [], message: String? = nil) {
        var object: [String: Any] = ["type": "screen", "state": state, "items": items]
        if let message { object["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        queue.async { [self] in clients.values.forEach { send(data, to: $0) } }
    }

    /// Görev/ipucu yazılarının çevirisi: oyun sürerken ekranın köşesinde, özgün yazıların üstünde durur.
    /// Boş liste katmanı temizler. Sonradan bağlanan TV de son durumu alır.
    public func sendHUD(items: [ScreenItem]) {
        broadcast(["type": "hud", "items": items.map(\.json)], remember: \.lastHUD)
    }

    /// Telefonun o anki durumu (teşhis için; TV uygulaması bu iletiyi yok sayar).
    public func sendStatus(_ fields: [String: Any]) {
        var object = fields
        object["type"] = "status"
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        queue.async { [self] in clients.values.forEach { send(data, to: $0) } }
    }

    public func sendStyle(position: SubtitlePosition, scale: Double, appearance: SubtitleAppearance = SubtitleAppearance()) {
        broadcast(["type": "style", "position": position.rawValue, "scale": scale,
                   "color": appearance.color.rawValue, "background": appearance.background,
                   "bold": appearance.bold, "speakerColors": appearance.speakerColors], remember: \.lastStyle)
    }

    // MARK: -

    private func broadcast(_ object: [String: Any], remember keyPath: ReferenceWritableKeyPath<SubtitleServer, Data?>) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        queue.async { [self] in
            self[keyPath: keyPath] = data
            clients.values.forEach { send(data, to: $0) }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.clients[id] = connection
                self.notifyCount()
                let hello = try? JSONSerialization.data(withJSONObject: ["type": "hello", "app": "altyazitr", "v": 1])
                // Yeni bağlanan TV son biçimi ve ekrandaki altyazıyı hemen alsın.
                // Köşe yazısı boş olsa da yollanır: TV önceki bağlantıdan kalan yazıyı ekranda tutmasın.
                let hud = self.lastHUD ?? (try? JSONSerialization.data(withJSONObject: ["type": "hud", "items": [Any]()]))
                for data in [hello, self.lastStyle, self.lastSubtitle, hud].compactMap({ $0 }) {
                    self.send(data, to: connection)
                }
                self.receive(on: connection)
            case .failed, .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async { [weak self] in self?.onClientMessage?(object) }
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                connection.cancel()
                self.drop(connection)
                return
            }
            self.receive(on: connection)
        }
    }

    private func drop(_ connection: NWConnection) {
        if clients.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            notifyCount()
        }
    }

    private func send(_ data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func notifyCount() {
        let count = clients.count
        DispatchQueue.main.async { [weak self] in self?.onClientCountChange?(count) }
    }

    private func report(_ message: String?) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(message) }
    }
}
