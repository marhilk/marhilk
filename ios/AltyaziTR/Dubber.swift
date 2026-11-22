import AltyaziCore
import AVFoundation

/// Dublaj (DENEME): çevrilen repliği seslendirir ve çalınacağı yere verir.
///
/// Ses iki yoldan üretilir: ElevenLabs (doğal ses, internet ve anahtar gerekir, karakter başına ücretli) ya da
/// telefonun kendi Türkçe sesi (ücretsiz, cihazda). ElevenLabs yanıt vermezse ya da hakkı biterse cihaz
/// sesine düşülür. Ses televizyonda çalınır; televizyon yoksa (ya da öyle seçildiyse) telefonda.
@MainActor
final class Dubber: NSObject, AVAudioPlayerDelegate {
    enum Engine: String { case system, eleven }
    enum Output: String { case tv, phone }

    struct Job {
        let text: String
        let speaker: String?
        let voice: DubVoice
        let gender: DubGender
        let queuedAt = Date()
    }

    var engine: Engine = .system
    var output: Output = .tv
    var volume: Double = 1
    var eleven: ElevenLabsSpeech? { didSet { elevenBlocked = false } }
    /// Televizyon bağlı mı (bağlı değilse ses telefonda çalınır).
    var tvConnected: () -> Bool = { false }
    /// Üretilen sesi televizyona yollar (ses verisi, türü, ses düzeyi).
    var deliver: ((Data, String, Double) -> Void)?
    /// Sayaçlar değişince çağrılır.
    var onChange: (() -> Void)?

    /// Bu oturumda ElevenLabs'e giden karakter, okunan ve (geride kalındığı için) atlanan replik sayısı.
    private(set) var characters = 0
    private(set) var spoken = 0
    private(set) var skipped = 0
    private(set) var problem: String?
    let log = DebugLog()

    private var queue = LatestQueue<Job>(limit: 2)
    private var busy = false
    private var elevenBlocked = false
    private var player: AVAudioPlayer?
    private var playback: CheckedContinuation<Void, Never>?
    private let synthesizer = AVSpeechSynthesizer()

    func enqueue(_ job: Job) {
        skipped += queue.push(job).count
        pump()
    }

    /// Bekleyenleri atar, telefonda çalan sesi keser.
    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        playback?.resume()
        playback = nil
    }

    private func pump() {
        guard !busy, let job = queue.pop() else { return }
        busy = true
        Task {
            await run(job)
            busy = false
            onChange?()
            pump()
        }
    }

    private func run(_ job: Job) async {
        var clip: (data: Data, type: String)?
        var used = "cihaz"
        if engine == .eleven, let eleven, !elevenBlocked {
            do {
                clip = (try await eleven.synthesize(text: job.text, voice: job.voice.id), "audio/mpeg")
                characters += job.text.count
                used = "ElevenLabs/\(job.voice.name)"
                problem = nil
            } catch let failure as ElevenLabsSpeech.Failure {
                // Hak bittiyse ya da anahtar geçersizse bu oturumda yeniden denemek boşuna: cihaz sesiyle sürer.
                if failure == .quota || failure == .unauthorized { elevenBlocked = true }
                problem = "\(failure.localizedDescription) Cihaz sesiyle devam ediliyor."
            } catch {
                problem = "ElevenLabs'e ulaşılamadı; bu replik cihaz sesiyle okundu."
            }
        }
        if clip == nil {
            guard let wave = await systemClip(for: job) else {
                problem = "Telefonda Türkçe ses bulunamadı (Ayarlar → Erişilebilirlik → Seslendirilen İçerik → Sesler → Türkçe)."
                return
            }
            clip = (wave, "audio/wav")
        }
        guard let clip else { return }
        let ready = Date().timeIntervalSince(job.queuedAt)
        spoken += 1
        let toTV = output == .tv && tvConnected()
        log.add(String(format: "[%@ · %@ · %d harf · %.2f sn'de hazır · %d KB] %@%@", used, toTV ? "TV" : "telefon",
                       job.text.count, ready, clip.data.count / 1024, job.speaker.map { "\($0): " } ?? "", job.text))
        if toTV {
            deliver?(clip.data, clip.type, volume)
        } else {
            await playLocally(clip.data)
        }
    }

    // MARK: Telefonda çalma

    private func playLocally(_ data: Data) async {
        guard let created = try? AVAudioPlayer(data: data) else { return }
        created.delegate = self
        created.volume = Float(volume)
        player = created
        await withCheckedContinuation { continuation in
            playback = continuation
            if !created.play() {
                playback = nil
                continuation.resume()
            }
        }
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playback?.resume()
            self.playback = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.playback?.resume()
            self.playback = nil
        }
    }

    // MARK: Cihaz sesi

    /// Telefonun Türkçe sesiyle okunmuş replik (WAV). Türkçe ses yoksa `nil`.
    private func systemClip(for job: Job) async -> Data? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("tr") }
        guard !voices.isEmpty else { return nil }
        let wanted: AVSpeechSynthesisVoiceGender? = job.gender == .male ? .male : (job.gender == .female ? .female : nil)
        // Cinsiyeti tutan sesler önce; aralarında en kalitelisi.
        let voice = voices.max { left, right in
            let a = (left.gender == wanted ? 10 : 0) + left.quality.rawValue
            let b = (right.gender == wanted ? 10 : 0) + right.quality.rawValue
            return a < b
        }
        let utterance = AVSpeechUtterance(string: job.text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.08
        // Telefonda tek bir Türkçe ses olabilir: karakterler perdeyle ayrışır (erkek kalın, kadın ince,
        // her karakter kendine özgü küçük bir kayma).
        let shift = Float(SubtitleAppearance.paletteIndex(for: job.speaker ?? "")) * 0.03
        switch job.gender {
        case .male: utterance.pitchMultiplier = (voice?.gender == .male ? 0.95 : 0.78) + shift
        case .female: utterance.pitchMultiplier = (voice?.gender == .female ? 1.0 : 1.12) + shift
        case .unknown: utterance.pitchMultiplier = 1
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dublaj-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = WaveWriter(url: url)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = OnceFlag()
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    // Boş tampon: okuma bitti.
                    if finished.set() { continuation.resume() }
                    return
                }
                writer.append(pcm)
            }
            // Okuma bitişi hiç bildirilmezse sıra tıkanmasın.
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                if finished.set() { continuation.resume() }
            }
        }
        writer.close()
        guard let data = try? Data(contentsOf: url), data.count > 1024 else { return nil }
        return data
    }
}

/// Okunan ses tamponlarını 16 bit WAV dosyasına yazar (televizyon tarayıcıları WAV çalar).
private final class WaveWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?

    init(url: URL) {
        self.url = url
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: buffer.format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            file = try? AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
        }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock()
        file = nil   // dosya kapanınca başlığı tamamlanır
        lock.unlock()
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// İlk çağrıda `true` döner.
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
