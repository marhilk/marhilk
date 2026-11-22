import AltyaziCore
import SwiftUI
import WebKit

/// Samsung televizyona kurulum: televizyonu bulur, hazır olup olmadığını denetler, Samsung hesabıyla
/// giriş alır ve TV uygulamasını bu telefondan kurar. Her aşama kendi durumunu gösterir.
struct SamsungInstallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLogin = false
    @State private var reinstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            televisionRow
            if model.samsung.host != nil {
                if model.samsung.appInstalled, !reinstall {
                    installedCard
                } else {
                    developerModeCard
                    if model.samsungReadyForInstall {
                        accountCard
                        installCard
                    }
                }
            }
            if let error = model.samsungError {
                StatusLine(text: error, color: .red, symbol: "exclamationmark.triangle.fill")
            }
        }
        .onAppear { model.checkSamsungTV() }
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                SamsungLoginView { token in
                    model.setSamsungToken(token)
                    showLogin = false
                }
                .navigationTitle("Samsung hesabı")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { showLogin = false } }
                }
            }
        }
    }

    // MARK: - Aşamalar

    @ViewBuilder private var televisionRow: some View {
        if model.samsung.searching {
            HStack(spacing: 10) { ProgressView(); Text("Samsung televizyon aranıyor…").foregroundStyle(.secondary) }
        } else if model.samsung.host == nil {
            StatusLine(text: "Samsung televizyon bulunamadı. Televizyon açık ve bu telefonla aynı Wi-Fi'da olmalı.",
                       color: .orange, symbol: "wifi.exclamationmark")
            Button("Yeniden ara") { model.checkSamsungTV() }
        } else {
            StatusLine(text: "\(model.samsung.name) bulundu.", color: .green, symbol: "checkmark.circle.fill")
        }
    }

    private var installedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusLine(text: "Marhilk bu televizyonda kurulu.", color: .green, symbol: "checkmark.circle.fill")
            if model.tvCount == 0 {
                Button {
                    model.openOnTV()
                } label: {
                    Label("Televizyonda aç", systemImage: "play.tv").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.tvLaunching)
                if let status = model.tvLaunchStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button("Yeniden kur ya da güncelle") { reinstall = true }
                .font(.footnote)
        }
    }

    @ViewBuilder private var developerModeCard: some View {
        if model.samsungReadyForInstall {
            StatusLine(text: "Televizyon bu telefondan kuruluma izin veriyor.", color: .green, symbol: "checkmark.circle.fill")
        } else {
            Card {
                Text("Televizyonda kurulum iznini aç").font(.headline)
                Text("Samsung, mağaza dışından kurulum için televizyonda bir ayar istiyor. Bir kez yapılır.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                step(1, "Kumandada **Ana Ekran** tuşuna bas, **Uygulamalar**'ı aç.")
                step(2, "Kumandada sırayla **1 2 3 4 5** tuşlarına bas. Sayı tuşu yoksa **123** tuşuyla ekran tuş takımını aç.")
                step(3, "Açılan pencerede **Developer mode**'u **On** yap.")
                step(4, "**Host PC IP** alanına bu telefonun adresini yaz ve **OK**'e bas:")
                Text(model.ipAddress)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                step(5, "Televizyonu **yeniden başlat**: kumandanın güç tuşunu, ekran kararıp Samsung logosu gelene kadar basılı tut.")
                if model.samsung.developerMode, model.samsung.developerIP != model.ipAddress {
                    Text("Televizyonda şu an kayıtlı adres: \(model.samsung.developerIP.isEmpty ? "yok" : model.samsung.developerIP). Bu telefonun adresi olmalı.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button {
                    model.checkSamsungTV()
                } label: {
                    Label("Yaptım, kontrol et", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.samsung.searching)
            }
        }
    }

    @ViewBuilder private var accountCard: some View {
        if model.samsungSignedIn {
            StatusLine(text: "Samsung hesabıyla giriş yapıldı.", color: .green, symbol: "checkmark.circle.fill")
        } else {
            Card {
                Text("Samsung hesabıyla giriş yap").font(.headline)
                Text(model.hasSamsungCertificates
                     ? "Daha önce izin belgesi alınmış. Bu televizyon için geçerliyse giriş gerekmez; doğrudan kurmayı deneyebilirsin."
                     : "Samsung, her televizyon için ayrı bir izin belgesi veriyor; bunu almak için Samsung hesabı gerekiyor. Hesabın yoksa aynı sayfadan ücretsiz açabilirsin. Giriş Samsung'un kendi sayfasında yapılır; parolan bu uygulamaya gelmez.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    showLogin = true
                } label: {
                    Label("Samsung hesabıyla giriş yap", systemImage: "person.crop.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var installCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.installOnSamsungTV()
            } label: {
                Label("Televizyona kur", systemImage: "arrow.down.to.line").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .disabled(model.samsungWork != nil || !(model.samsungSignedIn || model.hasSamsungCertificates))
            if let work = model.samsungWork {
                HStack(spacing: 10) { ProgressView(); Text(work).font(.footnote).foregroundStyle(.secondary) }
                Text("Kurulum bitene kadar uygulamadan çıkma.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Color.yellow, in: Circle())
            Text(LocalizedStringKey(text)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StatusLine: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Samsung'un kendi giriş sayfası. Parola uygulamaya gelmez; giriş sonunda Samsung'un bu cihaza
/// (localhost) gönderdiği tek kullanımlık erişim bilgisi alınır. Oturum çerezleri saklanmaz.
private struct SamsungLoginView: UIViewRepresentable {
    let onToken: (SamsungToken) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Yedek yol: geri dönüş formu yerel dinleyiciye ulaşamazsa (tarayıcı http'ye göndermeyi keserse)
        // formun içeriği sayfadan doğrudan alınır.
        let script = """
        (function () {
          function report(form) {
            try {
              if (form && form.action && form.action.indexOf('localhost') >= 0) {
                window.webkit.messageHandlers.marhilk.postMessage(new URLSearchParams(new FormData(form)).toString());
              }
            } catch (e) {}
          }
          document.addEventListener('submit', function (event) { report(event.target); }, true);
          var original = HTMLFormElement.prototype.submit;
          HTMLFormElement.prototype.submit = function () { report(this); return original.apply(this, arguments); };
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController.add(context.coordinator, name: "marhilk")
        context.coordinator.startListening()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: SamsungToken.loginURL))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "marhilk")
        coordinator.stopListening()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onToken: (SamsungToken) -> Void
        private var server: SamsungLoginCallbackServer?
        private var delivered = false

        init(onToken: @escaping (SamsungToken) -> Void) { self.onToken = onToken }

        func startListening() {
            let server = SamsungLoginCallbackServer { [weak self] token in
                DispatchQueue.main.async { self?.deliver(token) }
            }
            try? server.start()
            self.server = server
        }

        func stopListening() {
            server?.stop()
            server = nil
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String, let token = SamsungToken.parse(callbackBody: body) else { return }
            deliver(token)
        }

        private func deliver(_ token: SamsungToken) {
            guard !delivered else { return }
            delivered = true
            onToken(token)
        }
    }
}
