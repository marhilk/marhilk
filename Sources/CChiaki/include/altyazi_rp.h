// AltyazıTR — Remote Play kütüphanesinin (chiaki) Swift'ten kullanılan dar arayüzü.
#ifndef ALTYAZI_RP_H
#define ALTYAZI_RP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct arp_session arp_session;

typedef enum {
	ARP_EVENT_CONNECTED = 0,
	ARP_EVENT_LOGIN_PIN_REQUEST = 1,
	ARP_EVENT_QUIT = 2
} arp_event_type;

/**
 * Sıkıştırılmış görüntü verisi (Annex-B). İlk çağrı akış başlığıdır (SPS/PPS), sonrakiler karelerdir.
 * @return kare çözülebildiyse true. false dönerse kütüphane PS5'ten yeni bir tam kare (anahtar kare) ister;
 *         çözücü bozulduğunda akışın toparlanması buna bağlıdır.
 */
typedef bool (*arp_video_cb)(const uint8_t *data, size_t size, void *user);
typedef void (*arp_event_cb)(arp_event_type type, bool is_error, const char *message, void *user);
/** level: 1 hata, 2 uyarı, 4 bilgi */
typedef void (*arp_log_cb)(int level, const char *message, void *user);
/** Oyun sesinin biçimi; ses paketlerinden önce bir kez gelir. */
typedef void (*arp_audio_header_cb)(int channels, int sample_rate, int frame_size, void *user);
/** Tek bir Opus ses paketi (frame_size örnek). */
typedef void (*arp_audio_frame_cb)(const uint8_t *data, size_t size, void *user);

typedef struct {
	uint8_t regist_key[16];
	uint8_t morning[16];
	uint8_t mac[6];
	char nickname[0x21];
} arp_registered_host;

/**
 * PS5'te "Cihaz Bağla" ekranındaki 8 haneli kodla eşleşir. Sonuç gelene kadar bekler.
 * @return 0 başarılı; aksi hâlde hata kodu (arp_error_string ile metne çevrilir)
 */
int arp_register(const char *host, const uint8_t account_id[8], uint32_t pin,
	arp_log_cb log_cb, void *user, arp_registered_host *out);

/** Dinlenme modundaki PS5'i uyandırır. */
int arp_wakeup(const char *host, const uint8_t regist_key[16]);

/**
 * Oturumu başlatır. Geri çağrılar kütüphanenin kendi iş parçacıklarından gelir.
 * @param height 720 ya da 1080
 * @param audio_header_cb, audio_frame_cb ikisi de verilirse PS5'ten oyun sesi de istenir; NULL ise yalnız görüntü
 * @return NULL ise *error_out hata kodunu taşır
 */
arp_session *arp_session_start(const char *host, const uint8_t regist_key[16], const uint8_t morning[16],
	const uint8_t account_id[8], int height, bool hevc,
	arp_video_cb video_cb, arp_event_cb event_cb, arp_log_cb log_cb,
	arp_audio_header_cb audio_header_cb, arp_audio_frame_cb audio_frame_cb,
	void *user, int *error_out);

/** PS5'ten hemen yeni bir tam kare ister (çözücü yeniden kurulduğunda). */
void arp_session_request_keyframe(arp_session *session);

/** Oturumu durdurur ve belleği bırakır. Geri çağrıların İÇİNDEN çağrılmamalıdır (kilitlenir). */
void arp_session_stop(arp_session *session);

const char *arp_error_string(int code);

#ifdef __cplusplus
}
#endif

#endif
