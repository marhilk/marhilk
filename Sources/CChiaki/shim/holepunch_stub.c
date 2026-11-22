// AltyazıTR: internet üzerinden (PSN aracılığıyla) Remote Play bu uygulamada
// yok; yalnız ev ağındaki PS5'e bağlanılır. Asıl holepunch.c curl, json-c,
// libevent ve miniupnpc ister; yerine her işlevi "desteklenmiyor" döndüren
// bu dosya derlenir. Oturum bu yola yalnız holepunch_session verilirse girer,
// biz hiç vermiyoruz.
#include <netinet/in.h>
#include <arpa/inet.h>
#include <chiaki/remote/holepunch.h>
#include <string.h>

ChiakiErrorCode chiaki_holepunch_list_devices(const char *psn_oauth2_token, ChiakiHolepunchConsoleType console_type,
	ChiakiHolepunchDeviceInfo **devices, size_t *device_count, ChiakiLog *log)
{
	if(devices) *devices = NULL;
	if(device_count) *device_count = 0;
	return CHIAKI_ERR_UNKNOWN;
}

void chiaki_holepunch_free_device_list(ChiakiHolepunchDeviceInfo **devices) {}

ChiakiHolepunchRegistInfo chiaki_get_regist_info(ChiakiHolepunchSession session)
{
	ChiakiHolepunchRegistInfo info;
	memset(&info, 0, sizeof(info));
	return info;
}

void chiaki_get_ps_selected_addr(ChiakiHolepunchSession session, char *ps_ip) { if(ps_ip) ps_ip[0] = '\0'; }
uint16_t chiaki_get_ps_ctrl_port(ChiakiHolepunchSession session) { return 0; }
chiaki_socket_t *chiaki_get_holepunch_sock(ChiakiHolepunchSession session, ChiakiHolepunchPortType type) { return NULL; }
bool chiaki_holepunch_session_get_stun_allocation(ChiakiHolepunchSession session, int32_t *allocation_increment, bool *random_allocation) { return false; }
ChiakiErrorCode chiaki_holepunch_generate_client_device_uid(char *out, size_t *out_size) { return CHIAKI_ERR_UNKNOWN; }
ChiakiHolepunchSession chiaki_holepunch_session_init(const char *psn_oauth2_token, ChiakiLog *log) { return NULL; }
void chiaki_holepunch_session_force_port_guessing(ChiakiHolepunchSession session, bool enabled) {}
void chiaki_holepunch_session_set_ws_fqdn_override(ChiakiHolepunchSession session, const char *fqdn) {}
void chiaki_holepunch_session_set_port_guessing_ports(ChiakiHolepunchSession session, int count) {}
void chiaki_holepunch_session_set_port_guessing_socks(ChiakiHolepunchSession session, int count) {}
ChiakiErrorCode chiaki_holepunch_session_create(ChiakiHolepunchSession session) { return CHIAKI_ERR_UNKNOWN; }
ChiakiErrorCode chiaki_holepunch_session_start(ChiakiHolepunchSession session, const uint8_t *console_uid, ChiakiHolepunchConsoleType console_type) { return CHIAKI_ERR_UNKNOWN; }
ChiakiErrorCode chiaki_holepunch_upnp_discover(ChiakiHolepunchSession session) { return CHIAKI_ERR_UNKNOWN; }
ChiakiErrorCode holepunch_session_create_offer(ChiakiHolepunchSession session) { return CHIAKI_ERR_UNKNOWN; }
ChiakiErrorCode chiaki_holepunch_session_punch_hole(ChiakiHolepunchSession session, ChiakiHolepunchPortType port_type) { return CHIAKI_ERR_UNKNOWN; }
void chiaki_holepunch_main_thread_cancel(ChiakiHolepunchSession session, bool stop_thread) {}
void chiaki_holepunch_session_fini(ChiakiHolepunchSession session) {}

#include "aia.h"
ChiakiErrorCode chiaki_aia_init(void) { return CHIAKI_ERR_SUCCESS; }
void chiaki_aia_fini(void) {}
