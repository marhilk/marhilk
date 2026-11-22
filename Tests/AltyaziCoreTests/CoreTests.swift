import CoreGraphics
import CoreText
import XCTest
@testable import AltyaziCore

final class TrackerTests: XCTestCase {
    private func line(_ parts: String..., y: CGFloat = 0.8) -> RecognizedLine { RecognizedLine(parts: parts, y: y) }

    func testCompleteSentenceShowsImmediatelyAndOnlyOnce() {
        var tracker = SubtitleTracker()
        let t = Date()
        let first = tracker.ingest([line("Okay, make it fast, guys.")], at: t)
        XCTAssertEqual(first?.map(\.text), ["Okay, make it fast, guys."], "biten cümle ilk karede gösterilmeli")
        XCTAssertNil(tracker.ingest([line("Okay, make it fast, guys.")], at: t + 0.1))
        XCTAssertNil(tracker.ingest([line("Okay, make it fast, guvs.")], at: t + 0.2), "küçük okuma oynaması yeniden çevirtmemeli")
    }

    func testTypewriterLineWaitsUntilItSettles() {
        var tracker = SubtitleTracker()
        let t = Date()
        XCTAssertNil(tracker.ingest([line("We need")], at: t))
        XCTAssertNil(tracker.ingest([line("We need to cross the")], at: t + 0.1))
        let done = tracker.ingest([line("We need to cross the bridge before sunset.")], at: t + 0.2)
        XCTAssertEqual(done?.map(\.text), ["We need to cross the bridge before sunset."])
    }

    /// Konuşma dökümü: replikler GELİŞ SIRASIYLA dizilir (oyun onları ekranda nereye koyarsa koysun),
    /// her biri bir kez görünür, sınır aşılınca en eskisi çıkar.
    func testLinesFormARollingLogInArrivalOrder() {
        var tracker = SubtitleTracker()
        let t = Date()
        // Oyun yeni repliği ÜSTE ekliyor (y küçülüyor); dökümde yine de en altta olmalı.
        let all = [line("Dunn", "They got Ju Kwon, dude.", y: 0.90), line("Park", "We need to radio the Lieutenant.", y: 0.82),
                   line("Jae", "Radio's still dead.", y: 0.74), line("Cho", "Are we under attack?", y: 0.66),
                   line("Dunn", "The whole world is blowing up.", y: 0.58)]
        var emitted: [[String?]] = []
        var ids: [Int] = []
        var time = 0.0
        while time < 6.0 {
            let count = min(5, Int(time / 0.8) + 1)
            if let result = tracker.ingest(Array(all.prefix(count)), at: t + time) {
                emitted.append(result.map(\.speaker))
                ids = result.map(\.id)
            }
            time += 0.1
        }
        XCTAssertEqual(emitted, [["Dunn"], ["Dunn", "Park"], ["Dunn", "Park", "Jae"], ["Dunn", "Park", "Jae", "Cho"],
                                 ["Park", "Jae", "Cho", "Dunn"]], "beşinci replik gelince en eskisi çıkar")
        XCTAssertEqual(ids, ids.sorted(), "satırlar geliş sırasında kalmalı")
    }

    /// Replikle aynı hizadaki tabela yazısı cümlenin başına yapışınca yeni bir replik sanılmamalı.
    func testSignTextGluedInFrontDoesNotDuplicateTheLine() {
        var tracker = SubtitleTracker()
        let t = Date()
        let first = tracker.ingest([line("Jae", "Pack it up, Chow, we're leaving.")], at: t)
        XCTAssertEqual(first?.count, 1)
        XCTAssertNil(tracker.ingest([line("WELCOME Jae Pack it up, Chow, we're leaving.")], at: t + 0.1))
        XCTAssertNil(tracker.ingest([line("sh24 plus · Jae Pack it up, Chow, we're leaving.")], at: t + 0.2))
        XCTAssertNil(tracker.ingest([line("F8 219 nunn Pack it up, Chow, we're leaving.")], at: t + 0.3), "adı yanlış okunsa da aynı satır")

        // Ad bilindikten sonra, önüne yazı karışmış YENİ bir replik de doğru ayrılır.
        let next = tracker.ingest([line("WELCOME Jae Through here. Follow me.")], at: t + 0.4)
        XCTAssertEqual(next?.last?.speaker, "Jae")
        XCTAssertEqual(next?.last?.text, "Through here. Follow me.")
    }

    /// Uzun cümle iki satıra bölünmüş: tek cümle olarak ele alınmalı (yoksa yarım yarım çevrilir).
    func testWrappedSentenceIsOneLine() {
        var tracker = SubtitleTracker()
        let t = Date()
        let rows = [RecognizedLine(parts: ["Jae", "They want to haze the newbie pretty hard. Grab some stomach medicine and"], y: 0.70, height: 0.05),
                    RecognizedLine(parts: ["maybe some ramen for him, ya?"], y: 0.76, height: 0.05)]
        let result = tracker.ingest(rows, at: t)
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.speaker, "Jae")
        XCTAssertEqual(result?.first?.text, "They want to haze the newbie pretty hard. Grab some stomach medicine and maybe some ramen for him, ya?")

        // Alt satır başka birinin repliğiyse birleşmez.
        var other = SubtitleTracker()
        let two = [RecognizedLine(parts: ["Jae", "Dunn, he's dead"], y: 0.70, height: 0.05),
                   RecognizedLine(parts: ["Dunn", "I'm sorry, buddy."], y: 0.76, height: 0.05)]
        _ = other.ingest(two, at: t)
        XCTAssertEqual(other.ingest(two, at: t + 0.1)?.map(\.speaker), ["Jae", "Dunn"])
    }

    func testQuickLineStaysLongEnoughToRead() {
        var tracker = SubtitleTracker()
        let t = Date()
        // Oyun bu cümleyi hemen kaldırıyor; 22 harf için okuma süresi 1,5 + 22×0,06 ≈ 2,8 sn.
        _ = tracker.ingest([line("Hello there, traveler.")], at: t)
        XCTAssertNil(tracker.ingest([], at: t + 0.2), "tek karelik okuma kaçağında yazı titrememeli")
        XCTAssertNil(tracker.ingest([], at: t + 2.5), "oyundan kalksa da okunacak kadar ekranda kalmalı")
        XCTAssertEqual(tracker.ingest([], at: t + 3.0), [])
    }

    func testSameLineReadWithAndWithoutGluedSpeakerIsOneLine() {
        var tracker = SubtitleTracker()
        let t = Date()
        let first = tracker.ingest([line("Dunn", "Got it.")], at: t)
        XCTAssertEqual(first?.map(\.speaker), ["Dunn"])
        // Aynı replik bu kez adı cümleye yapışık okundu: yeni satır açılmamalı.
        XCTAssertNil(tracker.ingest([line("Dunn Got it.")], at: t + 0.1))
        // Öğrenilen ad, sonraki yapışık okumalarda da ayrılır.
        let next = tracker.ingest([line("Dunn Did you hear that sound?")], at: t + 0.2)
        XCTAssertEqual(next?.last?.speaker, "Dunn")
        XCTAssertEqual(next?.last?.text, "Did you hear that sound?")
    }

    func testChoicesThatAppearTogetherStayTogether() {
        var tracker = SubtitleTracker()
        let t = Date()
        let choices = [line("[Lie] Yes, Sushi.", y: 0.6), line("Fish that smells like piss.", y: 0.7), line("No Response.", y: 0.8)]
        XCTAssertEqual(tracker.ingest(choices, at: t)?.count, 3)
        for step in 1...80 {
            XCTAssertNil(tracker.ingest(choices, at: t + Double(step) * 0.1), "oyuncu seçerken seçenekler kaybolmamalı")
        }
    }

    func testFlickerDoesNotCreateADuplicate() {
        var tracker = SubtitleTracker()
        let t = Date()
        let first = tracker.ingest([line("Who's that? A K-POP star?")], at: t)
        _ = tracker.ingest([], at: t + 0.3)
        // 0,7 sn okunamadı (bulanık kare), sonra yeniden okundu: aynı satır, aynı kimlik.
        XCTAssertNil(tracker.ingest([line("Who's that? A K-POP star?")], at: t + 0.7))
        XCTAssertNotNil(first?.first?.id)
    }

    func testSpeakerSplitting() {
        let none: Set<String> = []
        XCTAssertEqual(SubtitleTracker.split(parts: ["Jae: [Yeah. I'm going to make a career out of it.]"], known: none).speaker, "Jae")
        XCTAssertEqual(SubtitleTracker.split(parts: ["Cho [Why? We're your best customers!]"], known: none).text, "[Why? We're your best customers!]")
        XCTAssertNil(SubtitleTracker.split(parts: ["Okay, make it fast, guys."], known: none).speaker)
        XCTAssertNil(SubtitleTracker.split(parts: ["LAST CHECKPOINT", "Pay the Cashier"], known: none).speaker, "menü başlığı konuşan değildir")
        XCTAssertNil(SubtitleTracker.split(parts: ["Listen up, here is the plan: we go in quiet."], known: none).speaker)

        // Simge yanlış okumaları konuşan olmaz; bilinen ad varsa o kullanılır.
        XCTAssertEqual(SubtitleTracker.split(parts: ["HEaRd Cashier", "[Buy something or leave!]"], known: ["Cashier"]).speaker, "Cashier")
        let junk = SubtitleTracker.split(parts: ["aer", "[We're waiting on our friend.]"], known: none)
        XCTAssertNil(junk.speaker)
        XCTAssertEqual(junk.text, "[We're waiting on our friend.]", "baştaki yanlış okuma atılmalı")
        XCTAssertNil(SubtitleTracker.split(parts: ["OPEN", "His sister's an ex-girlfriend of mine."], known: none).speaker)
        // Seslenme, konuşan değildir.
        XCTAssertNil(SubtitleTracker.split(parts: ["Dunn, he's dead"], known: ["Dunn"]).speaker)
    }

    func testInterfaceTextSignsAndNameTagsAreNotSubtitles() {
        var tracker = SubtitleTracker()
        let t = Date()
        _ = tracker.ingest([line("Jae", "Pack it up, we're leaving.")], at: t)   // "Jae" öğrenildi
        for (index, junk) in [["LAST SAVED 11/16/2026 2:37 × SELECT"], ["ENT DAY АУНЕМ"], ["RK HYUN-JUN BO"], ["12"],
                              ["Oomphf", "SODA"], ["Col. Dunn"], ["Sgt. Jae"], ["Jae"], ["Cpl: Dunn"], ["Sgt, Dunn"]].enumerated() {
            let time = t + 10 + Double(index)
            XCTAssertNil(tracker.ingest([RecognizedLine(parts: junk, y: 0.5)], at: time)?.first { $0.text.contains(junk.last!) }, "\(junk)")
            XCTAssertNil(tracker.ingest([RecognizedLine(parts: junk, y: 0.5)], at: time + 0.1)?.first { $0.text.contains(junk.last!) }, "\(junk)")
        }
        // Bağırılan kısa replik gürültü sayılmamalı.
        XCTAssertEqual(tracker.ingest([line("GET DOWN!")], at: t + 30)?.map(\.text), ["GET DOWN!"])
    }
}

