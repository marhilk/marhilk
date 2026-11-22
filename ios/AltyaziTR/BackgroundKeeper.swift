import AVFoundation

/// Ekran kilitliyken / uygulama arka plandayken çalışmayı sürdürebilmek için açık bir ses oturumu tutar.
///
/// iOS yalnız ses çalan (ya da arama/navigasyon yapan) uygulamaları kilitliyken çalışır tutar.
/// 16 Kas 2026'da ölçüldü: bu oturum açıkken, kilitli telefonda görüntü çözme, yazı okuma ve çeviri sürüyor.
///
/// Ses motoru kendiliğinden durabilir: telefon araması, Siri, alarm (kesinti) ya da kulaklık
/// takıp çıkarma (çıkış yolunun değişmesi) motoru durdurur. Durmuş motorla iOS uygulamayı kilitlenince
/// askıya alır ve bağlantı kopar. Bu yüzden kesinti bitince ve yol değişince motor yeniden başlatılır;
/// `ensureRunning()` de düzenli aralıkla çağrılarak durmuş motoru ayağa kaldırır.
///
/// YAYIN UYARISI: "Oyun sesini bu telefondan çal" seçeneği kapalıyken burada yalnız sessizlik çalınır.
/// App Store, yalnız ayakta kalmak için sessiz ses çalan uygulamaları reddedebilir (kural 2.5.4).
final class BackgroundKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var wanted = false
    private var observers: [NSObjectProtocol] = []
    /// Motorun durduğunun fark edilip yeniden başlatılma sayısı (teşhis için).
    private(set) var restarts = 0

    /// Ses gerçekten çalıyor mu? (İstenmiş olması yetmez; motor durmuş olabilir.)
    var running: Bool { wanted && engine.isRunning && player.isPlaying }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        wanted = true
        observeOnce()
        guard !running else { return }
        play()
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// İstenmiş ama durmuşsa yeniden başlatır. Dönen değer: şu an çalışıyor mu?
    @discardableResult
    func ensureRunning() -> Bool {
        guard wanted else { return false }
        if !running {
            restarts += 1
            play()
        }
        return running
    }

    private func play() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // Oyun sesi telefondan çalınırken gecikme en az olsun (varsayılan ~23 ms yerine ~5 ms).
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)

            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            if !attached {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                attached = true
            }
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            silence.frameLength = 44_100
            if !engine.isRunning { try engine.start() }
            player.stop()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
        } catch {
            // Bir sonraki ensureRunning() yeniden dener.
        }
    }

    private func observeOnce() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Arama / Siri / alarm bitti: ses oturumunu geri al.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.ensureRunning() }
        })
        // Kulaklık takıldı/çıkarıldı: motor durur, yeniden başlatılmalı.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.ensureRunning()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.ensureRunning()
        })
    }
}
