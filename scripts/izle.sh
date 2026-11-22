#!/bin/bash
# Çeviri hattını çalıştırır ve beklenmedik biçimde kapanırsa (ör. sistemin yazı okuyucusu
# kilitlenirse) yeniden başlatır. PS5 önceki bağlantıyı ~10 sn bırakmadığı için arada beklenir.
cd "$(dirname "$0")/.."
while true; do
  .build/debug/altyazi-mac ps5 izle
  code=$?
  # 0 = kullanıcı durdurdu ya da PS5 oturumu düzgün kapattı; yeniden bağlanmayı sürdür ama kısa bekle.
  echo "[bekçi] program kapandı (kod $code); 14 saniye sonra yeniden bağlanılacak."
  sleep 14
done
