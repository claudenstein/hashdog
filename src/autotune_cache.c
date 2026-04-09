/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 */

#include "common.h"
#include "types.h"
#include "memory.h"
#include "bitops.h"
#include "event.h"
#include "locking.h"
#include "shared.h"
#include "autotune_cache.h"

int sort_by_autotune_cache (const void *s1, const void *s2)
{
  return memcmp (s1, s2, AUTOTUNE_CACHE_KEY_SIZE);
}

static void autotune_cache_fill_key (autotune_cache_entry_t *entry, hashcat_ctx_t *hashcat_ctx, const hc_device_param_t *device_param)
{
  const hashconfig_t *hashconfig = hashcat_ctx->hashconfig;
  const hashes_t     *hashes     = hashcat_ctx->hashes;

  memset (entry, 0, sizeof (autotune_cache_entry_t));

  if (device_param->device_name)
  {
    strncpy (entry->device_name, device_param->device_name, sizeof (entry->device_name) - 1);
  }

  entry->hash_mode          = hashconfig->hash_mode;
  entry->attack_exec        = hashconfig->attack_exec;
  entry->device_processors  = device_param->device_processors;
  entry->kernel_accel_min   = device_param->kernel_accel_min;
  entry->kernel_accel_max   = device_param->kernel_accel_max;
  entry->kernel_loops_min   = device_param->kernel_loops_min;
  entry->kernel_loops_max   = device_param->kernel_loops_max;
  entry->kernel_threads_min = device_param->kernel_threads_min;
  entry->kernel_threads_max = device_param->kernel_threads_max;

  if (hashes && hashes->salts_buf)
  {
    entry->salt_iter = hashes->salts_buf->salt_iter;
  }
}

int autotune_cache_init (hashcat_ctx_t *hashcat_ctx)
{
  autotune_cache_ctx_t *autotune_cache_ctx = hashcat_ctx->autotune_cache_ctx;
  folder_config_t      *folder_config      = hashcat_ctx->folder_config;
  user_options_t       *user_options       = hashcat_ctx->user_options;

  autotune_cache_ctx->enabled = false;

  if (user_options->usage        > 0)    return 0;
  if (user_options->backend_info > 0)    return 0;
  if (user_options->hash_info    > 0)    return 0;
  if (user_options->version      == true) return 0;

  autotune_cache_ctx->enabled = true;
  autotune_cache_ctx->base    = (autotune_cache_entry_t *) hccalloc (MAX_AUTOTUNE_CACHE, sizeof (autotune_cache_entry_t));
  autotune_cache_ctx->cnt     = 0;

  hc_asprintf (&autotune_cache_ctx->filename, "%s/%s", folder_config->profile_dir, AUTOTUNE_CACHE_FILENAME);

  return 0;
}

void autotune_cache_destroy (hashcat_ctx_t *hashcat_ctx)
{
  autotune_cache_ctx_t *autotune_cache_ctx = hashcat_ctx->autotune_cache_ctx;

  if (autotune_cache_ctx->enabled == false) return;

  hcfree (autotune_cache_ctx->filename);
  hcfree (autotune_cache_ctx->base);

  memset (autotune_cache_ctx, 0, sizeof (autotune_cache_ctx_t));
}

void autotune_cache_read (hashcat_ctx_t *hashcat_ctx)
{
  autotune_cache_ctx_t *autotune_cache_ctx = hashcat_ctx->autotune_cache_ctx;

  if (autotune_cache_ctx->enabled == false) return;

  HCFILE fp;

  if (hc_fopen (&fp, autotune_cache_ctx->filename, "rb") == false)
  {
    // first run, file does not exist

    return;
  }

  // parse header

  u64 v;
  u64 z;

  const size_t nread1 = hc_fread (&v, sizeof (u64), 1, &fp);
  const size_t nread2 = hc_fread (&z, sizeof (u64), 1, &fp);

  if ((nread1 != 1) || (nread2 != 1))
  {
    event_log_error (hashcat_ctx, "%s: Invalid header", autotune_cache_ctx->filename);

    hc_fclose (&fp);

    return;
  }

  v = byte_swap_64 (v);
  z = byte_swap_64 (z);

  if ((v & 0xffffffffffffff00) != (AUTOTUNE_CACHE_VERSION & 0xffffffffffffff00))
  {
    event_log_error (hashcat_ctx, "%s: Invalid header, ignoring content", autotune_cache_ctx->filename);

    hc_fclose (&fp);

    return;
  }

  if (z != 0)
  {
    event_log_error (hashcat_ctx, "%s: Invalid header, ignoring content", autotune_cache_ctx->filename);

    hc_fclose (&fp);

    return;
  }

  if ((v & 0xff) < (AUTOTUNE_CACHE_VERSION & 0xff))
  {
    event_log_warning (hashcat_ctx, "%s: Outdated header version, ignoring content", autotune_cache_ctx->filename);

    hc_fclose (&fp);

    return;
  }

  // parse data

  while (!hc_feof (&fp))
  {
    autotune_cache_entry_t d;

    const size_t nread = hc_fread (&d, sizeof (autotune_cache_entry_t), 1, &fp);

    if (nread == 0) continue;

    lsearch (&d, autotune_cache_ctx->base, &autotune_cache_ctx->cnt, sizeof (autotune_cache_entry_t), sort_by_autotune_cache);

    if (autotune_cache_ctx->cnt == MAX_AUTOTUNE_CACHE)
    {
      event_log_error (hashcat_ctx, "There are too many entries in the %s database. You have to remove/rename it.", autotune_cache_ctx->filename);

      break;
    }
  }

  hc_fclose (&fp);
}

