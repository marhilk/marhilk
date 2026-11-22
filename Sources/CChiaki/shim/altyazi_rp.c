#include "altyazi_rp.h"

#include <netinet/in.h>
#include <arpa/inet.h>

#include <chiaki/common.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define ARP_LOG_MASK (CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR)

static pthread_once_t lib_once = PTHREAD_ONCE_INIT;
static ChiakiErrorCode lib_init_result = CHIAKI_ERR_SUCCESS;
static void lib_init(void) { lib_init_result = chiaki_lib_init(); }

typedef struct {
	arp_log_cb cb;
	void *user;
} arp_log_ctx;

static void log_trampoline(ChiakiLogLevel level, const char *msg, void *user)
{
	arp_log_ctx *ctx = user;
	if(ctx && ctx->cb)
		ctx->cb((int)level, msg, ctx->user);
}

const char *arp_error_string(int code)
{
	return chiaki_error_string((ChiakiErrorCode)code);
}

// ---------- Eşleşme ----------

typedef struct {
	bool success;
	ChiakiRegisteredHost host;
} arp_regist_result;

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	arp_regist_result *result = user;
	if(event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host)
	{
		result->success = true;
		result->host = *event->registered_host;
	}
}

int arp_register(const char *host, const uint8_t account_id[8], uint32_t pin,
	arp_log_cb log_cb, void *user, arp_registered_host *out)
{
	pthread_once(&lib_once, lib_init);
	if(lib_init_result != CHIAKI_ERR_SUCCESS)
		return lib_init_result;

	arp_log_ctx log_ctx = { log_cb, user };
	ChiakiLog log;
	chiaki_log_init(&log, ARP_LOG_MASK, log_trampoline, &log_ctx);

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = CHIAKI_TARGET_PS5_1;
	info.host = host;
	info.broadcast = false;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;

	arp_regist_result result;
	memset(&result, 0, sizeof(result));

	ChiakiRegist regist;
	ChiakiErrorCode err = chiaki_regist_start(&regist, &log, &info, regist_cb, &result);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	chiaki_regist_fini(&regist); // iş parçacığı bitene kadar bekler

	if(!result.success)
		return CHIAKI_ERR_UNKNOWN;

	memset(out, 0, sizeof(*out));
	memcpy(out->regist_key, result.host.rp_regist_key, sizeof(out->regist_key));
	memcpy(out->morning, result.host.rp_key, sizeof(out->morning));
	memcpy(out->mac, result.host.server_mac, sizeof(out->mac));
	memcpy(out->nickname, result.host.server_nickname, sizeof(result.host.server_nickname));
	return 0;
}

int arp_wakeup(const char *host, const uint8_t regist_key[16])
{
	pthread_once(&lib_once, lib_init);
	char key[17];
	memcpy(key, regist_key, 16);
	key[16] = '\0';
	uint64_t credential = strtoull(key, NULL, 16);
	return chiaki_discovery_wakeup(NULL, NULL, host, credential, true);
}

// ---------- Oturum ----------

struct arp_session {
	ChiakiSession session;
	ChiakiLog log;
	arp_log_ctx log_ctx;
	arp_video_cb video_cb;
	arp_event_cb event_cb;
	arp_audio_header_cb audio_header_cb;
	arp_audio_frame_cb audio_frame_cb;
	void *user;
};

static void audio_header_trampoline(ChiakiAudioHeader *header, void *user)
{
	arp_session *s = user;
	if(s->audio_header_cb && header)
		s->audio_header_cb(header->channels, (int)header->rate, (int)header->frame_size, s->user);
}

static void audio_frame_trampoline(uint8_t *buf, size_t buf_size, void *user)
{
	arp_session *s = user;
	if(s->audio_frame_cb)
		s->audio_frame_cb(buf, buf_size, s->user);
}

static bool video_trampoline(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	arp_session *s = user;
	if(s->video_cb)
		return s->video_cb(buf, buf_size, s->user);
	return true;
}

