import AltyaziCore
import StoreKit
import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("guideDone") private var guideDone = false

    private var showsGuide: Bool {
        #if DEBUG
        // Ekran görüntüsü almak için: `-debugMain YES` ana ekranı eşleşme olmadan açar.
        if UserDefaults.standard.bool(forKey: "debugMain") { return false }
        #endif
        if model.demo { return false }
        return model.credentials == nil || !guideDone
    }

    var body: some View {
        Group {
            if showsGuide {
                SetupView()
            } else {
                WatchView()
            }
        }
        .tint(.yellow)
        .modifier(TranslationSetup())
        .onAppear {
            model.activate()
            model.setLocked(!store.unlocked)
        }
        .onChange(of: store.unlocked) { _, unlocked in model.setLocked(!unlocked) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.activate()
                Task { await store.refreshEntitlement() }
            case .background: model.enteredBackground()
            default: break
            }
        }
    }
}

/// Cihaz üstü çeviri oturumunu açar. Simülatörde çeviri desteklenmez ve sistem her açılışta bir uyarı
/// penceresi gösterir; orada hiç denenmez (örnek kipi hazır çevirileriyle çalışır).
private struct TranslationSetup: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        #if targetEnvironment(simulator)
        content
        #else
        content.translationTask(model.translationConfiguration) { session in
            await model.runTranslation(with: session)
        }
        #endif
    }
}

// MARK: - Çalışma ekranı

/// Ana ekran: üstte tek bakışta durum, ortada oyun görüntüsü ve canlı çeviri. Ayarlar ayrı sayfadadır.
private struct WatchView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("tvBrand") private var tvBrand = ""
    @State private var showSettings: Bool = {
        #if DEBUG
        // Ekran görüntüsü almak için: `-debugSettings YES` ayarlar sayfasını açık başlatır.
        return UserDefaults.standard.bool(forKey: "debugSettings")
        #else
        return false
        #endif
    }()

    @State private var showPaywall: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugPaywall")
        #else
        return false
        #endif
    }()

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        if model.demo { DemoBanner() }
                        StatusHero()
                        if !model.tourHidden, model.tourDone.count < AppModel.TourItem.allCases.count {
                            TourCard(openSettings: { showSettings = true })
                        }
                        PreviewCard()
                        TranscriptCard()
                        QuickActions()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("Marhilk")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Ayarlar")
                    }
                }
                // Her dokunuş kendiliğinden kararma sayacını sıfırlar. Kaydırmaya ve düğmelere
                // karışmaması için SwiftUI hareketi değil, pencere düzeyinde bir izleyici kullanılır.
                .background(TouchObserver { model.noteInteraction() })
                .sheet(isPresented: $showSettings) { SettingsSheet() }
                .sheet(isPresented: $showPaywall) { PaywallView() }
                .onChange(of: showSettings) { _, shown in if shown { model.completeTour(.appearance) } }
                .onAppear { if model.locked { showPaywall = true } }
                #if DEBUG
                // Ekran görüntüsü almak için: `-debugPhone YES` telefon ekranı kipini, `-debugScreen YES`
                // birkaç saniye sonra "ekranı çevir"i açar.
                .task {
                    if UserDefaults.standard.bool(forKey: "debugPhone") { model.phoneDisplay = true }
                    if UserDefaults.standard.bool(forKey: "debugScreen") {
                        try? await Task.sleep(nanoseconds: 14_000_000_000)
                        model.toggleScreenTranslation()
                    }
                }
                #endif
                .onChange(of: model.locked) { _, locked in if locked { showPaywall = true } }
                .environment(\.openPaywall, { showPaywall = true })
            }

            if model.phoneDisplay { PhoneDisplayView() }
            if model.dimmed { DarkScreen() }
        }
        .statusBarHidden(model.dimmed || model.phoneDisplay)
        .persistentSystemOverlays(model.dimmed || model.phoneDisplay ? .hidden : .automatic)
        // Televizyonuna Marhilk kurulamayanlarda çevirinin görüneceği tek yer telefonun ekranıdır:
        // PS5 bağlanınca kendiliğinden açılır.
        .onChange(of: model.connection) { _, connection in
            if connection == .connected, TVSupport.phoneOnly(tvBrand), model.tvCount == 0, !model.demo {
                model.phoneDisplay = true
            }
        }
    }
}

/// Karanlık ekran: uygulama çalışmayı sürdürür, ekran siyahtır (OLED ekranda siyah piksel yanmaz).
/// Bir kez dokununca normal ekrana döner.
private struct DarkScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var hintVisible = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Çeviri sürüyor · ekranı açmak için dokun")
                .font(.footnote)
                .foregroundStyle(Color(white: 0.35))
                .opacity(hintVisible ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.setDimmed(false) }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeOut(duration: 1)) { hintVisible = false }
        }
        .accessibilityLabel("Karanlık ekran. Açmak için dokun.")
        .accessibilityAddTraits(.isButton)
    }
}

/// Örnek kipinde olduğunu ve nasıl çıkılacağını söyler.
private struct DemoBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "play.rectangle.fill").foregroundStyle(.black)
            VStack(alignment: .leading, spacing: 2) {
                Text("Örnek kipi").font(.subheadline.weight(.semibold)).foregroundStyle(.black)
                Text("PS5 yerine hazır bir sahne çevriliyor.").font(.caption).foregroundStyle(.black.opacity(0.75))
            }
            Spacer(minLength: 8)
            Button("Çık") { model.stopDemo() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.14), in: Capsule())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Durum