final class RecognizerTests: XCTestCase {
    /// Oyun karesine benzeyen bir görüntü üretir: üstte HUD yazısı, altta altyazı.
    private func makeFrame() -> CGImage {
        let width = 1280, height = 720
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.12, green: 0.16, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func draw(_ text: String, size: CGFloat, y: CGFloat) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: y)
            CTLineDraw(line, context)
        }
        draw("OBJECTIVE: REACH THE TOWER", size: 26, y: 660)   // HUD — okunmamalı
        draw("Where did you find this sword?", size: 40, y: 80) // altyazı
        return context.makeImage()!
    }

    func testFarApartTextOnSameRowStaysSeparate() throws {
        let width = 1280, height = 720
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.12, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func draw(_ text: String, x: CGFloat) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ]
            context.textPosition = CGPoint(x: x, y: 340)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        draw("Restart the mission", x: 90)
        draw("Pay the cashier", x: 820)
        let lines = try TextRecognizer().recognizeLines(cgImage: context.makeImage()!)
        XCTAssertEqual(lines.map(\.text).sorted(), ["Pay the cashier", "Restart the mission"])
    }

    func testReadsSubtitleInsideRegionOnly() throws {
        let frame = makeFrame()
        let lines = try TextRecognizer().recognizeLines(cgImage: frame, roi: CGRect(x: 0, y: 0, width: 1, height: 0.3))
        XCTAssertEqual(lines.map(\.text), ["Where did you find this sword?"])
        let bottom = lines.map(\.text).joined()
        XCTAssertFalse(bottom.contains("OBJECTIVE"))

        let whole = try TextRecognizer().recognize(cgImage: frame)
        XCTAssertTrue(whole.contains("OBJECTIVE"), "bölge sınırı olmadan HUD de okunur: \(whole)")
    }
}

final class ServerTests: XCTestCase {
    private func nextText(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        guard case .string(let string) = try await task.receive() else {
            XCTFail("metin çerçevesi bekleniyordu")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    func testLateJoiningTVGetsHelloStyleAndCurrentSubtitle() async throws {
        let port: UInt16 = 18765
        let server = SubtitleServer()
        server.start(port: port)
        server.sendStyle(position: .top, scale: 1.2)
        server.sendLines([(id: 1, speaker: "Jae", text: "Bu kılıcı nerede buldun?"), (id: 2, speaker: nil, text: "Bilmiyorum.")])
        try await Task.sleep(nanoseconds: 300_000_000)

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil); server.stop() }

        let hello = try await nextText(task)
        XCTAssertEqual(hello["app"] as? String, "altyazitr")
        let style = try await nextText(task)
        XCTAssertEqual(style["position"] as? String, "top")
        XCTAssertEqual(style["scale"] as? Double, 1.2)
        let sub = try await nextText(task)
        let lines = try XCTUnwrap(sub["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.map { $0["i"] as? Int }, [1, 2])
        XCTAssertEqual(lines.map { $0["s"] as? String }, ["Jae", nil])
        XCTAssertEqual(lines.map { $0["t"] as? String }, ["Bu kılıcı nerede buldun?", "Bilmiyorum."])
        // Köşe yazısı durumu boş olsa da gelir: TV önceki bağlantıdan kalan yazıyı ekranda tutmasın.
        let hud = try await nextText(task)
        XCTAssertEqual(hud["type"] as? String, "hud")
        XCTAssertEqual((hud["items"] as? [Any])?.count, 0)

        server.sendLines([])
        let clear = try await nextText(task)
        XCTAssertEqual(clear["type"] as? String, "lines")
        XCTAssertEqual((clear["lines"] as? [Any])?.count, 0)

        // "İngilizcesini de göster": özgün satır ayrı alanda gider; istenmediğinde alan hiç yoktur.
        server.send(lines: [SubtitleServer.Line(id: 3, speaker: nil, text: "Selam", original: "Hello"),
                            SubtitleServer.Line(id: 4, speaker: nil, text: "Görüşürüz")])
        let message = try await nextText(task)
        let both = try XCTUnwrap(message["lines"] as? [[String: Any]])
        XCTAssertEqual(both.map { $0["o"] as? String }, ["Hello", nil])
    }
}

final class ClaudeTranslatorTests: XCTestCase {
    func testRequestShapeAndHeaders() throws {
        let translator = ClaudeTranslator(apiKey: "test-key", model: "claude-opus-5-5")
        var request = URLRequest(url: URL(string: "https://example.invalid")!)
        let body = translator.body(line: "Park: [No, sir.]", context: [("Jae: [What about you?]", "Jae: [Ya sen?]")], request: &request)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertNil(body["thinking"], "bu modelde düşünme kapatılamaz; parametre gönderilmez")
        XCTAssertNil(body["temperature"])
        let prompt = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first?["content"]) as? String)
        XCTAssertTrue(prompt.contains("EN: Jae: [What about you?]\nTR: Jae: [Ya sen?]"))
        XCTAssertTrue(prompt.hasSuffix("Line to translate:\nPark: [No, sir.]"))
    }

    func testDefaultIsHaikuWithThinkingOffAndNoFallback() {
        var request = URLRequest(url: URL(string: "https://example.invalid")!)
        let body = ClaudeTranslator(apiKey: "k").body(line: "Hi.", context: [], request: &request)
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled", "tek satırlık çeviride düşünme yalnız gecikme katar")
        XCTAssertNil(body["fallbacks"], "Haiku'da sunucu taraflı yedek yok")
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testParsesTextSkipsThinkingAndHandlesHyphenAndRefusal() {
        let ok: [String: Any] = ["stop_reason": "end_turn", "content": [
            ["type": "thinking", "thinking": ""], ["type": "text", "text": "Park: [Hayır, komutanım.]\n"]]]
        XCTAssertEqual(ClaudeTranslator.parse(ok), .translation("Park: [Hayır, komutanım.]"))
        XCTAssertEqual(ClaudeTranslator.parse(["stop_reason": "end_turn", "content": [["type": "text", "text": "-"]]]), .notForPlayer)
        // Geri çevrilen satır GİZLENMEZ; cihaz üstü çeviriye dönülür.
        XCTAssertEqual(ClaudeTranslator.parse(["stop_reason": "refusal", "content": [["type": "text", "text": "x"]]]), .declined)
    }
}

final class PipelineTests: XCTestCase {
    func testQuickTranslationReachesTVWithSpeakerOnItsOwnLine() async throws {
        let port: UInt16 = 18766
        let server = SubtitleServer()
        server.start(port: port)
        try await Task.sleep(nanoseconds: 300_000_000)
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil); server.stop() }
        _ = try await task.receive() // hello

        let pipeline = SubtitlePipeline(server: server)
        // "Goh24" bir tabela: çevirisi kendisiyle aynı çıkar ve TV'ye hiç gitmemelidir.
        await pipeline.setQuickTranslator { text in text == "[No, sir.]" ? "[Hayır, komutanım.]" : text }
        await pipeline.ingest([RecognizedLine(parts: ["Goh24."], y: 0.5), RecognizedLine(parts: ["Park:", "[No, sir.]"], y: 0.8)])

        // İlk ileti çeviri gelmeden önceki boş durum olabilir; çevirili olanı bekle.
        for _ in 0..<5 {
            guard case .string(let raw) = try await task.receive() else { continue }
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            if let lines = message["lines"] as? [[String: Any]], !lines.isEmpty {
                XCTAssertEqual(lines.count, 1)
                XCTAssertEqual(lines[0]["s"] as? String, "Park")
                XCTAssertEqual(lines[0]["t"] as? String, "[Hayır, komutanım.]")
                return
            }
        }
        XCTFail("çevrilmiş satır TV'ye ulaşmadı")
    }
}

final class ReaderWatchdogTests: XCTestCase {
    private func makeBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    /// Sistemin yazı okuyucusu bir karede hiç dönmezse okuma tümden durmamalı.
    func testRecoversWhenRecognitionHangsForever() {
        let hang = DispatchSemaphore(value: 0)
        let calls = NSLock()
        var count = 0
        var cancelled = false
        let reader = FrameTextReader(interval: 0.01) { _, _, cancellation in
            calls.lock(); count += 1; let call = count; calls.unlock()
            if call == 1 {
                Thread.sleep(forTimeInterval: 0.6)   // ilk okuma: yavaş (yükleme), kilitlenme DEĞİL
                return [RecognizedLine(parts: ["Hello there."], y: 0.5)]
            }
            if call == 2 {
                hang.wait()                       // sonraki bir okuma: kilitlenir
                return [RecognizedLine(parts: ["eski"], y: 0.5)]
            }
            _ = cancellation
            return [RecognizedLine(parts: ["Hello there."], y: 0.5)]
        }
        reader.stallTimeout = 0.3
        let delivered = expectation(description: "kilitlenmeden sonra okuma sürdü")
        delivered.assertForOverFulfill = false
        var seen: [String] = []
        reader.onLines = { lines in
            calls.lock(); seen += lines.map(\.text); calls.unlock()
            if lines.first?.text == "Hello there." { delivered.fulfill() }
        }

        let buffer = makeBuffer()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, reader.stallCount == 0 || reader.secondsSinceLastRead > 0.2 {
            reader.submit(buffer)
            Thread.sleep(forTimeInterval: 0.02)
        }
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(reader.stallCount, 1, "yavaş ilk okuma kilitlenme sayılmamalı; yalnız gerçekten takılan sayılmalı")

        // Kilitlenen okuma sonunda dönse bile eskimiş sonucu iletilmemeli.
        hang.signal()
        Thread.sleep(forTimeInterval: 0.2)
        calls.lock(); let all = seen; calls.unlock()
        XCTAssertFalse(all.contains("eski"), "terk edilen okumanın sonucu yok sayılmalı")
        _ = cancelled; cancelled = true
    }
}

