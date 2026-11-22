import AltyaziCore
import Foundation
import Security
import ImageIO
import RemotePlayKit
import VideoToolbox
#if canImport(Translation)
import Translation
#endif

// Mac'te deneme aracı.
//   altyazi-mac demo                         → sunucuyu açar, örnek altyazı yollar (TV uygulamasını denemek için)
//   altyazi-mac ocr <resim>                  → resimdeki yazıyı okur
//   altyazi-mac cevir "<satır>" [model]       → yapay zekâ çevirisini dener, süresini ölçer
//   altyazi-mac ekran <resim>                → kayıtlı bir kareyi "ekranı çevir" ile çevirir
//   altyazi-mac ps5 ara                      → ağdaki PS5'leri listeler
//   altyazi-mac ps5 giris                    → PSN giriş sayfasını açar
//   altyazi-mac ps5 hesap <yönlendirme-adresi> → girişi tamamlar, hesap kimliğini saklar
//   altyazi-mac ps5 eslestir <ip> <8 haneli kod>
//   altyazi-mac ps5 izle                     → PS5'e bağlanır, altyazıyı çevirip TV'ye yollar

let arguments = Array(CommandLine.arguments.dropFirst())
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let credentialsURL: URL = {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AltyaziTR")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("ps5.json")
}()

let accountURL = credentialsURL.deletingLastPathComponent().appendingPathComponent("psn-account-id")

func runDemo() -> Never {
    let server = SubtitleServer()
    server.onClientCountChange = { print("Bağlı TV sayısı: \($0)") }
    // ALTYAZI_PORT: canlı hat çalışırken ayrı bir portta deneme yapabilmek için.
    let port = UInt16(ProcessInfo.processInfo.environment["ALTYAZI_PORT"] ?? "") ?? SubtitleServer.defaultPort
    server.onStatus = { print($0 ?? "Sunucu hazır, port \(port)") }
    server.start(port: port)
    // LG televizyonların tarayıcıda açtığı sayfa (http://<adres>:8080).
    let pageServer = TVPageServer()
    pageServer.start(port: UInt16(ProcessInfo.processInfo.environment["ALTYAZI_SAYFA_PORT"] ?? "") ?? TVPageServer.defaultPort)
    // Örnek görev yazısı (sol üstte, yerinde çeviri katmanını denemek için).
    server.sendHUD(items: [ScreenItem(x: 0.04, y: 0.08, width: 0.16, height: 0.03, lineHeight: 0.03, lines: 1, text: "Mangayı takip et")])
    server.sendStyle(position: .bottom, scale: 1.0)

    // Art arda dört kişi konuşur: her yeni replik alta eklenir, eskiler yukarı kayıp çıkar.
    let script: [(speaker: String?, text: String)] = [
        ("Dunn", "Ju Kwon'u aldılar, dostum."), ("Park", "Teğmene telsizle haber vermeliyiz."),
        ("Jae", "Telsiz hâlâ çalışmıyor."), ("Cho", "Saldırı altında mıyız?"),
        ("Dunn", "Sence? Bütün dünya havaya uçuyor."), ("Jae", "İşte stadyum. Gidelim."),
    ]
    var scenes: [[(id: Int, speaker: String?, text: String)]] = []
    for end in 1...script.count {
        scenes.append((max(0, end - 4)..<end).map { (id: $0 + 1, speaker: script[$0].speaker, text: script[$0].text) })
    }
    scenes.append([])
    var index = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1.6)
    timer.setEventHandler {
        server.sendLines(scenes[index % scenes.count])
        index += 1
    }
    timer.resume()
    RunLoop.main.run()
    exit(0)
}

func runOCR(_ path: String) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Resim açılamadı.") }
    do { print(try TextRecognizer().recognize(cgImage: image)) } catch { fail("Okuma hatası: \(error.localizedDescription)") }
}

func loadCredentials() -> RemotePlayCredentials {
    guard let data = try? Data(contentsOf: credentialsURL),
          let credentials = try? JSONDecoder().decode(RemotePlayCredentials.self, from: data) else {
        fail("Önce eşleşin: altyazi-mac ps5 eslestir <ip> <kod>")
    }
    return credentials
}

