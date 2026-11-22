#!/bin/sh
# tv-tizen/ altındaki TV sayfasını uygulamanın içine gömer (Sources/AltyaziCore/TVPageAssets.swift).
# Telefon bu sayfayı yerel ağda sunar; LG televizyonlar onu kendi tarayıcılarında açar.
# tv-tizen/ içindeki index.html, main.js ya da style.css değişince yeniden çalıştırın.
set -eu
cd "$(dirname "$0")/.."
out=Sources/AltyaziCore/TVPageAssets.swift
# TV uygulamasının sürümü: dosyalarının özeti. Bir dosya değişince sürüm de değişir.
build=$(cat tv-tizen/index.html tv-tizen/main.js tv-tizen/style.css tv-tizen/config.xml | shasum -a 256 | cut -c1-12)
{
    echo "// BU DOSYA ÜRETİLİR — elle düzenlemeyin. Kaynak: tv-tizen/ · Üreten: scripts/sync-tv-page.sh"
    echo
    echo "enum TVPageAssets {"
    for pair in indexHTML:index.html mainJS:main.js styleCSS:style.css; do
        name=${pair%%:*}; file=${pair#*:}
        if grep -q '"""#' "tv-tizen/$file"; then echo "tv-tizen/$file içinde \"\"\"# geçiyor; gömülemez." >&2; exit 1; fi
        echo "    static let $name = #\"\"\""
        # main.js içindeki sürüm yer tutucusu, gömülen kopyada gerçek sürümle değiştirilir.
        sed "s/var TV_BUILD = 'gelistirme';/var TV_BUILD = '$build';/" "tv-tizen/$file"
        echo    # kapanış işaretinden önceki satır sonu dizgiye girmez; dosyanın kendi satır sonu korunsun
        echo "\"\"\"#"
        echo
    done
    # Paketin geri kalanı: telefon, TV uygulamasını bu dosyalardan kendisi imzalayıp televizyona kurar.
    echo "    static let configXML = #\"\"\""
    cat tv-tizen/config.xml
    echo
    echo "\"\"\"#"
    echo
    echo "    /// Gömülü TV uygulamasının sürümü (dosyalarının özeti)."
    echo "    static let build = \"$build\""
    echo
    echo "    static let iconPNGBase64 = \"$(base64 -i tv-tizen/icon.png | tr -d '\n')\""
    echo "}"
} > "$out"
echo "yazıldı: $out"
