// AltyazıTR: asıl aia.h (eksik ara sertifikayı internetten indirme) curl ister
// ve yalnız internet üzerinden bağlantıda kullanılır. Kütüphanenin başlatma
// kodu yalnız chiaki_aia_init() çağırdığı için burada o kadarı tanımlanır.
#ifndef CHIAKI_AIA_H
#define CHIAKI_AIA_H

#include <chiaki/common.h>

ChiakiErrorCode chiaki_aia_init(void);
void chiaki_aia_fini(void);

#endif