/// İngilizce → Türkçe, cihaz üstünde. Dil paketi yoksa `nil` döner.
func makeTranslator() async -> ((String) async -> String?)? {
    #if canImport(Translation)
    if #available(macOS 26.0, *) {
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "tr"))
        do {
            _ = try await session.translate("Hello")
            return { text in try? await session.translate(text).targetText }
        } catch {
            print("Çeviri dil paketi yok (\(error.localizedDescription)). Sistem Ayarları › Genel › Dil ve Bölge › Çeviri Dilleri'nden İngilizce ve Türkçe'yi indirin. Şimdilik yalnız İngilizce gösterilecek.")
        }
    }
    #endif
    return nil
}

/// Yapay zekâ çevirisi için Anthropic API anahtarı: ortam değişkeni ya da 0600 izinli dosya.
func anthropicKey() -> String? {
    if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty { return key }
    let file = credentialsURL.deletingLastPathComponent().appendingPathComponent("anthropic-key")
    let key = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    return key?.isEmpty == false ? key : nil
}

/// Ekranın okunan bölümü: ALTYAZI_BOLGE="x,y,genişlik,yükseklik" (0…1, sol üstten) ile değiştirilebilir.
func watchRegion() -> CGRect {
    let parts = (ProcessInfo.processInfo.environment["ALTYAZI_BOLGE"] ?? "").split(separator: ",").compactMap { Double($0) }
    if parts.count == 4 { return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) }
    return FrameTextReader.defaultRegion
}

