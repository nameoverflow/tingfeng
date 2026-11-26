#include <stdint.h>

void kagura_host_present(void *w, int64_t wc, void *s, int64_t sc) { (void)w; (void)wc; (void)s; (void)sc; }
void kagura_host_set_cursor(void *c) { (void)c; }
void kagura_host_focus_ime(void *id, void *v, double x, double y, double w, double h) { (void)id; (void)v; (void)x; (void)y; (void)w; (void)h; }
void kagura_host_blur_ime(void) {}
void kagura_host_play_sfx(void *s) { (void)s; }
void kagura_host_save_local(void *k, void *v) { (void)k; (void)v; }
void kagura_host_send_net(void *p) { (void)p; }
void kagura_host_connect_net(void *m, void *u, void *t) { (void)m; (void)u; (void)t; }
