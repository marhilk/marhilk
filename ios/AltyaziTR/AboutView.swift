import SwiftUI

/// Hakkında: sürüm, bağlantılar ve uygulamanın içindeki açık kaynak kütüphanelerin lisansları.
///
/// PS5 bağlantısı chiaki-ng kütüphanesine dayanır (AGPL-3.0). Bu lisans, uygulamanın kaynak kodunun
/// kullanıcıya sunulmasını ve lisans metninin uygulamayla birlikte verilmesini şart koşar.
struct AboutView: View {
    private struct Component: Identifiable {
        let id: String          // paketteki lisans dosyasının adı (uzantısız)
        let name: String
        let license: String
        let purpose: String
    }

    private let components = [
        Component(id: "chiaki-ng-AGPL-3.0", name: "chiaki-ng", license: "GNU AGPL 3.0", purpose: "PS5'e Remote Play bağlantısı"),
        Component(id: "OpenSSL-Apache-2.0", name: "OpenSSL", license: "Apache 2.0", purpose: "PS5 bağlantısının şifrelenmesi"),
        Component(id: "jerasure-BSD", name: "Jerasure", license: "BSD", purpose: "Görüntü akışında hata düzeltme"),
        Component(id: "gf-complete-BSD", name: "GF-Complete", license: "BSD", purpose: "Görüntü akışında hata düzeltme"),
        Component(id: "nanopb-zlib", name: "nanopb", license: "zlib", purpose: "PS5 ile ileti alışverişi"),
    ]

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Sürüm")
                    Spacer()
                    Text(version).foregroundStyle(.secondary).monospacedDigit()
                }
                Link("Marhilk sitesi ve destek", destination: Links.site)
                Link("Gizlilik Politikası", destination: Links.privacy)
            }

            Section {
                Link("Kaynak kodu", destination: Links.source)
            } header: {
                Text("Açık kaynak")
            } footer: {
                Text("Marhilk açık kaynaklıdır ve GNU AGPL 3.0 lisansıyla sunulur. Kaynak kodunu inceleyebilir, değiştirebilir ve aynı lisansla paylaşabilirsin.")
            }

            Section {
                ForEach(components) { component in
                    NavigationLink {
                        LicenseText(file: component.id, title: component.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(component.name)
                                Spacer()
                                Text(component.license).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(component.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Kullanılan kütüphaneler")
            } footer: {
                Text("Marhilk bağımsız bir uygulamadır; Sony Interactive Entertainment ya da Samsung ile bağlantılı değildir ve onlar tarafından onaylanmamıştır. “PlayStation” ve “PS5”, Sony Interactive Entertainment Inc.'in ticari markalarıdır.")
            }
        }
        .navigationTitle("Hakkında")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Bir lisansın tam metni (uygulamayla birlikte gelir; internet gerekmez).
private struct LicenseText: View {
    let file: String
    let title: String

    private var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return "Lisans metni bulunamadı." }
        return content
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
