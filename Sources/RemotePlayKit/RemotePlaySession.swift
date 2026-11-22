import CChiaki
import CoreVideo
import Foundation

/// PS5'e Remote Play ile bağlanır ve ekran görüntüsünü kare kare verir.
/// Oyuna hiçbir girdi göndermez; yalnız izler.
public final class RemotePlaySession: @unchecked Sendable {
    public enum Event: Sendable {
        case connected
        /// PS5'te bu kullanıcı için giriş parolası (PIN) ayarlı; uzaktan girilemiyor.
        case loginPinRequired
        case ended(isError: Bool, message: String)
    }

    public enum Quality: Sendable {
        case hd720, hd1080
        var height: Int32 { self == .hd1080 ? 1080 : 720 }
    }

    /// Kütüphanenin iş parçacığında çağrılır; uzun iş yapılmamalı.
    public var onFrame: ((CVPixelBuffer) -> Void)?
    public var onEvent: ((Event) -> Void)?
    public var onLog: RemotePlayLog?
    /// Oyun sesi isteniyorsa: biçim (kanal, örnekleme hızı, paket başına örnek) ve Opus paketleri.
    public var onAudioFormat: ((_ channels: Int, _ sampleRate: Int, _ frameSize: Int) -> Void)?
    public var onAudioPacket: ((UnsafeBufferPointer<UInt8>) -> Void)?

    private let credentials: RemotePlayCredentials
    private let quality: Quality
    private let decoder: VideoDecoder
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private static let stopQueue = DispatchQueue(label: "altyazitr.remoteplay.stop")

    /// `audio`: PS5'ten oyun sesi de istensin mi (oturum başlarken belirlenir, sonradan değişmez).
    public init(credentials: RemotePlayCredentials, quality: Quality = .hd1080, codec: VideoDecoder.Codec = .h264, audio: Bool = false) {
        self.wantsAudio = audio
        self.credentials = credentials
        self.quality = quality
        self.decoder = VideoDecoder(codec: codec)
        self.codec = codec
    }

    private let codec: VideoDecoder.Codec
    private let wantsAudio: Bool

    public var decodedFrames: Int { decoder.decodedFrames }
    public var failedFrames: Int { decoder.failedFrames }
    public var decoderRebuilds: Int { decoder.sessionRebuilds }
    public var lastDecodeError: Int32 { decoder.lastErrorCode }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { return }
        guard credentials.registKey.count == 16, credentials.morning.count == 16, credentials.accountID.count == 8 else {
            throw RemotePlayError("Eşleşme bilgisi bozuk; PS5 ile yeniden eşleşin.")
        }

        decoder.onFrame = { [weak self] buffer in self?.onFrame?(buffer) }

        // Oturum sürdükçe bu nesne yaşamalı: C tarafı ona ham gösterici tutuyor.
        let retained = Unmanaged.passRetained(self)
        var error: Int32 = 0
        let started = credentials.registKey.withUnsafeBytes { key in
            credentials.morning.withUnsafeBytes { morning in
                credentials.accountID.withUnsafeBytes { account in
                    arp_session_start(credentials.host,
                                      key.bindMemory(to: UInt8.self).baseAddress,
                                      morning.bindMemory(to: UInt8.self).baseAddress,
                                      account.bindMemory(to: UInt8.self).baseAddress,
                                      quality.height, codec == .hevc,
                                      Self.videoCallback, Self.eventCallback, Self.logCallback,
                                      wantsAudio ? Self.audioHeaderCallback : nil,
                                      wantsAudio ? Self.audioFrameCallback : nil,
                                      retained.toOpaque(), &error)
                }
            }
        }
        guard let started else {
            retained.release()
            throw RemotePlayError(code: error, doing: "Oturum başlatılamadı")
        }
        handle = started
    }

    /// Oturumu kapatır. Geri çağrıların içinden çağrılsa da güvenlidir (ayrı kuyrukta bekler).
    public func stop() {
        lock.lock()
        let current = handle
        handle = nil
        lock.unlock()
        guard let current else { return }
        Self.stopQueue.async {
            arp_session_stop(current)
            Unmanaged.passUnretained(self).release()
        }
    }

    // MARK: - C geri çağrıları

    private static func instance(_ user: UnsafeMutableRawPointer?) -> RemotePlaySession? {
        guard let user else { return nil }
        return Unmanaged<RemotePlaySession>.fromOpaque(user).takeUnretainedValue()
    }

    private static let videoCallback: arp_video_cb = { data, size, user in
        guard let data, size > 0, let session = instance(user) else { return true }
        // false: kare çözülemedi → kütüphane PS5'ten yeni bir anahtar kare ister.
        return session.decoder.consume(UnsafeBufferPointer(start: data, count: size))
    }

    private static let eventCallback: arp_event_cb = { type, isError, message, user in
        guard let session = instance(user) else { return }
        let text = message.map { String(cString: $0) } ?? ""
        switch type {
        case ARP_EVENT_CONNECTED:
            session.onEvent?(.connected)
        case ARP_EVENT_LOGIN_PIN_REQUEST:
            session.onEvent?(.loginPinRequired)
        case ARP_EVENT_QUIT:
            session.onEvent?(.ended(isError: isError, message: text))
        default:
            break
        }
    }

    private static let audioHeaderCallback: arp_audio_header_cb = { channels, sampleRate, frameSize, user in
        instance(user)?.onAudioFormat?(Int(channels), Int(sampleRate), Int(frameSize))
    }

    private static let audioFrameCallback: arp_audio_frame_cb = { data, size, user in
        guard let data, size > 0, let session = instance(user) else { return }
        session.onAudioPacket?(UnsafeBufferPointer(start: data, count: size))
    }

    private static let logCallback: arp_log_cb = { level, message, user in
        guard let message, let session = instance(user) else { return }
        session.onLog?(Int(level), String(cString: message))
    }
}