func runWatch() async -> Never {
    var credentials = loadCredentials()
    let server = SubtitleServer()
    server.onClientCountChange = { print("Bağlı TV sayısı: \($0)") }
    server.start()
    server.sendStyle(position: .bottom, scale: 1.0)

    // PS5'in adresi değişmiş olabilir; dinlenme modunda olabilir.
    let hostID = credentials.mac.replacingOccurrences(of: ":", with: "").uppercased()
    if let host = PS5Discovery.search(timeout: 2).first(where: { $0.hostID.uppercased() == hostID }) {
        credentials.host = host.address
        if host.isStandby {
            print("PS5 dinlenme modunda, uyandırılıyor…")
            try? RemotePlayPairing.wake(credentials)
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    } else {
        print("PS5 aramada görünmedi; kayıtlı adres \(credentials.host) deneniyor.")
    }

    let pipeline = SubtitlePipeline(server: server)
    if let translate = await makeTranslator() {
        await pipeline.setQuickTranslator { text in await translate(text) }
    }
    // Canlı altyazıda yapay zekâ VARSAYILAN OLARAK KAPALI (kullanıcı kararı, 16 Kas 2026): Haiku bile
    // repliklerin yalnız ~%13'ünde 0,8 sn'ye yetişti; beklemek her repliği geciktiriyordu.
    // Denemek için: ALTYAZI_YZ=acik
    if ProcessInfo.processInfo.environment["ALTYAZI_YZ"] == "acik", let key = anthropicKey() {
        let model = ProcessInfo.processInfo.environment["ALTYAZI_MODEL"] ?? ClaudeTranslator.defaultModel
        await pipeline.setRefiner(ClaudeTranslator(apiKey: key, model: model))
        print("Yapay zekâ çevirisi AÇIK (\(model)).")
    } else {
        print("Yapay zekâ çevirisi KAPALI; yalnız cihaz üstü çeviri kullanılıyor.")
    }
    await pipeline.setProblemHandler { message in print("[çeviri] \(message)") }
    if let deadline = Double(ProcessInfo.processInfo.environment["ALTYAZI_BEKLEME"] ?? "") {
        await pipeline.setRefineDeadline(deadline)
    }
    await pipeline.setTimingHandler { timing in
        print(String(format: "[süre] %.2f sn %@", timing.delay, timing.refined ? "yapay zekâ" : "cihaz içi"))
    }

    let printed = PrintedLines()
    await pipeline.setDisplayHandler { lines in
        for line in lines {
            guard let translation = line.translation, printed.shouldPrint(id: line.id, refined: line.refined) else { continue }
            let who = line.speaker.map { "\($0): " } ?? ""
            print("\(line.refined ? "YZ" : "TR") \(who)\(translation)\n   EN \(line.source)")
        }
    }

    let reader = FrameTextReader()
    reader.setRegion(watchRegion())
    let (frames, feed) = AsyncStream.makeStream(of: [RecognizedLine].self, bufferingPolicy: .bufferingNewest(4))
    let crowded = SnapshotWriter(url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AltyaziTR-kalabalik.png"), every: 2)
    let lastFrame = FrameBox()
    reader.onLines = { lines in
        // Üç ve daha çok satırlı sahnelerin karesi ayrıca saklanır (yerleşim teşhisi için).
        if lines.count >= 3, let frame = lastFrame.value { crowded.offer(frame) }
        feed.yield(lines)
    }
    Task { for await lines in frames { await pipeline.ingest(lines) } }

    // Ekranı buradan görebilmek için ara ara son kareyi kaydet.
    let snapshotURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AltyaziTR-son-kare.png")
    let snapshot = SnapshotWriter(url: snapshotURL, every: 3)
    reader.onSample = { lastFrame.value = $0; snapshot.offer($0) }

    let session = RemotePlaySession(credentials: credentials)
    session.onFrame = { reader.submit($0) }
    session.onLog = { level, message in
        // Paket kaybı satırları çok gürültülü; yalnız özetini say.
        if level == 1, !message.contains("frame"), !message.contains("FEC"), !message.contains("Missing unit") { print("[ps5] \(message)") }
    }
    session.onEvent = { event in
        switch event {
        case .connected: print("PS5'e bağlandı (\(credentials.nickname)). Altyazı bekleniyor…")
        case .loginPinRequired: print("Bu PSN kullanıcısında giriş parolası var; PS5'te o kullanıcıdan parolayı kaldırın.")
        case .ended(let isError, let message):
            print("Oturum bitti\(isError ? " (hata)" : ""): \(message)")
            exit(isError ? 1 : 0)
        }
    }
    do { try session.start() } catch { fail(error.localizedDescription) }

    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        print("\nKapatılıyor… (çözülen kare: \(session.decodedFrames), bozuk: \(session.failedFrames))")
        session.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
    interrupt.resume()
    var ticks = 0
    var reportedStalls = 0
    while true {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        ticks += 1
        if reader.stallCount != reportedStalls {
            reportedStalls = reader.stallCount
            print("[uyarı] yazı okuma kilitlendi, bekçi yeni kuyrukta sürdürüyor (toplam \(reportedStalls)).")
        }
        // Kare geldiği hâlde okuma 12 saniyedir hiç bitmiyorsa sistemin okuyucusu tümden kilitlidir:
        // tek çare programı yeniden başlatmak (scripts/izle.sh bunu yapar).
        if session.decodedFrames > 0, reader.secondsSinceLastRead > (reader.lastReadDuration > 0 ? 12 : 60) {
            print("[hata] yazı okuma toparlanamadı; program yeniden başlatılacak.")
            session.stop()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            exit(3)
        }
        if ticks % 10 == 0 {
            print(String(format: "[durum] yazı okuma %.0f ms, çözülen kare %d", reader.lastReadDuration * 1000, session.decodedFrames))
        }
    }
}

/// Aynı satırı (aynı kademede) iki kez yazdırmamak için.
final class PrintedLines: @unchecked Sendable {
    private var seen: [Int: Bool] = [:]
    private let lock = NSLock()
    func shouldPrint(id: Int, refined: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let previous = seen[id], previous || !refined { return false }
        seen[id] = refined
        return true
    }
}

final class FrameBox: @unchecked Sendable {
    var value: CVPixelBuffer?
}

final class SnapshotWriter: @unchecked Sendable {
    private let url: URL
    private let interval: TimeInterval
    private var last = Date.distantPast
    init(url: URL, every interval: TimeInterval) { self.url = url; self.interval = interval }

    func offer(_ buffer: CVPixelBuffer) {
        guard Date().timeIntervalSince(last) >= interval else { return }
        last = Date()
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

switch arguments.first {
case "demo":
    runDemo()

case "ocr":
    guard arguments.count > 1 else { fail("Kullanım: altyazi-mac ocr <resim>") }
    runOCR(arguments[1])

case "cevir":
    // Yapay zekâ çevirisini tek satırda dener ve süresini ölçer: altyazi-mac cevir "<satır>" [model]
    guard arguments.count >= 2, let key = anthropicKey() else { fail("Kullanım: altyazi-mac cevir \"<satır>\" [model]  (anahtar gerekli)") }
    let model = arguments.count >= 3 ? arguments[2] : ClaudeTranslator.defaultModel
    let translator = ClaudeTranslator(apiKey: key, model: model)
    let started = Date()
    do {
        let outcome = try await translator.translate(line: arguments[1], context: [])
        let text: String
        switch outcome {
        case .translation(let translated): text = translated
        case .notForPlayer: text = "(gösterilmez)"
        case .declined: text = "(model geri çevirdi)"
        }
        print(String(format: "%@  [%.2f sn, %@]", text, Date().timeIntervalSince(started), model))
    } catch {
        fail(error.localizedDescription)
    }

case "ekran":
    // Kayıtlı bir oyun karesini "ekranı çevir" ile çevirir: altyazi-mac ekran <resim>
    // ALTYAZI_PORT verilirse sonucu o porttan TV önizlemesine de yollar (30 sn açık kalır).
    guard arguments.count >= 2, let key = anthropicKey(),
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Kullanım: altyazi-mac ekran <resim>  (anahtar gerekli)") }
    do {
        let started = Date()
        let lines = try TextRecognizer().recognizeLines(cgImage: image)
        let read = Date().timeIntervalSince(started)
        let items = try await ScreenTranslator(apiKey: key).translate(lines: lines)
        print(String(format: "okunan satır: %d (%.2f sn) · çevrilen öbek: %d · toplam %.2f sn", lines.count, read, items.count, Date().timeIntervalSince(started)))
        for item in items {
            print(String(format: "  (%.2f, %.2f) %@%@", item.x, item.y, item.lines > 1 ? "[\(item.lines) satır] " : "", item.text))
        }
        if let port = UInt16(ProcessInfo.processInfo.environment["ALTYAZI_PORT"] ?? "") {
            let server = SubtitleServer()
            server.onClientCountChange = { count in
                if count > 0 { server.sendScreen(state: "done", items: items.map { ["x": $0.x, "y": $0.y, "w": $0.width, "h": $0.height, "lh": $0.lineHeight, "n": $0.lines, "t": $0.text] }) }
            }
            server.start(port: port)
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    } catch {
        fail(error.localizedDescription)
    }

case "simge":
    // altyazi-mac simge <resim> [x y genişlik yükseklik]  → bölgedeki satırları ve bulunan tuş simgelerini gösterir
    guard arguments.count >= 2, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Kullanım: altyazi-mac simge <resim> [x y genişlik yükseklik]") }
    let numbers = arguments.dropFirst(2).compactMap(Double.init)
    let region = numbers.count == 4 ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
                                    : CGRect(x: 0, y: 0.1, width: 0.38, height: 0.32)
    let roi = CGRect(x: region.minX, y: 1 - region.maxY, width: region.width, height: region.height)
    do {
        for line in try TextRecognizer().recognizeLinesWithIcons(cgImage: image, roi: roi) {
            print("\(line.text)   [simge: \(line.icons.count)]")
            for (index, icon) in line.icons.enumerated() {
                let file = "/tmp/simge-\(Int(line.y * 1000))-\(index + 1).png"
                if let comma = icon.firstIndex(of: ","), let data = Data(base64Encoded: String(icon[icon.index(after: comma)...])) {
                    try data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIMGE_DIZIN"].map { $0 + "/simge-\(Int(line.y * 1000))-\(index + 1).png" } ?? file))
                }
            }
        }
    } catch {
        fail("Okunamadı: \(error.localizedDescription)")
    }

case "imza":
    // altyazi-mac imza dogrula <açılmış paket dizini>
    //   Tizen Studio'nun imzaladığı gerçek bir paketle kendi imzalayıcımızı karşılaştırır:
    //   imza değeri dışındaki her bayt aynı mı, ve özgün imza bizim ürettiğimiz baytların üstünde geçerli mi?
    if arguments.count >= 3, arguments[1] == "csr" {
        // altyazi-mac imza csr <dizin>  → örnek yazar/dağıtıcı sertifika isteği üretir (openssl ile denetlemek için)
        do {
            let key = try SamsungCSR.generateKey()
            try SamsungCSR.author(name: "Marhilk", key: key).write(toFile: arguments[2] + "/author.csr", atomically: true, encoding: .utf8)
            try SamsungCSR.distributor(email: "ornek@example.com", duids: ["ABCDEFGHIJKLM"], key: key)
                .write(toFile: arguments[2] + "/distributor.csr", atomically: true, encoding: .utf8)
            // Dışa aktarılan anahtar geri kurulabiliyor mu?
            _ = try SamsungCSR.importKey(try SamsungCSR.export(key))
            print("yazıldı")
        } catch { fail("Hata: \(error.localizedDescription)") }
        exit(0)
    }
    guard arguments.count >= 3, arguments[1] == "dogrula" else { fail("Kullanım: altyazi-mac imza dogrula <dizin>") }
    let directory = URL(fileURLWithPath: arguments[2])
    do {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var files: [WGTSigner.File] = try names.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".xml") || $0 == "config.xml" }
            .map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) }
        func parts(_ text: String, _ tag: String) -> [String] {
            text.components(separatedBy: "<\(tag)>").dropFirst().compactMap { $0.components(separatedBy: "</\(tag)>").first }
        }
        let throwaway = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        for role in [WGTSigner.Role.author, .distributor] {
            let name = role == .author ? "author-signature.xml" : "signature1.xml"
            let original = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let certificates = parts(original, "X509Certificate").compactMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            let mine = String(decoding: try WGTSigner.signature(role: role, files: files, identity: SigningIdentity(privateKey: throwaway, certificates: certificates)), as: UTF8.self)
            func blank(_ text: String) -> String {
                guard let value = parts(text, "SignatureValue").first else { return text }
                return text.replacingOccurrences(of: value, with: "X")
            }
            let sameBytes = blank(mine) == blank(original)
            // Özgün imza, bizim ürettiğimiz kurallı baytların üstünde geçerli mi?
            let signature = Data(base64Encoded: parts(original, "SignatureValue")[0], options: .ignoreUnknownCharacters)!
            let info = "<SignedInfo>" + mine.components(separatedBy: "<SignedInfo>")[1].components(separatedBy: "</SignedInfo>")[0] + "</SignedInfo>"
            let canonical = Data(info.replacingOccurrences(of: "<SignedInfo>", with: "<SignedInfo xmlns=\"http://www.w3.org/2000/09/xmldsig#\">").utf8)
            let key = SecCertificateCopyKey(SecCertificateCreateWithData(nil, certificates[0] as CFData)!)!
            let valid = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA512, canonical as CFData, signature as CFData, nil)
            print("\(name): imza dışındaki baytlar aynı: \(sameBytes) · özgün imza bizim baytlarımızda geçerli: \(valid) · \(mine.utf8.count)/\(original.utf8.count) bayt")
            // Dağıtıcı imzası yazar imzasını da kapsar: karşılaştırma için özgün yazar imzası kullanılır.
            if role == .author { files.append((name, Data(original.utf8))) }
        }
    } catch {
        fail("Hata: \(error.localizedDescription)")
    }

case "samsung":
    // altyazi-mac samsung giris <televizyonun DUID'i>
    //   Samsung giriş sayfasını tarayıcıda açar; giriş yapılınca o televizyon için yazar ve dağıtıcı
    //   sertifikası alır, örnek paketi imzalar ve sonucu denetler. Anahtarlar ve sertifikalar
    //   uygulama destek klasörüne (yalnız kullanıcının okuyabileceği biçimde) yazılır.
    guard arguments.count >= 3, arguments[1] == "giris" else { fail("Kullanım: altyazi-mac samsung giris <DUID>") }
    let duid = arguments[2]
    let done = DispatchSemaphore(value: 0)
    final class TokenBox: @unchecked Sendable { var token: SamsungToken? }
    let box = TokenBox()
    let callback = SamsungLoginCallbackServer { token in
        box.token = token
        done.signal()
    }
    do { try callback.start() } catch { fail("4794 portu dinlenemedi: \(error.localizedDescription)") }
    print("Giriş bekleniyor (5 dakika)…")
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    opener.arguments = ["-e", "tell application \"Safari\" to make new document with properties {URL:\"\(SamsungToken.loginURL.absoluteString)\"}",
                        "-e", "tell application \"Safari\" to activate"]
    try? opener.run()
    if done.wait(timeout: .now() + 300) == .timedOut { fail("Giriş 5 dakika içinde tamamlanmadı.") }
    callback.stop()
    guard let token = box.token else { fail("Giriş bilgisi alınamadı.") }
    print("Giriş alındı (hesap e-postası \(token.email.isEmpty ? "gelmedi" : "geldi"), kullanıcı kimliği \(token.userID.count) karakter).")
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let material = try await SamsungCertificateAuthority.issue(token: token, duid: duid)
            print("Sertifikalar alındı: yazar zinciri \(material.authorCertificates.count), dağıtıcı zinciri \(material.distributorCertificates.count), cihaz profili \(material.deviceProfile == nil ? "yok" : "var").")
            let identities = try material.identities()
            let package = try WGTSigner.package(files: SamsungTVSetup.packageFiles, author: identities.author, distributor: identities.distributor)
            let directory = credentialsURL.deletingLastPathComponent()
            let file = directory.appendingPathComponent("samsung-signing.json")
            try JSONEncoder().encode(material).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let wgt = FileManager.default.temporaryDirectory.appendingPathComponent("marhilk-samsung-deneme.wgt")
            try package.write(to: wgt)
            // Denetim için sertifikaları ayrı dosyalara yaz (sertifikalar gizli değildir; anahtarlar yazılmaz).
            for (name, chain) in [("yazar", material.authorCertificates), ("dagitici", material.distributorCertificates)] {
                for (index, certificate) in chain.enumerated() {
                    try certificate.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("marhilk-\(name)-\(index).der"))
                }
            }
            print("İmzalı paket: \(package.count) bayt → \(wgt.path)")
            print("Saklandı: \(file.path)")
        } catch {
            fail("Hata: \(error.localizedDescription)")
        }
        finished.signal()
    }
    finished.wait()