/// Kullanıcı kararı: ekranda gösterilen çeviri sonradan DEĞİŞMEZ.
final class SingleTranslationTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func add(_ lines: [DisplayLine]) {
            lock.lock()
            for line in lines { if let text = line.translation, texts.last != text { texts.append(text) } }
            lock.unlock()
        }
        var shown: [String] { lock.lock(); defer { lock.unlock() }; return texts }
    }

    private func run(aiDelay: TimeInterval, deadline: TimeInterval) async throws -> [String] {
        let pipeline = SubtitlePipeline(server: SubtitleServer())
        let collector = Collector()
        await pipeline.setDisplayHandler { collector.add($0) }
        await pipeline.setRefineDeadline(deadline)
        await pipeline.setQuickTranslator { _ in "Park et, hızlı düşün!" }
        await pipeline.setRefine { _, _ in
            try await Task.sleep(nanoseconds: UInt64(aiDelay * 1_000_000_000))
            return .translation("Dunn: Park, tut şunu!")
        }
        await pipeline.ingest([RecognizedLine(parts: ["Dunn", "Park, think fast!"], y: 0.8)])
        try await Task.sleep(nanoseconds: UInt64((max(aiDelay, deadline) + 0.4) * 1_000_000_000))
        return collector.shown
    }

    func testAIThatArrivesInTimeIsTheOnlyTranslationShown() async throws {
        let shown = try await run(aiDelay: 0.05, deadline: 0.4)
        XCTAssertEqual(shown, ["Park, tut şunu!"], "cihaz içi çeviri hiç görünmemeli")
    }

    func testLateAIDoesNotReplaceWhatIsOnScreen() async throws {
        let shown = try await run(aiDelay: 0.7, deadline: 0.2)
        XCTAssertEqual(shown, ["Park et, hızlı düşün!"], "yapay zekâ geç kaldıysa ekrandaki yazı değişmemeli")
    }

    func testDeclinedLineFallsBackToDeviceTranslationInsteadOfHiding() async throws {
        let pipeline = SubtitlePipeline(server: SubtitleServer())
        let collector = Collector()
        await pipeline.setDisplayHandler { collector.add($0) }
        await pipeline.setQuickTranslator { _ in "Kahretsin!" }
        await pipeline.setRefine { _, _ in .declined }
        await pipeline.ingest([RecognizedLine(parts: ["Cho", "Damn it!"], y: 0.8)])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(collector.shown, ["Kahretsin!"])
    }
}

final class TVPageServerTests: XCTestCase {
    func testServesEmbeddedPage() {
        XCTAssertEqual(TVPageServer.path(fromRequest: "GET /main.js?x=1 HTTP/1.1\r\nHost: a"), "/main.js?x=1")
        XCTAssertNil(TVPageServer.path(fromRequest: "POST / HTTP/1.1"))

        let page = TVPageServer.response(forPath: "/")
        XCTAssertEqual(page.status, "200 OK")
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("main.js"))
        XCTAssertEqual(TVPageServer.response(forPath: "/main.js?x=1").status, "200 OK")
        XCTAssertEqual(TVPageServer.response(forPath: "/style.css").type, "text/css; charset=utf-8")
        XCTAssertEqual(TVPageServer.response(forPath: "/$WEBAPIS/webapis/webapis.js").status, "404 Not Found")
        // TV'nin "orada mısın?" sorusu
        XCTAssertEqual(String(decoding: TVPageServer.response(forPath: "/marhilk?123").body, as: UTF8.self), "marhilk 1")
    }

    /// tv-tizen/ değişip scripts/sync-tv-page.sh çalıştırılmadıysa bu test düşer.
    func testEmbeddedCopyMatchesSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(SamsungTVSetup.embeddedBuild.count, 12)
        XCTAssertTrue(String(decoding: TVPageServer.response(forPath: "/main.js").body, as: UTF8.self).contains("var TV_BUILD = '\(SamsungTVSetup.embeddedBuild)';"))
        for file in ["index.html", "main.js", "style.css"] {
            let source = try Data(contentsOf: root.appendingPathComponent("tv-tizen/\(file)"))
            // Gömülü kopyada yalnız sürüm yer tutucusu gerçek sürümle değişmiştir.
            let expected = String(decoding: source, as: UTF8.self)
                .replacingOccurrences(of: "var TV_BUILD = 'gelistirme';", with: "var TV_BUILD = '\(SamsungTVSetup.embeddedBuild)';")
            let served = TVPageServer.response(forPath: "/\(file)").body
            XCTAssertEqual(String(decoding: served, as: UTF8.self), expected,
                           "\(file) gömülü kopyası eski: scripts/sync-tv-page.sh çalıştırın")
        }
    }
}

final class SamsungTVTests: XCTestCase {
    func testPacketRoundTrip() {
        let packet = SDBClient.Packet(command: "CNXN", arg0: 0x0100_0000, arg1: 65_536, payload: Data("host::\0".utf8))
        let data = SDBClient.encode(packet)
        XCTAssertEqual(data.count, 24 + 7)
        XCTAssertEqual([UInt8](data.prefix(4)), Array("CNXN".utf8))
        let header = SDBClient.decodeHeader(data.prefix(24))
        XCTAssertEqual(header?.command, "CNXN")
        XCTAssertEqual(header?.arg0, 0x0100_0000)
        XCTAssertEqual(header?.length, 7)
        // Sağlama: yük baytlarının düz toplamı
        let sum = Data("host::\0".utf8).reduce(UInt32(0)) { $0 + UInt32($1) }
        XCTAssertEqual([UInt8](data[16..<20]), withUnsafeBytes(of: sum.littleEndian) { Array($0) })
        // Bozuk "magic" reddedilir
        var broken = Data(data.prefix(24))
        broken[20] ^= 0xFF
        XCTAssertNil(SDBClient.decodeHeader(broken))
    }

    func testSyncAndCapabilities() {
        let message = SDBClient.syncMessage("DATA", Data([1, 2, 3]))
        XCTAssertEqual([UInt8](message), Array("DATA".utf8) + [3, 0, 0, 0, 1, 2, 3])
        XCTAssertNil(SDBClient.syncFailure(Data("OKAY".utf8) + Data([0, 0, 0, 0])))
        XCTAssertEqual(SDBClient.syncFailure(Data("FAIL".utf8) + Data([4, 0, 0, 0]) + Data("dolu".utf8)), "TV dosyayı kabul etmedi: dolu")
        let caps = SDBClient.parseCapabilities(Data([0, 40]) + Data("sdk_toolpath:/home/owner/share/tmp/sdk_tools\nplatform_version:8.0\n".utf8))
        XCTAssertEqual(caps["sdk_toolpath"], "/home/owner/share/tmp/sdk_tools")
        XCTAssertEqual(caps["platform_version"], "8.0")
    }