/// Tek bakışta durum: her şey çalışıyor mu, çalışmıyorsa sıradaki adım ne?
private struct StatusHero: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @Environment(\.openPaywall) private var openPaywall
    @AppStorage("tvBrand") private var tvBrand = ""

    private enum Overall { case running, waitingForTV, connecting(String), failed(String), idle, locked }

    /// Bu markada televizyona Marhilk kurulamıyor; çeviri telefonun ekranında gösterilir.
    private var phoneOnly: Bool { TVSupport.phoneOnly(tvBrand) }

    private var overall: Overall {
        if model.locked { return .locked }
        // Örnek kipinde televizyon şart değil: çeviri telefonda da izlenir.
        if model.demo { return .running }
        switch model.connection {
        case .connected: return model.tvCount > 0 || phoneOnly ? .running : .waitingForTV
        case .working(let step): return .connecting(step)
        case .failed(let message): return .failed(message)
        case .idle: return .idle
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headline
            HStack(spacing: 10) {
                DeviceChip(symbol: "gamecontroller.fill", name: model.credentials?.nickname ?? "PS5",
                           state: psState, color: psColor)
                if phoneOnly, model.tvCount == 0 {
                    DeviceChip(symbol: "iphone.landscape", name: "Telefon", state: "Ekran hazır", color: .green)
                } else {
                    DeviceChip(symbol: "tv", name: "Televizyon",
                               state: model.tvCount > 0 ? (model.tvMuted ? "Altyazı gizli" : "Bağlı") : "Bekleniyor",
                               color: model.tvCount > 0 && !model.tvMuted ? .green : .orange)
                }
            }
            actions
            if let note = model.thermalNote {
                Label(note, systemImage: model.readingLoad == .minimal ? "thermometer.high" : "thermometer.medium")
                    .font(.footnote)
                    .foregroundStyle(model.readingLoad == .minimal ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Örnek kipinde çeviri dili eksik olsa da sahnenin hazır çevirisi gösterilir; uyarıya gerek yok.
            if let problem = model.serverStatus ?? (model.demo ? nil : model.translationStatus) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if model.serverStatus == nil {
                    // Çeviri dili eksik: indirme penceresini yeniden açtır.
                    Button("Çeviri dilini indir") { model.retryTranslationSetup() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .card()
    }

    private var headline: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(tone.opacity(0.18)).frame(width: 52, height: 52)
                if case .connecting = overall {
                    ProgressView()
                } else {
                    Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(tone)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        if model.locked {
            Button(store.trialAvailable ? "30 gün ücretsiz dene" : "Aboneliği başlat") { openPaywall() }
                .buttonStyle(ProminentAction())
        }
        if case .failed = overall {
            Button("Yeniden bağlan") { model.connect() }
                .buttonStyle(ProminentAction())
        }
        if model.tvOutdated {
            VStack(alignment: .leading, spacing: 8) {
                Label("Televizyondaki Marhilk eski bir sürüm.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
                Button {
                    model.updateTVApp()
                } label: {
                    if let work = model.samsungWork {
                        HStack(spacing: 8) { ProgressView().tint(.black); Text(work).lineLimit(1).minimumScaleFactor(0.7) }
                    } else {
                        Text("Televizyonu güncelle")
                    }
                }
                .buttonStyle(ProminentAction())
                .disabled(model.samsungWork != nil)
                if let error = model.samsungError {
                    Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if phoneOnly, model.tvCount == 0, !model.demo, case .connected = model.connection {
            Button {
                model.phoneDisplay = true
            } label: {
                Label("Çeviriyi telefonda göster", systemImage: "iphone.landscape")
            }
            .buttonStyle(ProminentAction())
        } else if model.tvCount == 0, !model.demo, case .connected = model.connection {
            if tvBrand == "lg" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LG'nin Web Tarayıcı'sına şu adresi yaz:").font(.footnote).foregroundStyle(.secondary)
                    Text(model.browserAddress).font(.title3.monospacedDigit().weight(.semibold)).textSelection(.enabled)
                }
            } else {
                Button {
                    model.openOnTV()
                } label: {
                    if model.tvLaunching {
                        HStack(spacing: 8) { ProgressView().tint(.black); Text("Televizyon aranıyor…") }
                    } else {
                        Label("Televizyonda Marhilk'i aç", systemImage: "play.tv.fill")
                    }
                }
                .buttonStyle(ProminentAction())
                .disabled(model.tvLaunching)
                if let status = model.tvLaunchStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var title: String {
        switch overall {
        case .running: return "Çeviri çalışıyor"
        case .waitingForTV: return "Televizyon bekleniyor"
        case .connecting: return "PS5'e bağlanılıyor"
        case .failed: return "PS5'e bağlanılamadı"
        case .idle: return "Bağlı değil"
        case .locked: return "Abonelik gerekli"
        }
    }

    private var detail: String {
        switch overall {
        case .running: return model.demo
            ? "Örnek sahnedeki konuşmalar çevriliyor; aşağıda canlı çeviride görebilirsin. Televizyonun bağlıysa orada da görünür."
            : (phoneOnly && model.tvCount == 0
                ? "Telefonu televizyonun altına yatay koy; konuşmalar telefonun ekranında Türkçe akar."
                : "Oyununu oyna; konuşmalar televizyonda Türkçe akar. Telefonu kilitleyebilirsin.")
        case .waitingForTV: return "Çeviri hazır. Görmek için televizyonda Marhilk açık olmalı."
        case .connecting(let step): return step
        case .failed(let message): return message
        case .idle: return "PS5 açık ve aynı Wi-Fi ağında olmalı."
        case .locked: return store.trialAvailable
            ? "Çeviri için aboneliği başlat; ilk 30 gün ücretsiz."
            : "Çeviri için abonelik gerekiyor. Kurulumun ve ayarların duruyor."
        }
    }

    private var symbol: String {
        switch overall {
        case .running: return "captions.bubble.fill"
        case .waitingForTV: return "tv"
        case .failed: return "wifi.exclamationmark"
        case .locked: return "lock.fill"
        default: return "gamecontroller"
        }
    }

    private var tone: Color {
        switch overall {
        case .running: return .green
        case .failed: return .red
        default: return .orange
        }
    }

    private var psColor: Color {
        switch model.connection {
        case .connected: return .green
        case .failed: return .red
        default: return .orange
        }
    }

    private var psState: String {
        switch model.connection {
        case .connected: return "Bağlı"
        case .working: return "Bağlanıyor"
        case .failed: return "Bağlanamadı"
        case .idle: return "Bağlı değil"
        }
    }
}

/// Bir cihazın küçük durum kutusu: simge, ad ve renkli noktayla durum.
private struct DeviceChip: View {
    let symbol: String
    let name: String
    let state: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(state).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(state)")
    }
}

// MARK: - Oyun görüntüsü

private struct PreviewCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var addingGame = false
    @State private var pickingPack = false
    @State private var newGameName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Oyun görüntüsü").font(.headline)
                Spacer(minLength: 8)
                Menu {
                    Button { model.selectGame("") } label: {
                        if model.selectedGame.isEmpty { Label("Genel", systemImage: "checkmark") } else { Text("Genel") }
                    }
                    ForEach(model.games, id: \.self) { game in
                        Button { model.selectGame(game) } label: {
                            if model.selectedGame == game { Label(game, systemImage: "checkmark") } else { Text(game) }
                        }
                    }
                    Divider()
                    Button { pickingPack = true } label: { Label("Hazır oyunlardan seç…", systemImage: "list.star") }
                    Button { newGameName = ""; addingGame = true } label: { Label("Başka bir oyun ekle…", systemImage: "plus") }
                    if !model.selectedGame.isEmpty {
                        Button(role: .destructive) { model.removeGame(model.selectedGame) } label: {
                            Label("“\(model.selectedGame)” ayarını sil", systemImage: "trash")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.selectedGame.isEmpty ? "Genel" : model.selectedGame).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline)
                }
                .accessibilityLabel("Oyun ayarı")
            }
            ZStack {
                Color(white: 0.06)
                if let image = model.preview {
                    Image(decorative: image, scale: 1).resizable()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle").font(.title).foregroundStyle(.tertiary)
                        Text("PS5 görüntüsü bekleniyor").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                // Sarı çerçeveyi elle oynatmak otomatik bulmayı kapatır.
                RegionSelector(region: Binding(get: { model.region }, set: { model.setRegionManually($0) }))
                if model.hudEnabled {
                    RegionSelector(region: $model.hudRegion, color: .cyan)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .sheet(isPresented: $pickingPack) { GamePackPicker() }

            HStack(spacing: 14) {
                Legend(color: .yellow, text: "Konuşmalar")
                if model.hudEnabled { Legend(color: .cyan, text: "Görev ve ipuçları") }
                Spacer(minLength: 0)
            }
            Text("Çerçevelerin içindeki yazılar çevrilir. Elle ayarlamak istersen gövdesinden sürükle, köşesinden boyutlandır. Oyunlara göre ayrı ayar için sağ üstten oyun ekle.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(isOn: $model.autoRegion) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Altyazının yerini kendisi bulsun")
                    Text(model.autoRegion
                         ? (model.autoRegionFound ? "Bulundu; sarı çerçeve ona göre ayarlandı." : "Aranıyor… Oyunda birkaç replik geçince bulunur.")
                         : "Kapalı: sarı çerçeveyi sen yerleştiriyorsun.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Toggle("Görev ve ipucu yazılarını da çevir", isOn: $model.hudEnabled)
                .font(.subheadline)
        }
        .card()
        .alert("Oyun ekle", isPresented: $addingGame) {
            TextField("Oyunun adı", text: $newGameName)
            Button("Ekle") { model.addGame(newGameName) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Şimdiki çerçeve yerleri bu oyun için kaydedilir; sonra değiştirdiklerin de bu oyuna yazılır.")
        }
    }
}

private struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 2).frame(width: 14, height: 10)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Canlı çeviri

private struct TranscriptCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Canlı çeviri").font(.headline)
                Spacer(minLength: 8)
                Button {
                    showHistory = true
                } label: {
                    Label("Geçmiş", systemImage: "clock.arrow.circlepath").font(.subheadline)
                }
            }
            if model.lines.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "text.bubble").foregroundStyle(.tertiary)
                    Text("Altyazı bekleniyor").foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            ForEach(model.lines) { line in
                VStack(alignment: .leading, spacing: 3) {
                    (Text(line.speaker.map { "\($0)  " } ?? "").foregroundColor(speakerColor(line.speaker)).fontWeight(.semibold)
                     + Text(line.translation ?? "…"))
                        .font(.body)
                    Text(line.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
        .sheet(isPresented: $showHistory) { HistorySheet() }
        .onChange(of: showHistory) { _, shown in if shown { model.completeTour(.history) } }
    }
}

private extension TranscriptCard {
    func speakerColor(_ name: String?) -> Color {
        let palette = SubtitleAppearance.speakerPalette
        guard let name, model.appearance.speakerColors else { return Color(hex: palette[0]) }
        return Color(hex: palette[SubtitleAppearance.paletteIndex(for: name)])
    }
}

/// Bu oturumda çevrilen replikler; kaçırılan bir repliği geri okumak için.
private struct HistorySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView("Henüz replik yok", systemImage: "text.bubble",
                                           description: Text("Çevrilen replikler burada birikir; kaçırdığını geri kaydırıp okuyabilirsin."))
                } else {
                    ScrollViewReader { proxy in
                        List(model.history) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    if let speaker = line.speaker {
                                        Text(speaker).font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                                    }
                                    Spacer(minLength: 8)
                                    Text(line.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Text(line.translation)
                                Text(line.source).font(.caption).foregroundStyle(.secondary)
                            }
                            .id(line.id)
                        }
                        .onAppear { if let last = model.history.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                        .onChange(of: model.history.count) { _, _ in
                            if let last = model.history.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                }
            }
            .navigationTitle("Konuşma geçmişi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Temizle") { model.clearHistory() }.disabled(model.history.isEmpty)
                }
            }
        }
        .tint(.yellow)
    }
}

// MARK: - Hızlı işlemler

private struct QuickActions: View {
    @EnvironmentObject private var model: AppModel
    @State private var showHelper = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if DEBUG
            // DENEME: yalnız geliştirme sürümünde. Yayına çıkmadan önce gizlilik metni güncellenmeli
            // (bu özellik ekranın görüntüsünü yapay zekâya gönderir).
            ActionTile(symbol: "lightbulb.fill", title: "Takıldım",
                       detail: model.aiEnabled ? "Yardımcı ekrana bakıp ipucu versin (deneme)."
                                               : "Yapay zekâ anahtarı gerekli (Ayarlar).",
                       highlighted: model.helper.working || !model.helper.hints.isEmpty, compact: true) {
                showHelper = true
            }
            .sheet(isPresented: $showHelper) { HelperSheet() }
            #endif
            HStack(spacing: 12) {
                ActionTile(symbol: "text.viewfinder",
                           title: model.screenState == nil ? "Ekranı çevir" : "Çeviriyi kaldır",
                           detail: screenDetail, highlighted: model.screenState != nil) {
                    model.toggleScreenTranslation()
                }
                ActionTile(symbol: "moon.fill", title: "Ekranı karart", detail: "Çeviri sürer", highlighted: false) {
                    model.setDimmed(true)
                }
            }
            ActionTile(symbol: "iphone.landscape", title: "Telefonda göster",
                       detail: "Çeviri bu ekranda, büyük yazıyla. Televizyona bir şey kurmadan da çalışır.",
                       highlighted: false, compact: true) {
                model.phoneDisplay = true
            }
            if model.tvCount > 0 {
                ActionTile(symbol: model.tvMuted ? "eye.fill" : "eye.slash.fill",
                           title: model.tvMuted ? "Televizyonda altyazıyı göster" : "Televizyonda altyazıyı gizle",
                           detail: model.tvMuted ? "Altyazı şu an gizli; çeviri arkada sürüyor."
                                                 : "Bir sahneyi yazısız izlemek için. Kumandada YEŞİL tuş da aynı işi yapar.",
                           highlighted: model.tvMuted, compact: true) {
                    model.setTVMuted(!model.tvMuted)
                }
            }
            Text("Ekranı çevir: oyunu duraklat, sonra bas (ya da TV kumandasında MAVİ tuş). Menü, görev ve belgeler yerinde Türkçe görünür.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var screenDetail: String {
        switch model.screenState {
        case nil: return "Menüler, belgeler"
        case "working": return "Çevriliyor…"
        case "done": return model.tvCount > 0 ? "Televizyonda" : "Çevrildi"
        case .some(let message): return message
        }
    }
}

private struct ActionTile: View {
    let symbol: String
    let title: String
    let detail: String
    let highlighted: Bool
    /// Tam genişlikte, alçak düzen: simge solda, yazı sağda.
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let layout = compact ? AnyLayout(HStackLayout(alignment: .center, spacing: 14))
                                 : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            layout {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.black : Color.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(highlighted ? Color.black : Color.primary)
                    Text(detail).font(.caption).foregroundStyle(highlighted ? Color.black.opacity(0.7) : Color.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 84, alignment: .leading)
            .padding(14)
            .background(highlighted ? Color.yellow : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableTile())
    }
}

// MARK: - Ayarlar

private struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @State private var managingSubscription = false
    @State private var showPaywall = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("guideDone") private var guideDone = false
    @AppStorage("tvBrand") private var tvBrand = ""
    @State private var aiKey = ""
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Televizyondaki yazı") {
                    Picker("Yeri", selection: $model.position) {
                        Text("Üstte").tag(SubtitlePosition.top)
                        Text("Altta").tag(SubtitlePosition.bottom)
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $model.fontScale, in: 0.6...1.8, step: 0.1)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Yazı boyutu")
                }

                Section {
                    SubtitleSample(appearance: model.appearance, scale: model.fontScale)
                        .listRowInsets(EdgeInsets())
                    PresetRow()
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                    Picker("Yazı rengi", selection: $model.appearance.color) {
                        Text("Beyaz").tag(SubtitleAppearance.TextColor.white)
                        Text("Sarı").tag(SubtitleAppearance.TextColor.yellow)
                        Text("Açık mavi").tag(SubtitleAppearance.TextColor.cyan)
                        Text("Yeşil").tag(SubtitleAppearance.TextColor.green)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Zemin koyuluğu")
                        HStack(spacing: 12) {
                            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                            Slider(value: $model.appearance.background, in: 0...0.9, step: 0.1)
                            Image(systemName: "circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Kalın yazı", isOn: $model.appearance.bold)
                    Toggle("Konuşanları renklendir", isOn: $model.appearance.speakerColors)
                } header: {
                    Text("Görünüm")
                } footer: {
                    Text("Hazır görünümlerden biri tek dokunuşla uygulanır; sonra aşağıdan ince ayar yapabilirsin. Değişiklikler televizyonda anında görünür. Konuşanları renklendirince her kişi kendi rengini alır; kalabalık sahnelerde kimin konuştuğu daha kolay izlenir.")
                }

                Section {
                    Picker("Yazının ekranda kalma süresi", selection: $model.readingPace) {
                        Text("Kısa").tag(0.75)
                        Text("Olağan").tag(1.0)
                        Text("Uzun").tag(1.6)
                    }
                    Toggle("Konuşma seçeneklerini çevir", isOn: $model.choicesEnabled)
                    Toggle("İngilizcesini de göster", isOn: $model.showOriginal)
                    NavigationLink {
                        KeptTermsView()
                    } label: {
                        HStack {
                            Text("Çevrilmeyecek adlar")
                            Spacer()
                            Text(model.keptTerms.isEmpty ? "Yok" : "\(model.keptTerms.count)").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Çeviri")
                } footer: {
                    Text("Kalma süresi: oyun bir repliği çabuk kaldırdığında çevirisi okunsun diye ekranda bekletilir; yavaş okuyorsan \"Uzun\" seç. Konuşma seçenekleri: oyun sana bir seçim sunduğunda seçeneklerin Türkçesi listenin altında numaralı görünür. Çevrilmeyecek adlar: karakter ve yer adları çeviride olduğu gibi kalır (\"Ghost\", \"Hayalet\" olmaz). İngilizcesini de göster: özgün satır, Türkçesinin üstünde küçük harfle durur; oynarken İngilizce öğrenmek isteyenler için.")
                }

                Section {
                    Toggle("Çeviriyi sesli oku", isOn: $model.dubEnabled)
                    if model.dubEnabled {
                        Picker("Ses", selection: $model.dubEngine) {
                            Text("Cihaz sesi").tag(Dubber.Engine.system.rawValue)
                            if model.dubHasKey { Text("ElevenLabs").tag(Dubber.Engine.eleven.rawValue) }
                        }
                        Picker("Nereden gelsin", selection: $model.dubOutput) {
                            Text("Televizyon").tag(Dubber.Output.tv.rawValue)
                            Text("Telefon").tag(Dubber.Output.phone.rawValue)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $model.dubVolume, in: 0.2...1)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Dublaj sesi düzeyi")
                        NavigationLink("Karakter sesleri") { DubCastView() }
                        Button("Örnek bir replik oku") {
                            model.dub("Bu bir deneme. Çeviri bu sesle okunacak.", speaker: nil)
                        }
                    }
                    #if DEBUG
                    DubKeyField()
                    #endif
                } header: {
                    Text("Dublaj (deneme)")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Çevrilen her replik Türkçe seslendirilir. Oyunun kendi sesi kapanmaz, Türkçe ses üstüne okunur; istersen oyunun ses ayarlarından konuşma sesini (dialogue volume) kıs. Ses, replik ekrana geldikten kısa süre sonra başlar.")
                        Text("Cihaz sesi ücretsizdir ve telefonda üretilir. ElevenLabs daha doğal konuşur ama internet ister ve okunan her harf hesabından düşer.")
                        if !model.dubSummary.isEmpty { Text(model.dubSummary) }
                        if let problem = model.dubProblem { Text(problem).foregroundStyle(.orange) }
                    }
                }

                Section {
                    LabeledContent("Telefonun ısısı") {
                        Text(model.readingLoad >= .light ? "\(model.thermalName) · koruma devrede" : model.thermalName)
                            .foregroundStyle(model.readingLoad == .minimal ? Color.red : (model.readingLoad == .light ? Color.orange : Color.secondary))
                    }
                    Toggle("Kilitliyken çeviriyi sürdür", isOn: $model.keepRunningWhenLocked)
                    Toggle("Altyazı yokken sesten çevir (deneysel)", isOn: $model.speechEnabled)
                    Toggle("Oyun sesini telefondan çal", isOn: $model.gameAudioEnabled)
                    if model.gameAudioEnabled {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $model.gameAudioVolume, in: 0...1)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Oyun sesi düzeyi")
                    }
                } header: {
                    Text("Çalışma")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Isınma koruması: telefon ısınınca görev yazıları ve seçenekler kendiliğinden daha seyrek okunur, soğuyunca eski hızına döner; konuşma çevirisi bundan etkilenmez. Telefonu oynarken şarja takmamak ve kılıfından çıkarmak en çok işe yarayan iki şeydir.")
                        Text("Ekranda altyazı varken çeviri altyazıdan yapılır. Altyazı olmayan yerlerde (ara sahneler, altyazısız oyunlar) oyundaki İngilizce konuşma telefonda dinlenip çevrilir. Müzik ve efekt sesleri arasında her repliği yakalayamayabilir.")
                        if model.gameAudioEnabled {
                            Text("PS5'in sesi telefondan ya da bağlı kulaklıktan gelir.")
                        }
                        Text("Ses seçeneklerini açıp kapatınca PS5'e yeniden bağlanılır.")
                    }
                }

                Section("Abonelik") {
                    HStack {
                        Text("Durum")
                        Spacer()
                        Text(store.subscribed ? "Etkin" : (store.loading ? "Denetleniyor…" : "Yok"))
                            .foregroundStyle(.secondary)
                    }
                    if store.subscribed {
                        Button("Aboneliği yönet") { managingSubscription = true }
                    } else {
                        Button("Abonelik seçenekleri") { showPaywall = true }
                    }
                    Button("Satın alımları geri yükle") { Task { await store.restore() } }
                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                }

                if tvBrand != "lg" {
                    Section("Televizyon") {
                        NavigationLink("Samsung TV'ye kur ya da güncelle") {
                            ScrollView {
                                SamsungInstallView().padding(20)
                            }
                            .navigationTitle("Televizyon kurulumu")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }

                Section {
                    NavigationLink("Başka bir cihazı ekran yap") { SecondScreenView() }
                } footer: {
                    Text("Tablet, bilgisayar ya da eski bir telefon, tarayıcısından altyazıyı büyük yazıyla gösterebilir.")
                }

                Section {
                    HStack {
                        SecureField("Anthropic API anahtarı", text: $aiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Kaydet") {
                            model.setAIKey(aiKey)
                            aiKey = ""
                        }
                        .disabled(aiKey.isEmpty)
                    }
                } header: {
                    Text("Yapay zekâ anahtarı")
                } footer: {
                    Text(model.aiProblem ?? (model.aiEnabled
                         ? "Anahtar kayıtlı. \"Ekranı çevir\" yapay zekâyla, bağlamı bilerek çevirir; canlı altyazı hız için cihazda çevrilir."
                         : "İsteğe bağlı. \"Ekranı çevir\" anahtar olmadan da telefonda çevirir; anahtar girilirse menü ve belgeler daha doğal çevrilir."))
                        .foregroundStyle(model.aiProblem == nil ? Color.secondary : Color.orange)
                }

                Section {
                    Button("Kurulum rehberini yeniden göster") {
                        dismiss()
                        guideDone = false
                    }
                    Button("PS5 eşleşmesini sil", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("Telefonun adresi: \(model.ipAddress)").monospacedDigit()
                }

                Section {
                    ShareLink(item: model.diagnosticsReport) {
                        Label("Sorun bildir", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Yardım")
                } footer: {
                    Text("Bir şey çalışmıyorsa uygulamanın o anki durumunu (PS5 ve televizyon bağlı mı, hangi adımda kaldın) kısa bir yazı olarak paylaşır. Adın, hesabın ve adresin bu yazıda yer almaz.")
                }

                Section {
                    NavigationLink("Hakkında ve lisanslar") { AboutView() }
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
            .confirmationDialog("PS5 eşleşmesi silinsin mi?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Eşleşmeyi sil", role: .destructive) {
                    dismiss()
                    model.forget()
                }
            } message: {
                Text("Yeniden bağlanmak için PSN girişi ve PS5'teki kod baştan gerekir.")
            }
        }
        .tint(.yellow)
    }
}

/// Abonelik ekranını açar (ana ekranın herhangi bir yerinden).
/// Dublajda hangi karakterin hangi sesle konuştuğu. Cinsiyet oyunun hazır paketinden gelir; paket yoksa ya da
/// yanlışsa buradan seçilir. Adı yazmayan ya da cinsiyeti bilinmeyen konuşanlar anlatıcı sesiyle okunur.
private struct DubCastView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                row(name: "Anlatıcı", detail: "Adı yazmayan replikler", speaker: nil)
            } footer: {
                Text("Birçok oyun altyazıda konuşanın adını yazmaz (ör. GTA V); o oyunlarda bütün replikler bu sesle okunur.")
            }
            Section {
                if model.seenSpeakers.isEmpty {
                    Text("Henüz konuşan görülmedi. Oyunda adıyla konuşan biri çıkınca burada listelenir.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.seenSpeakers, id: \.self) { speaker in
                    VStack(alignment: .leading, spacing: 8) {
                        row(name: speaker, detail: nil, speaker: speaker)
                        Picker("Cinsiyet", selection: Binding(
                            get: { DubGender(rawValue: model.dubGenders[speaker.lowercased()] ?? "") ?? .unknown },
                            set: { model.setDubGender($0, for: speaker) })) {
                            Text("Kendiliğinden").tag(DubGender.unknown)
                            Text("Erkek").tag(DubGender.male)
                            Text("Kadın").tag(DubGender.female)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Bu oturumda konuşanlar")
            } footer: {
                Text("Erkek ya da kadın seçince karaktere o gruptan, başkasının kullanmadığı bir ses verilir ve o oyunda hep aynı kalır. Sesler ElevenLabs'in hazır sesleridir; cihaz sesinde karakterler ses perdesiyle ayrışır.")
            }
        }
        .navigationTitle("Karakter sesleri")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(name: String, detail: String?, speaker: String?) -> some View {
        let voice = model.dubVoice(for: speaker)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail ?? "\(voice.name) · \(voice.note)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.dub("Merhaba, ben bu sesle konuşacağım.", speaker: speaker)
            } label: {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(name) sesini dinle")
        }
    }
}

#if DEBUG
/// ElevenLabs anahtarı (yalnız geliştirme sürümünde): yayından önce gizlilik metni güncellenmeli.
private struct DubKeyField: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = ""

    var body: some View {
        if model.dubHasKey {
            Button("ElevenLabs anahtarını sil", role: .destructive) { model.setSpeechKey("") }
        } else {
            SecureField("ElevenLabs anahtarı", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Anahtarı kaydet") {
                model.setSpeechKey(key)
                key = ""
            }
            .disabled(key.isEmpty)
        }
    }
}
#endif

/// "Takıldım" yardımcısı (DENEME): isteğe bağlı bir soru yazılır, ipucu burada ve televizyonda görünür.
/// İpucu kademelidir: önce küçük bir işaret, istenirse daha açığı, en son tam çözüm.
private struct HelperSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @FocusState private var typing: Bool

    private static let depthNames = ["Küçük ipucu", "Daha açık ipucu", "Tam çözüm"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.helper.hints.isEmpty {
                        Text("Yardımcı, televizyonda şu an ne varsa ona ve son konuşmalara bakar. Soru yazmak zorunda değilsin; yazarsan cevap daha isabetli olur.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Ne soruyorsun? (boş bırakabilirsin)", text: $question, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($typing)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        if !model.helper.question.isEmpty {
                            Text(model.helper.question).font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.helper.hints.enumerated()), id: \.offset) { index, hint in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Self.depthNames[min(index, 2)].uppercased(with: Locale(identifier: "tr")))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.yellow)
                                Text(hint).font(.body).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }

                    if model.helper.working {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Yardımcı ekrana bakıyor…").foregroundStyle(.secondary)
                        }
                    } else if model.helper.hints.isEmpty {
                        Button("İpucu ver") {
                            typing = false
                            model.askHelper(question: question)
                        }
                        .buttonStyle(ProminentAction())
                    } else {
                        if model.helper.canGoDeeper {
                            Button(model.helper.hints.count == 1 ? "Yetmedi, daha açık söyle" : "Tam çözümü ver") {
                                model.askHelper(deeper: true)
                            }
                            .buttonStyle(ProminentAction())
                        }
                        Button("Yeni soru") {
                            question = ""
                            model.closeHelper()
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }

                    if let error = model.helper.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let seconds = model.helper.lastSeconds, let cost = model.helper.lastCost {
                        Text(String(format: "Deneme ölçümü — son soru: %.0f sn, yaklaşık %.3f $ · bu oturum: %d soru, %.3f $",
                                    seconds, cost, model.helper.asked, model.helper.totalCost))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text("Yardımcı yanılabilir; söylediği olmazsa bir kademe daha açığını iste. Düğmeye bastığında o anki ekran görüntüsü, kendi yapay zekâ anahtarınla Anthropic'e gönderilir.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Takıldım")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Bitti") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Hazır görünümler: her biri kendi biçimiyle yazılmış küçük bir örnek; dokununca uygulanır.
private struct PresetRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SubtitlePreset.all) { preset in
                    let selected = preset.matches(model.appearance, scale: model.fontScale)
                    Button {
                        model.apply(preset)
                    } label: {
                        VStack(spacing: 6) {
                            Text("Aa")
                                .font(.system(size: 15 * preset.scale, weight: preset.bold ? .bold : .medium))
                                .foregroundStyle(Color(hex: preset.color.rawValue))
                                .shadow(color: .black, radius: preset.background < 0.25 ? 2 : 0)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(preset.background), in: RoundedRectangle(cornerRadius: 3))
                                .frame(width: 104, height: 44)
                                .background(Color(red: 0.36, green: 0.42, blue: 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(selected ? Color.yellow : Color.clear, lineWidth: 2.5))
                            Text(preset.name)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.name) görünümü")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct OpenPaywallKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openPaywall: () -> Void {
        get { self[OpenPaywallKey.self] }
        set { self[OpenPaywallKey.self] = newValue }
    }
}

/// Televizyondaki altyazının küçük bir örneği: ayarlar değiştikçe nasıl görüneceğini gösterir.
private struct SubtitleSample: View {
    let appearance: SubtitleAppearance
    let scale: Double

    private let lines = [("Reyes", "Şafaktan önce köprüyü geçmeliyiz."), ("Nova", "Köprü tutulmuş. Başka bir yol olmalı.")]

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.2, blue: 0.36), Color(red: 0.55, green: 0.33, blue: 0.3), Color(red: 0.07, green: 0.08, blue: 0.13)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 4) {
                ForEach(lines, id: \.0) { speaker, text in
                    (Text(speaker + ": ").foregroundColor(speakerColor(speaker)).fontWeight(.bold)
                     + Text(text).foregroundColor(Color(hex: appearance.color.rawValue)))
                        .font(.system(size: 13 * scale, weight: appearance.bold ? .bold : .medium))
                        .shadow(color: .black.opacity(appearance.background < 0.25 ? 1 : 0.6), radius: appearance.background < 0.25 ? 3 : 1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.black.opacity(appearance.background), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.bottom, 12)
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .accessibilityHidden(true)
    }

    private func speakerColor(_ name: String) -> Color {
        let palette = SubtitleAppearance.speakerPalette
        return Color(hex: appearance.speakerColors ? palette[SubtitleAppearance.paletteIndex(for: name)] : palette[0])
    }
}

// MARK: - Ortak görünüm parçaları

/// Ana ekrandaki kartların ortak biçimi.
private extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Birincil işlem düğmesi: tam genişlik, vurgu renginde.
private struct ProminentAction: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.yellow.opacity(isEnabled ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Karo düğmelerin basılma tepkisi.
private struct PressableTile: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Bölge seçimi

/// Altyazının arandığı sarı çerçeve: gövdesinden sürüklenir, köşesinden boyutlanır.
private struct RegionSelector: View {
    @Binding var region: CGRect
    var color: Color = .yellow
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let frame = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                               width: region.width * size.width, height: region.height * size.height)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(color.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(color, lineWidth: 2))
                    .frame(width: frame.width, height: frame.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let start = dragStart ?? region
                                dragStart = start
                                var next = start
                                next.origin.x = clamp(start.minX + value.translation.width / size.width, 0, 1 - start.width)
                                next.origin.y = clamp(start.minY + value.translation.height / size.height, 0, 1 - start.height)
                                region = next
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .offset(x: frame.minX, y: frame.minY)

                Circle()
                    .fill(color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle().inset(by: -10))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let start = dragStart ?? region
                                dragStart = start
                                var next = start
                                next.size.width = clamp(start.width + value.translation.width / size.width, 0.15, 1 - start.minX)
                                next.size.height = clamp(start.height + value.translation.height / size.height, 0.06, 1 - start.minY)
                                region = next
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .offset(x: frame.maxX - 14, y: frame.maxY - 14)
                    .accessibilityLabel("Bölge boyutu")
            }
        }
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

// MARK: - Dokunuş izleyici

/// Penceredeki her dokunuşu haber verir ama hiçbirini tüketmez: düğmeler, anahtarlar ve
/// kaydırma olağan biçimde çalışmayı sürdürür.
private struct TouchObserver: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onTouch = onTouch
    }

    final class ObserverView: UIView {
        var onTouch: (() -> Void)?
        private var recognizer: PassiveRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            guard let window else { return }
            let added = PassiveRecognizer { [weak self] in self?.onTouch?() }
            added.cancelsTouchesInView = false
            added.delaysTouchesBegan = false
            added.delaysTouchesEnded = false
            window.addGestureRecognizer(added)
            recognizer = added
        }
    }

    /// Dokunuş başladığını bildirir ve hemen çekilir; başka hiçbir hareketi engellemez.
    final class PassiveRecognizer: UIGestureRecognizer {
        private let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
            super.init(target: nil, action: nil)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            handler()
            state = .failed
        }
    }
}


