# Marhilk

PS5 oyunlarındaki İngilizce altyazıyı anında Türkçeye çevirip televizyonda gösterir.

## Nasıl çalışır

1. iPhone, aynı Wi-Fi ağındaki PS5'e Remote Play ile bağlanır ve görüntüyü yalnızca izler (oyuna girdi göndermez).
2. Altyazı, telefonda Apple Vision ile okunur ve Apple'ın cihaz üstü çevirisiyle Türkçeye çevrilir. Görüntü ve yazı telefondan dışarı çıkmaz.
3. Çeviri yerel ağ üzerinden televizyondaki Marhilk sayfasına gönderilir; TV, oyun görüntüsünün üstüne akan konuşma dökümü olarak basar.

Samsung (Tizen) televizyonlarda TV uygulaması telefondan kurulur; bilgisayar gerekmez. LG (webOS) için tarayıcı yolu yazıldı, henüz gerçek cihazda denenmedi.

Tanıtım ve destek: <https://marhilk.github.io/> · Gizlilik: <https://marhilk.github.io/gizlilik/>

İsteğe bağlı "ekranı çevir" özelliği, kullanıcının kendi Anthropic API anahtarıyla duraklatılmış ekrandaki tüm yazıları çevirir.

## Dizinler

| Dizin | İçerik |
|---|---|
| `Sources/AltyaziCore` | Yazı okuma, replik takibi, çeviri hattı, TV sunucusu |
| `Sources/RemotePlayKit` | PS5 keşfi, eşleşme, oturum, görüntü ve ses çözme |
| `Sources/CChiaki` | [chiaki-ng](https://github.com/streetpea/chiaki-ng) kütüphanesinin gömülü kopyası ve dar C arayüzü |
| `Sources/altyazi-mac` | Mac'te deneme için komut satırı aracı |
| `ios/` | iPhone uygulaması |
| `tv-tizen/` | Samsung (Tizen) TV uygulaması |

## Derleme

```sh
swift test                      # çekirdek testler
open ios/AltyaziTR.xcodeproj    # iPhone uygulaması (Xcode 27, iOS 18+)
```

TV sayfası (`tv-tizen/`) uygulamanın içine gömülüdür; değiştirince `scripts/sync-tv-page.sh` çalıştırılır. Telefon, sayfayı Samsung televizyona kendisi imzalayıp kurar.

Sorun bildirimi ve öneriler: <https://github.com/marhilk/marhilk.github.io/issues>

## Lisans

GNU Affero General Public License v3.0 — bkz. [LICENSE](LICENSE).
Remote Play bağlantısı chiaki-ng (AGPL-3.0) üzerine kuruludur; üçüncü taraf lisansları `Sources/CChiaki/licenses` altındadır.

Bu proje Sony Interactive Entertainment ile bağlantılı değildir ve onun tarafından onaylanmamıştır. "PlayStation" ve "PS5", Sony Interactive Entertainment Inc.'in ticari markalarıdır.
