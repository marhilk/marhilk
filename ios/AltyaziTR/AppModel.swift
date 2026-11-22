import CoreImage
import ImageIO
import AltyaziCore
import CoreVideo
import RemotePlayKit
import SwiftUI
import Translation
import VideoToolbox

/// Akış: PS5 (Remote Play) → kare → satır satır yazı okuma → çeviri (önce cihaz üstü, sonra yapay zekâ) → TV.
@MainActor
final class AppModel: ObservableObject {
    enum Connection: Equatable {
        case idle
        case working(String)
        case connected
        case failed(String)
    }

    // Kurulum
    @Published private(set) var credentials: RemotePlayCredentials?
    @Published private(set) var accountID: Data?
    @Published private(set) var hosts: [PS5Host] = []
    @Published private(set) var searching = false
    @Published private(set) var pairing = false
    @Published var setupError: String?

    // Çalışma
    @Published private(set) var connection: Connection = .idle
    @Published private(set) var preview: CGImage?
    @Published private(set) var lines: [DisplayLine] = []
    @Published private(set) var aiEnabled = false
    @Published private(set) var aiProblem: String?
    @Published private(set) var tvCount = 0
    /// Bağlı televizyondaki uygulama bu telefonun içindekinden eski mi? (Yalnız Samsung: LG'de sayfa
    /// her seferinde telefondan yüklendiği için hep günceldir.)
    @Published private(set) var tvOutdated = false
    /// "Televizyonda aç" işleminin durumu (kullanıcıya gösterilir); nil = gösterilecek bir şey yok.
    @Published private(set) var tvLaunchStatus: String?
    @Published private(set) var tvLaunching = false
    /// Samsung televizyona kurulumun durumu (rehberin TV adımı bunu gösterir).
    struct SamsungStatus: Equatable {
        var searching = false
        var host: String?
        var name = ""
        /// Marhilk televizyonda kurulu mu?
        var appInstalled = false
        var developerMode = false
        /// Televizyonun kurulum kabul ettiği adres ("Host PC IP").
        var developerIP = ""
    }
    @Published private(set) var samsung = SamsungStatus()
    /// Süren kurulum adımı (kullanıcıya gösterilir); nil = kurulum sürmüyor.
    @Published private(set) var samsungWork: String?
    @Published var samsungError: String?
    @Published private(set) var samsungSignedIn = false
    private var samsungToken: SamsungToken?
    private var debugInstallStarted = false
    /// Daha önce Samsung'dan sertifika alınmış mı (yeniden giriş gerekmeyebilir)?
    var hasSamsungCertificates: Bool { KeychainStore.loadSamsungMaterial() != nil }
    /// Televizyon bu telefondan kurulum kabul etmeye hazır mı?
    var samsungReadyForInstall: Bool { samsung.host != nil && samsung.developerMode && samsung.developerIP == ipAddress }

    /// Bu açılışta televizyon kendiliğinden bir kez denendi mi?
    private var triedAutoLaunch = false
    @Published private(set) var serverStatus: String?
    @Published private(set) var translationStatus: String?
    @Published private(set) var ipAddress = "—"
    /// LG televizyonun tarayıcısına yazılacak adres.
    var browserAddress: String { "\(ipAddress):\(TVPageServer.defaultPort)" }
    /// Karanlık ekran kipi: uygulama çalışır, ekran siyah ve parlaklık en düşükte (kilitliymiş gibi).
    @Published private(set) var dimmed = false
    /// Ekran kilitliyken / uygulama arka plandayken çeviriyi sürdür.
    @Published var keepRunningWhenLocked: Bool {
        didSet {
            defaults.set(keepRunningWhenLocked, forKey: "keepRunningWhenLocked")
            if keepRunningWhenLocked { keeper.start() } else { keeper.stop() }
        }
    }
    /// İsteğe bağlı: PS5 oyun sesini bu telefondan (ya da bağlı kulaklıktan) çal.
    @Published var gameAudioEnabled: Bool {
        didSet {
            defaults.set(gameAudioEnabled, forKey: "gameAudioEnabled")
            // Ses, oturum başlarken PS5'ten istenir: değişince yeniden bağlan.
            if gameAudioEnabled != oldValue, credentials != nil { connect() }
        }
    }
    @Published var gameAudioVolume: Double {
        didSet {
            defaults.set(gameAudioVolume, forKey: "gameAudioVolume")
            gameAudio.volume = Float(gameAudioVolume)
        }
    }

    /// Altyazının arandığı bölge (karede normalize, başlangıç sol üst).
    @Published var region: CGRect { didSet { saveRegion(); reader.setRegion(region); saveGameProfile() } }
    /// Görev/ipucu yazılarını da çevir (ekranın bir köşesinde sürekli duran yazılar).
    @Published var hudEnabled: Bool {
        didSet {
            defaults.set(hudEnabled, forKey: "hudEnabled")
            hudFlag.value = hudEnabled
            if !hudEnabled { Task { await hud.reset() } }
            saveGameProfile()
        }
    }
    /// Görev yazılarının arandığı bölge (karede normalize, başlangıç sol üst).
    @Published var hudRegion: CGRect {
        didSet {
            defaults.set([hudRegion.minX, hudRegion.minY, hudRegion.width, hudRegion.height].map(Double.init), forKey: "hudRegion")
            hudReader.setRegion(hudRegion)
            saveGameProfile()
        }
    }

    /// Konuşma seçeneklerini de çevir: ekranda alt alta beliren 2–6 kısa seçenek, listenin altında
    /// numaralı Türkçe karşılıklarıyla gösterilir.
    @Published var choicesEnabled: Bool = true {
        didSet {
            defaults.set(choicesEnabled, forKey: "choicesEnabled")
            choiceFlag.value = choicesEnabled
            if !choicesEnabled { Task { await choices.reset() } }
        }
    }
    private let choiceFlag = Flag(true)
    /// Seçeneklerin arandığı alan: üst şerit dışında ekranın neredeyse tamamı. Altyazı ve görev
    /// çerçevelerinin içine düşen yazılar burada yok sayılır (onları kendi okuyucuları çevirir).
    private static let choiceArea = CGRect(x: 0.04, y: 0.22, width: 0.92, height: 0.75)
    private let choiceReader: FrameTextReader = {
        let reader = FrameTextReader(interval: 0.5)
        reader.setRegion(AppModel.choiceArea)
        return reader
    }()

    /// Okuma süresi: oyun bir repliği çabuk kaldırdığında çevirinin ekranda bekleme süresinin çarpanı.
    @Published var readingPace: Double = 1 {
        didSet {
            defaults.set(readingPace, forKey: "readingPace")
            let pace = readingPace
            Task { await pipeline.setReadingPace(pace) }
        }
    }

    /// Çevirinin üstünde özgün İngilizce satırı da göster (oynarken İngilizce öğrenmek isteyenler için).
    @Published var showOriginal = false {
        didSet {
            defaults.set(showOriginal, forKey: "showOriginal")
            let on = showOriginal
            Task { await pipeline.setShowsOriginal(on) }
        }
    }

    /// Özellik turu: kullanıcı bir özelliği gerçekten kullanınca o madde işaretlenir.
    enum TourItem: String, CaseIterable {
        case screen, history, names, appearance, phone
    }
    @Published private(set) var tourDone: Set<String> = []
    @Published var tourHidden = false { didSet { defaults.set(tourHidden, forKey: "tourHidden") } }

    func completeTour(_ item: TourItem) {
        guard !tourDone.contains(item.rawValue) else { return }
        tourDone.insert(item.rawValue)
        defaults.set(Array(tourDone), forKey: "tourDone")
    }

    /// Seçili oyunda çevrilmeyecek adlar (karakter, yer, silah).
    @Published private(set) var keptTerms: [String] = []
    private var protector = TermProtector(terms: [])
    /// Bu oturumda konuşan olarak görülen adlar; "çevirme" listesine eklemek için öneri.
    @Published private(set) var seenSpeakers: [String] = []

    func addKeptTerm(_ raw: String) {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, !keptTerms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        keptTerms.append(term)
        keptTerms.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        applyKeptTerms()
        completeTour(.names)
    }