/// Seçili oyunda çevrilmeyecek adların listesi: karakter, yer, silah adları çeviride olduğu gibi kalır.
private struct KeptTermsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newTerm = ""

    /// Bu oturumda konuşan olarak görülen, henüz listede olmayan adlar.
    private var suggestions: [String] {
        model.seenSpeakers.filter { name in
            !model.keptTerms.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Ad (ör. Ghost)", text: $newTerm)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Ekle", action: add)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).count < 2)
                }
            } footer: {
                Text("Ad, oyunda yazıldığı gibi girilir. Yalnız baş harfi büyük yazıldığında korunur: \"Ghost\" olduğu gibi kalır, cümle içindeki \"ghost\" (hayalet) çevrilir.")
            }

            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.self) { name in
                        Button {
                            model.addKeptTerm(name)
                        } label: {
                            Label(name, systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("Bu oturumda konuşanlar")
                } footer: {
                    Text("Dokununca listeye eklenir.")
                }
            }

            Section {
                if model.keptTerms.isEmpty {
                    Text("Henüz ad eklenmedi.").foregroundStyle(.secondary)
                }
                ForEach(model.keptTerms, id: \.self) { term in
                    Text(term)
                }
                .onDelete { offsets in
                    for term in offsets.map({ model.keptTerms[$0] }) { model.removeKeptTerm(term) }
                }
            } header: {
                Text(model.selectedGame.isEmpty ? "Çevrilmeyecek adlar" : "“\(model.selectedGame)” için")
            } footer: {
                Text("Silmek için adı sola kaydır. Liste her oyun için ayrı tutulur; oyunu ana ekrandaki oyun menüsünden seçersin.")
            }
        }
        .navigationTitle("Çevrilmeyecek adlar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        model.addKeptTerm(newTerm)
        newTerm = ""
    }
}

