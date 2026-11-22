import Foundation
import Network

/// Samsung televizyonun geliştirici kipi durumu (TV'nin 8001 portundaki bilgi sayfasından).
public struct SamsungTVInfo: Sendable, Equatable {
    public var name: String
    public var model: String
    /// TV'de "Developer Mode" açık mı?
    public var developerMode: Bool
    /// TV'ye uygulama yüklemesine izin verilen adres ("Host PC IP").
    public var developerIP: String

    public static func parse(_ data: Data) -> SamsungTVInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device"] as? [String: Any] else { return nil }
        let name = ((device["name"] as? String) ?? (object["name"] as? String) ?? "Samsung TV")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        return SamsungTVInfo(name: name,
                             model: (device["modelName"] as? String) ?? "",
                             developerMode: "\(device["developerMode"] ?? "0")" == "1",
                             developerIP: (device["developerIP"] as? String) ?? "")
    }

    public static func fetch(host: String) async throws -> SamsungTVInfo {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { throw SDBError("TV adresi geçersiz.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let info = parse(data) else { throw SDBError("Bu adresteki cihaz bir Samsung TV gibi yanıt vermedi.") }
        return info
    }
}

extension SamsungTVInfo {
    /// Marhilk'in televizyondaki uygulama kimliği.
    public static let marhilkAppID = "AltyzTR001.AltyaziTR"

    /// Yerel ağdaki Samsung televizyonları bulur. `address`: bu cihazın adresi ("192.168.1.100");
    /// aynı /24 ağındaki bütün adresler denenir. Modem yeniden başlayıp adresler değişse de TV bulunur.
    public static func discover(from address: String) async -> [(host: String, info: SamsungTVInfo)] {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts.prefix(3).joined(separator: ".")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: (String, SamsungTVInfo)?.self) { group in
            for last in 1...254 {
                let host = "\(prefix).\(last)"
                guard host != address, let url = URL(string: "http://\(host):8001/api/v2/") else { continue }
                group.addTask {
                    guard let (data, _) = try? await session.data(from: url), let info = parse(data) else { return nil }
                    return (host, info)
                }
            }
            var found: [(host: String, info: SamsungTVInfo)] = []
            for await result in group {
                if let result { found.append((result.0, result.1)) }
            }
            return found.sorted { $0.host < $1.host }
        }
    }

    public enum AppState: Sendable, Equatable { case notInstalled, stopped, running, unreachable }

    /// Televizyondaki bir uygulamanın durumu.
    public static func appState(host: String, appID: String = marhilkAppID) async -> AppState {
        guard let url = URL(string: "http://\(host):8001/api/v2/applications/\(appID)") else { return .unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .unreachable }
        return appState(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    static func appState(status: Int, body: Data) -> AppState {
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return status == 404 ? .notInstalled : .unreachable
        }
        return (object["running"] as? Bool) == true && (object["visible"] as? Bool) == true ? .running : .stopped
    }

    /// Televizyonda uygulamayı açar (kumandaya dokunmadan). Başarılıysa `true`.
    public static func launch(host: String, appID: String = marhilkAppID) async -> Bool {
        guard let url = URL(string: "http://\(host):8001/api/v2/applications/\(appID)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

public struct SDBError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Samsung TV'nin geliştirici kapısıyla (SDB, port 26101) konuşur: komut çalıştırır, dosya gönderir.
/// Android'in ADB paket biçimidir; şifreleme ve kimlik doğrulama yoktur, TV yalnız
/// "Host PC IP" olarak girilen adresten gelen bağlantıyı kabul eder.
public actor SDBClient {
    public static let port: UInt16 = 26101

    struct Packet: Equatable {
        var command: String
        var arg0: UInt32
        var arg1: UInt32
        var payload: Data
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "altyazitr.sdb")
    private var nextLocalID: UInt32 = 1
    /// Tek paketin en büyük yükü. Bildirdiğimizden büyüğünü yollarsak TV bağlantıyı keser.
    private let maxPayload = 16_384
    public private(set) var banner = ""

    public init(host: String, port: UInt16 = SDBClient.port) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    // MARK: - Paket biçimi

    static func encode(_ packet: Packet) -> Data {
        var data = Data()
        let command = packet.command.utf8.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let checksum = packet.payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        for value in [command, packet.arg0, packet.arg1, UInt32(packet.payload.count), checksum, command ^ 0xFFFF_FFFF] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(packet.payload)
        return data
    }

    /// 24 baytlık başlığı çözer; yük uzunluğunu da verir.
    static func decodeHeader(_ header: Data) -> (command: String, arg0: UInt32, arg1: UInt32, length: Int)? {
        guard header.count == 24 else { return nil }
        let bytes = [UInt8](header)
        func word(_ index: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index * 4 + $1]) << (8 * UInt32($1)) }
        }
        guard word(0) ^ 0xFFFF_FFFF == word(5), let command = String(bytes: bytes[0..<4], encoding: .ascii) else { return nil }
        return (command, word(1), word(2), Int(word(3)))
    }

    // MARK: - Bağlantı

    /// TV'ye bağlanır. Dönen değer TV'nin kendini tanıttığı metindir ("device::QE75…::0").
    @discardableResult
    public func connect(timeout: TimeInterval = 6) async throws -> String {
        try await withTimeout(timeout, "TV'ye bağlanılamadı. TV açık, aynı Wi-Fi'da ve geliştirici kipinde bu telefonun adresi yazılı olmalı.") {
            try await self.waitUntilReady()
            try await self.send(Packet(command: "CNXN", arg0: 0x0100_0000, arg1: 65_536, payload: Data("host::\0".utf8)))
            let reply = try await self.readPacket()
            guard reply.command == "CNXN" else {
                throw SDBError(reply.command == "AUTH" ? "TV kimlik doğrulaması istiyor; bu model henüz desteklenmiyor."
                                                       : "TV beklenmeyen yanıt verdi (\(reply.command)).")
            }
            self.banner = String(decoding: reply.payload.prefix { $0 != 0 }, as: UTF8.self)
            return self.banner
        }
    }

    public nonisolated func close() {
        connection.cancel()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Durum bildirimleri tek kuyruktan gelir; yalnız ilki sonucu belirler.
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.first() { continuation.resume(throwing: SDBError("TV'ye bağlanılamadı: \(error.localizedDescription)")) }
                case .cancelled:
                    if once.first() { continuation.resume(throwing: SDBError("TV bağlantısı kapandı.")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    // MARK: - Komut

    /// TV'de bir komut çalıştırır ve çıktısını döndürür. TV gerçek bir kabuk vermez;
    /// yalnız "0 getduid", "0 vd_appinstall …" gibi sabit komutları kabul eder.
    public func shell(_ command: String, timeout: TimeInterval = 30) async throws -> String {
        try await withTimeout(timeout, "TV komuta yanıt vermedi: \(command)") {
            let stream = try await self.open("shell:\(command)")
            var output = Data()
            while true {
                let packet = try await self.readPacket()
                switch packet.command {
                case "WRTE":
                    output.append(packet.payload)
                    try await self.send(Packet(command: "OKAY", arg0: stream.local, arg1: stream.remote, payload: Data()))
                case "CLSE":
                    try? await self.send(Packet(command: "CLSE", arg0: stream.local, arg1: stream.remote, payload: Data()))
                    return String(decoding: output, as: UTF8.self)
                default:
                    break
                }
            }
        }
    }

    /// TV'nin özellik listesi (ör. `sdk_toolpath`, `platform_version`).
    public func capabilities() async throws -> [String: String] {
        try await withTimeout(10, "TV özelliklerini bildirmedi.") {
            let stream = try await self.open("capability:")
            var data = Data()
            loop: while true {
                let packet = try await self.readPacket()
                switch packet.command {
                case "WRTE":
                    data.append(packet.payload)
                    try await self.send(Packet(command: "OKAY", arg0: stream.local, arg1: stream.remote, payload: Data()))
                case "CLSE":
                    try? await self.send(Packet(command: "CLSE", arg0: stream.local, arg1: stream.remote, payload: Data()))
                    break loop
                default:
                    break
                }
            }
            return Self.parseCapabilities(data)
        }
    }

    static func parseCapabilities(_ data: Data) -> [String: String] {
        // İlk iki bayt uzunluktur; kalanı "anahtar:değer" satırları.
        let text = String(decoding: data.dropFirst(2), as: UTF8.self)
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    // MARK: - Dosya gönderme

    /// Bir dosyayı TV'ye yazar. `progress` 0…1 arası ilerlemeyi bildirir.
    public func push(_ file: Data, to remotePath: String, mode: Int = 0o100644,
                     timeout: TimeInterval = 180, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await withTimeout(timeout, "Dosya TV'ye gönderilemedi (zaman aşımı).") {
            let stream = try await self.open("sync:")
            var inbox = Data()

            func write(_ data: Data) async throws {
                try await self.send(Packet(command: "WRTE", arg0: stream.local, arg1: stream.remote, payload: data))
                // TV her paketi onaylar; onay gelmeden sıradaki yollanmaz.
                while true {
                    let packet = try await self.readPacket()
                    if packet.command == "OKAY" { return }
                    if packet.command == "WRTE" {
                        inbox.append(packet.payload)
                        try await self.send(Packet(command: "OKAY", arg0: stream.local, arg1: stream.remote, payload: Data()))
                    } else if packet.command == "CLSE" {
                        throw SDBError(Self.syncFailure(inbox) ?? "TV dosya aktarımını kesti.")
                    }
                }
            }

            try await write(Self.syncMessage("SEND", Data("\(remotePath),\(mode)".utf8)))
            let chunkSize = self.maxPayload - 8
            var offset = 0
            while offset < file.count {
                let end = min(offset + chunkSize, file.count)
                try await write(Self.syncMessage("DATA", file.subdata(in: offset..<end)))
                offset = end
                progress?(Double(offset) / Double(max(file.count, 1)))
            }
            var done = Data("DONE".utf8)
            withUnsafeBytes(of: UInt32(Date().timeIntervalSince1970).littleEndian) { done.append(contentsOf: $0) }
            try await write(done)

            // Sonuç: "OKAY" ya da "FAIL" + ileti.
            while inbox.count < 8 {
                let packet = try await self.readPacket()
                if packet.command == "WRTE" {
                    inbox.append(packet.payload)
                    try await self.send(Packet(command: "OKAY", arg0: stream.local, arg1: stream.remote, payload: Data()))
                } else if packet.command == "CLSE" {
                    throw SDBError("TV dosya aktarımını sonuç bildirmeden kapattı.")
                }
            }
            if let failure = Self.syncFailure(inbox) { throw SDBError(failure) }

            try? await self.send(Packet(command: "WRTE", arg0: stream.local, arg1: stream.remote,
                                        payload: Self.syncMessage("QUIT", Data())))
            try? await self.send(Packet(command: "CLSE", arg0: stream.local, arg1: stream.remote, payload: Data()))
            // Kalan onay/kapanış paketlerini bir sonraki işlem karıştırmasın.
            try? await self.drain(until: "CLSE")
        }
    }

    /// "SEND"/"DATA"/"QUIT" + 4 baytlık uzunluk + içerik.
    static func syncMessage(_ id: String, _ body: Data) -> Data {
        var data = Data(id.utf8)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }

    /// Aktarım sonucu "FAIL" ise TV'nin iletisini verir; "OKAY" ise `nil`.
    static func syncFailure(_ inbox: Data) -> String? {
        guard inbox.count >= 4, String(decoding: inbox.prefix(4), as: UTF8.self) == "FAIL" else { return nil }
        let message = String(decoding: inbox.dropFirst(8), as: UTF8.self)
        return "TV dosyayı kabul etmedi\(message.isEmpty ? "." : ": \(message)")"
    }

    // MARK: - Akış ve ham okuma/yazma

    private func open(_ service: String) async throws -> (local: UInt32, remote: UInt32) {
        let local = nextLocalID
        nextLocalID += 1
        try await send(Packet(command: "OPEN", arg0: local, arg1: 0, payload: Data("\(service)\0".utf8)))
        while true {
            let packet = try await readPacket()
            if packet.command == "OKAY", packet.arg1 == local { return (local, packet.arg0) }
            if packet.command == "CLSE", packet.arg1 == local { throw SDBError("TV bu işlemi reddetti (\(service)).") }
        }
    }

    private func drain(until command: String) async throws {
        try await withTimeout(1.5, "") {
            while try await self.readPacket().command != command {}
        }
    }

    private func send(_ packet: Packet) async throws {
        let data = Self.encode(packet)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func readPacket() async throws -> Packet {
        guard let header = Self.decodeHeader(try await read(24)) else { throw SDBError("TV'den bozuk veri geldi.") }
        let payload = header.length > 0 ? try await read(header.length) : Data()
        return Packet(command: header.command, arg0: header.arg0, arg1: header.arg1, payload: payload)
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? SDBError("TV bağlantıyı kapattı."))
                }
            }
        }
    }

    /// Süre dolarsa bağlantıyı keser; bekleyen okuma hatayla döner.
    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ message: String,
                                          _ work: () async throws -> T) async throws -> T {
        let connection = self.connection
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            connection.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await work()
        } catch {
            if timer.isCancelled == false, connection.state == .cancelled, !message.isEmpty { throw SDBError(message) }
            throw error
        }
    }
}