    func testInstallOutputAndInfo() {
        XCTAssertNil(SamsungTVInstaller.installFailure(in: "app_id[x] install completed\nspend time for wascmd is [3000]ms\ncmd_ret:0"))
        XCTAssertTrue(SamsungTVInstaller.installFailure(in: "install failed[118, -12], reason: Check certificate error")!.contains("imzasını kabul etmedi"))
        XCTAssertTrue(SamsungTVInstaller.installFailure(in: "install failed[118, -11], reason: Author certificate not match")!.contains("eski bir kopyası"))

        let json = Data(#"{"device":{"developerIP":"192.168.1.5","developerMode":"1","modelName":"QE75","name":"Salon"},"name":"Salon"}"#.utf8)
        XCTAssertEqual(SamsungTVInfo.parse(json), SamsungTVInfo(name: "Salon", model: "QE75", developerMode: true, developerIP: "192.168.1.5"))
        XCTAssertNil(SamsungTVInfo.parse(Data("{}".utf8)))

        // Uygulama durumu: açık ve önde / kapalı / kurulu değil
        XCTAssertEqual(SamsungTVInfo.appState(status: 200, body: Data(#"{"id":"x","running":true,"visible":true}"#.utf8)), .running)
        XCTAssertEqual(SamsungTVInfo.appState(status: 200, body: Data(#"{"id":"x","running":true,"visible":false}"#.utf8)), .stopped)
        XCTAssertEqual(SamsungTVInfo.appState(status: 200, body: Data(#"{"id":"x","running":false,"visible":false}"#.utf8)), .stopped)
        XCTAssertEqual(SamsungTVInfo.appState(status: 404, body: Data()), .notInstalled)
        XCTAssertEqual(SamsungTVInfo.appState(status: 0, body: Data()), .unreachable)
    }
}

final class HUDTests: XCTestCase {
    private let region = CGRect(x: 0.02, y: 0.03, width: 0.4, height: 0.3)

    private func line(_ text: String, y: CGFloat, x: CGFloat = 0.1, height: CGFloat = 0.1) -> RecognizedLine {
        RecognizedLine(parts: [text], y: y, height: height, x: x, width: 0.5)
    }

    func testAppearsAfterTwoReadsAndDisappearsAfterTwoMisses() {
        var tracker = HUDTracker()
        tracker.update(lines: [line("Follow Squad", y: 0.2)], region: region)
        XCTAssertTrue(tracker.stable.isEmpty, "tek okumayla görünmemeli")
        tracker.update(lines: [line("Follow Squad", y: 0.2)], region: region)
        XCTAssertEqual(tracker.stable.map(\.source), ["Follow Squad"])
        // İki okumada kaçarsa kalır, üçüncüde kalkar.
        tracker.update(lines: [], region: region)
        tracker.update(lines: [], region: region)
        XCTAssertEqual(tracker.stable.count, 1)
        tracker.update(lines: [], region: region)
        XCTAssertTrue(tracker.stable.isEmpty)
    }

    func testOneFrameMisreadNeverShows() {
        var tracker = HUDTracker()
        tracker.update(lines: [line("Fo11ow 5quad xx", y: 0.2)], region: region)
        tracker.update(lines: [], region: region)
        tracker.update(lines: [line("Fo11ow 5quad xx", y: 0.2)], region: region)
        XCTAssertTrue(tracker.stable.isEmpty, "aralıklı görülen yazı sayılmamalı")
    }

    func testNoisyRereadKeepsFirstTextAndPlace() {
        var tracker = HUDTracker()
        tracker.update(lines: [line("Destroy the radio tower", y: 0.2)], region: region)
        tracker.update(lines: [line("Destroy the radio towcr", y: 0.21, x: 0.11)], region: region)
        XCTAssertEqual(tracker.stable.map(\.source), ["Destroy the radio tower"])
        // Kare koordinatı: bölgenin sol üstü + bölge içi konum × bölge boyutu
        XCTAssertEqual(tracker.stable[0].x, 0.02 + 0.1 * 0.4, accuracy: 0.0001)
        XCTAssertEqual(tracker.stable[0].top, 0.03 + (0.2 - 0.05) * 0.3, accuracy: 0.0001)
    }

    func testWorldTextIsIgnored() {
        // Küçük yazı (tabela): hiç sayılmaz.
        var tracker = HUDTracker()
        for _ in 0..<3 { tracker.update(lines: [line("WE KNOW THE WAY", y: 0.2, height: 0.03)], region: region) }
        XCTAssertTrue(tracker.stable.isEmpty)
        // Okumalar arasında kayan yazı (kamera dönüyor): sayım her seferinde baştan başlar.
        for step in 0..<4 {
            tracker.update(lines: [line("Brian's Boat Works", y: 0.2, x: 0.1 + CGFloat(step) * 0.05)], region: region)
        }
        XCTAssertTrue(tracker.stable.isEmpty)
        // Kaymayı bırakıp yerinde durursa sayılır.
        tracker.update(lines: [line("Brian's Boat Works", y: 0.2, x: 0.25)], region: region)
        XCTAssertEqual(tracker.stable.count, 1)
    }

    /// Kutudaki parçalar ayrı ayrı çevrilse de tek öğe olur ve kutunun en alt satırının altına konur.
    func testPartsOfOneBoxBecomeOneItemBelowTheBox() async {
        final class Box: @unchecked Sendable { var sent: [[ScreenItem]] = [] }
        let box = Box()
        let hud = HUDTranslator { box.sent.append($0) }
        await hud.setTranslator { text in "TR(\(text))" }
        // Kısa satırlar: ayrı madde sayılır ama alt alta bitişiktir.
        let lines = [RecognizedLine(parts: ["Follow Squad"], y: 0.2, height: 0.1, x: 0.1, width: 0.2, icons: ["data:a"]),
                     RecognizedLine(parts: ["Destroy the ⬚ tower"], y: 0.31, height: 0.1, x: 0.1, width: 0.45, icons: ["data:b"])]
        for _ in 0..<3 {
            await hud.ingest(lines, region: region)
            await hud.waitForTranslations()
        }
        let items = box.sent.last ?? []
        XCTAssertEqual(items.count, 1, "aynı kutunun parçaları tek öğe")
        XCTAssertEqual(items.first?.text, "TR(Follow Squad)\nTR(Destroy the [2] tower)", "ikinci parçanın simge numarası kayar")
        XCTAssertEqual(items.first?.icons, ["data:a", "data:b"])
        // En alttaki özgün satırın alt kenarı: bölge üstü + (0.31 + 0.05) × bölge yüksekliği
        XCTAssertEqual(items.first?.y ?? 0, 0.03 + 0.36 * 0.3 + 0.008, accuracy: 0.0001)
        XCTAssertEqual(HUDTranslator.shiftingMarkers(in: "[1] ve [2] [x]", by: 2), "[3] ve [4] [x]")
    }

    /// Kutu belirirken ilk karede simge kaçarsa, sonraki karede bulunan simgeli hâl alınır.
    func testLaterReadWithIconsWins() {
        var tracker = HUDTracker()
        tracker.update(lines: [line("Hold to access the radio", y: 0.2)], region: region)
        tracker.update(lines: [RecognizedLine(parts: ["Hold ⬚ to access the radio"], y: 0.2, height: 0.1, x: 0.1, width: 0.5, icons: ["data:a"])],
                       region: region)
        XCTAssertEqual(tracker.stable.map(\.source), ["Hold ⬚ to access the radio"])
        XCTAssertEqual(tracker.stable.first?.icons, ["data:a"])
        // Sonraki okumada simge yine kaçsa bile eldeki simgeli hâl korunur.
        tracker.update(lines: [line("Hold to access the radio", y: 0.2)], region: region)
        XCTAssertEqual(tracker.stable.first?.icons, ["data:a"])
    }

    /// Önce okunan parça, yazının tamamı gelince atılır.
    func testFragmentIsDroppedWhenWholeTextArrives() {
        var tracker = HUDTracker()
        tracker.update(lines: [line("radio frequencies and will be", y: 0.31)], region: region)
        tracker.update(lines: [line("radio frequencies and will be", y: 0.31)], region: region)
        XCTAssertEqual(tracker.stable.count, 1)
        let whole = [line("You can now listen in on cop", y: 0.2), line("radio frequencies and will be", y: 0.31),
                     line("notified of dispatch areas.", y: 0.42)]
        tracker.update(lines: whole, region: region)
        tracker.update(lines: whole, region: region)
        XCTAssertEqual(tracker.stable.map(\.source), ["You can now listen in on cop radio frequencies and will be notified of dispatch areas."])
    }

    func testCountersIgnoredAndWrappedLinesJoined() {
        XCTAssertFalse(HUDTracker.isWorthTranslating("125 m"))
        XCTAssertFalse(HUDTracker.isWorthTranslating("30 / 120"))
        XCTAssertTrue(HUDTracker.isWorthTranslating("Follow Squad"))
        XCTAssertFalse(HUDTracker.isWorthTranslating("MUTINEER"), "tek kelimelik tabela kırıntısı")
        XCTAssertFalse(HUDTracker.isWorthTranslating("VA"))
        let blocks = HUDTracker.blocks(from: [line("Reach the extraction point", y: 0.2), line("before the timer runs out", y: 0.31),
                                               line("Optional: Find intel", y: 0.6)])
        XCTAssertEqual(blocks.map { $0.count }, [2, 1])
        // Büyük harfle başlayan alt satır: üst satır cümleyi bitirmemiş ve kutuyu doldurmuşsa aynı yazıdır…
        let box = HUDTracker.blocks(from: [line("to rest up and advance time", y: 0.2), line("You can also access your hidden", y: 0.31),
                                            line("stash of cash", y: 0.42)])
        XCTAssertEqual(box.map { $0.count }, [3])
        // …kısa satırlar ise alt alta duran ayrı maddelerdir.
        let list = HUDTracker.blocks(from: [RecognizedLine(parts: ["Follow Squad"], y: 0.2, height: 0.1, x: 0.1, width: 0.2),
                                             RecognizedLine(parts: ["Destroy the radio tower"], y: 0.31, height: 0.1, x: 0.1, width: 0.45)])
        XCTAssertEqual(list.map { $0.count }, [1, 1])
    }

    func testTranslatesOnceAndPlacesBelowOriginal() async {
        final class Box: @unchecked Sendable { var sent: [[ScreenItem]] = []; var calls = 0 }
        let box = Box()
        let hud = HUDTranslator { box.sent.append($0) }
        await hud.setTranslator { text in
            box.calls += 1
            return text == "Follow Squad" ? "Mangayı takip et" : text   // ikinci yazı "çevrilemez" (aynı döner)
        }
        let lines = [line("Follow Squad", y: 0.2), line("MAYHEM CITY", y: 0.6)]
        for _ in 0..<4 {
            await hud.ingest(lines, region: region)
            await hud.waitForTranslations()
        }
        XCTAssertEqual(box.calls, 2, "her yazı bir kez çevrilir")
        XCTAssertEqual(box.sent.count, 1, "değişmeyen durum yeniden yollanmaz")
        XCTAssertEqual(box.sent[0].map(\.text), ["Mangayı takip et"], "çevirisi özgünle aynı olan gösterilmez")
        // Çeviri özgün yazının alt kenarının hemen altında, aynı sol hizada durur.
        let originalBottom = 0.03 + (0.2 + 0.05) * 0.3
        XCTAssertEqual(box.sent[0][0].y, originalBottom + 0.008, accuracy: 0.0001)
        XCTAssertEqual(box.sent[0][0].x, 0.02 + 0.1 * 0.4, accuracy: 0.0001)
        // Yazı kalkınca çeviri de kalkar.
        for _ in 0..<3 { await hud.ingest([], region: region) }
        XCTAssertEqual(box.sent.last, [])
    }
}

final class NoticeTests: XCTestCase {
    func testNoticeShowsAboveDialogueAndExpires() async throws {
        final class Box: @unchecked Sendable { var shown: [[DisplayLine]] = [] }
        let box = Box()
        let pipeline = SubtitlePipeline(server: SubtitleServer())
        await pipeline.setDisplayHandler { box.shown.append($0) }
        await pipeline.announce(label: "Görev", source: "Follow Squad", translation: "Mangayı takip et", duration: 0.2)
        XCTAssertEqual(box.shown.last?.map(\.translation), ["Mangayı takip et"])
        XCTAssertEqual(box.shown.last?.first?.speaker, "Görev")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(box.shown.last, [], "süresi dolan duyuru kalkar")
    }
}

final class IconTests: XCTestCase {
    func testMarksReplaceStandInsOrInsertBetweenWords() {
        // Okuyucu simgeleri "•" ve "O" diye uydurmuş: yerlerine işaret konur.
        XCTAssertEqual(IconFinder.mark(text: "Hold • or O to use the plane", lineStart: 0, lineEnd: 100,
                                       icons: [(21, 8), (40, 8)]),
                       "Hold ⬚ or ⬚ to use the plane")
        // Okuyucu simgeleri hiç yazmamış: en yakın kelime arasına eklenir.
        XCTAssertEqual(IconFinder.mark(text: "Hold or to use the plane", lineStart: 0, lineEnd: 100,
                                       icons: [(21, 8), (40, 8)]),
                       "Hold ⬚ or ⬚ to use the plane")
        // Satır başındaki simge
        XCTAssertEqual(IconFinder.mark(text: "Jump", lineStart: 0, lineEnd: 30, icons: [(5, 10)]), "⬚ Jump")
        XCTAssertEqual(IconFinder.mark(text: "Press to open", lineStart: 0, lineEnd: 100, icons: []), "Press to open")
        // Cümle ortasında tek başına büyük harf uydurmadır; cümle başındaki "A" ve "I" değildir.
        XCTAssertEqual(IconFinder.mark(text: "This is your house A Brian lets", lineStart: 0, lineEnd: 100, icons: [(58, 8)]),
                       "This is your house ⬚ Brian lets")
        XCTAssertTrue(IconFinder.isStandIn("•"))
        XCTAssertFalse(IconFinder.isStandIn("a"))
    }

    func testNumberingAndLostMarkers() {
        let numbered = HUDTranslator.numbered("Hold ⬚ or ⬚ to steer")
        XCTAssertEqual(numbered.text, "Hold [1] or [2] to steer")
        XCTAssertEqual(numbered.count, 2)
        XCTAssertEqual(HUDTranslator.restoringMarkers(in: "Yönlendirmek için [1] veya [2] tuşunu basılı tut", count: 2),
                       "Yönlendirmek için [1] veya [2] tuşunu basılı tut")
        XCTAssertEqual(HUDTranslator.restoringMarkers(in: "Yönlendirmek için [1] tuşunu basılı tut", count: 2),
                       "[2] Yönlendirmek için [1] tuşunu basılı tut", "çevirinin düşürdüğü simge kaybolmaz")
    }

    /// Çizilmiş bir satırda harfler simge sayılmaz, tam yükseklikteki halka simge sayılır.
    func testFindsRingButNotLetters() throws {
        let width = 420, height = 80
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        func draw(_ text: String, at x: CGFloat) {
            let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                           kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true])
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.textPosition = CGPoint(x: x, y: 28)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        draw("Hold", at: 20)
        draw("to jump", at: 150)
        // Halka: satırın tam yüksekliğinde
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(4)
        context.strokeEllipse(in: CGRect(x: 100, y: 22, width: 34, height: 34))
        let image = context.makeImage()!
        // Satır kutusu (sol üst başlangıçlı): yazının kapladığı şerit
        let found = IconFinder.icons(in: image, lineRect: CGRect(x: 18, y: 24, width: 250, height: 34))
        XCTAssertEqual(found.count, 1, "yalnız halka bulunmalı")
        XCTAssertEqual(found.first?.midX ?? 0, 117, accuracy: 6)
        XCTAssertNotNil(IconFinder.dataURL(of: image, rect: found[0]))
    }
}

final class SamsungInstallTests: XCTestCase {
    /// İmza, anahtarın açık yarısıyla doğrulanır; imzalanan veri kurallı biçimdeki özet listesidir.
    func testSignatureVerifiesAndCoversEveryFile() throws {
        let key = try SamsungCSR.generateKey()
        let identity = SigningIdentity(privateKey: key, certificates: [Data([1, 2, 3]), Data([4, 5, 6])])
        let files: [WGTSigner.File] = [("main.js", Data("a".utf8)), ("config.xml", Data("b".utf8))]
        let xml = String(decoding: try WGTSigner.signature(role: .author, files: files, identity: identity), as: UTF8.self)
        XCTAssertTrue(xml.hasPrefix("<Signature xmlns=\"http://www.w3.org/2000/09/xmldsig#\" Id=\"AuthorSignature\">\n<SignedInfo>"))
        // Dosyalar ada göre sıralı, ardından özellikler
        let references = xml.components(separatedBy: "<Reference URI=\"").dropFirst().map { $0.prefix { $0 != "\"" } }
        XCTAssertEqual(references.map(String.init), ["config.xml", "main.js", "#prop"])
        XCTAssertEqual(xml.components(separatedBy: "<X509Certificate>").count - 1, 2)

        let info = WGTSigner.signedInfo(role: .author, files: files)
        XCTAssertTrue(xml.contains(info))
        let value = xml.components(separatedBy: "<SignatureValue>\n")[1].components(separatedBy: "\n</SignatureValue>")[0]
        let signature = try XCTUnwrap(Data(base64Encoded: value, options: .ignoreUnknownCharacters))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA512, WGTSigner.canonical(info) as CFData, signature as CFData, nil))
        // Dosya değişirse aynı imza artık geçmez
        let changed = WGTSigner.signedInfo(role: .author, files: [("main.js", Data("x".utf8)), ("config.xml", Data("b".utf8))])
        XCTAssertFalse(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA512, WGTSigner.canonical(changed) as CFData, signature as CFData, nil))
    }

    func testPackageContainsBothSignaturesAndIsAValidZip() throws {
        let key = try SamsungCSR.generateKey()
        let identity = SigningIdentity(privateKey: key, certificates: [Data([1])])
        let package = try WGTSigner.package(files: SamsungTVSetup.packageFiles, author: identity, distributor: identity)
        XCTAssertEqual(SamsungTVSetup.packageFiles.map(\.name), ["config.xml", "icon.png", "index.html", "main.js", "style.css"])
        XCTAssertGreaterThan(SamsungTVSetup.packageFiles[1].data.count, 1000, "simge gömülü olmalı")
        #if os(macOS)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marhilk-test-\(UUID().uuidString).wgt")
        try package.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", url.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = pipe
        try unzip.run()
        unzip.waitUntilExit()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(unzip.terminationStatus, 0, listing)
        for name in ["author-signature.xml", "signature1.xml", "config.xml", "icon.png", "index.html", "main.js", "style.css"] {
            XCTAssertTrue(listing.contains(name), "\(name) pakette olmalı")
        }
        XCTAssertTrue(listing.contains("No errors detected"))
        #endif
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testLoginCallbackAndCertificateChain() throws {
        let json = #"{"access_token":"tok","userId":"u1","inputEmailID":"a@b.c","access_token_expires_in":"86400"}"#
        let body = "state=x&code=" + json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(SamsungToken.parse(callbackBody: body), SamsungToken(accessToken: "tok", userID: "u1", email: "a@b.c"))
        XCTAssertNil(SamsungToken.parse(callbackBody: "code=bozuk"))
        XCTAssertTrue(SamsungToken.loginURL.absoluteString.contains("redirect_uri=http://localhost:4794/signin/callback"))

        // İstek: başlıklar + gövde; gövde tamamlanmadan sonuç verilmez
        let request = "POST /signin/callback HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        XCTAssertEqual(SamsungLoginCallbackServer.body(of: Data(request.utf8)), body)
        XCTAssertNil(SamsungLoginCallbackServer.body(of: Data(request.utf8).dropLast(5)))

        // Yalnız yaprak sertifika gelirse ara sertifika eklenir
        let pem = "-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n"
        let chain = try SamsungCertificateAuthority.chain(from: pem, intermediate: SamsungCAs.authorCA)
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain[0], Data([1, 2, 3]))
        XCTAssertThrowsError(try SamsungCertificateAuthority.chain(from: "<html>hata</html>", intermediate: SamsungCAs.authorCA))

        let form = String(decoding: SamsungCertificateAuthority.multipart(fields: ["platform": "VD"], fileName: "author.csr", csr: "CSR", boundary: "B"), as: UTF8.self)
        XCTAssertEqual(form, "--B\r\nContent-Disposition: form-data; name=\"platform\"\r\n\r\nVD\r\n--B\r\nContent-Disposition: form-data; name=\"csr\"; filename=\"author.csr\"\r\nContent-Type: application/octet-stream\r\n\r\nCSR\r\n--B--\r\n")
    }

    func testMaterialCoversOnlyItsTVAndExpires() throws {
        let material = SamsungSigningMaterial(authorKey: Data(), authorCertificates: [], distributorKey: Data(), distributorCertificates: [],
                                              duids: ["TV1"], issued: Date(timeIntervalSince1970: 0), deviceProfile: nil)
        XCTAssertTrue(material.covers(duid: "TV1", at: Date(timeIntervalSince1970: 100 * 86_400)))
        XCTAssertFalse(material.covers(duid: "TV2", at: Date(timeIntervalSince1970: 100 * 86_400)))
        XCTAssertFalse(material.covers(duid: "TV1", at: Date(timeIntervalSince1970: 340 * 86_400)), "bitmeye yakın sertifika yenilenmeli")
    }
}

final class GameProfileTests: XCTestCase {
    func testProfilesAreKeptPerGame() throws {
        let suite = "marhilk-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GameProfileStore(defaults: defaults)
        XCTAssertNil(store.profile(for: "PPSA00001"))

        let first = GameProfile(region: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.25),
                                hudRegion: CGRect(x: 0, y: 0.1, width: 0.38, height: 0.32), hudEnabled: true)
        let second = GameProfile(region: CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.4),
                                 hudRegion: CGRect(x: 0.6, y: 0, width: 0.4, height: 0.3), hudEnabled: false)
        store.save(first, for: "PPSA00001")
        store.save(second, for: "PPSA00002")
        XCTAssertEqual(store.profile(for: "PPSA00001"), first)
        XCTAssertEqual(store.profile(for: "PPSA00002"), second)
        XCTAssertEqual(store.profile(for: "PPSA00002")?.regionRect, CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.4))
        XCTAssertEqual(store.profile(for: "PPSA00002")?.hudEnabled, false)
    }
}

final class UtteranceSegmenterTests: XCTestCase {
    func testSentenceIsEmittedOnlyOnceSpeechMovesOn() {
        var segmenter = UtteranceSegmenter()
        let start = Date()
        XCTAssertEqual(segmenter.update("We need", at: start), [])
        XCTAssertEqual(segmenter.update("We need to move.", at: start.addingTimeInterval(0.2)), [], "son kelimedeki nokta henüz kesin değil")
        XCTAssertEqual(segmenter.update("We need to move. Get", at: start.addingTimeInterval(0.4)), ["We need to move."])
        // Aynı cümle yeniden verilmez; tanıyıcı sonraki kelimeleri düzeltse de gösterilen değişmez.
        XCTAssertEqual(segmenter.update("We need to move. Get to the", at: start.addingTimeInterval(0.6)), [])
        XCTAssertEqual(segmenter.update("We need to move. Get to the chopper! Now", at: start.addingTimeInterval(0.8)), ["Get to the chopper!"])
    }

    func testRemainderIsFlushedAfterAPause() {
        var segmenter = UtteranceSegmenter()
        let start = Date()
        _ = segmenter.update("Cover me", at: start)
        XCTAssertNil(segmenter.flushIfSilent(at: start.addingTimeInterval(0.5)), "konuşma sürüyor olabilir")
        XCTAssertEqual(segmenter.flushIfSilent(at: start.addingTimeInterval(1.0)), "Cover me")
        XCTAssertNil(segmenter.flushIfSilent(at: start.addingTimeInterval(2.0)), "bir kez verilir")
        XCTAssertFalse(segmenter.hasPending)
    }

    func testNoiseIsDropped() {
        var segmenter = UtteranceSegmenter()
        let start = Date()
        _ = segmenter.update("Uh", at: start)
        XCTAssertNil(segmenter.flushIfSilent(at: start.addingTimeInterval(2)))
        XCTAssertFalse(segmenter.hasPending, "gürültü atılır, bekletilmez")
    }
}

final class SubtitleRegionFinderTests: XCTestCase {
    private func subtitle(_ text: String, top: Double = 0.84, width: Double = 0.4) -> SubtitleRegionFinder.Observation {
        .init(text: text, x: 0.5 - width / 2, top: top, width: width, height: 0.04)
    }

    func testFindsBandWhereTransientSentencesAppear() {
        var finder = SubtitleRegionFinder()
        let start = Date()
        let hud = SubtitleRegionFinder.Observation(text: "Follow the squad leader", x: 0.03, top: 0.45, width: 0.2, height: 0.03)
        let lines = ["We need to cross the bridge", "The bridge is guarded tonight", "Then we take the old tunnel",
                     "Stay close and keep quiet", "Did you hear that noise"]
        XCTAssertNil(finder.suggestion())
        for (index, text) in lines.enumerated() {
            // Her altyazı iki tarama boyunca görünür; görev yazısı hep ekranda.
            let time = start.addingTimeInterval(Double(index) * 4)
            finder.observe([subtitle(text, width: 0.3 + Double(index) * 0.04), hud], at: time)
            finder.observe([subtitle(text, width: 0.3 + Double(index) * 0.04), hud], at: time.addingTimeInterval(1.5))
        }
        let region = try! XCTUnwrap(finder.suggestion())
        // Altyazı satırı (0.84–0.88) bölgenin içinde, payla birlikte
        XCTAssertLessThan(region.minY, 0.82)
        XCTAssertGreaterThan(region.maxY, 0.9)
        XCTAssertGreaterThan(region.minY, 0.6, "uzun süre duran görev yazısı (0.45) bölgeyi yukarı çekmemeli")
        // Ortalanmış altyazı: bölge ortaya göre simetrik ve en uzun satırdan geniş
        XCTAssertEqual(region.midX, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(region.width, 0.46 + 0.1)
    }

    func testStaticTextAloneGivesNoSuggestion() {
        var finder = SubtitleRegionFinder()
        let start = Date()
        let labels = ["Main objective follow squad", "Press options to open map", "Health and armor status", "Current weapon assault rifle"]
        for step in 0..<12 {
            finder.observe(labels.enumerated().map { .init(text: $0.element, x: 0.05, top: 0.5 + Double($0.offset) * 0.06, width: 0.3, height: 0.03) },
                           at: start.addingTimeInterval(Double(step) * 1.5))
        }
        XCTAssertNil(finder.suggestion(), "yerinde duran yazılar altyazı değildir")
    }

    func testTypewriterTextCountsOnceAndSmallChangesAreIgnored() {
        var finder = SubtitleRegionFinder()
        let start = Date()
        for (index, text) in ["We need", "We need to cross", "We need to cross the bridge"].enumerated() {
            finder.observe([subtitle(text)], at: start.addingTimeInterval(Double(index)))
        }
        XCTAssertNil(finder.suggestion(), "harf harf yazılan tek cümle tek gözlemdir")
        XCTAssertFalse(SubtitleRegionFinder.looksLikeSentence("125 m"))
        XCTAssertFalse(SubtitleRegionFinder.looksLikeSentence("MAYHEM"))
        let current = CGRect(x: 0.2, y: 0.75, width: 0.6, height: 0.2)
        XCTAssertFalse(SubtitleRegionFinder.differs(CGRect(x: 0.21, y: 0.76, width: 0.6, height: 0.2), from: current))
        XCTAssertTrue(SubtitleRegionFinder.differs(CGRect(x: 0.2, y: 0.6, width: 0.6, height: 0.2), from: current))
    }
}

final class AppearanceTests: XCTestCase {
    /// Telefon ile televizyon aynı konuşana aynı rengi vermeli: iki taraftaki özet hesabı aynı olmalı.
    func testSpeakerColorMatchesTVPage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("tv-tizen/main.js"), encoding: .utf8)
        // Renk listesi iki tarafta aynı
        let palette = SubtitleAppearance.speakerPalette.map { "'\($0)'" }.joined(separator: ", ")
        XCTAssertTrue(script.contains("var SPEAKER_PALETTE = [\(palette)];"), "TV'deki renk listesi telefonla aynı olmalı")
        XCTAssertTrue(script.contains("hash = (hash * 31 + lower.charCodeAt(i)) % 100003;"), "TV'deki özet hesabı telefonla aynı olmalı")
        // Aynı ad hep aynı sırayı alır; büyük-küçük harf fark etmez
        XCTAssertEqual(SubtitleAppearance.paletteIndex(for: "Reyes"), SubtitleAppearance.paletteIndex(for: "REYES"))
        XCTAssertTrue((0..<6).contains(SubtitleAppearance.paletteIndex(for: "Çavuş Öztürk")))
        // Bilinen bir değer: "ab" → (97·31 + 98) mod 100003 = 3105 → 3105 mod 6 = 3
        XCTAssertEqual(SubtitleAppearance.paletteIndex(for: "ab"), 3)
    }
}


final class TermProtectorTests: XCTestCase {
    func testNamesSurviveTranslationAndCommonWordsAreLeftAlone() throws {
        let protector = TermProtector(terms: ["Ghost", "Captain Price", "Price"])
        let protected = protector.protect("Ghost, tell Captain Price the ghost is gone. Price is waiting.")
        XCTAssertFalse(protected.text.contains("Ghost"))
        XCTAssertFalse(protected.text.contains("Price"))
        XCTAssertTrue(protected.text.contains("the ghost is gone"), "küçük harfli kelime ad değildir, çevrilir")
        XCTAssertEqual(protected.replacements.map(\.term), ["Captain Price", "Ghost", "Price"], "uzun ad önce eşleşir")

        // Çevirmen uydurma adları olduğu gibi bırakır (ek alsalar da).
        let fake = protected.text.replacingOccurrences(of: ", tell", with: ", söyle")
        XCTAssertEqual(protector.restore(fake, from: protected),
                       "Ghost, söyle Captain Price the ghost is gone. Price is waiting.")
        XCTAssertNil(protector.restore("Hayalet gitti.", from: protected), "uydurma ad kaybolduysa koruma geçersizdir")
    }

    func testPartOfAnotherWordIsNotAName() {
        let protector = TermProtector(terms: ["Price"])
        XCTAssertTrue(protector.protect("Priceless artifacts").isEmpty)
        XCTAssertTrue(TermProtector(terms: [" ", "a"]).isEmpty, "boş ve tek harfli girişler yok sayılır")
        XCTAssertFalse(protector.protect("Where is PRICE?").isEmpty, "tümü büyük yazılmış ad da korunur")
    }

    func testMenuEntriesComeFromTheGlossaryInTheSameCase() {
        XCTAssertEqual(MenuGlossary.lookup("Resume"), "Devam Et")
        XCTAssertEqual(MenuGlossary.lookup("RESUME"), "DEVAM ET")
        XCTAssertEqual(MenuGlossary.lookup("INVENTORY"), "ENVANTER", "Türkçe büyük harf: i → İ değil, ı → I")
        XCTAssertEqual(MenuGlossary.lookup("Skills:"), "Yetenekler")
        XCTAssertNil(MenuGlossary.lookup("Resume the mission when ready"), "cümle içindeki kelimeye dokunulmaz")
        XCTAssertEqual(MenuGlossary.sentenceCased("ACCEPT THE CONTRACT"), "Accept the contract")
    }
}

final class LocalScreenTranslatorTests: XCTestCase {
    private func line(_ text: String, y: CGFloat, x: CGFloat = 0.1, width: CGFloat = 0.2, height: CGFloat = 0.04) -> RecognizedLine {
        RecognizedLine(parts: [text], y: y, height: height, x: x, width: width)
    }

    func testMenuEntriesStaySeparateAndParagraphsJoin() {
        let menu = LocalScreenTranslator.blocks(from: [line("RESUME", y: 0.30), line("OPTIONS", y: 0.36), line("QUIT TO MAIN MENU", y: 0.42)])
        XCTAssertEqual(menu.count, 3, "alt alta menü girişleri ayrı ayrı çevrilir")

        let paragraph = LocalScreenTranslator.blocks(from: [
            line("The old lighthouse keeper left this note", y: 0.30, width: 0.5),
            line("for his daughter and his old friend", y: 0.345, width: 0.45),
            line("Maria before he vanished into the storm.", y: 0.39, width: 0.5),   // büyük harfle başlar ama cümle sürüyor
            line("Nobody has seen him since.", y: 0.435, width: 0.4),                // yeni cümle: ayrı çevrilir
        ])
        XCTAssertEqual(paragraph.map(\.count), [3, 1])

        // Yan yana iki sütun: araya öbür sütunun satırı girse de her sütun kendi öbeğinde kalır.
        let columns = LocalScreenTranslator.blocks(from: [
            line("Increases the damage you deal", y: 0.30, x: 0.1, width: 0.3), line("Damage", y: 0.31, x: 0.6),
            line("with heavy weapons.", y: 0.345, x: 0.1, width: 0.25),
        ])
        XCTAssertEqual(columns.map { $0.map(\.text).joined(separator: " ") }.sorted(),
                       ["Damage", "Increases the damage you deal with heavy weapons."])
    }

    func testGlossaryIsUsedAndCapsAreKept() async {
        let asked = Box<[String]>([])
        let translator = LocalScreenTranslator { texts in
            asked.value = texts
            return texts.map { $0 == "Northgate" ? "Northgate" : "tr(\($0))" }
        }
        let items = await translator.translate(lines: [
            line("RESUME", y: 0.30), line("ACCEPT THE CONTRACT", y: 0.40, width: 0.3),
            line("Northgate", y: 0.50), line("12 / 40", y: 0.60),
        ])
        XCTAssertEqual(asked.value, ["Accept the contract", "Northgate"], "sözlükteki giriş çevirmene gitmez; büyük harfli yazı cümle düzeninde gider")
        XCTAssertEqual(items.map(\.text), ["DEVAM ET", "TR(ACCEPT THE CONTRACT)"], "ad ve sayaç çevrilmez")
        XCTAssertEqual(items[0].y, 0.28, accuracy: 0.001, "çeviri özgün yazının yerine oturur")
    }
}

final class ChoiceTests: XCTestCase {
    private let region = CGRect(x: 0, y: 0, width: 1, height: 1)
    private func option(_ text: String, y: CGFloat, x: CGFloat = 0.3) -> RecognizedLine {
        RecognizedLine(parts: [text], y: y, height: 0.04, x: x, width: 0.3)
    }

    func testListOfOptionsIsNumberedBelowTheList() async {
        let sent = Box<[[ScreenItem]]>([])
        let choices = HUDTranslator(kind: .choices) { sent.value.append($0) }
        await choices.setTranslator { "tr(\($0))" }
        let lines = [option("I'll take the money", y: 0.40), option("Who are you working for?", y: 0.45), option("Leave", y: 0.50)]
        for _ in 0..<3 {
            await choices.ingest(lines, region: region)
            await choices.waitForTranslations()
        }
        await choices.ingest(lines, region: region)
        let item = try? XCTUnwrap(sent.value.last?.first)
        XCTAssertEqual(sent.value.last?.count, 1, "üç seçenek tek kutuda")
        XCTAssertEqual(item?.text, "1. tr(I'll take the money)\n2. tr(Who are you working for?)\n3. tr(Leave)")
        XCTAssertGreaterThan(item?.y ?? 0, 0.52, "çeviri listenin altında")
    }

    func testLoneTextAndLongMenusAreNotChoices() async {
        let sent = Box<[[ScreenItem]]>([])
        let choices = HUDTranslator(kind: .choices) { sent.value.append($0) }
        await choices.setTranslator { "tr(\($0))" }
        let menu = (0..<8).map { option("Menu entry \($0)", y: 0.2 + CGFloat($0) * 0.05) }
        for lines in [[option("Press to open the door", y: 0.5)], menu] {
            for _ in 0..<4 {
                await choices.ingest(lines, region: region)
                await choices.waitForTranslations()
            }
        }
        XCTAssertTrue(sent.value.allSatisfy(\.isEmpty), "tek yazı ya da uzun menü seçenek listesi değildir")
    }

    func testListAtTheBottomGoesAboveAndOtherReadersAreasAreSkipped() async {
        let sent = Box<[[ScreenItem]]>([])
        let choices = HUDTranslator(kind: .choices) { sent.value.append($0) }
        await choices.setTranslator { "tr(\($0))" }
        let low = [option("Yes", y: 0.90), option("No", y: 0.95)]
        for _ in 0..<4 {
            await choices.ingest(low, region: region)
            await choices.waitForTranslations()
        }
        XCTAssertLessThan(sent.value.last?.first?.y ?? 1, 0.86, "ekranın dibindeki listenin çevirisi üstüne konur")

        let other = HUDTranslator(kind: .choices) { sent.value.append($0) }
        await other.setTranslator { "tr(\($0))" }
        sent.value = []
        for _ in 0..<4 {
            await other.ingest(low, region: region, excluding: [CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.2)])
            await other.waitForTranslations()
        }
        XCTAssertTrue(sent.value.allSatisfy(\.isEmpty), "altyazı çerçevesinin içindeki yazıyı altyazı okuyucusu çevirir")
    }
}

final class ReadingLoadTests: XCTestCase {
    func testLoadFollowsHeat() {
        XCTAssertEqual(ReadingLoad.level(thermal: .nominal, lowPower: false), .full)
        XCTAssertEqual(ReadingLoad.level(thermal: .fair, lowPower: false), .eased)
        XCTAssertEqual(ReadingLoad.level(thermal: .serious, lowPower: false), .light)
        XCTAssertEqual(ReadingLoad.level(thermal: .critical, lowPower: false), .minimal)
    }

