import CoreGraphics
import CoreVideo
import Foundation

/// Görüntü akışından saniyede birkaç kare seçip seçili bölgedeki yazıyı okur.
/// Kareler herhangi bir iş parçacığından verilebilir; okuma kendi kuyruğunda yapılır
/// ve bir okuma sürerken gelen kareler atlanır (akışı asla bekletmez).
///
/// Sistemin yazı okuyucusu nadiren bir karede kilitlenip hiç dönmeyebiliyor (16 Kas 2026'da
/// gerçek oyunda görüldü). Bu yüzden bir bekçi vardır: okuma `stallTimeout` içinde dönmezse
/// iptal edilir, takılan kuyruk terk edilir ve okuma yeni bir kuyrukta sürer.
public final class FrameTextReader: @unchecked Sendable {
    public typealias Recognize = (CVPixelBuffer, CGRect, TextRecognizer.Cancellation) -> [RecognizedLine]

    /// Her okuma sonunda çağrılır (yazı yoksa boş liste). Okuma kuyruğunda çağrılır.
    public var onLines: (([RecognizedLine]) -> Void)?
    /// Okunan karenin kendisi (önizleme için). Okuma kuyruğunda çağrılır.
    public var onSample: ((CVPixelBuffer) -> Void)?
    /// Bir okuma bu süreden uzun sürerse kilitlenmiş sayılır.
    public var stallTimeout: TimeInterval = 2.5
    /// İlk okuma, sistemin yazı okuyucusunu yüklediği için uzun sürer (soğuk açılışta 25 sn görüldü);
    /// ilk başarılı okumaya kadar bu daha uzun süre uygulanır. Yoksa bekçi yüklemeyi kilitlenme sanar.
    public var warmUpTimeout: TimeInterval = 45

    private let lock = NSLock()
    private let recognize: Recognize
    private let interval: TimeInterval
    private var queue = DispatchQueue(label: "altyazitr.reader")
    private var generation = 0
    private var region = FrameTextReader.defaultRegion
    private var busy = false
    private var busySince = Date.distantPast
    private var current: TextRecognizer.Cancellation?
    private var lastRun = Date.distantPast
    private var lastFinished = Date()
    private var duration: TimeInterval = 0
    private var stalls = 0
    private var latest: CVPixelBuffer?
    private var warmedUp = false

    /// Konuşma altyazıları altta, oyunun sorduğu sorular / seçenekler / görevler çoğu oyunda
    /// ekranın alt yarısında çıkar; varsayılan bölge ikisini de kapsar. Yanlar bilerek dışarıda: oyun
    /// dünyasındaki tabela/etiket yazıları repliklerle aynı hizaya gelip karışıyor.
    public static let defaultRegion = CGRect(x: 0.12, y: 0.42, width: 0.76, height: 0.55)

    /// `interval`: iki okuma arasındaki en kısa süre. Gecikmeyi doğrudan etkiler.
    /// `recognize`: yalnız testlerde verilir; verilmezse Apple Vision kullanılır.
    public init(interval: TimeInterval = 0.08, recognize: Recognize? = nil) {
        self.interval = interval
        let recognizer = TextRecognizer()
        self.recognize = recognize ?? { buffer, roi, cancellation in
            (try? recognizer.recognizeLines(pixelBuffer: buffer, roi: roi, cancellation: cancellation)) ?? []
        }
    }

    /// Son okumanın sürdüğü süre (saniye); gecikme teşhisi için.
    public var lastReadDuration: TimeInterval { locked { duration } }
    /// Bekçinin kilitlenme yakaladığı sayı.
    public var stallCount: Int { locked { stalls } }
    /// Son başarılı okumadan bu yana geçen süre. Kare gelirken büyüyorsa okuma tümden durmuştur.
    public var secondsSinceLastRead: TimeInterval { locked { Date().timeIntervalSince(lastFinished) } }

    /// `region`: karede normalize bölge (0…1, başlangıç SOL ÜST).
    public func setRegion(_ region: CGRect) {
        lock.lock()
        self.region = region
        lock.unlock()
    }

    /// Akıştan gelen en son kare ("ekranı çevir" için tüm ekran buradan okunur).
    public var latestFrame: CVPixelBuffer? { locked { latest } }

    public func submit(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()
        lock.lock()
        latest = pixelBuffer
        if busy {
            guard now.timeIntervalSince(busySince) > (warmedUp ? stallTimeout : warmUpTimeout) else {
                lock.unlock()
                return
            }
            // Okuma kilitlendi: iptal et, o kuyruğu terk et, yenisinde devam et.
            current?.cancel()
            generation += 1
            stalls += 1
            queue = DispatchQueue(label: "altyazitr.reader.\(generation)")
            busy = false
        }
        guard now.timeIntervalSince(lastRun) >= interval else {
            lock.unlock()
            return
        }
        busy = true
        busySince = now
        lastRun = now
        let mine = generation
        let cancellation = TextRecognizer.Cancellation()
        current = cancellation
        let region = self.region
        let queue = self.queue
        lock.unlock()

        queue.async { [self] in
            // Vision'da y alttan ölçülür.
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            let flipped = CGRect(x: region.minX, y: 1 - region.maxY, width: region.width, height: region.height).intersection(unit)
            let started = Date()
            let lines = recognize(pixelBuffer, flipped.isEmpty ? unit : flipped, cancellation)

            lock.lock()
            // Bu okuma terk edildiyse (kilitlenip geç döndüyse) sonucu eskimiştir: yok say.
            guard mine == generation else {
                lock.unlock()
                return
            }
            lock.unlock()

            onSample?(pixelBuffer)
            onLines?(lines)

            lock.lock()
            if mine == generation {
                busy = false
                warmedUp = true
                duration = Date().timeIntervalSince(started)
                lastFinished = Date()
            }
            lock.unlock()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
