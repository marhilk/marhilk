import Foundation

/// Ekranda gösterilen tek satır: kaynağı ve (varsa) çevirisi.
public struct DisplayLine: Equatable, Sendable, Identifiable {
    public let id: Int
    public var speaker: String?
    public var source: String
    public var translation: String?
    /// Çeviri yapay zekâdan mı geldi (yoksa cihaz üstü çeviriden mi).
    public var refined: Bool
}

/// Okunan satırlardan TV'ye giden Türkçe altyazıya kadar olan hat.
///
/// Her satır için TEK çeviri gösterilir ve gösterilen yazı bir daha DEĞİŞMEZ (ekranda düzelen
/// yazı kötü görünüyor — kullanıcı kararı, 16 Kas 2026). Yapay zekâ çevirisi `refineDeadline`
/// içinde yetişirse o gösterilir; yetişmezse cihaz üstü çeviri gösterilir ve öyle kalır.
public actor SubtitlePipeline {
    public typealias QuickTranslate = @Sendable (String) async -> String?
    /// Yapay zekâ çevirisi: satır + önceki satırların bağlamı.
    public typealias Refine = @Sendable (String, [(source: String, target: String)]) async throws -> ClaudeTranslator.Outcome

    /// Hattın her satır için ne yaptığını bildirir (gecikme ölçümü için).
    public struct Timing: Sendable {
        public let source: String
        /// Satırın ekranda ilk görülmesinden çevirisinin TV'ye gitmesine kadar geçen süre.
        public let delay: TimeInterval
        public let refined: Bool
    }

    private struct Translation {
        var text: String?      // nil = gösterme (oyuncu için anlamsız satır)
        var refined: Bool
    }

    private struct Pending {
        var started: Date
        var speaker: String?
        var quick: String??    // .none = henüz gelmedi, .some(nil) = çevrilemedi
        var deadlinePassed = false
        var refineFinished = false
    }

    /// Yapay zekâ çevirisi için en çok bu kadar beklenir; sonra cihaz üstü çeviri gösterilir.
    public var refineDeadline: TimeInterval = 0.8

    private var tracker = SubtitleTracker()
    private var visible: [SubtitleLine] = []
    private var translations: [String: Translation] = [:]
    private var pending: [String: Pending] = [:]
    private var history: [(source: String, target: String)] = []
    private var lastSent: [DisplayLine] = []
    /// Konuşma dışı duyurular (ör. ekranın köşesindeki görev yazısının çevirisi): bir süre gösterilip kalkar.
    private var notices: [(line: DisplayLine, expires: Date)] = []
    private var nextNoticeID = 1_000_000

    private let server: SubtitleServer
    private var quick: QuickTranslate?
    private var refine: Refine?
    private var onDisplay: (@Sendable ([DisplayLine]) -> Void)?
    private var onProblem: (@Sendable (String) -> Void)?
    private var onTiming: (@Sendable (Timing) -> Void)?

    public init(server: SubtitleServer) {
        self.server = server
    }

    public func setQuickTranslator(_ quick: QuickTranslate?) { self.quick = quick }
    public func setRefiner(_ refiner: ClaudeTranslator?) {
        refine = refiner.map { translator in { line, context in try await translator.translate(line: line, context: context) } }
    }
    public func setRefine(_ refine: Refine?) { self.refine = refine }
    public func setRefineDeadline(_ seconds: TimeInterval) { refineDeadline = seconds }
    public func setDisplayHandler(_ handler: (@Sendable ([DisplayLine]) -> Void)?) { onDisplay = handler }
    public func setProblemHandler(_ handler: (@Sendable (String) -> Void)?) { onProblem = handler }
    public func setTimingHandler(_ handler: (@Sendable (Timing) -> Void)?) { onTiming = handler }

    public func ingest(_ lines: [RecognizedLine], at now: Date = Date()) {
        guard let changed = tracker.ingest(lines, at: now) else { return }
        visible = changed
        for line in changed { startTranslation(for: line) }
        publish()
    }

    public func reset() {
        tracker.reset()
        visible = []
        notices = []
        publish()
    }

    /// Konuşma dökümüne bir duyuru satırı ekler (ör. "Görev: Mangayı takip et"); `duration` sonra kalkar.
    /// Aynı anda en çok dört duyuru durur; yenisi gelince en eskisi çıkar. Sesten çevrilen replikler de
    /// (etiketsiz, `label` boş) bu yoldan döküme girer.
    public func announce(label: String, source: String, translation: String, duration: TimeInterval, at now: Date = Date()) {
        let line = DisplayLine(id: nextNoticeID, speaker: label.isEmpty ? nil : label, source: source, translation: translation, refined: false)
        nextNoticeID += 1
        notices.append((line, now.addingTimeInterval(duration)))
        if notices.count > 4 { notices.removeFirst(notices.count - 4) }
        publish()
        let id = line.id
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.expireNotice(id)
        }
    }

    private func expireNotice(_ id: Int) {
        let before = notices.count
        notices.removeAll { $0.line.id == id }
        if notices.count != before { publish() }
    }

    // MARK: -

    private func startTranslation(for line: SubtitleLine) {
        let key = line.raw
        guard translations[key] == nil, pending[key] == nil else { return }

        guard quick != nil || refine != nil else {
            // Hiç çevirici yok: en azından özgün metni göster.
            translations[key] = Translation(text: key, refined: false)
            return
        }
        pending[key] = Pending(started: Date(), speaker: line.speaker, quick: quick == nil ? .some(nil) : .none,
                               refineFinished: refine == nil)

        if let quick {
            let text = line.text
            Task {
                let result = await quick(text)
                self.quickArrived(key: key, text: result)
            }
        }
        if let refine {
            let context = history
            let deadline = refineDeadline
            Task {
                do {
                    let outcome = try await refine(key, context)
                    self.refineArrived(key: key, outcome: outcome)
                } catch {
                    self.onProblem?(error.localizedDescription)
                    self.refineArrived(key: key, outcome: .declined)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                self.deadlinePassed(key: key)
            }
        }
    }

    private func quickArrived(key: String, text: String?) {
        guard var state = pending[key] else { return }
        state.quick = .some(text?.isEmpty == false ? text : nil)
        pending[key] = state
        settleIfPossible(key)
    }

    private func deadlinePassed(key: String) {
        guard var state = pending[key] else { return }
        state.deadlinePassed = true
        pending[key] = state
        settleIfPossible(key)
    }

    private func refineArrived(key: String, outcome: ClaudeTranslator.Outcome) {
        switch outcome {
        case .translation(let text):
            history.append((key, text))
            if history.count > 8 { history.removeFirst(history.count - 8) }
            // Yetiştiyse gösterilir. Yetişmediyse ekrandaki yazıya DOKUNULMAZ; çeviri yalnız bağlam
            // olarak (sonraki satırların tutarlılığı için) saklanmış olur.
            if let state = pending[key] { finish(key, state, Translation(text: text, refined: true)) }
        case .notForPlayer:
            if let state = pending[key] { finish(key, state, Translation(text: nil, refined: true)) }
        case .declined:
            guard var state = pending[key] else { return }
            state.refineFinished = true
            pending[key] = state
            settleIfPossible(key)
        }
    }

    /// Yapay zekâ beklenmeyecekse (süre doldu ya da yapay zekâ yok/başarısız) cihaz üstü çeviriyle kapat.
    private func settleIfPossible(_ key: String) {
        guard let state = pending[key], state.deadlinePassed || state.refineFinished else { return }
        guard case .some(let quickResult) = state.quick else { return }   // cihaz üstü çeviri henüz gelmedi
        guard let text = quickResult else {
            // Cihaz üstü çeviri yok. Yapay zekâ hâlâ çalışıyorsa onu bekle; o da bittiyse özgün metni göster.
            if state.refineFinished { finish(key, state, Translation(text: key, refined: false)) }
            return
        }
        // Çeviri özgün metinle aynıysa bu bir cümle değil, oyun dünyasındaki bir tabela ya da addır
        // ("Goh24" gibi): ekrana basmanın anlamı yok.
        if state.speaker == nil, SubtitleTracker.similarity(text, key) >= 0.95 {
            finish(key, state, Translation(text: nil, refined: false))
        } else {
            finish(key, state, Translation(text: state.speaker.map { "\($0): \(text)" } ?? text, refined: false))
        }
    }

    private func finish(_ key: String, _ state: Pending, _ translation: Translation) {
        pending[key] = nil
        translations[key] = translation
        if translations.count > 800 { translations.removeAll() }
        if translation.text != nil {
            onTiming?(Timing(source: key, delay: Date().timeIntervalSince(state.started), refined: translation.refined))
        }
        publish()
    }

    private func publish() {
        // Duyurular üstte, konuşmalar altta: replikler oyuncunun gözünün alıştığı yerde kalır.
        let display: [DisplayLine] = notices.map(\.line) + visible.map { line in
            let translation = translations[line.raw]
            var speaker = line.speaker
            var text = translation?.text
            // Çevirinin kendi "Ad: " öneki varsa konuşanı oradan al (yapay zekâ eksik iki noktayı onarır).
            if let whole = text, let colon = whole.firstIndex(of: ":") {
                let name = String(whole[..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = String(whole[whole.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if SubtitleTracker.looksLikeName(name), !rest.isEmpty {
                    speaker = name
                    text = rest
                }
            }
            return DisplayLine(id: line.id, speaker: speaker, source: line.text, translation: text,
                               refined: translation?.refined ?? false)
        }
        guard display != lastSent else { return }
        lastSent = display
        // Çevirisi henüz gelmemiş ya da "gösterme" denmiş satırlar TV'ye gitmez.
        server.sendLines(display.compactMap { line in
            line.translation.map { (id: line.id, speaker: line.speaker, text: $0) }
        })
        onDisplay?(display)
    }
}