    func testLowPowerEasesButNeverStopsSideReading() {
        XCTAssertEqual(ReadingLoad.level(thermal: .nominal, lowPower: true), .eased)
        XCTAssertEqual(ReadingLoad.level(thermal: .fair, lowPower: true), .light)
        // Düşük Güç Modu tek başına yan okumaları durdurmaz: durdurmak yalnız ısıyla olur.
        XCTAssertEqual(ReadingLoad.level(thermal: .serious, lowPower: true), .light)
        XCTAssertNotNil(ReadingLoad.level(thermal: .serious, lowPower: true).sideSlowdown)
    }

    func testSpeechReadingIsTouchedOnlyAtTheLastStep() {
        for load in ReadingLoad.allCases where load != .minimal {
            XCTAssertEqual(load.speechSlowdown, 1, "\(load) konuşma okumasını yavaşlatmamalı")
            XCTAssertNotNil(load.sideSlowdown)
        }
        XCTAssertNil(ReadingLoad.minimal.sideSlowdown)
        XCTAssertGreaterThan(ReadingLoad.minimal.speechSlowdown, 1)
    }

    private func makeBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    /// Okuyucuya 0,6 saniye boyunca sürekli kare verir; kaç okuma yapıldığını döner.
    private func reads(slowdown: Double?) -> Int {
        let count = Box(0)
        let reader = FrameTextReader(interval: 0.05) { _, _, _ in
            count.value += 1
            return []
        }
        reader.setSlowdown(slowdown)
        let buffer = makeBuffer()
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            reader.submit(buffer)
            Thread.sleep(forTimeInterval: 0.005)
        }
        Thread.sleep(forTimeInterval: 0.05)
        return count.value
    }

