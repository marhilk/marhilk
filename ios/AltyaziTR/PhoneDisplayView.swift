import AltyaziCore
import SwiftUI

/// Çeviriyi telefonun kendi ekranında, uzaktan okunacak büyüklükte gösterir.
///
/// Televizyonuna Marhilk kurulamayanlar (Samsung ve LG dışındaki markalar) içindir: telefon televizyonun
/// altına yatay konur, konuşmalar büyük yazıyla burada akar. Görev yazıları ve konuşma seçenekleri üstte,
/// "ekranı çevir"in sonucu ise oyun karesinin üstünde gösterilir.
///
/// Yazı, telefonun döndürme kilidi açık olsa da yatay durur: ekran döndürülmez, içerik çevrilir.
struct PhoneDisplayView: View {
    @EnvironmentObject private var model: AppModel
    /// 0 = yatay (sola yatık), 1 = yatay (sağa yatık), 2 = dik.
    @AppStorage("phoneDisplayTurn") private var turn = 0
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let sideways = turn != 2
            content
                .frame(width: sideways ? size.height : size.width, height: sideways ? size.width : size.height)
                .rotationEffect(.degrees(turn == 0 ? 90 : (turn == 1 ? -90 : 0)))
                .position(x: size.width / 2, y: size.height / 2)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { showControls() }
        .onAppear { showControls() }
        .onDisappear { hideTask?.cancel() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var content: some View {
        ZStack(alignment: .topTrailing) {
            if let frame = model.screenFrame, !model.screenItems.isEmpty {
                ScreenTranslationBoard(frame: frame, items: model.screenItems)
            } else {
                VStack(spacing: 14) {
                    overlays
                    Spacer(minLength: 0)
                    transcript
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            controls
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: controlsVisible)
        }
    }

    // MARK: Konuşmalar

    private var transcript: some View {
        VStack(spacing: 10) {
            let lines = model.lines.filter { $0.translation != nil }.suffix(3)
            if lines.isEmpty {
                Text(waitingText)
                    .font(.system(size: 20))
                    .foregroundStyle(Color(white: 0.3))
            }
            ForEach(Array(lines)) { line in
                if model.showOriginal, !line.source.isEmpty, line.source != line.translation {
                    Text(line.source)
                        .font(.system(size: 20 * model.fontScale))
                        .foregroundStyle(Color(white: 0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, -6)
                }
                (Text(line.speaker.map { "\($0)  " } ?? "").foregroundColor(speakerColor(line.speaker))
                 + Text(line.translation ?? "").foregroundColor(Color(hex: model.appearance.color.rawValue)))
                    .font(.system(size: 34 * model.fontScale, weight: model.appearance.bold ? .bold : .semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.lines.map(\.id))
    }

    private var waitingText: String {
        if model.locked { return "Abonelik gerekli" }
        switch model.connection {
        case .connected: return "Altyazı bekleniyor"
        case .working(let step): return step
        case .failed(let message): return message
        case .idle: return "PS5 bağlı değil"
        }
    }

    private func speakerColor(_ name: String?) -> Color {
        let palette = SubtitleAppearance.speakerPalette
        guard let name, model.appearance.speakerColors else { return Color(hex: palette[0]) }
        return Color(hex: palette[SubtitleAppearance.paletteIndex(for: name)])
    }

    // MARK: Görev yazıları ve seçenekler

    @ViewBuilder private var overlays: some View {
        HStack(alignment: .top, spacing: 18) {
            if !model.hintItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.hintItems.enumerated()), id: \.offset) { _, item in
                        OverlayText.make(item, size: 19)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Color(white: 0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.choiceItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.choiceItems.enumerated()), id: \.offset) { _, item in
                        OverlayText.make(item, size: 22)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.yellow.opacity(0.8), lineWidth: 1.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Denetimler

    private var controls: some View {
        HStack(spacing: 10) {
            control("text.viewfinder", label: model.screenState == nil ? "Ekranı çevir" : "Çeviriyi kaldır",
                    highlighted: model.screenState != nil) {
                model.toggleScreenTranslation()
            }
            control("rotate.right", label: "Yazıyı döndür", highlighted: false) {
                turn = (turn + 1) % 3
            }
            control("xmark", label: "Telefon ekranından çık", highlighted: false) {
                model.phoneDisplay = false
            }
        }
        .padding(14)
    }

    private func control(_ symbol: String, label: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showControls()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(highlighted ? Color.black : Color.white)
                .frame(width: 44, height: 44)
                .background(highlighted ? Color.yellow : Color(white: 0.18), in: Circle())
        }
        .accessibilityLabel(label)
    }

    /// Denetimler birkaç saniye görünür, sonra kaybolur; ekrana dokununca geri gelir.
    private func showControls() {
        controlsVisible = true
        model.noteInteraction()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { controlsVisible = false }
        }
    }
}

/// "Ekranı çevir"in sonucu: duraklatılmış oyun karesi ve üstünde, yerinde Türkçe yazılar.
/// Çift dokunuş yakınlaştırır; yakınken parmakla kaydırılır.
private struct ScreenTranslationBoard: View {
    let frame: CGImage
    let items: [ScreenItem]
    @State private var zoomed = false

    var body: some View {
        GeometryReader { proxy in
            let aspect = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
            let fitted = fit(aspect: aspect, in: proxy.size)
            let scale: CGFloat = zoomed ? 2 : 1
            let board = CGSize(width: fitted.width * scale, height: fitted.height * scale)
            let heights = Self.evenHeights(items)
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .frame(width: board.width, height: board.height)
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        label(item, lineHeight: heights[index], board: board)
                    }
                }
                .frame(width: board.width, height: board.height)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .scrollDisabled(!zoomed)
            .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.2)) { zoomed.toggle() } }
        }
    }

