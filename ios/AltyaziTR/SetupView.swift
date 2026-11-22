import RemotePlayKit
import SwiftUI
import WebKit

/// Kurulum rehberi: kullanıcıyı adım adım, her adımı doğrulayarak bağlantıya götürür.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case welcome, tvBrand, account, remotePlay, login, console, code, tv, ready
    }

    /// Kullanıcının televizyonu. Rehberin TV adımı buna göre anlatır.
    enum TVBrand: String, CaseIterable {
        case samsung, lg, android, other

        var title: String {
            switch self {
            case .samsung: return "Samsung"
            case .lg: return "LG"
            case .android: return "Android TV / Google TV"
            case .other: return "Başka bir marka"
            }
        }

        var detail: String {
            switch self {
            case .samsung: return "2018 ve sonrası akıllı TV'ler"
            case .lg: return "webOS · TV'nin tarayıcısıyla · deneme aşamasında"
            case .android: return "Sony, Philips, TCL, Xiaomi, Vestel…"
            case .other: return "Listede olmayanlar"
            }
        }

        /// Bu marka için televizyon uygulaması var mı?
        var supported: Bool { self == .samsung || self == .lg }
    }

    @EnvironmentObject private var model: AppModel
    @AppStorage("guideDone") private var guideDone = false
    @State private var step: Step = {
        #if DEBUG
        // Ekran görüntüsü almak için: uygulamayı `-debugGuideStep 3` ile başlat.
        if let forced = Step(rawValue: UserDefaults.standard.integer(forKey: "debugGuideStep")) { return forced }
        #endif
        return .welcome
    }()
    @State private var showLogin = false
    @State private var selectedHost = ""
    @State private var manualHost = ""
    @State private var pin = ""
    /// Bu adımda kullanıcının "yaptım" dediği madde sayısı.
    @State private var ticked = 0
    @AppStorage("tvBrand") private var tvBrandRaw = ""
    @FocusState private var typing: Bool

    private var host: String {
        let typed = manualHost.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? selectedHost : typed
    }

    private var paired: Bool { model.credentials != nil }
    private var tvBrand: TVBrand? { TVBrand(rawValue: tvBrandRaw) }

    /// Bu adımda kullanıcının tek tek onaylaması gereken madde sayısı.
    private var actionCount: Int {
        switch step {
        case .account, .remotePlay: return instructions.count
        case .code: return paired ? 0 : 2
        case .tv: return model.tvCount > 0 || tvBrand == .samsung ? 0 : instructions.count
        default: return 0
        }
    }

    /// Onaylanmayı bekleyen madde var mı?
    private var ticking: Bool { ticked < actionCount }

    var body: some View {
        VStack(spacing: 0) {
            progress
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Illustration(step: step)
                    Text(title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedStringKey(summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !instructions.isEmpty {
                        NumberedList(items: instructions, ticked: actionCount > 0 ? ticked : nil)
                    }
                    controls
                    if step == .welcome {
                        // PS5'i ya da televizyonu yanında olmayan (ör. uygulamayı inceleyen) kişi için.
                        Button {
                            model.startDemo()
                        } label: {
                            Label("Cihazlarım yanımda değil, örneği göster", systemImage: "play.rectangle")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    if let note { Note(text: note) }
                    if let error = model.setupError, [.login, .console, .code].contains(step) {
                        Banner(text: error, color: .red, icon: "exclamationmark.triangle.fill")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onChange(of: step) { _, new in
            typing = false
            ticked = 0
            model.setupError = nil
            if new == .console, !paired { model.searchHosts() }
        }
        .onChange(of: model.hosts.map(\.address)) { _, found in
            if selectedHost.isEmpty, found.count == 1 { selectedHost = found[0] }
        }
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                PSNLoginView { url in
                    showLogin = false
                    Task { await model.finishLogin(redirect: url) }
                }
                .navigationTitle("PSN girişi")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Vazgeç") { showLogin = false }
                    }
                }
            }
        }
    }

    // MARK: - Üst ve alt çubuk

    private var progress: some View {
        HStack(spacing: 12) {
            Button {
                move(-1)
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .accessibilityLabel("Geri")
            .opacity(step == .welcome ? 0 : 1)
            .disabled(step == .welcome)

            HStack(spacing: 4) {
                ForEach(1..<Step.allCases.count, id: \.self) { index in
                    Capsule()
                        .fill(index <= step.rawValue ? Color.yellow : Color(.tertiarySystemFill))
                        .frame(height: 4)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Adım \(step.rawValue) / \(Step.allCases.count - 1)")

            Text("\(step.rawValue)/\(Step.allCases.count - 1)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(step == .welcome ? 0 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        Button(action: advance) {
            Label(ticking ? "Bunu yaptım" : primaryLabel, systemImage: ticking ? "checkmark" : "arrow.right")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(ticking || canContinue ? Color.black : Color(.tertiaryLabel))
                .background(ticking || canContinue ? Color.yellow : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(!ticking && !canContinue)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }

    private func advance() {
        if ticking {
            withAnimation(.easeInOut(duration: 0.2)) { ticked += 1 }
        } else if step == .ready {
            guideDone = true
        } else {
            move(1)
        }
    }

    private var canContinue: Bool {
        switch step {
        case .tvBrand: return tvBrand?.supported == true
        case .login: return model.accountID != nil
        case .console: return paired || !host.isEmpty
        case .code: return paired
        default: return true
        }
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Başlayalım"
        case .tv: return model.tvCount > 0 ? "Devam" : "TV'yi sonra bağlayacağım"
        case .ready: return "Çeviriyi başlat"
        default: return "Devam"
        }
    }

    // MARK: - Adım metinleri

    private var title: String {
        switch step {
        case .welcome: return "PS5 oyunların artık Türkçe altyazılı"
        case .tvBrand: return "Televizyonun hangisi?"
        case .account: return "PS5'e ikinci bir hesap ekle"
        case .remotePlay: return "PS5'te Uzaktan Oynama'yı aç"
        case .login: return "İkinci hesapla giriş yap"
        case .console: return "PS5'ini seç"
        case .code: return "PS5'teki kodu gir"
        case .tv: return "Televizyonu bağla"
        case .ready: return "Hazırsın"
        }
    }

    private var summary: String {
        switch step {
        case .welcome:
            return "Bu telefon PS5'inin ekranını izler, İngilizce altyazıyı okur ve Türkçesini televizyonuna gönderir. Kurulum yaklaşık 5 dakika sürer ve bir kez yapılır."
        case .tvBrand:
            return "Rehber, seçtiğin televizyona göre anlatır."
        case .account:
            return "Sen oyunu her zamanki hesabınla, kumandanla oynarsın. Marhilk PS5'e **ayrı bir hesapla** bağlanıp yalnızca izler."
        case .remotePlay:
            return "Bu ayar **ikinci hesabın** içindeyken yapılmalı. PS5'te o hesaba geçtikten sonra:"
        case .login:
            return "Az önce PS5'e eklediğin **ikinci hesabın** e-postası ve parolasıyla giriş yap. Giriş Sony'nin kendi sayfasında yapılır; parolan bu uygulamaya gelmez."
        case .console:
            return "Telefon, bulunduğun Wi-Fi ağında PS5'ini arıyor."
        case .code:
            return "PS5 sana 8 haneli bir kod verecek. Kod birkaç dakika geçerlidir."
        case .tv:
            return tvBrand == .lg
                ? "Çeviriler LG televizyonunun tarayıcısında açılan Marhilk sayfasında görünür. Her maddeyi yapınca alttaki düğmeye bas."
                : "Çeviriler televizyondaki Marhilk uygulamasında görünür. Uygulamayı televizyona bu telefon kurar; bir kez yapılır."
        case .ready:
            return "Kurulum tamam. Geriye yalnız oyunu açmak kaldı."
        }
    }

    private var instructions: [String] {
        switch step {
        case .welcome:
            return ["**PS5** — açık ve Wi-Fi'ya bağlı",
                    "**Akıllı TV** — PS5'in bağlı olduğu televizyon",
                    "**Aynı Wi-Fi** — telefon, PS5 ve TV aynı ağda",
                    "**İkinci bir PlayStation hesabı** — ücretsiz, birazdan birlikte ekleyeceğiz",
                    "**Samsung hesabı** — Samsung televizyona kurulum için, ücretsiz"]
        case .account:
            return ["Kumandada **PS tuşuna** bas, alttaki menüden **profil resmini** seç.",
                    "**Kullanıcı Değiştir** › **Kullanıcı Ekle**'yi seç.",
                    "**Başlarken**'i seç ve koşulları kabul et.",
                    "İkinci bir PlayStation hesabıyla giriş yap. Yoksa aynı ekrandan **Hesap Oluştur** ile ücretsiz aç (farklı bir e-posta gerekir)."]
        case .remotePlay:
            return ["Ana ekranın sağ üstünden **Ayarlar**'ı (dişli) aç.",
                    "**Sistem** › **Uzaktan Oynama**'ya gir.",
                    "**Uzaktan Oynamayı Etkinleştir**'i aç."]
        case .tvBrand, .login:
            return []
        case .console:
            return paired ? [] : ["Telefon \"yerel ağdaki cihazları bulmak istiyor\" diye sorarsa **İzin Ver**'e bas.",
                                  "Listeden PS5'ine dokun."]
        case .code:
            return paired ? [] : ["PS5'te **ikinci hesaptayken** **Ayarlar** › **Sistem** › **Uzaktan Oynama**'ya gir.",
                                  "**Cihaz Bağla**'yı seç.",
                                  "Ekranda çıkan 8 haneli kodu aşağıya yaz."]
        case .tv:
            return tvInstructions
        case .ready:
            return ["PS5'te **kendi hesabına** dön ve oyununu aç. İkinci hesap yalnız bağlantı içindi.",
                    "Oyunun ayarlarından **altyazıyı aç**; dili **İngilizce** olsun. Marhilk ekrandaki İngilizce yazıyı çevirir.",
                    "Bundan sonra oynamadan önce yalnız telefonda **Marhilk'i aç**. Televizyondaki uygulamayı telefon kendisi açar; sonra telefonu kilitleyebilirsin."]
        }
    }

    /// TV adımının maddeleri, seçilen markaya göre.
    private var tvInstructions: [String] {
        switch tvBrand {
        case .samsung, .none:
            return []   // Samsung'da kurulumu telefon yapar; adımları SamsungInstallView gösterir.
        case .lg:
            return ["LG kumandasında **Ana Ekran** (ev) tuşuna bas, uygulamalar arasından **Web Tarayıcı**'yı aç.",
                    "Adres çubuğuna aşağıdaki adresi yaz ve **Git**'e bas.",
                    "Sayfa açılınca kumandada **Tamam**'a bas: görüntü tam ekran olur.",
                    "PS5 görüntüsü gelmediyse kumandada **KIRMIZI** tuşa bas; sıradaki HDMI girişine geçer."]
        case .android, .other:
            return []
        }
    }

    private var note: String? {
        switch step {
        case .account:
            return "Neden ikinci hesap? PS5 bir hesaba uzaktan bağlanılınca o hesabın kumandasını kapatır. Kendi hesabınla bağlansaydık oyunun ortasında kumandan devre dışı kalırdı."
        case .remotePlay:
            return "Bu ayar her kullanıcı için ayrıdır. Kendi hesabında açık olması yetmez; ikinci hesapta da açılmalı."
        case .console:
            return paired ? nil : "PS5 listede yoksa: açık olduğundan ve kabloyla değil **Wi-Fi ile** aynı ağa bağlı olduğundan emin ol, sonra yeniden ara."
        case .tvBrand:
            return "Marhilk'in televizyonda da bir uygulaması var; oyun görüntüsünün üstüne yazıyı o basıyor. Bu yüzden televizyonun markası önemli."
        case .tv where tvBrand == .lg:
            return "LG'de uygulama kurulmaz; Marhilk TV'nin kendi tarayıcısında çalışır. Bu yol **deneme aşamasında**: her LG modelinde çalışmayabilir. Yazının yeri ▲▼, boyutu ◀▶ tuşlarıyla ayarlanır."
        case .ready:
            return "Altyazının ekrandaki yerini uygulama kendisi bulur; ilk birkaç replikten sonra çeviri gelmeye başlar. Televizyon kumandasında **SARI** tuş son replikleri yeniden gösterir."
        case .tv:
            return "Yanlış HDMI girişi görünürse TV kumandasında **KIRMIZI** tuşa bas. Yazının yeri ▲▼, boyutu ◀▶ tuşlarıyla ayarlanır."
        default:
            return nil
        }
    }

    // MARK: - Adıma özel denetimler

    @ViewBuilder private var controls: some View {
        switch step {
        case .tvBrand:
            VStack(spacing: 8) {
                ForEach(TVBrand.allCases, id: \.self) { brand in
                    Button {
                        tvBrandRaw = brand.rawValue
                    } label: {
                        HStack {
                            Image(systemName: "tv")
                            VStack(alignment: .leading) {
                                Text(brand.title).fontWeight(.semibold)
                                Text(brand.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !brand.supported {
                                Text("yakında").font(.caption2).foregroundStyle(.secondary)
                            }
                            Image(systemName: tvBrand == brand ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(tvBrand == brand ? Color.yellow : Color.secondary)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .foregroundStyle(.primary)
                }
                if let tvBrand, !tvBrand.supported {
                    Banner(text: "Marhilk şimdilik Samsung ve LG televizyonlarda çalışıyor. \(tvBrand == .other ? "Diğer markalar" : tvBrand.title) için destek hazırlanıyor.",
                           color: .orange, icon: "clock.fill")
                }
            }

        case .login:
            if model.accountID != nil {
                Banner(text: "Giriş yapıldı.", color: .green, icon: "checkmark.circle.fill")
            } else {
                Button {
                    showLogin = true
                } label: {
                    Label("PlayStation hesabına giriş yap", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

        case .console:
            if paired {
                Banner(text: "PS5 zaten eşleşmiş.", color: .green, icon: "checkmark.circle.fill")
            } else {
                consolePicker
            }

        case .code:
            if paired {
                Banner(text: "PS5 ile eşleşildi.", color: .green, icon: "checkmark.circle.fill")
            } else if !ticking {
                VStack(spacing: 10) {
                    TextField("8 haneli kod", text: $pin)
                        .keyboardType(.numberPad)
                        .focused($typing)
                        .font(.title2.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button {
                        typing = false
                        model.pair(host: host, pin: pin.filter(\.isNumber))
                    } label: {
                        Group {
                            if model.pairing {
                                HStack { ProgressView(); Text("Eşleşiliyor…") }
                            } else {
                                Text("Eşleş")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(host.isEmpty || pin.filter(\.isNumber).count != 8 || model.pairing)
                }
            }

        case .tv where tvBrand == .samsung || tvBrand == nil:
            SamsungInstallView()
            if model.tvCount > 0 {
                Banner(text: "Televizyon bağlandı.", color: .green, icon: "checkmark.circle.fill")
            }

        case .tv:
            if tvBrand == .lg {
                VStack(spacing: 4) {
                    Text("LG tarayıcısına yazılacak adres").font(.caption).foregroundStyle(.secondary)
                    Text(model.browserAddress)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if model.tvCount > 0 {
                Banner(text: "Televizyon bağlandı.", color: .green, icon: "checkmark.circle.fill")
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(tvBrand == .lg ? "Televizyon bekleniyor… Sayfa açılınca burası kendiliğinden yeşile döner."
                                        : "Televizyon bekleniyor… TV'de Marhilk'i açınca burası kendiliğinden yeşile döner.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

        case .ready:
            // Çeviri dili inmemişse çeviri gelmez; kullanıcı bunu oyuna başlamadan görsün.
            if model.translationReady {
                Banner(text: "Türkçe çeviri dili hazır.", color: .green, icon: "checkmark.circle.fill")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Banner(text: "Türkçe çeviri dili henüz telefonda yok.", color: .orange, icon: "arrow.down.circle.fill")
                    Text("iPhone, çeviri dilini bir kez indirmek ister. Aşağıdaki düğmeye bas ve çıkan pencerede indirmeyi onayla.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        model.retryTranslationSetup()
                    } label: {
                        Label("Çeviri dilini indir", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

        default:
            EmptyView()
        }
    }

    private var consolePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.searching {
                HStack(spacing: 10) { ProgressView(); Text("PS5 aranıyor…").foregroundStyle(.secondary) }
            } else if model.hosts.isEmpty {
                Banner(text: "PS5 bulunamadı.", color: .orange, icon: "wifi.exclamationmark")
            }
            ForEach(model.hosts, id: \.address) { found in
                Button {
                    selectedHost = found.address
                    manualHost = ""
                } label: {
                    HStack {
                        Image(systemName: "gamecontroller.fill")
                        VStack(alignment: .leading) {
                            Text(found.name).fontWeight(.semibold)
                            Text(found.address + (found.isStandby ? " · dinlenme modunda" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: host == found.address ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(host == found.address ? Color.green : Color.secondary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .foregroundStyle(.primary)
            }
            Button("Yeniden ara") { model.searchHosts() }
                .disabled(model.searching)
            if !model.searching, model.hosts.isEmpty {
                TextField("ya da PS5'in IP adresini yaz", text: $manualHost)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .focused($typing)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

// MARK: - Küçük parçalar

/// Numaralı talimatlar. `ticked` verilirse maddeler tek tek onaylanır:
/// bitenler yeşil işaretlenir, sıradaki öne çıkar, sonrakiler soluk kalır.
private struct NumberedList: View {
    let items: [String]
    var ticked: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let done = ticked.map { index < $0 } ?? false
                let active = ticked.map { index == $0 } ?? false
                let waiting = ticked.map { index > $0 } ?? false
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if done {
                            Image(systemName: "checkmark").font(.footnote.bold())
                        } else {
                            Text("\(index + 1)").font(.footnote.bold())
                        }
                    }
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(done ? Color.green : (waiting ? Color(white: 0.35) : Color.yellow), in: Circle())
                    Text(LocalizedStringKey(item))
                        .font(.body)
                        .foregroundStyle(waiting || done ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(active ? 12 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(active ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(active ? 0.7 : 0), lineWidth: 1.5))
            }
        }
    }
}

private struct Banner: View {
    let text: String
    let color: Color
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Note: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            Text(LocalizedStringKey(text))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Resimler

/// Her adımın üstündeki çizim: kullanıcının PS5'te ya da TV'de göreceği ekranın sadeleştirilmiş hâli.
private struct Illustration: View {
    let step: SetupView.Step

    var body: some View {
        Group {
            switch step {
            case .welcome:
                HStack(spacing: 10) {
                    device("gamecontroller.fill", "PS5 oyunu")
                    arrow
                    device("iphone", "Telefon çevirir")
                    arrow
                    device("tv", "TV'de Türkçe")
                }
            case .tvBrand:
                HStack(spacing: 22) {
                    Image(systemName: "tv").font(.system(size: 60))
                    Image(systemName: "questionmark").font(.system(size: 34, weight: .bold)).foregroundStyle(.yellow)
                }
            case .account:
                TVFrame {
                    VStack(spacing: 12) {
                        Text("Kim oynuyor?").font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 18) {
                            avatar("person.fill", "Sen", highlighted: false)
                            avatar("person.fill", "İkinci hesap", highlighted: true)
                            avatar("plus", "Kullanıcı Ekle", highlighted: false)
                        }
                    }
                }
            case .remotePlay:
                TVFrame {
                    MenuMock(path: "Ayarlar › Sistem › Uzaktan Oynama", rows: [
                        .init(title: "Uzaktan Oynamayı Etkinleştir", highlighted: true, isOn: true),
                        .init(title: "Cihaz Bağla"),
                        .init(title: "Bağlantı Geçmişi"),
                    ])
                }
            case .login:
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 56))
                        .foregroundStyle(.yellow)
                    Text("İkinci PlayStation hesabı").font(.footnote).foregroundStyle(.secondary)
                }
            case .console:
                HStack(spacing: 14) {
                    device("iphone", "Telefon")
                    Image(systemName: "wifi").font(.title).foregroundStyle(.yellow)
                    device("gamecontroller.fill", "PS5")
                }
            case .code:
                TVFrame {
                    VStack(spacing: 6) {
                        Text("Ayarlar › Sistem › Uzaktan Oynama › Cihaz Bağla")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text("Bu sayıyı cihazına gir")
                            .font(.system(size: 10))
                        Text("1234 5678")
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow, lineWidth: 2))
                        Text("örnek · seninki farklı olacak")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            case .tv:
                TVFrame {
                    VStack(spacing: 10) {
                        Text("Uygulamalar").font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            tile(nil)
                            tile("M")
                            tile(nil)
                            tile(nil)
                        }
                        Text("Marhilk").font(.system(size: 10, weight: .semibold))
                    }
                }
            case .ready:
                TVFrame {
                    VStack(spacing: 5) {
                        Spacer()
                        Text("Reyes: We need to move, now!")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.6))
                        (Text("Reyes: ").foregroundColor(.yellow).fontWeight(.bold) + Text("Hemen gitmeliyiz!"))
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .background(
            LinearGradient(colors: [Color(red: 0.11, green: 0.2, blue: 0.31), Color(red: 0.05, green: 0.08, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityHidden(true)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").foregroundStyle(.yellow)
    }

    private func device(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 84)
    }

    private func avatar(_ symbol: String, _ label: String, highlighted: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 42, height: 42)
                .background(Color(white: highlighted ? 0.3 : 0.18), in: Circle())
                .overlay(Circle().strokeBorder(highlighted ? Color.yellow : Color.clear, lineWidth: 2))
            Text(label).font(.system(size: 9)).foregroundStyle(highlighted ? Color.primary : Color.secondary)
        }
    }

    private func tile(_ letter: String?) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(letter == nil ? Color(white: 0.2) : Color(red: 0.11, green: 0.2, blue: 0.31))
            .frame(width: 46, height: 46)
            .overlay(Text(letter ?? "").font(.system(size: 22, weight: .heavy)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(letter == nil ? Color.clear : Color.yellow, lineWidth: 2))
    }
}

/// Televizyon çerçevesi: içine PS5 ya da TV ekranının taslağı çizilir.
private struct TVFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 3) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.04, green: 0.06, blue: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(white: 0.4), lineWidth: 2))
            Capsule().fill(Color(white: 0.4)).frame(width: 64, height: 4)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .padding(.vertical, 14)
    }
}

/// PS5 ayar menüsünün taslağı: yol, satırlar ve seçili satır.
private struct MenuMock: View {
    struct Row {
        var title: String
        var highlighted = false
        var isOn = false
    }

    let path: String
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(path).font(.system(size: 8)).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.title).font(.system(size: 10, weight: row.highlighted ? .semibold : .regular))
                    Spacer()
                    if row.isOn {
                        Capsule().fill(Color.green).frame(width: 22, height: 12)
                            .overlay(Circle().fill(.white).padding(2), alignment: .trailing)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(row.highlighted ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(row.highlighted ? Color.yellow : Color.clear, lineWidth: 1.5))
            }
        }
        .padding(12)
    }
}

/// Sony'nin kendi giriş sayfası. Parola uygulamaya gelmez; yalnız giriş sonunda
/// yönlenilen adresteki tek kullanımlık kod alınır. Oturum çerezleri saklanmaz.
private struct PSNLoginView: UIViewRepresentable {
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRedirect: onRedirect) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: PSNAccount.loginURL))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onRedirect: (URL) -> Void
        private var finished = false

        init(onRedirect: @escaping (URL) -> Void) { self.onRedirect = onRedirect }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, PSNAccount.isRedirect(url), !finished {
                finished = true
                decisionHandler(.cancel)
                onRedirect(url)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