    func testSlowdownThinsReadsAndPauseStopsThem() {
        let normal = reads(slowdown: 1)
        let slowed = reads(slowdown: 3)
        XCTAssertGreaterThanOrEqual(normal, 8)
        XCTAssertLessThanOrEqual(slowed, normal / 2)
        XCTAssertGreaterThanOrEqual(slowed, 2)
        XCTAssertEqual(reads(slowdown: nil), 0)
    }

    func testPausedReaderStillKeepsTheLatestFrame() {
        let reader = FrameTextReader(interval: 0.01) { _, _, _ in [] }
        reader.setSlowdown(nil)
        XCTAssertNil(reader.latestFrame)
        reader.submit(makeBuffer())
        XCTAssertNotNil(reader.latestFrame, "\"ekranı çevir\" duran okuyucudan da kare alabilmeli")
    }

    func testReaderResumesAfterPause() {
        let count = Box(0)
        let reader = FrameTextReader(interval: 0.01) { _, _, _ in
            count.value += 1
            return []
        }
        let buffer = makeBuffer()
        reader.setSlowdown(nil)
        reader.submit(buffer)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(count.value, 0)
        reader.setSlowdown(1)
        reader.submit(buffer)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(count.value, 1)
    }
}

final class SubtitlePresetTests: XCTestCase {
    func testPresetsAreDistinctAndWithinWhatTheTVAccepts() {
        XCTAssertEqual(Set(SubtitlePreset.all.map(\.name)).count, SubtitlePreset.all.count)
        for preset in SubtitlePreset.all {
            XCTAssertTrue((0.6...1.8).contains(preset.scale), preset.name)       // ayarlardaki kaydırıcının aralığı
            XCTAssertTrue((0...0.9).contains(preset.background), preset.name)
        }
    }

