import AVFoundation
import Foundation

/// PS5'ten gelen oyun sesini (Opus) çözüp cihazın hoparlöründen ya da kulaklığından çalar.
/// İsteğe bağlı bir özelliktir: kullanıcı açarsa oyunun sesini telefondan dinleyebilir.
public final class GameAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var opusFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var frameSize: AVAudioFrameCount = 480
    private var queued = 0
    private var attached = false

    /// Sırada bekleyen her paket ~10 ms gecikme demektir. Ağdan paketler öbek öbek gelebildiği için
    /// sıra bir kez uzarsa kendiliğinden kısalmaz (çalma hızı geliş hızına eşit) ve ses kalıcı olarak
    /// geride kalır. Bu yüzden sıra `highWater`'ı aşınca `lowWater`'a inene dek gelen paketler atılır:
    /// kısa bir atlama, kalıcı gecikmeye yeğdir.
    private let highWater = 7
    private let lowWater = 2
    private var catchingUp = false

    public private(set) var decodedPackets = 0
    public private(set) var failedPackets = 0
    public private(set) var droppedPackets = 0
    /// Son çözülen paketteki en yüksek ses düzeyi (0…1); sesin gerçekten geldiğini doğrulamaya yarar.
    public private(set) var peak: Float = 0
    /// Şu an çalınmayı bekleyen paket sayısı (×10 ms = uygulamanın eklediği gecikme).
    public var queuedPackets: Int { lock.lock(); defer { lock.unlock() }; return queued }

    public init() {}

    public var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    /// Çalıcının gerçekte kullandığı örnekleme hızı ve ses donanımının hızı (teşhis için).
    public private(set) var playbackRate: Double = 0
    public private(set) var hardwareRate: Double = 0

    /// Ses biçimi PS5'ten geldiğinde çağrılır (genelde 2 kanal, 48000 Hz, paket başına 480 örnek).
    public func configure(channels: Int, sampleRate: Int, frameSize: Int) {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameSize), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description) else { return }

        if !attached {
            engine.attach(player)
            attached = true
        }
        // Çalıcı, verilen arabelleğin örnekleme hızını DÖNÜŞTÜRMEZ: arabellek çalıcının çıkış biçimiyle aynı
        // hızda olmalı, yoksa ses yanlış hızda çalar (16 Kas 2026'da ölçüldü: 48 kHz ses ~44,1 kHz gibi,
        // %8 yavaş çalıyor ve geride kalıyordu). Bu yüzden önce bağlanılır, sonra çalıcının GERÇEK çıkış
        // biçimi okunur ve Opus doğrudan o biçime çözülür (çözme + hız dönüşümü tek adımda).
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let wanted = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate > 0 ? hardware.sampleRate : Double(sampleRate),
                                   channels: AVAudioChannelCount(channels))
        engine.connect(player, to: engine.mainMixerNode, format: wanted)
        let actual = player.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: input, to: actual) else { return }

        lock.lock()
        self.opusFormat = input
        self.pcmFormat = actual
        self.converter = converter
        // Hız dönüşümünde paket başına çıkan örnek sayısı değişir; biraz pay bırak.
        self.frameSize = AVAudioFrameCount((Double(frameSize) * actual.sampleRate / Double(sampleRate)).rounded(.up)) + 64
        self.playbackRate = actual.sampleRate
        self.hardwareRate = hardware.sampleRate
        lock.unlock()

        do {
            try engine.start()
            player.play()
        } catch {
            // Ses aygıtı açılamadıysa paketler çözülür ama çalınmaz; sayaçlar durumu gösterir.
        }
    }

    /// Tek bir Opus paketi. PS5'in ses iş parçacığından çağrılır.
    public func enqueue(_ packet: UnsafeBufferPointer<UInt8>) {
        lock.lock()
        guard let converter, let opusFormat, let pcmFormat else {
            lock.unlock()
            return
        }
        if queued >= highWater { catchingUp = true }
        if catchingUp {
            if queued > lowWater {
                droppedPackets += 1
                lock.unlock()
                return
            }
            catchingUp = false
        }
        let frames = frameSize
        lock.unlock()

        let compressed = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        compressed.data.copyMemory(from: packet.baseAddress!, byteCount: packet.count)
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, pcm.frameLength > 0 else {
            lock.lock(); failedPackets += 1; lock.unlock()
            return
        }

        var loudest: Float = 0
        if let channel = pcm.floatChannelData?[0] {
            for index in stride(from: 0, to: Int(pcm.frameLength), by: 8) { loudest = max(loudest, abs(channel[index])) }
        }
        lock.lock()
        decodedPackets += 1
        peak = loudest
        queued += 1
        lock.unlock()

        player.scheduleBuffer(pcm) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queued -= 1
            self.lock.unlock()
        }
    }

    public func stop() {
        player.stop()
        engine.stop()
        lock.lock()
        converter = nil
        queued = 0
        lock.unlock()
    }
}