/// Televizyon markasına göre çevirinin nerede gösterileceği.
enum TVSupport {
    /// Bu markalarda televizyona Marhilk kurulamıyor; çeviri telefonun ekranında gösterilir.
    static func phoneOnly(_ brand: String) -> Bool {
        brand == "android" || brand == "other"
    }
}

// MARK: - Özellik turu

/// İlk oyunda denenecekler. Madde, kullanıcı o özelliği gerçekten kullanınca kendiliğinden işaretlenir;
/// maddeye dokunmak özelliği açar ya da nerede olduğunu gösterir.
private struct TourCard: View {
    @EnvironmentObject private var model: AppModel
    let openSettings: () -> Void

    private struct Entry {
        let item: AppModel.TourItem
        let title: String
        let detail: String
        let symbol: String
    }

    private let entries = [
        Entry(item: .screen, title: "Bir menüyü çevir",
              detail: "Oyunu duraklat, sonra buna dokun (ya da kumandada MAVİ tuş).", symbol: "text.viewfinder"),
        Entry(item: .history, title: "Kaçırdığın repliği geri oku",
              detail: "Buna dokun; geçmiş açılır. Televizyonda SARI tuş aynı işi görür.", symbol: "clock.arrow.circlepath"),
        Entry(item: .names, title: "Adların çevrilmesini önle",
              detail: "Oyununu listeden seç; karakter adları olduğu gibi kalsın.", symbol: "person.text.rectangle"),
        Entry(item: .appearance, title: "Yazıyı kendine göre ayarla",
              detail: "Boyut, renk, ekranda kalma süresi ayarlarda.", symbol: "textformat.size"),
        Entry(item: .phone, title: "Çeviriyi telefonda gör",
              detail: "Televizyon bağlı değilken de çalışır.", symbol: "iphone.landscape"),
    ]