static void event_trampoline(ChiakiEvent *event, void *user)
{
	arp_session *s = user;
	if(!s->event_cb)
		return;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			s->event_cb(ARP_EVENT_CONNECTED, false, "", s->user);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			s->event_cb(ARP_EVENT_LOGIN_PIN_REQUEST, event->login_pin_request.pin_incorrect, "", s->user);
			break;
		case CHIAKI_EVENT_QUIT:
		{
			const char *message = event->quit.reason_str ? event->quit.reason_str : chiaki_quit_reason_string(event->quit.reason);
			s->event_cb(ARP_EVENT_QUIT, chiaki_quit_reason_is_error(event->quit.reason), message ? message : "", s->user);
			break;
		}
		default:
			break;
	}
}

arp_session *arp_session_start(const char *host, const uint8_t regist_key[16], const uint8_t morning[16],
	const uint8_t account_id[8], int height, bool hevc,
	arp_video_cb video_cb, arp_event_cb event_cb, arp_log_cb log_cb,
	arp_audio_header_cb audio_header_cb, arp_audio_frame_cb audio_frame_cb,
	void *user, int *error_out)
{
	int dummy;
	if(!error_out)
		error_out = &dummy;
	pthread_once(&lib_once, lib_init);
	if(lib_init_result != CHIAKI_ERR_SUCCESS)
	{
		*error_out = lib_init_result;
		return NULL;
	}

	arp_session *s = calloc(1, sizeof(arp_session));
	if(!s)
	{
		*error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	bool want_audio = audio_header_cb && audio_frame_cb;
	s->video_cb = video_cb;
	s->event_cb = event_cb;
	s->audio_header_cb = audio_header_cb;
	s->audio_frame_cb = audio_frame_cb;
	s->user = user;
	s->log_ctx.cb = log_cb;
	s->log_ctx.user = user;
	chiaki_log_init(&s->log, ARP_LOG_MASK, log_trampoline, &s->log_ctx);

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = true;
	info.host = host;
	memcpy(info.regist_key, regist_key, sizeof(info.regist_key));
	memcpy(info.morning, morning, sizeof(info.morning));
	memcpy(info.psn_account_id, account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	chiaki_connect_video_profile_preset(&info.video_profile,
		height >= 1080 ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p : CHIAKI_VIDEO_RESOLUTION_PRESET_720p,
		CHIAKI_VIDEO_FPS_PRESET_30);
	info.video_profile.codec = hevc ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = false;
	info.audio_video_disabled = want_audio ? CHIAKI_NONE_DISABLED : CHIAKI_AUDIO_DISABLED;
	info.auto_regist = false;
	info.holepunch_session = NULL;
	info.rudp_sock = NULL;
	info.packet_loss_max = 0.05;
	info.enable_idr_on_fec_failure = true;

	ChiakiErrorCode err = chiaki_session_init(&s->session, &info, &s->log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		*error_out = err;
		free(s);
		return NULL;
	}
	chiaki_session_set_event_cb(&s->session, event_trampoline, s);
	chiaki_session_set_video_sample_cb(&s->session, video_trampoline, s);
	if(want_audio)
	{
		// Kütüphane Opus çözücüsüz derlendiği için ses paketleri sıkıştırılmış (Opus) olarak gelir.
		ChiakiAudioSink sink = { .user = s, .header_cb = audio_header_trampoline, .frame_cb = audio_frame_trampoline };
		chiaki_session_set_audio_sink(&s->session, &sink);
	}

	err = chiaki_session_start(&s->session);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		*error_out = err;
		chiaki_session_fini(&s->session);
		free(s);
		return NULL;
	}
	*error_out = 0;
	return s;
}

void arp_session_request_keyframe(arp_session *s)
{
	if(s)
		chiaki_session_request_idr(&s->session);
}

void arp_session_stop(arp_session *s)
{
	if(!s)
		return;
	chiaki_session_stop(&s->session);
	chiaki_session_join(&s->session);
	chiaki_session_fini(&s->session);
	free(s);
}
