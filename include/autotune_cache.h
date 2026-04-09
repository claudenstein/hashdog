/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 */

#ifndef HC_AUTOTUNE_CACHE_H
#define HC_AUTOTUNE_CACHE_H

#include <errno.h>
#include <search.h>

#define MAX_AUTOTUNE_CACHE      10000
#define AUTOTUNE_CACHE_FILENAME "hashcat.autotune"
#define AUTOTUNE_CACHE_VERSION  (0x6863617574303000 | 0x01)

int  sort_by_autotune_cache  (const void *s1, const void *s2);

int  autotune_cache_init     (hashcat_ctx_t *hashcat_ctx);
void autotune_cache_destroy  (hashcat_ctx_t *hashcat_ctx);
void autotune_cache_read     (hashcat_ctx_t *hashcat_ctx);
int  autotune_cache_write    (hashcat_ctx_t *hashcat_ctx);
bool autotune_cache_lookup   (hashcat_ctx_t *hashcat_ctx, const hc_device_param_t *device_param, u32 *out_kernel_accel, u32 *out_kernel_loops, u32 *out_kernel_threads);
void autotune_cache_store    (hashcat_ctx_t *hashcat_ctx, const hc_device_param_t *device_param, u32 kernel_accel, u32 kernel_loops, u32 kernel_threads);

#endif // HC_AUTOTUNE_CACHE_H