    /// Seçili oyunun hazır ad listesini (varsa) "çevrilmeyecek adlar"a ekler.
    func addPackTerms(_ pack: GamePack) {
        for term in pack.terms where !keptTerms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            keptTerms.append(term)
        }
        keptTerms.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        applyKeptTerms()
        completeTour(.names)
    }

    func removeKeptTerm(_ term: String) {
        keptTerms.removeAll { $0 == term }
        applyKeptTerms()
    }

    private func applyKeptTerms() {
        protector = TermProtector(terms: keptTerms)
        saveGameProfile()
    }

    // MARK: Isınma koruması

    /// Telefonun ısısına göre ekran okuma yükü. Isındıkça önce yan okumalar (görev yazıları, seçenekler,
    /// altyazının yerini arama) seyrelir; konuşma okuması yalnız son kademede yavaşlar.
    @Published private(set) var readingLoad: ReadingLoad = .full
    /// Telefonun bildirdiği ısı durumu (ayarlar ve durum raporu için).
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    #if DEBUG
    /// Deneme: ısı durumunu elle ver (`-debugThermal 0…3` ya da `:8080/isi?d=0…3`; -1 gerçeğe döner).
    private var thermalOverride: ProcessInfo.ThermalState?
    #endif

    private func watchThermalState() {
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyReadingLoad() }
            }
        }
        applyReadingLoad()
    }

    private func applyReadingLoad() {
        let info = ProcessInfo.processInfo
        var thermal = info.thermalState
        #if DEBUG
        if let thermalOverride { thermal = thermalOverride }
        #endif
        thermalState = thermal
        let load = ReadingLoad.level(thermal: thermal, lowPower: info.isLowPowerModeEnabled)
        reader.setSlowdown(load.speechSlowdown)
        for side in [hudReader, choiceReader, scanReader] { side.setSlowdown(load.sideSlowdown) }
        guard load != readingLoad else { return }
        let previous = readingLoad
        readingLoad = load
        if load == .minimal {
            // Yan okumalar durdu: ekranda kalan görev yazısı ve seçenekler takılı kalmasın.
            Task { await hud.reset(); await choices.reset() }
            if connection == .connected {
                server.sendNotice("Telefon çok ısındı: görev yazıları ve seçenekler bir süre çevrilmeyecek. Konuşma çevirisi sürüyor.", seconds: 7)
            }
        } else if previous == .minimal, connection == .connected {
            server.sendNotice("Telefon soğudu: görev yazıları ve seçenekler yeniden çevriliyor.", seconds: 4)
        }
    }

    /// Isınma korumasının kullanıcıya gösterilecek açıklaması; koruma devrede değilse `nil`.
    var thermalNote: String? {
        switch readingLoad {
        case .full, .eased: return nil
        case .light: return "Telefonu serin tutmak için görev yazıları ve seçenekler daha seyrek okunuyor. Konuşma çevirisi etkilenmez."
        case .minimal: return "Telefon çok ısındı: görev yazıları ve seçenekler durduruldu, konuşma çevirisi sürüyor. Şarjdaysa çıkar, kılıfını çıkar, serin bir yere koy."
        }
    }

    /// Isı durumunun kısa adı.
    var thermalName: String {
        switch thermalState {
        case .nominal: return "Serin"
        case .fair: return "Ilık"
        case .serious: return "Sıcak"
        case .critical: return "Çok sıcak"
        @unknown default: return "Bilinmiyor"
        }
    }

    // MARK: "Takıldım" yardımcısı (DENEME)

    /// Bir takılma anının durumu: soru, o ana dek verilen ipuçları (kademe kademe), bedel.
    struct HelperState: Equatable {
        var working = false
        var question = ""
        var hints: [String] = []
        var error: String?
        /// Son sorunun süresi (sn) ve yaklaşık bedeli (dolar); bu oturumdaki toplam bedel ve soru sayısı.
        var lastSeconds: Double?
        var lastCost: Double?
        var totalCost = 0.0
        var asked = 0
        /// Daha açık bir ipucu istenebilir mi?
        var canGoDeeper: Bool { !hints.isEmpty && hints.count < GameHelper.Depth.allCases.count }
    }
    @Published private(set) var helper = HelperState()
    private var helperClient: GameHelper?
    private var helperRun = 0

    /// Ekrana bakıp ipucu ister. `deeper`: aynı takılma için bir kademe daha açık ipucu.
    /// Yalnız kullanıcı istediğinde çalışır ve o anki TEK kareyi yapay zekâya gönderir.
    func askHelper(question: String = "", deeper: Bool = false) {
        guard !helper.working else { return }
        guard let client = helperClient else {
            helper.error = "Yardımcı için yapay zekâ anahtarı gerekli (Ayarlar)."
            return
        }
        guard let frame = reader.latestFrame, let jpeg = Self.helperJPEG(from: frame) else {
            helper.error = "Oyun görüntüsü henüz gelmedi; PS5 bağlanınca yeniden dene."
            return
        }
        if !deeper {
            helper.hints = []
            helper.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        helper.error = nil
        helper.working = true
        helperRun += 1
        let run = helperRun
        let depth = GameHelper.Depth(rawValue: helper.hints.count + 1) ?? .full
        // Görev yazısı okunmuyorsa (kapalı ya da ısınma koruması durdurmuş) eldeki yazı bayattır: gönderme.
        let objective = hudEnabled && readingLoad != .minimal ? hudTracked : ""
        let context = GameHelper.Context(game: selectedGame, question: helper.question, objective: objective,
                                         recentLines: history.suffix(10).map { line in
                                             (line.speaker.map { "\($0): " } ?? "") + (line.source.isEmpty ? line.translation : line.source)
                                         },
                                         depth: depth, earlierHints: helper.hints)
        server.sendHelp(state: "working")
        let started = Date()
        Task {
            do {
                let answer = try await client.ask(jpeg: jpeg, context: context)
                guard run == helperRun else { return }
                helper.hints.append(answer.text)
                helper.lastSeconds = Date().timeIntervalSince(started)
                helper.lastCost = answer.cost
                helper.totalCost += answer.cost
                helper.asked += 1
                helper.working = false
                // Uzun ipucu ekranda daha uzun kalır.
                server.sendHelp(state: "done", text: answer.text, seconds: max(30, min(90, Double(answer.text.count) * 0.15)))
                helperLog.add(String(format: "[%@ · kademe %d · %.1f sn · %d+%d belirteç · $%.4f] S: %@ → %@",
                                     selectedGame.isEmpty ? "oyun seçilmedi" : selectedGame, depth.rawValue,
                                     helper.lastSeconds ?? 0, answer.inputTokens, answer.outputTokens, answer.cost,
                                     helper.question.isEmpty ? "(yok)" : helper.question, answer.text))
            } catch {
                guard run == helperRun else { return }
                helper.working = false
                helper.error = error.localizedDescription
                server.sendHelp(state: "clear")
                helperLog.add("HATA: \(error.localizedDescription)")
            }
        }
    }

    /// İpucu kutusunu televizyondan kaldırır ve takılma anını kapatır (süren istek varsa yanıtı yok sayılır).
    func closeHelper() {
        helperRun += 1
        helper.working = false
        helper.hints = []
        helper.question = ""
        helper.error = nil
        server.sendHelp(state: "clear")
    }

    /// Deneme günlüğü: sorulan her soru, yanıtı, süresi ve bedeli (yalnız bu oturum; `:8080/takildim`).
    let helperLog = DebugLog()

    /// Kareyi yardımcıya gidecek boyuta getirir: uzun kenar 1456 piksel (modelin yazıyı rahat okuduğu,
    /// bedeli de düşük tutan boy), JPEG.
    private static func helperJPEG(from buffer: CVPixelBuffer) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > 1456 {
            let scale = 1456 / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIContext().jpegRepresentation(of: image, colorSpace: space,
                                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.75])
    }

    // MARK: Dublaj (DENEME)

    /// Çevrilen replikleri Türkçe seslendir. Oyunun kendi sesi sürer; Türkçe ses üstüne okunur.
    @Published var dubEnabled = false {
        didSet {
            defaults.set(dubEnabled, forKey: "dubEnabled")
            if !dubEnabled {
                dubber.stop()
                server.sendSpeakStop()
            }
        }
    }
    /// "eleven" (ElevenLabs, doğal ses) ya da "system" (telefonun kendi sesi, ücretsiz).
    @Published var dubEngine = Dubber.Engine.system.rawValue {
        didSet {
            defaults.set(dubEngine, forKey: "dubEngine")
            dubber.engine = Dubber.Engine(rawValue: dubEngine) ?? .system
        }
    }
    /// "tv" (televizyondan) ya da "phone" (telefondan).
    @Published var dubOutput = Dubber.Output.tv.rawValue {
        didSet {
            defaults.set(dubOutput, forKey: "dubOutput")
            dubber.output = Dubber.Output(rawValue: dubOutput) ?? .tv
        }
    }
    @Published var dubVolume = 1.0 {
        didSet {
            defaults.set(dubVolume, forKey: "dubVolume")
            dubber.volume = dubVolume
        }
    }
    /// ElevenLabs anahtarı kayıtlı mı?
    @Published private(set) var dubHasKey = false
    /// Kullanıcının elle seçtiği cinsiyetler (konuşan adı küçük harfle → "male" / "female").
    @Published private(set) var dubGenders: [String: String] = [:]
    /// Bu oturumun ölçümü (ayarlar ekranında gösterilir).
    @Published private(set) var dubSummary = ""
    @Published private(set) var dubProblem: String?
    let dubber = Dubber()
    private var cast = VoiceCast()
    private var castGame: String?

    private func setUpDubbing() {
        dubGenders = defaults.dictionary(forKey: "dubGenders") as? [String: String] ?? [:]
        dubVolume = defaults.object(forKey: "dubVolume") as? Double ?? 1
        dubOutput = defaults.string(forKey: "dubOutput") ?? Dubber.Output.tv.rawValue
        let key = KeychainStore.loadSpeechKey()
        dubber.eleven = key.map { ElevenLabsSpeech(apiKey: $0) }
        dubHasKey = key != nil
        // Anahtar varsa doğal ses, yoksa cihaz sesi.
        dubEngine = defaults.string(forKey: "dubEngine") ?? (dubHasKey ? Dubber.Engine.eleven : .system).rawValue
        dubEnabled = defaults.bool(forKey: "dubEnabled")
        dubber.tvConnected = { [weak self] in (self?.tvCount ?? 0) > 0 }
        dubber.deliver = { [weak self] data, type, volume in
            guard let self else { return }
            self.server.sendSpeak(path: self.pageServer.clips.add(data, type: type), volume: volume)
        }
        dubber.onChange = { [weak self] in
            guard let self else { return }
            self.dubProblem = self.dubber.problem
            self.dubSummary = "Bu oturum: \(self.dubber.spoken) replik okundu"
                + (self.dubber.skipped > 0 ? ", \(self.dubber.skipped) replik geride kalındığı için atlandı" : "")
                + (self.dubber.characters > 0 ? " · ElevenLabs'e \(self.dubber.characters) harf gitti" : "")
        }
    }

    func setSpeechKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.saveSpeechKey(key.isEmpty ? nil : key)
        dubber.eleven = key.isEmpty ? nil : ElevenLabsSpeech(apiKey: key)
        dubHasKey = !key.isEmpty
        if key.isEmpty, dubEngine == Dubber.Engine.eleven.rawValue { dubEngine = Dubber.Engine.system.rawValue }
    }

    /// Konuşanın cinsiyetini elle belirler (`unknown` = kendiliğinden); sesi buna göre yeniden seçilir.
    func setDubGender(_ gender: DubGender, for speaker: String) {
        let key = speaker.lowercased()
        dubGenders[key] = gender == .unknown ? nil : gender.rawValue
        defaults.set(dubGenders, forKey: "dubGenders")
    }

    func dubGender(of speaker: String?) -> DubGender {
        VoiceCast.gender(of: speaker, pack: GamePacks.find(selectedGame),
                         overrides: dubGenders.compactMapValues { DubGender(rawValue: $0) })
    }

    /// Konuşana verilen ses. Dağıtım oyun başına saklanır: karakter her oturumda aynı sesle konuşur.
    func dubVoice(for speaker: String?) -> DubVoice {
        if castGame != selectedGame {
            let all = defaults.dictionary(forKey: "dubCast") as? [String: [String: String]] ?? [:]
            cast = VoiceCast(assigned: all[selectedGame] ?? [:])
            castGame = selectedGame
        }
        let before = cast.assigned
        let voice = cast.voice(for: speaker, gender: dubGender(of: speaker))
        if cast.assigned != before {
            var all = defaults.dictionary(forKey: "dubCast") as? [String: [String: String]] ?? [:]
            all[selectedGame] = cast.assigned
            defaults.set(all, forKey: "dubCast")
        }
        return voice
    }

    /// Bir repliği dublaj sırasına koyar (ayarlardaki "dinle" düğmesi de bunu kullanır).
    func dub(_ text: String, speaker: String?) {
        guard let clean = DubText.clean(text) else { return }
        dubber.enqueue(Dubber.Job(text: clean, speaker: speaker, voice: dubVoice(for: speaker), gender: dubGender(of: speaker)))
    }

    // MARK: Televizyonda gizle / göster

    /// Televizyondaki altyazı gizli mi (kumandada YEŞİL tuş ya da buradaki düğme)? Televizyon bildirir.
    @Published private(set) var tvMuted = false

    func setTVMuted(_ hidden: Bool) {
        server.sendMute(hidden)
    }

    /// Hazır bir görünümü uygular (yazının yeri ve konuşan renkleri olduğu gibi kalır).
    func apply(_ preset: SubtitlePreset) {
        fontScale = preset.scale
        appearance = preset.applied(to: appearance)
    }

    /// Çeviriyi telefonun kendi ekranında büyük yazıyla göster (televizyona bir şey kurulamayan markalar için).
    @Published var phoneDisplay = false {
        didSet {
            if phoneDisplay { setDimmed(false); completeTour(.phone) }
            lastInteraction = Date()
        }
    }
    /// Görev yazılarının ve konuşma seçeneklerinin çevirileri (telefon ekranında göstermek için).
    @Published private(set) var hintItems: [ScreenItem] = []
    @Published private(set) var choiceItems: [ScreenItem] = []
    /// "Ekranı çevir"in sonucu ve çevrilen kare (telefon ekranında göstermek için).
    @Published private(set) var screenItems: [ScreenItem] = []
    @Published private(set) var screenFrame: CGImage?

    /// Altyazının ekrandaki yerini uygulama kendisi bulsun (sarı çerçeveyi elle yerleştirmeye gerek kalmasın).
    /// Kullanıcı çerçeveyi elle oynatırsa kapanır.
    @Published var autoRegion: Bool {
        didSet {
            defaults.set(autoRegion, forKey: "autoRegion")
            scanFlag.value = autoRegion
            regionFinder.reset()
            autoRegionFound = false
        }
    }
    /// Otomatik bulma bu oturumda bir bölge belirledi mi?
    @Published private(set) var autoRegionFound = false
    private var regionFinder = SubtitleRegionFinder()
    private var lastAutoRegionChange = Date.distantPast
    private var applyingAutoRegion = false
    private let scanFlag = Flag(false)
    /// Altyazı aranırken taranan alan: ekranın alt bölümü, neredeyse tam genişlik.
    private static let scanArea = CGRect(x: 0.02, y: 0.35, width: 0.96, height: 0.63)
    private let scanReader: FrameTextReader = {
        let reader = FrameTextReader(interval: 1.5)
        reader.setRegion(AppModel.scanArea)
        return reader
    }()

    /// Kullanıcı sarı çerçeveyi elle oynattı: artık onun dediği geçerli.
    func setRegionManually(_ rect: CGRect) {
        if autoRegion { autoRegion = false }
        region = rect
    }

    /// DENEYSEL: altyazı olmayan yerlerde konuşmayı oyunun sesinden çevir.
    /// Ekranda altyazı varken çeviri altyazıdan yapılır (daha hızlı ve doğru); altyazı yokken
    /// (ara sahne, altyazısız oyun) duyulan konuşma çevrilir.
    @Published var speechEnabled: Bool {
        didSet {
            defaults.set(speechEnabled, forKey: "speechEnabled")
            speechFlag.value = speechEnabled
            if speechEnabled { speech.start() } else { speech.stop() }
            // Ses akışı oturum başlarken istenir: açıp kapatınca PS5'e yeniden bağlan.
            if oldValue != speechEnabled, credentials != nil, session != nil { connect() }
        }
    }
    private let speech = SpeechListener()
    private let speechFlag = Flag(false)
    /// Ekranda şu an altyazıdan okunmuş bir replik var mı, en son ne zaman kalktı?
    private var subtitleOnScreen = false
    private var lastSubtitleGone = Date.distantPast
    /// Altyazı kalktıktan sonra bu süre içinde duyulan cümle büyük olasılıkla o altyazının sesidir: gösterilmez.
    private let speechQuietAfterSubtitle: TimeInterval = 4

    /// Oyun ayarları: çerçevelerin yeri her oyun için ayrı saklanır. PS5 çalışan oyunu bildirmediği için
    /// (22 Kas 2026'da oyun açıkken ölçüldü) oyunu kullanıcı seçer.
    @Published private(set) var games: [String]
    /// Seçili oyun; boşsa "Genel" ayarlar geçerlidir.
    @Published private(set) var selectedGame: String
    private var applyingProfile = false
    private let profiles = GameProfileStore()

    /// Bu oturumda çevrilen replikler (kaçırılan repliği geri okumak için). Uygulama kapanınca silinir.
    struct HistoryLine: Identifiable, Equatable {
        let id: Int
        let date: Date
        let speaker: String?
        let translation: String
        let source: String
    }
    @Published private(set) var history: [HistoryLine] = []
    private var recorded = Set<Int>()

    static let defaultHUDRegion = CGRect(x: 0.02, y: 0.03, width: 0.38, height: 0.32)
    @Published var position: SubtitlePosition { didSet { defaults.set(position.rawValue, forKey: "position"); pushStyle() } }
    @Published var fontScale: Double { didSet { defaults.set(fontScale, forKey: "fontScale"); pushStyle() } }
    /// Televizyondaki yazının rengi, zemini, kalınlığı ve konuşan renkleri.
    @Published var appearance: SubtitleAppearance {
        didSet {
            defaults.set(appearance.color.rawValue, forKey: "subtitleColor")
            defaults.set(appearance.background, forKey: "subtitleBackground")
            defaults.set(appearance.bold, forKey: "subtitleBold")
            defaults.set(appearance.speakerColors, forKey: "subtitleSpeakerColors")
            pushStyle()
        }
    }

    @Published var translationConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "tr")
    )
    /// Türkçe çeviri dili telefonda hazır mı (indirilmiş mi)?
    @Published private(set) var translationReady = false

    /// Çeviri dilinin hazırlanmasını yeniden dener; dil inmemişse iPhone indirme iznini yeniden sorar.
    func retryTranslationSetup() {
        translationStatus = nil
        translationConfiguration.invalidate()
    }

    private let server = SubtitleServer()
    /// TV sayfasını yerel ağda sunar: uygulama kurulamayan televizyonlar (LG) tarayıcıda açar.
    private let pageServer = TVPageServer()
    private let reader = FrameTextReader()
    /// Görev/ipucu yazıları saniyede üç kez okunur: bir yazı iki okumada görülünce gösterildiği için
    /// çeviri, yazı çıktıktan yaklaşık yarım saniye sonra ekrana gelir.
    private let hudReader = FrameTextReader(interval: 0.3) { buffer, roi, _ in
        // Görev/ipucu yazılarında tuş simgeleri de aranır ("□ tuşunu basılı tut").
        (try? TextRecognizer().recognizeLinesWithIcons(pixelBuffer: buffer, roi: roi)) ?? []
    }
    private let hudFlag = Flag(false)
    /// Örnek kipi: PS5 ve televizyon olmadan, hazır bir sahne gerçek çeviri hattından geçirilir.
    @Published private(set) var demo = false
    private var demoTimer: DispatchSourceTimer?

    /// Abonelik yokken çeviri durur: kareler okunmaz.
    private let lockedFlag = Flag(false)
    @Published private(set) var locked = false
    /// Görev/ipucu yazısının çevirisi televizyonda özgün yazının hemen altında gösterilir.
    private lazy var hud = HUDTranslator { [overlay] items in overlay.set(hints: items) }
    /// Konuşma seçeneklerinin çevirisi: listenin altında, numaralı.
    private lazy var choices = HUDTranslator(kind: .choices) { [overlay] items in overlay.set(choices: items) }
    /// Televizyonun köşe katmanı tektir: görev yazıları ile seçenekler birleştirilip yollanır.
    private lazy var overlay = OverlayMerger(server: server)
    /// Görev bölgesinde en son okunan ham yazı ve izlenen yazılar (teşhis için).
    private var hudRaw = ""
    private var hudTracked = ""
    private let defaults = UserDefaults.standard
    private var session: RemotePlaySession?
    private var generation = 0
    private lazy var pipeline = SubtitlePipeline(server: server)
    private var translationSession: TranslationSession?
    private var retryTask: Task<Void, Never>?
    private var savedBrightness: CGFloat?
    private var lastInteraction = Date()
    private var autoDimTask: Task<Void, Never>?
    private let previewEnabled = Flag(true)
    private let keeper = BackgroundKeeper()
    private let gameAudio = GameAudioPlayer()
    /// "Ekranı çevir": duraklatılmış ekrandaki tüm yazıları yapay zekâyla çevirip TV'de yerinde gösterir.
    private lazy var screen = ScreenTranslationController(server: server) { [reader] in reader.latestFrame }
    /// Ekran çevirisinin durumu: nil (kapalı), "working", "done" ya da hata metni.
    @Published private(set) var screenState: String?
    private var statusTask: Task<Void, Never>?
    /// Bu kadar süre dokunulmazsa (PS5 bağlıyken) ekran kendiliğinden kararır.
    private let autoDimAfter: TimeInterval = 30

    init() {
        Self.importProvisionedFiles()
        let stored = KeychainStore.load()
        credentials = stored
        accountID = stored?.accountID ?? UserDefaults.standard.data(forKey: "accountID")

        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: "region") as? [Double], saved.count == 4 {
            region = CGRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
        } else {
            region = FrameTextReader.defaultRegion
        }
        position = SubtitlePosition(rawValue: defaults.string(forKey: "position") ?? "") ?? .bottom
        let scale = defaults.double(forKey: "fontScale")
        fontScale = scale > 0 ? scale : 1.0
        appearance = SubtitleAppearance(
            color: SubtitleAppearance.TextColor(rawValue: defaults.string(forKey: "subtitleColor") ?? "") ?? .white,
            background: defaults.object(forKey: "subtitleBackground") as? Double ?? 0.62,
            bold: defaults.bool(forKey: "subtitleBold"),
            speakerColors: defaults.bool(forKey: "subtitleSpeakerColors"))
        keepRunningWhenLocked = defaults.object(forKey: "keepRunningWhenLocked") as? Bool ?? true
        gameAudioEnabled = defaults.bool(forKey: "gameAudioEnabled")
        gameAudioVolume = defaults.object(forKey: "gameAudioVolume") as? Double ?? 0.8

        hudEnabled = defaults.object(forKey: "hudEnabled") as? Bool ?? true
        choicesEnabled = defaults.object(forKey: "choicesEnabled") as? Bool ?? true
        let pace = defaults.double(forKey: "readingPace")
        readingPace = pace > 0 ? pace : 1
        showOriginal = defaults.bool(forKey: "showOriginal")
        tourDone = Set(defaults.stringArray(forKey: "tourDone") ?? [])
        tourHidden = defaults.bool(forKey: "tourHidden")
        speechEnabled = defaults.bool(forKey: "speechEnabled")
        autoRegion = defaults.object(forKey: "autoRegion") as? Bool ?? true
        games = defaults.stringArray(forKey: "games") ?? []
        selectedGame = defaults.string(forKey: "gameSelected") ?? ""
        if let saved = defaults.array(forKey: "hudRegion") as? [Double], saved.count == 4 {
            hudRegion = CGRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
        } else {
            hudRegion = Self.defaultHUDRegion
        }

        reader.setRegion(region)
        hudFlag.value = hudEnabled
        hudReader.setRegion(hudRegion)
        choiceFlag.value = choicesEnabled
        keptTerms = profiles.profile(for: selectedGame)?.keptTerms ?? []
        protector = TermProtector(terms: keptTerms)
        if profiles.profile(for: selectedGame) == nil { saveGameProfile() }
        overlay.onChange = { [weak self] hints, choices in
            DispatchQueue.main.async {
                self?.hintItems = hints
                self?.choiceItems = choices
            }
        }
        speechFlag.value = speechEnabled
        if speechEnabled { speech.start() }
        scanFlag.value = autoRegion
        // Altyazının yerini bulma: ekranın alt bölümü seyrek taranır, geçici cümlelerin toplandığı bant bulunur.
        let (scans, scanFeed) = AsyncStream.makeStream(of: [RecognizedLine].self, bufferingPolicy: .bufferingNewest(1))
        scanReader.onLines = { scanFeed.yield($0) }
        Task { [weak self] in
            for await lines in scans {
                guard let self, self.autoRegion else { continue }
                self.updateAutoRegion(with: lines)
            }
        }
        // Sesten gelen her cümle çevrilip konuşma dökümüne eklenir.
        speech.onUtterance = { [weak self] sentence in
            Task { @MainActor in
                guard let self, self.speechEnabled, !self.locked else { return }
                // Altyazı varsa (ya da az önce vardıysa) bu cümle zaten altyazıdan çevrildi.
                guard !self.subtitleOnScreen,
                      Date().timeIntervalSince(self.lastSubtitleGone) > self.speechQuietAfterSubtitle else { return }
                guard let translated = await self.quickTranslate(sentence), !translated.isEmpty else { return }
                let seconds = max(2.0, min(6.0, 1.5 + Double(translated.count) * 0.06))
                await self.pipeline.announce(label: "", source: sentence, translation: translated, duration: seconds)
            }
        }
        server.onClientCountChange = { [weak self] count in
            self?.tvCount = count
            if count > 0 { self?.tvLaunchStatus = nil }
            if count == 0 { self?.tvOutdated = false; self?.tvMuted = false }
        }
        server.onStatus = { [weak self] status in self?.serverStatus = status }
        // TV kumandasından gelen komutlar (mavi tuş: ekranı çevir).
        server.onClientMessage = { [weak self] message in
            if message["type"] as? String == "hello" {
                // Televizyon kendi sürümünü bildirir.
                if message["platform"] as? String == "tizen", let build = message["build"] as? String {
                    self?.tvOutdated = build != SamsungTVSetup.embeddedBuild
                }
                return
            }
            if message["type"] as? String == "spoke" {
                // Televizyon bir dublaj sesini çaldı (ya da çalamadı): ölçüm günlüğüne yaz.
                let ok = message["ok"] as? Bool ?? false
                self?.dubber.log.add("  TV: \(message["path"] as? String ?? "?") \(ok ? "çalındı" : "ÇALINAMADI") · sırada bekleme \(message["wait"] as? Int ?? -1) ms")
                return
            }
            if message["type"] as? String == "visibility" {
                self?.tvMuted = message["hidden"] as? Bool ?? false
                return
            }
            self?.screen.handle(message: message)
        }
        // Okunan satırlar sırası bozulmadan tek bir görevde işlenir.
        let (frames, feed) = AsyncStream.makeStream(of: [RecognizedLine].self, bufferingPolicy: .bufferingNewest(4))
        reader.onLines = { feed.yield($0) }
        Task { [weak self] in
            guard let pipeline = self?.pipeline else { return }
            await pipeline.setDisplayHandler { lines in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lines = lines
                    self.record(lines)
                    for name in lines.compactMap(\.speaker) where !self.seenSpeakers.contains(name) && self.seenSpeakers.count < 40 {
                        self.seenSpeakers.append(name)
                    }
                    // Altyazıdan okunan satırlar (duyurular ve sesten gelenler hariç) ekranda mı?
                    let hasSubtitle = lines.contains { $0.id < 1_000_000 }
                    if self.subtitleOnScreen, !hasSubtitle { self.lastSubtitleGone = Date() }
                    self.subtitleOnScreen = hasSubtitle
                }
            }
            await pipeline.setProblemHandler { message in
                DispatchQueue.main.async { self?.aiProblem = message }
            }
            await pipeline.setQuickTranslator { text in await self?.quickTranslate(text) }
            if let pace = self?.readingPace { await pipeline.setReadingPace(pace) }
            if self?.showOriginal == true { await pipeline.setShowsOriginal(true) }
            await self?.applyAIKey(KeychainStore.loadAIKey())
            for await lines in frames { await pipeline.ingest(lines) }
        }
        // Görev yazıları: ayrı, yavaş bir okuma hattı.
        let (hudFrames, hudFeed) = AsyncStream.makeStream(of: [RecognizedLine].self, bufferingPolicy: .bufferingNewest(1))
        hudReader.onLines = { hudFeed.yield($0) }
        Task { [weak self] in
            guard let hud = self?.hud else { return }
            await hud.setTranslator { text in await self?.quickTranslate(text) }
            for await lines in hudFrames {
                guard let self, self.hudEnabled else { continue }
                await hud.ingest(lines, region: self.hudRegion)
                self.hudRaw = String(lines.map(\.text).joined(separator: " | ").prefix(200))
                self.hudTracked = String(await hud.current.joined(separator: " | ").prefix(200))
            }
        }
        // Konuşma seçenekleri: ekranın geri kalanını seyrek okuyan üçüncü hat.
        let (choiceFrames, choiceFeed) = AsyncStream.makeStream(of: [RecognizedLine].self, bufferingPolicy: .bufferingNewest(1))
        choiceReader.onLines = { choiceFeed.yield($0) }
        Task { [weak self] in
            guard let choices = self?.choices else { return }
            // Tek kelimelik seçenekler ("Leave", "Yes") bağlamsız çevrilince saçmalıyor; önce sözlüğe bakılır.
            await choices.setTranslator { text in
                if let known = MenuGlossary.lookup(text) { return known }
                return await self?.quickTranslate(text)
            }
            for await lines in choiceFrames {
                guard let self, self.choicesEnabled else { continue }
                await choices.ingest(lines, region: Self.choiceArea,
                                     excluding: [self.region] + (self.hudEnabled ? [self.hudRegion] : []))
            }
        }
        // "Ekranı çevir" anahtarsız da çalışır: yazılar cihaz üstü çeviriyle çevrilir.
        screen.setLocalTranslator(LocalScreenTranslator { [weak self] texts in
            await self?.quickTranslateBatch(texts) ?? texts.map { _ in nil }
        })
        screen.onItems = { [weak self] items, frame in
            var image: CGImage?
            if !items.isEmpty, let frame {
                VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image)
            }
            DispatchQueue.main.async {
                self?.screenItems = items
                self?.screenFrame = image
            }
        }
        #if DEBUG
        // Geliştirme sürümünde teşhis: telefonun gördüğü son kare yerel ağdan alınabilir (http://<telefon>:8080/kare.jpg).
        // Çeviri denemesi: /cevir?t=<yazı>|<yazı> sıraya alır, /cevir sonuçları verir; /ad?t=<ad> "çevirme"
        // listesine ekler; /ekran "ekranı çevir"i çalıştırır, /ekran-sonuc çevrilen öğeleri verir.
        let debugLog = DebugLog()
        pageServer.extra = { [reader, weak self] path in
            let text = { (prefix: String) -> String? in
                path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)).removingPercentEncoding : nil
            }
            if let query = text("/cevir?t=") {
                Task { @MainActor in
                    for piece in query.split(separator: "|").map(String.init) {
                        let started = Date()
                        let result = await self?.quickTranslate(piece) ?? "(çevrilemedi)"
                        debugLog.add("\(piece)  =>  \(result)  [\(Int(Date().timeIntervalSince(started) * 1000)) ms]")
                    }
                }
                return ("text/plain; charset=utf-8", Data("sıraya alındı\n".utf8))
            }
            if path == "/cevir" { return ("text/plain; charset=utf-8", Data(debugLog.text.utf8)) }
            if let term = text("/ad?t=") {
                Task { @MainActor in self?.addKeptTerm(term) }
                return ("text/plain; charset=utf-8", Data("eklendi\n".utf8))
            }
            if let degree = text("/isi?d=") {
                Task { @MainActor in
                    self?.thermalOverride = Int(degree).flatMap { ProcessInfo.ThermalState(rawValue: $0) }
                    self?.applyReadingLoad()
                }
                return ("text/plain; charset=utf-8", Data("ayarlandı\n".utf8))
            }
            if let line = text("/dublaj?t=") {
                // "Ad: metin" biçiminde verilirse konuşan adıyla okunur.
                Task { @MainActor in
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, parts[0].count <= 24 { self?.dub(parts[1], speaker: parts[0]) } else { self?.dub(line, speaker: nil) }
                }
                return ("text/plain; charset=utf-8", Data("sıraya alındı\n".utf8))
            }
            if path == "/dublaj" {
                let state = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { () -> String in
                        guard let self else { return "" }
                        return "açık: \(self.dubEnabled) · ses: \(self.dubEngine) · çıkış: \(self.dubOutput) · anahtar: \(self.dubHasKey ? "var" : "YOK") · tv: \(self.tvCount) · \(self.dubSummary)\(self.dubProblem.map { " · SORUN: \($0)" } ?? "")\n" + self.dubber.log.text
                    }
                }
                return ("text/plain; charset=utf-8", Data(state.utf8))
            }
            if let question = text("/takildim?s=") {
                // "+" = aynı takılma için bir kademe daha açık ipucu; "-" = kutuyu kapat.
                Task { @MainActor in
                    if question == "-" { self?.closeHelper() } else { self?.askHelper(question: question == "+" ? "" : question, deeper: question == "+") }
                }
                return ("text/plain; charset=utf-8", Data("istendi\n".utf8))
            }
            if path == "/takildim" {
                let state = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { () -> String in
                        guard let self else { return "" }
                        let helper = self.helper
                        return "anahtar: \(self.aiEnabled ? "var" : "YOK") · çalışıyor: \(helper.working) · soru sayısı: \(helper.asked) · toplam: $\(String(format: "%.4f", helper.totalCost))\(helper.error.map { " · HATA: \($0)" } ?? "")\n" + self.helperLog.text
                    }
                }
                return ("text/plain; charset=utf-8", Data(state.utf8))
            }
            if let hidden = text("/gizle?d=") {
                Task { @MainActor in self?.setTVMuted(hidden == "1") }
                return ("text/plain; charset=utf-8", Data("istendi\n".utf8))
            }
            if path == "/rapor" {
                let report = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.diagnosticsReport ?? "" } }
                return ("text/plain; charset=utf-8", Data(report.utf8))
            }
            if path == "/ekran" {
                Task { @MainActor in self?.toggleScreenTranslation() }
                return ("text/plain; charset=utf-8", Data("istendi\n".utf8))
            }
            if path == "/ekran-sonuc" {
                let lines = DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        (self?.screenItems ?? []).map { String(format: "%.2f,%.2f  %@", $0.x, $0.y, $0.text) }
                            + ["durum: \(self?.screenState ?? "kapalı")"]
                    }
                }
                return ("text/plain; charset=utf-8", Data(lines.joined(separator: "\n").utf8))
            }
            guard path == "/kare.jpg", let buffer = reader.latestFrame,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpeg = CIContext().jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: space) else { return nil }
            return ("image/jpeg", jpeg)
        }
        #endif
        let previewEnabled = self.previewEnabled
        reader.onSample = { [weak self] buffer in
            // Ekran karanlıkken önizleme üretmek boşa iş (ve pil).
            guard previewEnabled.value else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            DispatchQueue.main.async { self?.preview = image }
        }
        #if DEBUG
        let forced = defaults.object(forKey: "debugThermal") as? Int ?? Int(defaults.string(forKey: "debugThermal") ?? "") ?? -1
        thermalOverride = ProcessInfo.ThermalState(rawValue: forced)
        #endif
        watchThermalState()
        setUpDubbing()
    }

    /// Mac'te yapılmış PS5 eşleşmesi ve yapay zekâ anahtarı, uygulamanın Belgeler klasörüne
    /// kopyalanarak telefona aktarılabilir (PSN girişi ve PS5 kodu baştan gerekmesin diye).
    /// Dosyalar Anahtar Zinciri'ne alınır ve hemen silinir.
    private static func importProvisionedFiles() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let pairing = documents.appendingPathComponent("ps5.json")
        if let data = try? Data(contentsOf: pairing),
           let imported = try? JSONDecoder().decode(RemotePlayCredentials.self, from: data) {
            KeychainStore.save(imported)
        }
        try? FileManager.default.removeItem(at: pairing)

        // Bilgisayarda alınmış Samsung kurulum sertifikaları (deneme ve taşıma için).
        let signing = documents.appendingPathComponent("samsung-signing.json")
        if let data = try? Data(contentsOf: signing),
           let material = try? JSONDecoder().decode(SamsungSigningMaterial.self, from: data) {
            KeychainStore.saveSamsungMaterial(material)
        }
        try? FileManager.default.removeItem(at: signing)

        let key = documents.appendingPathComponent("anthropic-key")
        if let text = try? String(contentsOf: key, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { KeychainStore.saveAIKey(trimmed) }
        }
        try? FileManager.default.removeItem(at: key)

        let speechKey = documents.appendingPathComponent("elevenlabs-key")
        if let text = try? String(contentsOf: speechKey, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { KeychainStore.saveSpeechKey(trimmed) }
        }
        try? FileManager.default.removeItem(at: speechKey)
    }

    // MARK: - Yaşam döngüsü

    /// Uygulama öne her geldiğinde çağrılır.
    func activate() {
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        applyReadingLoad()
        ipAddress = LocalNetwork.wifiAddress() ?? "Wi-Fi yok"
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugSamsungInstall") { checkSamsungTV() }
        #endif
        server.start()
        pageServer.start()
        pushStyle()
        if credentials != nil, session == nil, !demo { connect() }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugDemo") { startDemo() }
        #endif
        if keepRunningWhenLocked { keeper.start() }
        gameAudio.volume = Float(gameAudioVolume)
        startStatusReports()
        lastInteraction = Date()
        autoDimTask?.cancel()
        autoDimTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                // Örnek kipinde ekran kendiliğinden kararmaz: gösterilen şey ekranın kendisidir.
                if !self.dimmed, !self.demo, !self.phoneDisplay, self.connection == .connected,
                   Date().timeIntervalSince(self.lastInteraction) >= self.autoDimAfter {
                    self.setDimmed(true)
                }
            }
        }
    }

    /// Ekrana dokunulduğunda çağrılır; kendiliğinden kararma sayacını sıfırlar.
    func noteInteraction() {
        lastInteraction = Date()
    }

    /// Karanlık ekran kipini açar/kapatır. iOS, ekran KİLİTLENİNCE uygulamanın görüntü çözmesini
    /// durdurduğu için gerçek kilit yerine bu kullanılır: uygulama önde kalır, ekran siyah olur.
    func setDimmed(_ on: Bool) {
        guard on != dimmed else { return }
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        if on {
            savedBrightness = screen?.brightness
            screen?.brightness = 0
        } else {
            if let savedBrightness { screen?.brightness = savedBrightness }
            savedBrightness = nil
            lastInteraction = Date()
        }
        previewEnabled.value = !on
        dimmed = on
    }

    /// Uygulama arka plana geçti (başka uygulamaya geçildi ya da ekran kilitlendi).
    /// Ses oturumu açıksa iOS uygulamayı çalışır tutar: bağlantı ve çeviri sürdürülür.
    func enteredBackground() {
        setDimmed(false)
        // Ses motoru durmuşsa (arama, kulaklık değişimi) kilitlenmeden önce ayağa kaldır;
        // yoksa iOS uygulamayı askıya alır ve bağlantı kopar.
        if keepRunningWhenLocked, keeper.ensureRunning() { return }
        deactivate()
    }

    /// Telefonun durumunu iki saniyede bir ağa bildirir (teşhis: kilitliyken neyin çalıştığını görmek için).
    private func startStatusReports() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let state = UIApplication.shared.applicationState
                self.server.sendStatus([
                    "app": state == .active ? "önde" : (state == .background ? "arka planda" : "geçişte"),
                    "kilitli": !UIApplication.shared.isProtectedDataAvailable,
                    "kare": self.session?.decodedFrames ?? -1,
                    "bozuk": self.session?.failedFrames ?? -1,
                    "çözücüYenileme": self.session?.decoderRebuilds ?? -1,
                    "çözücüHata": Int(self.session?.lastDecodeError ?? 0),
                    "okumaKilit": self.reader.stallCount,
                    "sonOkuma": (self.reader.secondsSinceLastRead * 10).rounded() / 10,
                    "ses": self.keepRunningWhenLocked ? self.keeper.ensureRunning() : false,
                    "sesYeniden": self.keeper.restarts,
                    "arkaPlan": UIApplication.shared.applicationState != .active,
                    "samsung": self.samsungWork ?? (self.samsungError.map { "HATA: \($0)" } ?? (self.samsung.host == nil ? "tv yok" : (self.samsung.appInstalled ? "kurulu" : "kurulu değil"))),
                    "tv": self.tvCount,
                    "bölge": [self.region.minX, self.region.minY, self.region.width, self.region.height].map { (Double($0) * 100).rounded() / 100 },
                    "otoBölge": self.autoRegion ? (self.autoRegionFound ? "bulundu" : "aranıyor") : "kapalı",
                    "konuşma": self.speechEnabled ? self.speech.status : "kapalı",
                    "konuşmaSon": self.speechEnabled ? self.speech.lastHeard : "",
                    "konuşmaCümle": self.speechEnabled ? self.speech.utterances : 0,
                    "oyun": self.selectedGame,
                    "geçmiş": self.history.count,
                    "tvEski": self.tvOutdated,
                    "samsungİzin": self.samsungReadyForInstall,
                    "samsungSertifika": self.hasSamsungCertificates,
                    "görev": self.hudEnabled,
                    "seçenek": self.choicesEnabled ? self.choiceItems.map(\.text).joined(separator: " | ") : "kapalı",
                    "seçenekOkuma": (self.choiceReader.lastReadDuration * 1000).rounded(),
                    "telefonEkranı": self.phoneDisplay,
                    "ısı": self.thermalName,
                    "yük": "\(self.readingLoad)",
                    "düşükGüç": ProcessInfo.processInfo.isLowPowerModeEnabled,
                    "pil": UIDevice.current.batteryLevel < 0 ? -1 : Int(UIDevice.current.batteryLevel * 100),
                    "şarjda": UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full,
                    "okuma": (self.reader.lastReadDuration * 1000).rounded(),
                    "görevOkuma": (self.hudReader.lastReadDuration * 1000).rounded(),
                    "tvGizli": self.tvMuted,
                    "adlar": self.keptTerms.count,
                    "görevBölge": [self.hudRegion.minX, self.hudRegion.minY, self.hudRegion.width, self.hudRegion.height].map { (Double($0) * 100).rounded() / 100 },
                    "görevOkunan": self.hudRaw,
                    "görevİzlenen": self.hudTracked,
                    "oyunSesi": self.gameAudioEnabled,
                    "sesPaket": self.gameAudio.decodedPackets,
                    "sesBozuk": self.gameAudio.failedPackets,
                    "sesAtlanan": self.gameAudio.droppedPackets,
                    "sesSıra": self.gameAudio.queuedPackets,
                    "sesHız": Int(self.gameAudio.playbackRate),
                    "donanımHız": Int(self.gameAudio.hardwareRate),
                    "sesTepe": (Double(self.gameAudio.peak) * 1000).rounded() / 1000,
                ])
            }
        }
    }

    func deactivate() {
        keeper.stop()
        autoDimTask?.cancel()
        setDimmed(false)   // parlaklığı geri ver
        disconnect()
        connection = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Kurulum

    func finishLogin(redirect url: URL) async {
        do {
            let id = try await PSNAccount.accountID(fromRedirect: url)
            accountID = id
            defaults.set(id, forKey: "accountID")
            setupError = nil
            searchHosts()
        } catch {
            setupError = error.localizedDescription
        }
    }

    func searchHosts() {
        guard !searching else { return }
        searching = true
        Task {
            let found = await Task.detached { PS5Discovery.search() }.value
            hosts = found
            searching = false
        }
    }

    func pair(host: String, pin: String) {
        guard let accountID, !pairing else { return }
        pairing = true
        setupError = nil
        Task {
            let result = await Task.detached {
                Result { try RemotePlayPairing.pair(host: host, accountID: accountID, pin: pin) }
            }.value
            pairing = false
            switch result {
            case .success(let paired):
                KeychainStore.save(paired)
                credentials = paired
                connect()
            case .failure(let error):
                setupError = error.localizedDescription
            }
        }
    }

    /// Samsung televizyonu ağda bulur ve Marhilk'i kumandaya dokunmadan açar. Modem yeniden başlayıp
    /// adresler değişse de çalışır: televizyon her seferinde ağ taranarak bulunur.
    /// `announce`: sonucu kullanıcıya yaz (düğmeyle çağrıldığında); kendiliğinden denemede sessiz kalınır.
    func openOnTV(announce: Bool = true) {
        guard !tvLaunching else { return }
        guard defaults.string(forKey: "tvBrand") != "lg" else { return }   // LG'de uygulama yok, tarayıcı var
        tvLaunching = true
        if announce { tvLaunchStatus = "Televizyon aranıyor…" }
        let address = ipAddress
        Task {
            defer { tvLaunching = false }
            var hosts: [String] = []
            // Önce bilinen adres; tutmazsa (adres değişmiş olabilir) ağı tara.
            if let known = defaults.string(forKey: "tvHost"), (try? await SamsungTVInfo.fetch(host: known)) != nil {
                hosts = [known]
            } else {
                hosts = await SamsungTVInfo.discover(from: address).map(\.host)
            }
            guard !hosts.isEmpty else {
                if announce { tvLaunchStatus = "Samsung televizyon bulunamadı. Televizyon açık ve bu telefonla aynı Wi-Fi'da olmalı." }
                return
            }
            for host in hosts {
                switch await SamsungTVInfo.appState(host: host) {
                case .running:
                    defaults.set(host, forKey: "tvHost")
                    if announce { tvLaunchStatus = "Marhilk televizyonda açık; birkaç saniye içinde bağlanır." }
                    return
                case .stopped:
                    if await SamsungTVInfo.launch(host: host) {
                        defaults.set(host, forKey: "tvHost")
                        if announce { tvLaunchStatus = "Televizyonda açıldı; birkaç saniye içinde bağlanır." }
                        return
                    }
                case .notInstalled, .unreachable:
                    continue
                }
            }
            if announce { tvLaunchStatus = "Televizyon bulundu ama Marhilk orada kurulu değil ya da açılamadı." }
        }
    }

    // MARK: - Samsung TV'ye kurulum

    /// Ağdaki Samsung televizyonu bulur; geliştirici kipini ve Marhilk'in kurulu olup olmadığını okur.
    func checkSamsungTV() {
        guard !samsung.searching else { return }
        samsung.searching = true
        let address = ipAddress
        Task {
            var found: (host: String, info: SamsungTVInfo)?
            if let known = samsung.host ?? defaults.string(forKey: "tvHost"), let info = try? await SamsungTVInfo.fetch(host: known) {
                found = (known, info)
            } else {
                found = await SamsungTVInfo.discover(from: address).first
            }
            var status = SamsungStatus()
            if let found {
                defaults.set(found.host, forKey: "tvHost")
                status.host = found.host
                status.name = found.info.name
                status.developerMode = found.info.developerMode
                status.developerIP = found.info.developerIP
                let state = await SamsungTVInfo.appState(host: found.host)
                status.appInstalled = state == .running || state == .stopped
            }
            samsung = status
            #if DEBUG
            // Deneme: uygulama `-debugSamsungInstall YES` ile başlatılırsa kurulum kendiliğinden yapılır.
            if UserDefaults.standard.bool(forKey: "debugSamsungInstall"), !debugInstallStarted, samsungReadyForInstall {
                debugInstallStarted = true
                installOnSamsungTV()
            }
            #endif
        }
    }

    func setSamsungToken(_ token: SamsungToken) {
        samsungToken = token
        samsungSignedIn = true
        samsungError = nil
    }

    /// Televizyondaki uygulamayı bu telefonun içindeki sürüme günceller (televizyonu gerekirse önce bulur).
    func updateTVApp() {
        guard samsungWork == nil else { return }
        if samsung.host != nil { return installOnSamsungTV() }
        samsungError = nil
        samsungWork = "Televizyon aranıyor…"
        let address = ipAddress
        Task {
            var host = defaults.string(forKey: "tvHost")
            if let known = host, (try? await SamsungTVInfo.fetch(host: known)) == nil { host = nil }
            if host == nil { host = await SamsungTVInfo.discover(from: address).first?.host }
            samsungWork = nil
            guard let host else {
                samsungError = "Samsung televizyon bulunamadı. Televizyon açık ve bu telefonla aynı Wi-Fi'da olmalı."
                return
            }
            defaults.set(host, forKey: "tvHost")
            samsung.host = host
            installOnSamsungTV()
        }
    }

    /// TV uygulamasını bu telefondan televizyona kurar (gerekirse önce Samsung'dan sertifika alır).
    func installOnSamsungTV() {
        guard samsungWork == nil, let host = samsung.host else { return }
        samsungError = nil
        samsungWork = "Televizyona bağlanılıyor…"
        let token = samsungToken
        let existing = KeychainStore.loadSamsungMaterial()
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                let material = try await SamsungTVSetup.install(host: host, token: token, existing: existing) { [weak self] step in
                    let text: String
                    switch step {
                    case .connecting: text = "Televizyona bağlanılıyor…"
                    case .readingTV: text = "Televizyonun kimliği okunuyor…"
                    case .requestingCertificates: text = "Samsung'dan bu televizyon için izin belgesi alınıyor…"
                    case .signing: text = "Uygulama imzalanıyor…"
                    case .sending(let fraction): text = "Televizyona gönderiliyor… %\(Int(fraction * 100))"
                    case .installing: text = "Televizyonda kuruluyor…"
                    case .launching: text = "Televizyonda açılıyor…"
                    case .done: text = "Tamam."
                    }
                    Task { @MainActor in self?.samsungWork = text }
                }
                KeychainStore.saveSamsungMaterial(material)
                samsung.appInstalled = true
                tvOutdated = false
                samsungWork = nil
            } catch {
                samsungWork = nil
                samsungError = error.localizedDescription
            }
        }
    }

    /// Eşleşmeyi siler; kurulum baştan yapılır.
    func forget() {
        disconnect()
        KeychainStore.delete()
        defaults.removeObject(forKey: "accountID")
        credentials = nil
        accountID = nil
        hosts = []
        connection = .idle
        preview = nil
    }

    // MARK: - Bağlantı

    func connect() {
        guard var target = credentials else { return }
        disconnect()
        generation += 1
        let current = generation
        connection = .working("PS5 aranıyor…")

        Task {
            // PS5'in adresi değişmiş ya da PS5 dinlenme modunda olabilir.
            let hostID = target.mac.replacingOccurrences(of: ":", with: "").uppercased()
            let found = await Task.detached { PS5Discovery.search(timeout: 2) }.value
            guard current == generation else { return }
            if let host = found.first(where: { $0.hostID.uppercased() == hostID }) {
                if host.address != target.host {
                    target.host = host.address
                    credentials = target
                    KeychainStore.save(target)
                }
                if host.isStandby {
                    connection = .working("PS5 uyandırılıyor…")
                    try? RemotePlayPairing.wake(target)
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard current == generation else { return }
                }
            }

            connection = .working("PS5'e bağlanılıyor…")
            let session = RemotePlaySession(credentials: target, audio: gameAudioEnabled || speechEnabled)
            let reader = self.reader
            let hudReader = self.hudReader
            let hudFlag = self.hudFlag
            let lockedFlag = self.lockedFlag
            let scanReader = self.scanReader
            let scanFlag = self.scanFlag
            let choiceReader = self.choiceReader
            let choiceFlag = self.choiceFlag
            session.onFrame = { frame in
                guard !lockedFlag.value else { return }
                reader.submit(frame)
                if scanFlag.value { scanReader.submit(frame) }
                if hudFlag.value { hudReader.submit(frame) }
                if choiceFlag.value { choiceReader.submit(frame) }
            }
            if gameAudioEnabled || speechEnabled {
                // Oyun sesi iki işe yarar: telefondan çalmak (isteğe bağlı) ve konuşmayı yazıya dökmek (deneysel).
                let audio = gameAudioEnabled ? self.gameAudio : nil
                let listener = speechEnabled ? self.speech : nil
                session.onAudioFormat = { channels, rate, frameSize in
                    audio?.configure(channels: channels, sampleRate: rate, frameSize: frameSize)
                    listener?.configure(channels: channels, sampleRate: rate, frameSize: frameSize)
                }
                session.onAudioPacket = { packet in
                    audio?.enqueue(packet)
                    listener?.enqueue(packet)
                }
            }
            session.onEvent = { [weak self] event in
                DispatchQueue.main.async { self?.handle(event, generation: current) }
            }
            do {
                try session.start()
                self.session = session
            } catch {
                fail(error.localizedDescription, generation: current)
            }
        }
    }

    private func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        generation += 1
        session?.stop()
        session = nil
        gameAudio.stop()
        Task { await pipeline.reset() }
        Task { await hud.reset() }
        Task { await choices.reset() }
    }

    private func handle(_ event: RemotePlaySession.Event, generation current: Int) {
        guard current == generation else { return }
        switch event {
        case .connected:
            connection = .connected
            // PS5 bağlandı ama televizyon yok: büyük olasılıkla TV'de uygulama kapalı. Bir kez kendiliğinden aç.
            if tvCount == 0, !triedAutoLaunch {
                triedAutoLaunch = true
                openOnTV(announce: false)
            }
        case .loginPinRequired:
            fail("Bu PSN kullanıcısında giriş parolası var. PS5'te o kullanıcının giriş parolasını kaldırın.", generation: current, retry: false)
        case .ended(let isError, let message):
            fail(isError ? "Bağlantı koptu: \(message)" : "PS5 oturumu kapattı.", generation: current)
        }
    }

    private func fail(_ message: String, generation current: Int, retry: Bool = true) {
        guard current == generation else { return }
        disconnect()
        connection = .failed(message)
        guard retry else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: - Çeviri

    /// `.translationTask` içinden çağrılır; görev iptal edilene kadar cihaz üstü çeviri oturumunu açık tutar.
    func runTranslation(with translation: TranslationSession) async {
        do {
            // Türkçe dil paketi yoksa sistem burada indirme izni ister.
            try await translation.prepareTranslation()
            translationStatus = nil
            translationReady = true
        } catch {
            translationReady = false
            translationStatus = "Türkçe çeviri dili henüz telefonda yok; çeviri bu yüzden gelmiyor."
        }
        translationSession = translation
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        translationSession = nil
    }

    /// Hızlı (cihaz üstü) çeviri; yapay zekâ çevirisi gelene kadar ekranda bu görünür.
    private func quickTranslate(_ text: String) async -> String? {
        if let translationSession {
            // Oyunun "çevirme" listesindeki adlar korunarak çevrilir; koruma çeviride bozulursa korumasız çevrilir.
            let protected = protector.protect(text)
            if !protected.isEmpty,
               let translated = try? await translationSession.translate(protected.text).targetText,
               let restored = protector.restore(translated, from: protected) {
                return restored
            }
            if let translated = try? await translationSession.translate(text).targetText { return translated }
        }
        // Örnek kipinde çeviri dili yoksa sahnenin hazır çevirisi kullanılır.
        return demo ? DemoScene.translation(for: text) : nil
    }

    /// Birçok yazıyı tek seferde çevirir ("ekranı çevir" için); sonuç aynı sırada döner.
    private func quickTranslateBatch(_ texts: [String]) async -> [String?] {
        var results = [String?](repeating: nil, count: texts.count)
        if let translationSession {
            let protected = texts.map { protector.protect($0) }
            let requests = protected.enumerated().map {
                TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset))
            }
            if let responses = try? await translationSession.translations(from: requests) {
                for response in responses {
                    guard let index = response.clientIdentifier.flatMap({ Int($0) }), results.indices.contains(index) else { continue }
                    results[index] = protected[index].isEmpty
                        ? response.targetText
                        : protector.restore(response.targetText, from: protected[index])
                }
            }
        }
        // Toplu çeviride eksik kalanlar tek tek denenir (örnek kipinde hazır çeviriler buradan gelir).
        for index in results.indices where results[index] == nil {
            results[index] = await quickTranslate(texts[index])
        }
        return results
    }

    /// Yapay zekâ çevirisi için Anthropic API anahtarı; boş verilirse kapatılır.
    func setAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.saveAIKey(trimmed.isEmpty ? nil : trimmed)
        Task { await applyAIKey(trimmed.isEmpty ? nil : trimmed) }
    }

    /// Yapay zekâ yalnız "ekranı çevir" için kullanılır. Canlı altyazıda kullanılmaz: orada gecikme
    /// kaliteden önemli (kullanıcı kararı; Haiku repliklerin yalnız ~%13'ünde süreye yetişti).
    private func applyAIKey(_ key: String?) async {
        screen.setTranslator(key.map { ScreenTranslator(apiKey: $0) })
        helperClient = key.map { GameHelper(apiKey: $0) }
        screen.onState = { [weak self] state, message in
            DispatchQueue.main.async {
                switch state {
                case "working", "done":
                    self?.screenState = state
                    if state == "done" { self?.completeTour(.screen) }
                case "error": self?.screenState = message ?? "Ekran çevrilemedi."
                default: self?.screenState = nil
                }
            }
        }
        aiEnabled = key != nil
        aiProblem = nil
    }

    /// Telefondaki düğme: ekrandaki her şeyi çevir / çeviriyi kaldır.
    func toggleScreenTranslation() {
        screen.toggle()
    }

    private func pushStyle() {
        server.sendStyle(position: position, scale: fontScale, appearance: appearance)
    }

    // MARK: - Örnek kipi

    /// Hazır sahneyi oynatır: kareler saniyede on kez üretilip gerçek okuma ve çeviri hattına verilir.
    func startDemo() {
        guard !demo else { return }
        disconnect()
        demo = true
        connection = .connected
        let scene = DemoScene()
        let started = Date()
        let reader = self.reader
        let hudReader = self.hudReader
        let hudFlag = self.hudFlag
        let lockedFlag = self.lockedFlag
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "altyazitr.demo"))
        timer.schedule(deadline: .now(), repeating: 0.1)
        let scanReader = self.scanReader
        let scanFlag = self.scanFlag
        let choiceReader = self.choiceReader
        let choiceFlag = self.choiceFlag
        timer.setEventHandler {
            guard !lockedFlag.value, let frame = scene.frame(at: Date().timeIntervalSince(started)) else { return }
            reader.submit(frame)
            if scanFlag.value { scanReader.submit(frame) }
            if hudFlag.value { hudReader.submit(frame) }
            if choiceFlag.value { choiceReader.submit(frame) }
        }
        timer.resume()
        demoTimer = timer
    }

    func stopDemo() {
        guard demo else { return }
        demoTimer?.cancel()
        demoTimer = nil
        demo = false
        connection = .idle
        preview = nil
        Task {
            await pipeline.reset()
            await hud.reset()
            await choices.reset()
        }
        if credentials != nil { connect() }
    }

    // MARK: - Abonelik

    /// Abonelik durumuna göre çeviriyi açar ya da durdurur. Bağlantı, kurulum ve ayarlar açık kalır.
    func setLocked(_ isLocked: Bool) {
        guard isLocked != locked else { return }
        locked = isLocked
        lockedFlag.value = isLocked
        guard isLocked else { return }
        preview = nil
        Task {
            await pipeline.reset()
            await hud.reset()
            await choices.reset()
            // Televizyona bakan kişi neden yazı gelmediğini bilsin.
            await pipeline.announce(label: "Marhilk", source: "", translation: "Abonelik gerekli. Telefonda Marhilk'i aç.", duration: 12)
        }
    }

    // MARK: - Altyazının yerini bulma

    private func updateAutoRegion(with lines: [RecognizedLine]) {
        let area = Self.scanArea
        // Satırlar taranan alana görelidir; karenin tamamına çevir.
        let observations = lines.map { line in
            SubtitleRegionFinder.Observation(text: line.text,
                                             x: Double(area.minX + line.x * area.width),
                                             top: Double(area.minY + (line.y - line.height / 2) * area.height),
                                             width: Double(line.width * area.width),
                                             height: Double(line.height * area.height))
        }
        regionFinder.observe(observations)
        guard let suggestion = regionFinder.suggestion() else { return }
        autoRegionFound = true
        // Çerçeve sık sık kıpırdamasın: yalnız belirgin farkta ve en çok 20 saniyede bir değişir.
        guard SubtitleRegionFinder.differs(suggestion, from: region),
              Date().timeIntervalSince(lastAutoRegionChange) > 20 else { return }
        lastAutoRegionChange = Date()
        region = suggestion
    }

    // MARK: - Sorun bildir

    /// Uygulamanın o anki durumunun kısa dökümü: bir şey çalışmadığında kullanıcı bunu paylaşır.
    /// Kişisel bilgi içermez (ad, hesap, adres, PS5'in adı yoktur).
    var diagnosticsReport: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        var system = utsname()
        uname(&system)
        let device = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let brand = defaults.string(forKey: "tvBrand") ?? ""
        let guideStep = defaults.integer(forKey: "guideStep")

        let ps5: String
        switch connection {
        case .connected: ps5 = "bağlı"
        case .working(let step): ps5 = "bağlanıyor (\(step))"
        case .failed(let message): ps5 = "BAĞLANAMADI: \(message)"
        case .idle: ps5 = "bağlı değil"
        }
        var tv = tvCount > 0 ? "bağlı" : "bağlı değil"
        if tvOutdated { tv += ", eski sürüm" }
        var lines = [
            "Marhilk durum raporu",
            "Sürüm: \(version) · iOS \(UIDevice.current.systemVersion) · \(device)",
            "Kurulum rehberi: \(defaults.bool(forKey: "guideDone") ? "tamamlandı" : "\(guideStep + 1). adımda")",
            "Wi-Fi: \(LocalNetwork.wifiAddress() == nil ? "YOK" : "bağlı")",
            "PS5 eşleşmesi: \(credentials == nil ? "YOK" : "var") · PSN girişi: \(accountID == nil ? "YOK" : "var")",
            "PS5: \(ps5)",
            "Televizyon markası: \(brand.isEmpty ? "seçilmedi" : brand) · \(tv)",
        ]
        if brand == "samsung" || brand.isEmpty {
            let state = samsung.host == nil ? "ağda bulunamadı"
                : "\(samsung.appInstalled ? "uygulama kurulu" : "uygulama kurulu değil"), geliştirici kipi \(samsung.developerMode ? "açık" : "KAPALI"), izinli adres \(samsung.developerIP == ipAddress ? "doğru" : "YANLIŞ")"
            lines.append("Samsung TV: \(state) · sertifika \(hasSamsungCertificates ? "var" : "yok")")
            if let samsungError { lines.append("Samsung hatası: \(samsungError)") }
        }
        lines.append("Çeviri dili: \(translationReady ? "hazır" : "HAZIR DEĞİL")\(translationStatus.map { " (\($0))" } ?? "")")
        if let serverStatus { lines.append("Sunucu: \(serverStatus)") }
        if locked { lines.append("Abonelik: gerekli (çeviri duruyor)") }
        lines.append("Görüntü: \(session?.decodedFrames ?? 0) kare · son okuma \(String(format: "%.1f", reader.secondsSinceLastRead)) sn önce · \(history.count) replik çevrildi")
        lines.append("Ayarlar: görev yazıları \(hudEnabled ? "açık" : "kapalı"), seçenekler \(choicesEnabled ? "açık" : "kapalı"), sesten çeviri \(speechEnabled ? "açık" : "kapalı"), otomatik çerçeve \(autoRegion ? (autoRegionFound ? "bulundu" : "aranıyor") : "kapalı"), telefon ekranı \(phoneDisplay ? "açık" : "kapalı"), kilitliyken çalış \(keepRunningWhenLocked ? "açık" : "kapalı")")
        lines.append("Isı: \(thermalName)\(ProcessInfo.processInfo.isLowPowerModeEnabled ? " · Düşük Güç Modu açık" : "")\(readingLoad >= .light ? " · ısınma koruması devrede" : "")")
        if tvMuted { lines.append("Televizyonda altyazı gizli (YEŞİL tuş)") }
        if demo { lines.append("Örnek kipi açık") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Oyuna göre ayar

    /// Bir oyunu seçer (boş ad = "Genel"). O oyunun kayıtlı çerçeveleri yüklenir.
    func selectGame(_ name: String) {
        guard name != selectedGame else { return }
        regionFinder.reset()
        autoRegionFound = false
        lastAutoRegionChange = .distantPast
        selectedGame = name
        defaults.set(name, forKey: "gameSelected")
        guard let saved = profiles.profile(for: name) else {
            keptTerms = []
            protector = TermProtector(terms: [])
            return saveGameProfile()
        }
        applyingProfile = true
        if let rect = saved.regionRect { region = rect }
        if let rect = saved.hudRegionRect { hudRegion = rect }
        hudEnabled = saved.hudEnabled
        keptTerms = saved.keptTerms ?? []
        protector = TermProtector(terms: keptTerms)
        applyingProfile = false
    }

    /// Yeni bir oyun ekler; şimdiki çerçeveler o oyunun başlangıç ayarı olur. Oyun hazır paketlerdeyse
    /// (ya da `pack` verildiyse) karakter ve yer adları "çevrilmeyecek adlar"a hazır gelir.
    func addGame(_ rawName: String, pack: GamePack? = nil) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let isNew = !games.contains(name)
        if !games.contains(name) {
            games.append(name)
            games.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            defaults.set(games, forKey: "games")
        }
        selectedGame = name
        defaults.set(name, forKey: "gameSelected")
        if isNew {
            keptTerms = (pack ?? GamePacks.find(name))?.terms.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? []
            protector = TermProtector(terms: keptTerms)
        }
        saveGameProfile()
    }

    func removeGame(_ name: String) {
        games.removeAll { $0 == name }
        defaults.set(games, forKey: "games")
        if selectedGame == name { selectGame("") }
    }

    private func saveGameProfile() {
        guard !applyingProfile else { return }
        profiles.save(GameProfile(region: region, hudRegion: hudRegion, hudEnabled: hudEnabled, keptTerms: keptTerms), for: selectedGame)
    }

    // MARK: - Konuşma geçmişi

    private func record(_ lines: [DisplayLine]) {
        for line in lines where !recorded.contains(line.id) {
            guard let translation = line.translation else { continue }
            recorded.insert(line.id)
            history.append(HistoryLine(id: line.id, date: Date(), speaker: line.speaker, translation: translation, source: line.source))
            // Dublaj: yalnız konuşma replikleri (duyurular değil), her replik bir kez.
            if dubEnabled, line.id < 1_000_000 { dub(translation, speaker: line.speaker) }
        }
        if history.count > 400 { history.removeFirst(history.count - 400) }
    }

    func clearHistory() {
        history = []
    }

    private func saveRegion() {
        defaults.set([region.minX, region.minY, region.width, region.height].map(Double.init), forKey: "region")
    }
}