case "tv":
    // altyazi-mac tv bilgi <ip>                 → Samsung TV'nin geliştirici kipi durumunu gösterir
    // altyazi-mac tv kur <ip> <paket.wgt> <uygulama kimliği> → imzalı paketi TV'ye kurar ve açar (Tizen Studio olmadan)
    let rest = Array(arguments.dropFirst())
    guard rest.count >= 2 else { fail("Kullanım: altyazi-mac tv bilgi <ip> | tv kur <ip> <paket.wgt> <uygulama kimliği>") }
    let host = rest[1]
    let finished = DispatchSemaphore(value: 0)
    // Ana iş parçacığı aşağıda beklediği için iş ondan bağımsız yürümeli.
    Task.detached {
        do {
            switch rest[0] {
            case "bilgi":
                let info = try await SamsungTVInfo.fetch(host: host)
                print("\(info.name) · \(info.model)")
                print("Geliştirici kipi: \(info.developerMode ? "açık" : "kapalı") · izinli adres: \(info.developerIP)")
                let client = SDBClient(host: host)
                print("Kapı: \(try await client.connect())")
                print("DUID: \(try await client.shell("0 getduid").trimmingCharacters(in: .whitespacesAndNewlines))")
                let caps = try await client.capabilities()
                print("Tizen \(caps["platform_version"] ?? "?") · araç yolu \(caps["sdk_toolpath"] ?? "?")")
                client.close()
            case "ac":
                // altyazi-mac tv ac <bu bilgisayarın adresi>  → ağdaki Samsung TV'yi bulur, Marhilk'i açar
                let found = await SamsungTVInfo.discover(from: host)
                if found.isEmpty { fail("Ağda Samsung televizyon bulunamadı.") }
                for tv in found {
                    let before = await SamsungTVInfo.appState(host: tv.host)
                    print("\(tv.info.name) · \(tv.host) · Marhilk: \(before)")
                    if before == .stopped { print("  açıldı: \(await SamsungTVInfo.launch(host: tv.host))") }
                }
            case "kur":
                guard rest.count >= 4 else { fail("Kullanım: altyazi-mac tv kur <ip> <paket.wgt> <uygulama kimliği>") }
                let package = try Data(contentsOf: URL(fileURLWithPath: rest[2]))
                let started = Date()
                try await SamsungTVInstaller.install(package: package, appID: rest[3], host: host) { step in
                    switch step {
                    case .connecting: print("Bağlanılıyor…")
                    case .sending(let fraction): if fraction >= 1 { print("Paket gönderildi (\(package.count) bayt)") }
                    case .installing: print("Kuruluyor…")
                    case .launching: print("Açılıyor…")
                    case .done: print("Tamam.")
                    }
                }
                print(String(format: "Süre: %.1f sn", Date().timeIntervalSince(started)))
            default:
                fail("Bilinmeyen tv komutu: \(rest[0])")
            }
        } catch {
            fail("Hata: \(error.localizedDescription)")
        }
        finished.signal()
    }
    finished.wait()

