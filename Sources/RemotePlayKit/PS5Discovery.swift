import Foundation

public struct PS5Host: Hashable, Sendable {
    public let address: String
    public let name: String
    public let hostID: String
    public let systemVersion: String
    /// Dinlenme modunda mı (uyandırılabilir) yoksa açık mı.
    public let isStandby: Bool
    /// O an çalışan oyunun kimliği ve adı (ana ekrandaysa `nil`). PS5 bunu keşif yanıtında bildirir.
    public var runningTitleID: String?
    public var runningTitleName: String?
}

/// Ev ağındaki PS5'leri bulur. PS5, UDP 9302'ye gelen "SRCH" paketine yanıt verir.
///
/// iOS'ta yayın (broadcast) paketi özel izin ister; bu yüzden alt ağdaki her
/// adrese tek tek de gönderilir — bu yalnız "yerel ağ" iznine bağlıdır.
public enum PS5Discovery {
    static let port: UInt16 = 9302
    static let localPorts: ClosedRange<UInt16> = 9303...9319
    static let request = Array("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n".utf8)

    /// Bekleyen (blocking) çağrı; ana iş parçacığında çağırmayın.
    public static func search(timeout: TimeInterval = 2.5) -> [PS5Host] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        bindLocal(fd)

        var targets: [in_addr_t] = [INADDR_BROADCAST.bigEndian]
        for network in localNetworks() {
            targets.append(network.broadcast)
            targets.append(contentsOf: network.hosts)
        }

        var found: [String: PS5Host] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var nextSend = Date.distantPast

        while Date() < deadline {
            if Date() >= nextSend {
                for target in targets { send(fd, to: target) }
                nextSend = Date().addingTimeInterval(1.0)
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 150) > 0 else { continue }

            var buffer = [UInt8](repeating: 0, count: 2048)
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0, let address = ipv4String(storage) else { continue }
            if let host = parse(String(decoding: buffer[0..<count], as: UTF8.self), address: address) {
                found[address] = host
            }
        }
        return found.values.sorted { $0.address < $1.address }
    }

    // MARK: -

    static func parse(_ response: String, address: String) -> PS5Host? {
        let lines = response.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 ") else { return nil }
        let code = status.dropFirst("HTTP/1.1 ".count).prefix(3)
        guard code == "200" || code == "620" else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["host-type"] == "PS5" else { return nil }
        return PS5Host(address: address,
                       name: headers["host-name"] ?? "PS5",
                       hostID: headers["host-id"] ?? "",
                       systemVersion: headers["system-version"] ?? "",
                       isStandby: code == "620",
                       runningTitleID: headers["running-app-titleid"].flatMap { $0.isEmpty ? nil : $0 },
                       runningTitleName: headers["running-app-name"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Tek bir PS5'e sorar (ağın tamamını taramadan): açık mı, hangi oyun çalışıyor?
    /// Bekleyen (blocking) çağrı; ana iş parçacığında çağırmayın.
    public static func query(address: String, timeout: TimeInterval = 1.2) -> PS5Host? {
        var target = in_addr()
        guard inet_pton(AF_INET, address, &target) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        bindLocal(fd)
        let deadline = Date().addingTimeInterval(timeout)
        var nextSend = Date.distantPast
        while Date() < deadline {
            if Date() >= nextSend {
                send(fd, to: target.s_addr)
                nextSend = Date().addingTimeInterval(0.5)
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 150) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            if let host = parse(String(decoding: buffer[0..<count], as: UTF8.self), address: address) { return host }
        }
        return nil
    }

    private static func bindLocal(_ fd: Int32) {
        // PS5 yanıtı kaynak porta yollar; asıl uygulamalar bu aralığı kullanır.
        for port in localPorts {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY.bigEndian
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return }
        }
        // Hepsi doluysa sistem rastgele port verir.
    }

    private static func send(_ fd: Int32, to target: in_addr_t) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = target
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func ipv4String(_ storage: sockaddr_storage) -> String? {
        guard storage.ss_family == sa_family_t(AF_INET) else { return nil }
        var copy = storage
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> String? in
                var address = pointer.pointee.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: text)
            }
        }
    }

    struct LocalNetwork {
        let broadcast: in_addr_t   // ağ bayt sırası
        let hosts: [in_addr_t]     // ağ bayt sırası
    }

    /// Açık, yayın destekleyen IPv4 arayüzleri. Büyük ağlarda yalnız kendi /24 dilimimiz taranır.
    static func localNetworks() -> [LocalNetwork] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var networks: [LocalNetwork] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }

            let own = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let realBroadcast = (own & netmask) | ~netmask
            netmask |= 0xFFFF_FF00
            let base = own & netmask
            let last = base | ~netmask
            guard last > base + 1 else { continue }
            let hosts = ((base + 1)..<last).filter { $0 != own }.map { $0.bigEndian }
            networks.append(LocalNetwork(broadcast: realBroadcast.bigEndian, hosts: hosts))
        }
        return networks
    }
}