/// Yalnız ilk çağrıda `true` döner.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Hazır (imzalı) bir TV uygulama paketini Samsung televizyona kurar ve açar.
public enum SamsungTVInstaller {
    public enum Step: Sendable { case connecting, sending(Double), installing, launching, done }

    /// - Parameters:
    ///   - package: imzalı `.wgt` dosyasının içeriği
    ///   - appID: uygulamanın tam kimliği ("PaketKimliği.Ad")
    public static func install(package: Data, appID: String, host: String,
                               progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws {
        progress(.connecting)
        let client = SDBClient(host: host)
        defer { client.close() }
        try await client.connect()

        let toolPath = (try? await client.capabilities()["sdk_toolpath"]) ?? "/home/owner/share/tmp/sdk_tools"
        // Dosya adında boşluk olmamalı: kurulum komutu boşluktan böler.
        let remote = "\(toolPath)/tmp/marhilk.wgt"
        try await client.push(package, to: remote) { progress(.sending($0)) }

        progress(.installing)
        let output = try await client.shell("0 vd_appinstall \(appID) \(remote)", timeout: 180)
        if let failure = installFailure(in: output) { throw SDBError(failure) }

        progress(.launching)
        _ = try? await client.shell("0 was_execute \(appID)", timeout: 20)
        progress(.done)
    }

    /// Kurulum çıktısında hata varsa kullanıcıya gösterilecek açıklamayı verir; başarılıysa `nil`.
    static func installFailure(in output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("install completed") || lower.contains("cmd_ret:0") { return nil }
        if lower.contains("author certificate not match") {
            return "TV'de bu uygulamanın başka bir imzayla kurulmuş eski bir kopyası var. Önce onu TV'den silin."
        }
        if lower.contains("certificate") {
            return "TV, uygulamanın imzasını kabul etmedi. İmza bu televizyon için alınmış olmalı."
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Kurulum başarısız oldu\(trimmed.isEmpty ? "." : ": \(trimmed.suffix(200))")"
    }
}