    @State private var showHistory = false
    @State private var pickingPack = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("İlk oyununda dene").font(.headline)
                Spacer(minLength: 8)
                Text("\(model.tourDone.count)/\(entries.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    model.tourHidden = true
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Turu kapat")
            }
            ForEach(entries, id: \.item) { entry in
                let done = model.tourDone.contains(entry.item.rawValue)
                Button {
                    perform(entry.item)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(done ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.subheadline.weight(.semibold))
                                .foregroundStyle(done ? Color.secondary : Color.primary)
                                .strikethrough(done, color: .secondary)
                            if !done {
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        if !done { Image(systemName: entry.symbol).foregroundStyle(.yellow) }
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
        .sheet(isPresented: $showHistory) { HistorySheet() }
        .sheet(isPresented: $pickingPack) { GamePackPicker() }
    }

    private func perform(_ item: AppModel.TourItem) {
        switch item {
        case .screen: model.toggleScreenTranslation()
        case .history:
            showHistory = true
            model.completeTour(.history)
        case .names: pickingPack = true
        case .appearance: openSettings()
        case .phone: model.phoneDisplay = true
        }
    }
}

// MARK: - Hazır oyunlar

/// Sık oynanan oyunların listesi: seçilen oyun eklenir ve karakter/yer adları "çevrilmeyecek adlar"a hazır gelir.
private struct GamePackPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var packs: [GamePack] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? GamePacks.all : GamePacks.all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(packs) { pack in
                        Button {
                            choose(pack)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pack.name).foregroundStyle(.primary)
                                    Text("\(pack.terms.count) ad: \(pack.terms.prefix(4).joined(separator: ", "))…")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if model.selectedGame == pack.name { Image(systemName: "checkmark").foregroundStyle(.yellow) }
                            }
                        }
                    }
                } footer: {
                    Text("Oyunu seçince karakter ve yer adları çeviride olduğu gibi kalır. Oyunun listede yoksa ana ekrandaki oyun menüsünden \"Başka bir oyun ekle\"yi kullan; adları Ayarlar › Çevrilmeyecek adlar'dan kendin eklersin.")
                }
            }
            .searchable(text: $search, prompt: "Oyun ara")
            .navigationTitle("Oyununu seç")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
            }
        }
        .tint(.yellow)
    }

    private func choose(_ pack: GamePack) {
        if model.games.contains(pack.name) {
            // Oyun zaten ekli: seç ve eksik adları tamamla.
            model.selectGame(pack.name)
            model.addPackTerms(pack)
        } else {
            model.addGame(pack.name, pack: pack)
            model.completeTour(.names)
        }
        dismiss()
    }
}