    func testApplyingKeepsSpeakerColorsAndIsRecognisedAfterwards() {
        let mine = SubtitleAppearance(color: .green, background: 0.3, bold: false, speakerColors: true)
        for preset in SubtitlePreset.all {
            let applied = preset.applied(to: mine)
            XCTAssertTrue(applied.speakerColors)
            XCTAssertTrue(preset.matches(applied, scale: preset.scale))
            // Aynı anda yalnız bir hazır görünüm seçili görünür.
            XCTAssertEqual(SubtitlePreset.all.filter { $0.matches(applied, scale: preset.scale) }.count, 1, preset.name)
        }
        XCTAssertFalse(SubtitlePreset.all.contains { $0.matches(mine, scale: 1) })
    }
}

final class GameHelperTests: XCTestCase {
    func testRequestCarriesTheImageFirstThenTheContext() throws {
        let helper = GameHelper(apiKey: "anahtar")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let context = GameHelper.Context(game: "Grand Theft Auto V", question: "Polisten nasıl kurtulurum?",
                                         objective: "Lose the cops.", recentLines: ["Franklin: We gotta move!"],
                                         depth: .clearer, earlierHints: ["Görüş alanından çık."])
        let body = helper.body(jpeg: jpeg, context: context)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        // Bu modelde düşünme kapatılamaz ve elle ayarlanamaz: istekte `thinking` alanı olmamalı.
        XCTAssertNil(body["thinking"])
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        let message = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, jpeg.base64EncodedString())
        let text = try XCTUnwrap(content[1]["text"] as? String)
        for piece in ["Grand Theft Auto V", "Hint level: 2 of 3", "Lose the cops.", "Franklin: We gotta move!",
                      "Polisten nasıl kurtulurum?", "1. Görüş alanından çık."] {
            XCTAssertTrue(text.contains(piece), "istekte eksik: \(piece)")
        }
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testPromptSaysSoWhenGameAndQuestionAreMissing() {
        let text = GameHelper.prompt(for: GameHelper.Context())
        XCTAssertTrue(text.contains("Game: not specified"))
        XCTAssertTrue(text.contains("Hint level: 1 of 3"))
        XCTAssertTrue(text.contains("(none; they only pressed"))
        XCTAssertFalse(text.contains("Hints already given"))
        XCTAssertFalse(text.contains("Recent subtitle lines"))
    }

