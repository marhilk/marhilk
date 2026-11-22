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
                               state: model.tvCount > 0 ? "Bağlı" : "Bekleniyor",
                               color: model.tvCount > 0 ? .green : .orange)
                }
            }
            actions
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
                    Button { newGameName = ""; addingGame = true } label: { Label("Oyun ekle…", systemImage: "plus") }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    Text("Değişiklikler televizyonda anında görünür. Konuşanları renklendirince her kişi kendi rengini alır; kalabalık sahnelerde kimin konuştuğu daha kolay izlenir.")
                }

                Section {
                    Picker("Yazının ekranda kalma süresi", selection: $model.readingPace) {
                        Text("Kısa").tag(0.75)
                        Text("Olağan").tag(1.0)
                        Text("Uzun").tag(1.6)
                    }
                    Toggle("Konuşma seçeneklerini çevir", isOn: $model.choicesEnabled)
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
                    Text("Kalma süresi: oyun bir repliği çabuk kaldırdığında çevirisi okunsun diye ekranda bekletilir; yavaş okuyorsan \"Uzun\" seç. Konuşma seçenekleri: oyun sana bir seçim sunduğunda seçeneklerin Türkçesi listenin altında numaralı görünür. Çevrilmeyecek adlar: karakter ve yer adları çeviride olduğu gibi kalır (\"Ghost\", \"Hayalet\" olmaz).")
                }

                Section {
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