case "ps5":
    switch arguments.dropFirst().first {
    case "ara":
        let hosts = PS5Discovery.search()
        if hosts.isEmpty {
            print("PS5 bulunamadı. PS5 açık mı, aynı ağda mı, Ayarlar › Sistem › Uzaktan Oynama etkin mi?")
        }
        for host in hosts {
            print("\(host.address)  \(host.name)  [\(host.isStandby ? "dinlenme modunda" : "açık")]  sürüm \(host.systemVersion)")
            print("   çalışan oyun: \(host.runningTitleName ?? "yok") [\(host.runningTitleID ?? "-")]")
            if let again = PS5Discovery.query(address: host.address) {
                print("   tek sorgu: \(again.runningTitleName ?? "yok") [\(again.runningTitleID ?? "-")]")
            } else {
                print("   tek sorgu: yanıt yok")
            }
        }

    case "giris":
        print("Tarayıcıda PSN giriş sayfası açılıyor. Giriş bitince sayfada yalnız \"redirect\" yazar;\nadres çubuğundaki adresin tamamını kopyalayın.\n\n\(PSNAccount.loginURL.absoluteString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [PSNAccount.loginURL.absoluteString]
        try? process.run()

    case "hesap":
        // Girişten sonraki yönlendirme adresindeki tek kullanımlık kodu hesap kimliğine çevirip saklar.
        guard arguments.count == 3, let redirect = URL(string: arguments[2]) else {
            fail("Kullanım: altyazi-mac ps5 hesap <yönlendirme-adresi>")
        }
        do {
            let accountID = try await PSNAccount.accountID(fromRedirect: redirect)
            try accountID.write(to: accountURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountURL.path)
            print("PSN hesap kimliği alındı ve saklandı.")
        } catch {
            fail(error.localizedDescription)
        }

    case "eslestir":
        guard arguments.count == 4, let accountID = try? Data(contentsOf: accountURL), accountID.count == 8 else {
            fail("Önce giriş yapın (ps5 giris, ps5 hesap). Kullanım: altyazi-mac ps5 eslestir <ip> <8 haneli kod>")
        }
        do {
            let credentials = try RemotePlayPairing.pair(host: arguments[2], accountID: accountID, pin: arguments[3]) { level, message in
                if level <= 2 { print("[ps5] \(message)") }
            }
            try JSONEncoder().encode(credentials).write(to: credentialsURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)
            print("Eşleşti: \(credentials.nickname) (\(credentials.host)). Şimdi: altyazi-mac ps5 izle")
        } catch {
            fail(error.localizedDescription)
        }

    case "izle":
        await runWatch()

    default:
        fail("Kullanım: altyazi-mac ps5 ara | giris | hesap <adres> | eslestir <ip> <kod> | izle")
    }

default:
    print("Kullanım:\n  altyazi-mac demo\n  altyazi-mac ocr <resim>\n  altyazi-mac ps5 ara | giris | hesap <adres> | eslestir <ip> <kod> | izle")
}