    func testAnswerIsReadPastThinkingBlocksWithItsCost() throws {
        let answer = try GameHelper.parse([
            "stop_reason": "end_turn",
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "  Ara sokağa gir.  "]],
            "usage": ["input_tokens": 2_000, "output_tokens": 500],
        ])
        XCTAssertEqual(answer.text, "Ara sokağa gir.")
        XCTAssertEqual(answer.cost, 0.018, accuracy: 0.0001)   // 2000 × 4 $ + 500 × 20 $, milyonda
    }

    func testRefusalAndEmptyAnswerAreErrorsNotBlankHints() {
        XCTAssertThrowsError(try GameHelper.parse(["stop_reason": "refusal", "content": [["type": "text", "text": "x"]]]))
        XCTAssertThrowsError(try GameHelper.parse(["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""]]]))
    }

    func testDepthStopsAtTheFullSolution() {
        XCTAssertEqual(GameHelper.Depth.nudge.next, .clearer)
        XCTAssertEqual(GameHelper.Depth.full.next, .full)
    }
}

final class DubbingTests: XCTestCase {
    func testSameCharacterKeepsItsVoiceAndOthersGetDifferentOnes() {
        var cast = VoiceCast()
        let kratos = cast.voice(for: "Kratos", gender: .male)
        let atreus = cast.voice(for: "Atreus", gender: .male)
        let freya = cast.voice(for: "Freya", gender: .female)
        XCTAssertNotEqual(kratos, atreus)
        XCTAssertEqual(cast.voice(for: "kratos", gender: .male), kratos)   // büyük-küçük harf fark etmez
        XCTAssertTrue(VoiceCast.men.contains(kratos))
        XCTAssertTrue(VoiceCast.women.contains(freya))
        // Saklanan dağıtım yeni oturumda aynı sesi verir.
        var later = VoiceCast(assigned: cast.assigned)
        XCTAssertEqual(later.voice(for: "Atreus", gender: .male), atreus)
    }

    func testUnknownSpeakerOrGenderIsReadByTheNarrator() {
        var cast = VoiceCast()
        XCTAssertEqual(cast.voice(for: nil, gender: .unknown), VoiceCast.narrator)
        XCTAssertEqual(cast.voice(for: "  ", gender: .male), VoiceCast.narrator)
        XCTAssertEqual(cast.voice(for: "Stranger", gender: .unknown), VoiceCast.narrator)
        XCTAssertTrue(cast.assigned.isEmpty)
    }

    func testCrowdSharesVoicesEvenlyAndGenderChangeRecasts() {
        var cast = VoiceCast()
        for index in 0..<(VoiceCast.men.count * 2) { _ = cast.voice(for: "Asker \(index)", gender: .male) }
        let usage = Dictionary(grouping: cast.assigned.values, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(Set(usage.values), [2])
        // Kullanıcı cinsiyeti düzeltince ses öteki gruptan yeniden seçilir.
        XCTAssertTrue(VoiceCast.women.contains(cast.voice(for: "Asker 0", gender: .female)))
    }

    func testVoicePoolsHaveNoDuplicates() {
        let all = [VoiceCast.narrator] + VoiceCast.men + VoiceCast.women
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(VoiceCast.voice(id: VoiceCast.women[0].id), VoiceCast.women[0])
    }

    func testGenderComesFromTheUserThenFromTheGamePack() {
        let pack = GamePacks.find("God of War")
        XCTAssertEqual(VoiceCast.gender(of: "Freya", pack: pack, overrides: [:]), .female)
        XCTAssertEqual(VoiceCast.gender(of: "KRATOS", pack: pack, overrides: [:]), .male)
        XCTAssertEqual(VoiceCast.gender(of: "Stranger", pack: pack, overrides: [:]), .unknown)
        XCTAssertEqual(VoiceCast.gender(of: "Stranger", pack: pack, overrides: ["stranger": .male]), .male)
        XCTAssertEqual(VoiceCast.gender(of: "Kratos", pack: nil, overrides: [:]), .unknown)
        XCTAssertEqual(VoiceCast.gender(of: nil, pack: pack, overrides: [:]), .unknown)
        // Etiket unvanla gelirse ad kelimelerden biridir.
        XCTAssertEqual(VoiceCast.gender(of: "Captain Price", pack: GamePacks.find("Call of Duty: Modern Warfare"), overrides: [:]), .male)
    }

    func testEveryWomanListedBelongsToHerPack() {
        for pack in GamePacks.all {
            for name in pack.women { XCTAssertTrue(pack.terms.contains(name), "\(pack.name): \(name) pakette yok") }
        }
        XCTAssertEqual(Set(GamePacks.women.keys).subtracting(GamePacks.all.map(\.name)), [], "paketi olmayan oyun adı")
    }

    func testOnlySpeakableTextIsSent() {
        XCTAssertEqual(DubText.clean("[Yalan] Evet, oradaydım."), "Evet, oradaydım.")
        XCTAssertEqual(DubText.clean("Siper almak için [1] tuşuna   bas"), "Siper almak için tuşuna bas")
        XCTAssertEqual(DubText.clean("- Hadi!"), "Hadi!")
        XCTAssertNil(DubText.clean("..."))
        XCTAssertNil(DubText.clean("[1]"))
        XCTAssertEqual(DubText.clean(String(repeating: "a", count: 500))?.count, 320)
    }

    func testQueueKeepsOnlyTheNewestLines() {
        var queue = LatestQueue<Int>(limit: 2)
        XCTAssertEqual(queue.push(1), [])
        XCTAssertEqual(queue.push(2), [])
        XCTAssertEqual(queue.push(3), [1])
        XCTAssertEqual(queue.pop(), 2)
        XCTAssertEqual(queue.pop(), 3)
        XCTAssertNil(queue.pop())
    }

    func testSpeechRequestAsksForTurkishOnTheFastModel() throws {
        let request = try ElevenLabsSpeech(apiKey: "anahtar").request(text: "Merhaba.", voice: "ses1")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/ses1/stream?output_format=mp3_44100_64")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "anahtar")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "Merhaba.")
        XCTAssertEqual(body["model_id"] as? String, "eleven_flash_v2_5")
        XCTAssertEqual(body["language_code"] as? String, "tr")
    }

    func testQuotaAndBadKeyAreToldApart() {
        let quota = Data(#"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota."}}"#.utf8)
        XCTAssertEqual(ElevenLabsSpeech.failure(status: 401, body: quota), .quota)
        let key = Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8)
        XCTAssertEqual(ElevenLabsSpeech.failure(status: 401, body: key), .unauthorized)
        guard case .other = ElevenLabsSpeech.failure(status: 500, body: Data()) else { return XCTFail("beklenmeyen tür") }
    }

    func testClipStoreServesRecentClipsOnly() {
        let store = ClipStore(limit: 2)
        let first = store.add(Data([1]), type: "audio/mpeg")
        let second = store.add(Data([2]), type: "audio/wav")
        XCTAssertEqual(store.clip(forPath: second + "?x=1")?.type, "audio/wav")
        XCTAssertEqual(store.clip(forPath: first)?.body, Data([1]))
        _ = store.add(Data([3]), type: "audio/mpeg")
        XCTAssertNil(store.clip(forPath: first), "eski parça atılmış olmalı")
        XCTAssertNil(store.clip(forPath: "/ses/abc"))
        XCTAssertNil(store.clip(forPath: "/main.js"))
    }
}

final class GamePackTests: XCTestCase {
    func testPacksAreWellFormed() {
        XCTAssertEqual(Set(GamePacks.all.map { $0.name.lowercased() }).count, GamePacks.all.count, "oyun adları tekil")
        XCTAssertEqual(GamePacks.all.map(\.name), GamePacks.all.map(\.name).sorted(), "liste alfabetik")
        for pack in GamePacks.all {
            XCTAssertGreaterThanOrEqual(pack.terms.count, 8, pack.name)
            XCTAssertEqual(Set(pack.terms.map { $0.lowercased() }).count, pack.terms.count, "\(pack.name): yinelenen ad")
            for term in pack.terms {
                XCTAssertGreaterThanOrEqual(term.count, 2, "\(pack.name): \(term)")
                XCTAssertTrue(term.first?.isUppercase ?? false, "\(pack.name): \(term) büyük harfle başlamalı (yoksa hiç korunmaz)")
            }
        }
        XCTAssertEqual(GamePacks.find(" call of duty: modern warfare ")?.terms.contains("Ghost"), true)
        XCTAssertNil(GamePacks.find("Bilinmeyen Oyun"))
    }

    /// Paketteki adlar gerçekten korunur: çevirmene uydurma adla gider, geri konur.
    func testPackNamesAreProtected() throws {
        let pack = try XCTUnwrap(GamePacks.find("The Witcher 3"))
        let protector = TermProtector(terms: pack.terms)
        let protected = protector.protect("Geralt, take Roach and ride to Kaer Morhen.")
        XCTAssertEqual(protected.replacements.count, 3)
        XCTAssertEqual(protector.restore(protected.text, from: protected), "Geralt, take Roach and ride to Kaer Morhen.")
    }
}

/// Testlerde kapanışlar arasında paylaşılan değer kutusu.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
