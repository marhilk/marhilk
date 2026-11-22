import StoreKit
import SwiftUI

/// Abonelik ekranı: ne alındığı, planlar, ücretsiz deneme ve Apple'ın zorunlu tuttuğu bilgiler.
struct PaywallView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String = Store.yearlyID

    /// Gösterilecek plan (gerçek ürün ya da, ekran görüntüsü için, örnek veri).
    private struct Plan: Identifiable {
        let id: String
        let title: String
        let price: String
        let detail: String
        let badge: String?
        let product: Product?
    }

    private var plans: [Plan] {
        if !store.products.isEmpty {
            let monthly = store.products.first { $0.id == Store.monthlyID }
            return store.products.map { product in
                let yearly = product.id == Store.yearlyID
                var badge: String?
                if yearly, let monthly, monthly.price > 0 {
                    // Yıllık plan, on iki aylık ödemeye göre ne kadar ucuz?
                    let saving = 1 - (product.price / (monthly.price * 12))
                    let percent = Int((NSDecimalNumber(decimal: saving).doubleValue * 100).rounded())
                    if percent > 0 { badge = "%\(percent) indirimli" }
                }
                return Plan(id: product.id, title: yearly ? "Yıllık" : "Aylık", price: product.displayPrice,
                            detail: yearly ? "yılda bir ödenir" : "her ay ödenir", badge: badge, product: product)
            }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugPaywall") {
            return [Plan(id: Store.yearlyID, title: "Yıllık", price: "₺599,99", detail: "yılda bir ödenir", badge: "%37 indirimli", product: nil),
                    Plan(id: Store.monthlyID, title: "Aylık", price: "₺79,99", detail: "her ay ödenir", badge: nil, product: nil)]
        }
        #endif
        return []
    }

    private var trial: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugPaywall") { return true }
        #endif
        return store.trialAvailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    benefits
                    if plans.isEmpty {
                        unavailable
                    } else {
                        VStack(spacing: 10) {
                            ForEach(plans) { plan in planRow(plan) }
                        }
                        purchaseButton
                    }
                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
            .onChange(of: store.subscribed) { _, subscribed in
                if subscribed { dismiss() }
            }
        }
        .tint(.yellow)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
                .padding(.top, 8)
            Text(trial ? "30 gün ücretsiz dene" : "Marhilk aboneliği")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("PS5 oyunlarını Türkçe altyazıyla oyna.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit("bolt.fill", "Anlık çeviri: replik geldiği anda Türkçesi televizyonda")
            benefit("list.bullet.rectangle", "Görev ve ipucu yazıları, tuş simgeleriyle birlikte")
            benefit("lock.iphone", "Telefon kilitliyken de çalışır")
            benefit("hand.raised.fill", "Çeviri telefonunda yapılır; veri toplanmaz")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.yellow).frame(width: 22)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planRow(_ plan: Plan) -> some View {
        Button {
            selected = plan.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected == plan.id ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected == plan.id ? Color.yellow : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(plan.title).font(.headline)
                        if let badge = plan.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.yellow, in: Capsule())
                        }
                    }
                    Text(plan.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(plan.price).font(.headline.monospacedDigit())
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected == plan.id ? Color.yellow : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == plan.id ? .isSelected : [])
    }

    private var purchaseButton: some View {
        VStack(spacing: 8) {
            Button {
                guard let product = plans.first(where: { $0.id == selected })?.product else { return }
                Task { await store.purchase(product) }
            } label: {
                Group {
                    if store.purchasing {
                        ProgressView().tint(.black)
                    } else {
                        Text(trial ? "Ücretsiz denemeyi başlat" : "Abone ol")
                    }
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.yellow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(store.purchasing)
            if let plan = plans.first(where: { $0.id == selected }) {
                Text(trial ? "30 gün ücretsiz, sonra \(plan.price) (\(plan.detail)). İstediğin zaman iptal edebilirsin."
                           : "\(plan.price), \(plan.detail). İstediğin zaman iptal edebilirsin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            if store.loading {
                ProgressView()
            } else {
                Text("Abonelik seçenekleri şu an App Store'dan alınamıyor. İnternet bağlantını kontrol edip yeniden dene.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Yeniden dene") { Task { await store.refresh() } }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button("Satın alımları geri yükle") { Task { await store.restore() } }
                .font(.subheadline)
            Text("Abonelik, dönem bitmeden en az 24 saat önce iptal edilmezse kendiliğinden yenilenir. Ücret Apple hesabından alınır. Aboneliğini Ayarlar › Apple hesabın › Abonelikler bölümünden yönetebilir ve iptal edebilirsin.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Link("Kullanım Koşulları", destination: Links.terms)
                Link("Gizlilik Politikası", destination: Links.privacy)
            }
            .font(.caption)
        }
    }
}