int autotune_cache_write (hashcat_ctx_t *hashcat_ctx)
{
  autotune_cache_ctx_t *autotune_cache_ctx = hashcat_ctx->autotune_cache_ctx;

  if (autotune_cache_ctx->enabled == false) return 0;

  if (autotune_cache_ctx->cnt == 0) return 0;

  HCFILE fp;

  if (hc_fopen (&fp, autotune_cache_ctx->filename, "wb") == false)
  {
    event_log_error (hashcat_ctx, "%s: %s", autotune_cache_ctx->filename, strerror (errno));

    return -1;
  }

  if (hc_lockfile (&fp) == -1)
  {
    hc_fclose (&fp);

    event_log_error (hashcat_ctx, "%s: %s", autotune_cache_ctx->filename, strerror (errno));

    return -1;
  }

  // header

  u64 v = AUTOTUNE_CACHE_VERSION;
  u64 z = 0;

  v = byte_swap_64 (v);
  z = byte_swap_64 (z);

  hc_fwrite (&v, sizeof (u64), 1, &fp);
  hc_fwrite (&z, sizeof (u64), 1, &fp);

  // data

  hc_fwrite (autotune_cache_ctx->base, sizeof (autotune_cache_entry_t), autotune_cache_ctx->cnt, &fp);

  if (hc_unlockfile (&fp) == -1)
  {
    hc_fclose (&fp);

    event_log_error (hashcat_ctx, "%s: %s", autotune_cache_ctx->filename, strerror (errno));

    return -1;
  }

  hc_fclose (&fp);

  return 0;
}

bool autotune_cache_lookup (hashcat_ctx_t *hashcat_ctx, const hc_device_param_t *device_param, u32 *out_kernel_accel, u32 *out_kernel_loops, u32 *out_kernel_threads)
{
  autotune_cache_ctx_t *autotune_cache_ctx = hashcat_ctx->autotune_cache_ctx;

  if (autotune_cache_ctx->enabled == false) return false;

  autotune_cache_entry_t needle;

  autotune_cache_fill_key (&needle, hashcat_ctx, device_param);

  autotune_cache_entry_t *found = (autotune_cache_entry_t *) lfind (&needle, autotune_cache_ctx->base, &autotune_cache_ctx->cnt, sizeof (autotune_cache_entry_t), sort_by_autotune_cache);

  if (found == NULL) return false;

  *out_kernel_accel   = found->kernel_accel;
  *out_kernel_loops   = found->kernel_loops;
  *out_kernel_threads = found->kernel_threads;

  return true;
}

void autotune_cache_store (hashcat_ctx_t *hashcat_ctx, const hc_device_param_t *device_param, u32 kernel_accel, u32 kernel_loops, u32 kernel_threads)
{
  autotune_cache_ctx_t *autotune_cache_ctx = hashcat_ctx->autotune_cache_ctx;

  if (autotune_cache_ctx->enabled == false) return;

  if (autotune_cache_ctx->cnt == MAX_AUTOTUNE_CACHE)
  {
    event_log_error (hashcat_ctx, "There are too many entries in the %s database. You have to remove/rename it.", autotune_cache_ctx->filename);

    return;
  }

  autotune_cache_entry_t entry;

  autotune_cache_fill_key (&entry, hashcat_ctx, device_param);

  entry.kernel_accel   = kernel_accel;
  entry.kernel_loops   = kernel_loops;
  entry.kernel_threads = kernel_threads;

  // lsearch inserts if not found, updates nothing if found (which is fine — first write wins)

  lsearch (&entry, autotune_cache_ctx->base, &autotune_cache_ctx->cnt, sizeof (autotune_cache_entry_t), sort_by_autotune_cache);
}