/// İş parçacıkları arasında paylaşılan basit bayrak.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

enum LocalNetwork {
    /// Telefonun Wi-Fi (en0) IPv4 adresi.
    static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cursor = interface.ifa_next
        }
        return nil
    }
}

/// Televizyonun köşe katmanı tek iletiyle güncellenir; görev yazıları ile konuşma seçenekleri ayrı
/// hatlardan gelir. Burada birleştirilip birlikte yollanır.
final class OverlayMerger: @unchecked Sendable {
    private let lock = NSLock()
    private var hints: [ScreenItem] = []
    private var choices: [ScreenItem] = []
    private let server: SubtitleServer
    /// Her değişiklikte çağrılır (telefon ekranında göstermek için).
    var onChange: (@Sendable ([ScreenItem], [ScreenItem]) -> Void)?

    init(server: SubtitleServer) {
        self.server = server
    }

    func set(hints items: [ScreenItem]) {
        update { hints = items }
    }

    func set(choices items: [ScreenItem]) {
        update { choices = items }
    }

    private func update(_ change: () -> Void) {
        lock.lock()
        change()
        let hints = self.hints, choices = self.choices
        lock.unlock()
        server.sendHUD(items: hints + choices)
        onChange?(hints, choices)
    }
}

/// Deneme çıktıları (yerel ağdan yalnız geliştirme sürümünde okunur).
final class DebugLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        lock.unlock()
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n") + "\n"
    }
}
