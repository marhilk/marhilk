#!/bin/bash
# chiaki-ng kütüphanesinin yerel ağ Remote Play için gereken kısmını
# Sources/CChiaki altına kopyalar. Kütüphaneyi güncellemek için:
#   git -C third_party/chiaki-ng pull --recurse-submodules && scripts/vendor-chiaki.sh <takion.pb dizini>
# Dışarıda bırakılanlar: internet üzerinden bağlantı (holepunch + sertifika
# indirme; curl/json-c/libevent/miniupnpc ister), FFmpeg ve Raspberry Pi çözücüleri.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/chiaki-ng"
DST="$ROOT/Sources/CChiaki"
PB="${1:?takion.pb.c ve takion.pb.h dosyalarının bulunduğu dizini verin}"

rm -rf "$DST/chiaki" "$DST/include/chiaki" "$DST/nanopb" "$DST/jerasure" "$DST/gf-complete" "$DST/proto"
mkdir -p "$DST/chiaki/remote" "$DST/include/chiaki/remote" "$DST/nanopb" "$DST/jerasure" "$DST/gf-complete" "$DST/proto"

cp "$SRC"/lib/src/*.c "$SRC"/lib/src/*.h "$DST/chiaki/"
rm "$DST"/chiaki/{ffmpegdecoder.c,pidecoder.c,aia.c,aia.h,aia_openssl.c}
cp "$SRC"/lib/src/remote/{rudp.c,rudpsendbuffer.c,stun.h} "$DST/chiaki/remote/"

cp "$SRC"/lib/include/chiaki/*.h "$DST/include/chiaki/"
rm "$DST"/include/chiaki/{ffmpegdecoder.h,pidecoder.h,config.h}
cp "$SRC"/lib/include/chiaki/remote/*.h "$DST/include/chiaki/remote/"
cat > "$DST/include/chiaki/config.h" <<'CFG'
// AltyazıTR için elle yazıldı (asıl projede CMake üretir).
#ifndef CHIAKI_CONFIG_H
#define CHIAKI_CONFIG_H
#define CHIAKI_LIB_ENABLE_OPUS 0
#define CHIAKI_LIB_ENABLE_PI_DECODER 0
#define CHIAKI_LIB_ENABLE_FFMPEG_DECODER 0
#endif
CFG

cp "$PB"/takion.pb.c "$PB"/takion.pb.h "$DST/proto/"
cp "$SRC"/third-party/nanopb/{pb.h,pb_common.c,pb_common.h,pb_decode.c,pb_decode.h,pb_encode.c,pb_encode.h} "$DST/nanopb/"
cp "$SRC"/third-party/jerasure/src/{galois.c,jerasure.c,reed_sol.c,cauchy.c,liberation.c} "$SRC"/third-party/jerasure/include/*.h "$DST/jerasure/"
cp "$SRC"/third-party/gf-complete/src/{gf.c,gf_wgen.c,gf_w4.c,gf_w8.c,gf_w16.c,gf_w32.c,gf_w64.c,gf_w128.c,gf_rand.c,gf_general.c,gf_cpu.c} "$SRC"/third-party/gf-complete/include/*.h "$DST/gf-complete/"

mkdir -p "$DST/licenses"
cp "$SRC/COPYING" "$DST/licenses/chiaki-ng-COPYING"
git -C "$SRC" rev-parse HEAD > "$DST/licenses/chiaki-ng-REVISION"
echo "Tamam: $(find "$DST" -name '*.c' | wc -l | tr -d ' ') C dosyası"