// MARK: - İkinci ekran

/// Başka bir cihazın (tablet, bilgisayar, eski telefon) tarayıcısını altyazı ekranı yapar:
/// o cihaz aynı Wi-Fi ağındayken telefonun sunduğu sayfayı açar.
private struct SecondScreenView: View {
    @EnvironmentObject private var model: AppModel

    private var address: String { "http://\(model.browserAddress)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let code = QRCode.image(for: address) {
                    Image(uiImage: code)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Adresin kare kodu")
                }
                VStack(spacing: 4) {
                    Text("Tarayıcıya yazılacak adres").font(.caption).foregroundStyle(.secondary)
                    Text(address).font(.title3.monospacedDigit().weight(.semibold)).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Öbür cihazı **aynı Wi-Fi ağına** bağla.")
                    step(2, "Kamerasıyla yukarıdaki **kare kodu** okut ya da tarayıcısına adresi yaz.")
                    step(3, "Cihazı **yatay** çevir, açılan siyah sayfayı tam ekran yap ve televizyonun yanına koy. Çeviri orada büyük yazıyla akar.")
                    step(4, "O cihazın ekranı kendiliğinden kapanmasın: ayarlarından **otomatik kilidi kapat**.")
                }

                Label(model.tvCount > 0 ? "Bir ekran bağlı." : "Henüz bağlanan ekran yok.",
                      systemImage: model.tvCount > 0 ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.tvCount > 0 ? Color.green : Color.secondary)

                Text("Bu telefonda Marhilk açık kaldığı sürece çalışır. Adres, Wi-Fi ağın değişirse değişebilir; o zaman bu sayfadaki yeni adresi kullan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Başka bir cihazı ekran yap")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                .frame(width: 24, height: 24).background(Color.yellow, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Bir metnin kare kodu (cihazda üretilir).
enum QRCode {
    static func image(for text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let rendered = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
