import StoreKit
import SwiftUI

/// Abonelik: ürünleri App Store'dan yükler, satın almayı ve abonelik durumunu izler.
///
/// Abonelik yoksa çeviri durur; kurulum ve ayarlar açık kalır. İlk 30 günü Apple'ın "tanıtım teklifi"
/// yönetir: kullanıcı aboneliği başlatır, 30 gün ücret alınmaz, iptal etmezse ücretli döneme geçer.
@MainActor
final class Store: ObservableObject {
    static let monthlyID = "com.marhilk.app.monthly"
    static let yearlyID = "com.marhilk.app.yearly"
    static let productIDs: Set<String> = [monthlyID, yearlyID]

    /// Yıllık önce (önerilen), sonra aylık.
    @Published private(set) var products: [Product] = []
    @Published private(set) var subscribed = false
    /// Ürünler ve abonelik durumu henüz öğrenilmedi.
    @Published private(set) var loading = true
    @Published private(set) var purchasing = false
    @Published var message: String?
    /// Kullanıcı ücretsiz denemeye hak kazanıyor mu (daha önce abone olmamışsa)?
    @Published private(set) var trialAvailable = false

    /// Çeviri kullanılabilir mi? Ürünler App Store'dan alınamıyorsa (satın alma mümkün değilse)
    /// kullanıcı kilitlenmez: satın alamayacağı bir şey için uygulamayı kapatmak doğru olmaz.
    var unlocked: Bool { subscribed || loading || products.isEmpty }

    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await _ in Transaction.updates {
                await self?.refreshEntitlement()
            }
        }
        Task { await refresh() }
    }

    deinit { updates?.cancel() }

    func refresh() async {
        let loaded = (try? await Product.products(for: Self.productIDs)) ?? []
        products = loaded.sorted { first, _ in first.id == Self.yearlyID }
        if let subscription = products.first?.subscription {
            trialAvailable = await subscription.isEligibleForIntroOffer && subscription.introductoryOffer != nil
        }
        await refreshEntitlement()
        loading = false
    }

    func refreshEntitlement() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID),
               transaction.revocationDate == nil {
                active = true
            }
        }
        subscribed = active
    }

    func purchase(_ product: Product) async {
        guard !purchasing else { return }
        purchasing = true
        message = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlement()
                } else {
                    message = "Satın alma doğrulanamadı."
                }
            case .pending:
                message = "Satın alma onay bekliyor (ör. aile onayı). Onaylanınca abonelik kendiliğinden açılır."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "Satın alma tamamlanamadı: \(error.localizedDescription)"
        }
    }

    /// Daha önce yapılmış satın alımları geri yükler (telefon değişince ya da uygulama yeniden kurulunca).
    func restore() async {
        message = nil
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !subscribed { message = "Bu Apple hesabında etkin bir Marhilk aboneliği bulunamadı." }
        } catch {
            message = "Geri yüklenemedi: \(error.localizedDescription)"
        }
    }
}

/// Uygulamanın dışarıya verdiği bağlantılar.
enum Links {
    /// Apple'ın standart kullanım koşulları (abonelikli uygulamalarda gösterilmesi zorunlu).
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// Gizlilik politikası (kaynağı: yayin/site/gizlilik/).
    static let privacy = URL(string: "https://marhilk.github.io/gizlilik/")!
    /// Tanıtım ve destek sayfası.
    static let site = URL(string: "https://marhilk.github.io/")!
    /// Uygulamanın kaynak kodu (AGPL gereği kullanıcıya sunulur). Depo, uygulama mağazaya çıkmadan önce herkese açılmalıdır.
    static let source = URL(string: "https://github.com/marhilk/marhilk")!
}