    private func fit(aspect: CGFloat, in size: CGSize) -> CGSize {
        size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }

    /// Aynı boydaki yazılar aynı boyda görünsün: okuyucu, kuyruklu harf içeren satırı ("g", "p") biraz
    /// yarı yarıya daha yüksek ölçer. Her öğe, boyu kendisine yakın öğelerin ortancasını alır.
    static func evenHeights(_ items: [ScreenItem]) -> [Double] {
        items.map { item in
            let near = items.map(\.lineHeight).filter { $0 >= item.lineHeight * 0.6 && $0 <= item.lineHeight / 0.6 }.sorted()
            return near.isEmpty ? item.lineHeight : near[near.count / 2]
        }
    }

    private func label(_ item: ScreenItem, lineHeight: Double, board: CGSize) -> some View {
        // Yazı, özgün satırın boyuna yakın ama okunacak kadar büyük; çeviri uzunsa kutusu sağa doğru büyür.
        let fontSize = max(11, lineHeight * board.height * 0.82)
        let width = max(item.width * board.width, 40)
        return Text(item.text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(item.lines > 1 ? nil : 1)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: item.lines <= 1, vertical: true)
            .frame(minWidth: width, maxWidth: item.lines > 1 ? width : nil, alignment: .leading)
            .padding(.horizontal, 3)
            .frame(minHeight: item.height * board.height)
            .background(Color.black)
            .offset(x: item.x * board.width - 3, y: item.y * board.height)
    }
}

/// Görev yazısı ya da seçenek metni; içindeki "[1]" işaretleri oyunun tuş simgeleriyle değiştirilir.
enum OverlayText {
    static func make(_ item: ScreenItem, size: CGFloat) -> Text {
        var result = Text("")
        var rest = Substring(item.text)
        while let open = rest.firstIndex(of: "[") {
            result = result + Text(String(rest[..<open]))
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "]"), let number = Int(after[..<close]) {
                if item.icons.indices.contains(number - 1), let image = icon(item.icons[number - 1], height: size * 1.15) {
                    result = result + Text(Image(uiImage: image)).baselineOffset(-size * 0.2)
                } else {
                    result = result + Text("◉")
                }
                rest = after[after.index(after: close)...]
            } else {
                result = result + Text("[")
                rest = after
            }
        }
        return result + Text(String(rest))
    }

    /// `data:image/png;base64,…` adresindeki simgeyi istenen yüksekliğe getirir.
    private static func icon(_ dataURL: String, height: CGFloat) -> UIImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = UIImage(data: data), image.size.height > 0 else { return nil }
        let size = CGSize(width: image.size.width * height / image.size.height, height: height)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

extension Color {
    /// "#rrggbb" biçimindeki renk.
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
