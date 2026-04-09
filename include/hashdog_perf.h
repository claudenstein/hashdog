/**
 * hashdog performance instrumentation
 *
 * Measures time spent in each stage of the dispatch pipeline:
 *   get_work  — mutex-protected work allocation
 *   generate  — candidate generation (slow_candidates_next, feed, etc.)
 *   copy      — host-to-device memory transfer (run_copy)
 *   cracker   — GPU kernel execution (run_cracker)
 *   idle      — time between cracker return and next get_work
 *
 * Enable with: make CFLAGS=-DHASHDOG_PERF
 * Results printed to stderr at session end.
 */

#ifndef HC_HASHDOG_PERF_H
#define HC_HASHDOG_PERF_H

#include "timer.h"

typedef struct hashdog_perf
{
  double   time_get_work_ms;    // accumulated time in get_work()
  double   time_generate_ms;    // accumulated time generating candidates
  double   time_copy_ms;        // accumulated time in run_copy()
  double   time_cracker_ms;     // accumulated time in run_cracker()
  double   time_idle_ms;        // accumulated idle time between batches
  u64      batch_count;         // number of dispatch iterations
  u64      candidates_total;    // total candidates processed

} hashdog_perf_t;

#ifdef HASHDOG_PERF

#define HASHDOG_TIMER_START(name) \
  hc_timer_t _hd_timer_##name; \
  hc_timer_set (&_hd_timer_##name)

#define HASHDOG_TIMER_STOP(perf, field, name) \
  (perf)->field += hc_timer_get (_hd_timer_##name)

#define HASHDOG_PERF_BATCH(perf, cnt) \
  do { (perf)->batch_count++; (perf)->candidates_total += (cnt); } while (0)

#else

#define HASHDOG_TIMER_START(name)             do {} while (0)
#define HASHDOG_TIMER_STOP(perf, field, name) do {} while (0)
#define HASHDOG_PERF_BATCH(perf, cnt)         do {} while (0)

#endif

#endif // HC_HASHDOG_PERF_H
