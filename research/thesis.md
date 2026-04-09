# Hashdog: Toward a Faster GPU-Accelerated Password Recovery Engine

## A Structured Performance Analysis and Optimization Research Document

**Status:** Active Research  
**Base:** hashcat v7.1.2 (fork: hashdog)  
**Authors:** Research in progress  
**Last updated:** 2026-04-08

---

## Abstract

This document presents a systematic performance analysis of hashcat, the state-of-the-art GPU-accelerated password recovery tool, with the objective of identifying and exploiting optimization opportunities across its full execution pipeline. We decompose the system into six performance domains — GPU kernel execution, host-device data transfer, candidate generation, work scheduling, I/O subsystem, and algorithmic overhead — and analyze each for bottlenecks using source-level inspection. Our findings suggest multiple avenues for measurable throughput improvement, ranging from pipeline parallelism in the dispatch loop to vectorized rule application and improved memory transfer patterns.

---

## 1. Introduction

### 1.1 Problem Statement

Password recovery throughput is bounded by the interaction of multiple subsystems: GPU compute capacity, host-device memory bandwidth, candidate generation rate, and work scheduling efficiency. While hashcat is highly optimized, its architecture reflects design decisions made for correctness and portability that may leave performance on the table in specific configurations.

### 1.2 Research Methodology

Our analysis follows a four-phase approach:

1. **Architectural decomposition**: Map the full execution pipeline from input to output
2. **Bottleneck taxonomy**: Classify performance-limiting factors by domain
3. **Per-domain analysis**: Deep investigation of each bottleneck with source-level evidence
4. **Experimental validation**: Prototype optimizations and measure impact (ongoing)

### 1.3 Scope

This research focuses on single-machine, multi-GPU configurations running Linux. Distributed cracking (brain system) is analyzed but not the primary optimization target.

---

## 2. System Architecture

### 2.1 Execution Pipeline Overview

The hashcat execution pipeline consists of the following stages, each with distinct performance characteristics:

```
┌─────────────────────────────────────────────────────────────────┐
│                    SESSION INITIALIZATION                       │
│  backend_ctx_init → device enumeration → kernel compilation     │
│  Time: O(seconds) — one-time cost, amortized by kernel cache    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                      OUTER LOOP                                 │
│  Hash loading → bitmap construction → backend_session_begin     │
│  Per hash-mode setup, buffer allocation, kernel arg binding     │
└──────────────────────────┬──────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                      AUTOTUNE                                   │
│  Binary search over (kernel_accel, kernel_loops, kernel_threads)│
│  Target: ~100ms per kernel launch. Time: 10-30s per mode.       │
└──────────────────────────┬──────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                  DISPATCH LOOP (HOT PATH)                       │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌─────────────┐ │
│  │ get_work │──▶│ generate │──▶│ run_copy │──▶│ run_cracker │ │
│  │  (mutex) │   │candidates│   │ (H2D xfer)│   │(GPU kernel) │ │
│  └──────────┘   └──────────┘   └──────────┘   └─────────────┘ │
│       ▲                                              │          │
│       └──────────────────────────────────────────────┘          │
│                    repeat until keyspace exhausted               │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Key Data Structures

| Structure | Location | Role |
|-----------|----------|------|
| `hashcat_ctx_t` | include/types.h:3236 | Master context, contains all sub-contexts |
| `hc_device_param_t` | include/types.h | Per-GPU device state, buffers, kernel handles |
| `status_ctx_t` | include/types.h | Global progress, mutexes, run-level flags |
| `kernel_param_t` | OpenCL/inc_types.h:1986 | Scalar parameters passed to GPU kernels per launch |

### 2.3 Threading Model

- **1 CPU thread per GPU device** — each runs the dispatch loop independently
- **1 monitor thread** — wakes every 1s for temperature/status checks
- **1 outfile-remove thread** (optional) — periodic potfile maintenance
- **No work-stealing** — global `words_off` counter serialized by `mux_dispatcher` mutex

---

## 3. Bottleneck Taxonomy

We classify identified bottlenecks into six domains, ranked by estimated impact:

### Priority 1: GPU Kernel Utilization

| Finding | Evidence | Impact |
|---------|----------|--------|
| Autotune targets 100ms kernel execution | `backend_ctx->target_msec` in autotune.c:108 | May under-utilize fast GPUs |
| Single-dimensional work dispatch (1D global_work_size) | backend.c:3073-3112 | Limits occupancy for some algorithms |
| Vectorization width (VECT_SIZE) hardcoded per kernel | OpenCL kernel headers | Not adaptive to GPU architecture |
| Kernel compilation latency | backend.c:9445 — sequential per device | Delays session start |

### Priority 2: Pipeline Stalls (CPU-GPU Overlap)

| Finding | Evidence | Impact |
|---------|----------|--------|
| **Synchronous dispatch loop** — generate → copy → execute → wait → repeat | dispatch.c:416, backend.c:2700 (`cuEventSynchronize`) | GPU idles during candidate generation and H2D transfer |
| No double-buffering of password candidate buffers | Single `pws_comp`/`pws_idx` buffer set per device | Cannot overlap transfer with compute |
| `run_cracker()` blocks until kernel completes | `hc_cuEventSynchronize()` in backend.c | Full pipeline stall per batch |

### Priority 3: Candidate Generation Overhead

| Finding | Evidence | Impact |
|---------|----------|--------|
| Rule engine not vectorized, per-candidate malloc | rp_cpu.c:1172-1883, `_old_apply_rule()` | CPU-bound for large rule sets |
| Slow-candidates path does CPU-side expansion | dispatch.c:506-750 | Necessary but adds latency |
| Wordlist I/O uses buffered fread, not mmap | wordlist.c:54-105, `load_segment()` | Page cache misses on cold reads |
| Feed system already uses mmap | feeds/feed_wordlist.c:190 | Proves mmap is viable |

### Priority 4: Work Scheduling

| Finding | Evidence | Impact |
|---------|----------|--------|
| `mux_dispatcher` mutex serializes work allocation | dispatch.c:116 | Contention with many GPUs |
| Static proportional load balancing | dispatch.c:86-108, `get_power()` | Doesn't adapt to runtime variance |
| No work-stealing between devices | Architecture decision | Slower GPU can hold up keyspace |

### Priority 5: Memory Transfer

| Finding | Evidence | Impact |
|---------|----------|--------|
| H2D transfer per batch (pws_comp + pws_idx) | backend.c:3673-3754, `run_copy()` | PCI-E bandwidth ceiling ~12-16 GB/s |
| Slow hash tmps buffer round-trips (D2H + H2D per iteration) | backend.c:1441-1631 | Extra latency for bridge-processed hashes |
| No pinned/page-locked host memory visible | Memory allocated via `hcmalloc()` → `calloc()` | Non-pinned transfers are slower |

### Priority 6: Peripheral Overhead

| Finding | Evidence | Impact |
|---------|----------|--------|
| Loopback per-write file locking | loopback.c:157-163 | Serializes output under high crack rate |
| Dictionary cache uses linear search (`lfind`) | dictstat.c:262 | O(n) per lookup, marginal for large caches |
| Bitmap sizing is one-time but conservative | bitmap.c:120-132, collision < 50% target | Could tune for lower false-positive rate |

---

## 4. Detailed Analysis

### 4.1 Pipeline Parallelism (Priority 2 — Highest Practical Impact)

**Current state:** The dispatch loop in `calc()` (dispatch.c:416) executes sequentially:

```
get_work() → generate candidates → run_copy() → run_cracker() → [GPU blocks] → repeat
```

The GPU sits idle during candidate generation and host-to-device transfer. For fast hashes (MD5, SHA1), candidate generation time can approach or exceed kernel execution time, meaning the GPU is idle ~50% of the time.

**Proposed optimization: Double-buffered async pipeline**

```
Time →
CPU:  [gen batch N+1] [gen batch N+2] [gen batch N+3] ...
DMA:       [copy N]        [copy N+1]       [copy N+2] ...
GPU:            [exec N]        [exec N+1]       [exec N+2] ...
```

This requires:
1. Two sets of `pws_comp`/`pws_idx` buffers per device (alternating)
2. Async memory transfers (CUDA streams, OpenCL command queues with events)
3. Non-blocking kernel launch with event-based completion notification
4. Careful synchronization to ensure batch N completes before buffer reuse

**Estimated impact:** 20-40% throughput improvement for compute-bound fast hashes. Less impact for slow/iterated hashes where kernel time dominates.

**Complexity:** High — requires modifying backend.c buffer management, dispatch.c loop structure, and adding async primitives.

### 4.2 Rule Engine Vectorization (Priority 3)

**Current state:** `_old_apply_rule()` in rp_cpu.c processes one password at a time with per-call buffer allocation. No SIMD.

**Proposed optimization:** Batch rule application using SIMD intrinsics (AVX2/AVX-512) for common operations (case change, character append/prepend, position swap). Pre-allocate rule output buffers.

**Estimated impact:** 2-5x speedup in rule application throughput. Only matters when rule count is large and GPU is fast enough to be starved.

### 4.3 Autotune Acceleration (Priority 1)

**Current state:** Autotune (autotune.c:100-614) performs iterative binary search over three parameters with actual kernel launches. Takes 10-30 seconds per hash mode per device.

**Proposed optimization:**
- Cache autotune results per (device, hash_mode, salt_count) tuple across sessions
- Use performance model to predict optimal parameters from device characteristics
- Reduce probing rounds for known device families

**Estimated impact:** Reduces startup latency from 10-30s to <1s for cached configurations. Critical for multi-mode benchmark runs.

### 4.4 Memory Transfer Optimization (Priority 5)

**Current state:** Host memory allocated via `calloc()` (memory.c:26). Transfers use standard APIs.

**Proposed optimization:**
- Use pinned (page-locked) host memory for candidate buffers (`cuMemAllocHost` / `clCreateBuffer` with `CL_MEM_ALLOC_HOST_PTR`)
- Enables DMA transfers without page table walk overhead
- Required foundation for async double-buffered pipeline

**Estimated impact:** 10-30% transfer speedup. Multiplicative with pipeline parallelism.

### 4.5 Wordlist I/O Modernization (Priority 3)

**Current state:** Core wordlist code uses `fread()` with segment buffering (wordlist.c). The newer feed system (feed_wordlist.c) already uses `mmap()` with `POSIX_MADV_SEQUENTIAL`.

**Proposed optimization:** Migrate core wordlist path to mmap-based reading, or accelerate migration to the feed system as the primary candidate source.

**Estimated impact:** Reduces I/O latency for cold wordlist reads. Marginal for cached workloads.

---

## 5. Experimental Roadmap

### Phase 1: Measurement Infrastructure — COMPLETE (2026-04-08)
- [x] Add high-resolution timing instrumentation to dispatch loop stages
- [x] Measure actual GPU utilization (idle time between kernel launches)
- [x] Profile rule engine CPU cost for representative workloads
- [x] Establish baseline benchmarks across hash modes (fast, medium, slow)

#### Key Empirical Findings (RTX 3090)

**Brute-force mode:** GPU utilization 99-100%. No pipeline bottleneck.
- MD5: 70.7 GH/s, 99.1% GPU util
- SHA256: 9.4 GH/s, 99.9% GPU util
- SHA512: 3.2 GH/s, 100.0% GPU util

**Dictionary+rules (slow-candidates):** GPU utilization **0.4%**.
- 94.1% of time in CPU candidate generation
- 5.5% in H2D transfer
- 0.4% in GPU kernel execution
- **The GPU is idle 99.6% of the time**

**Conclusion:** Pipeline parallelism is critical for dictionary/rule attacks,
but irrelevant for brute-force. The optimization strategy must be attack-mode aware.

### Phase 2: Low-Risk Optimizations — IN PROGRESS
- [x] Implement autotune result caching across sessions (2026-04-08)
- [x] Switch candidate buffers to pinned host memory (2026-04-08)
- [x] Eliminate per-candidate malloc in rule engine (2026-04-08)
- [~] Explore mmap for core wordlist path — **deferred** (2026-04-08): analysis shows I/O is not a bottleneck (GPU util 99%+ in brute-force, CPU candidate gen 94% in dict+rules). The feed plugin system already provides mmap. Migrating core path would break compressed wordlist support and touch many tightly-coupled hot-path functions for marginal gain.

#### Autotune Caching Implementation (2026-04-08)

**Problem:** The autotuner performs iterative binary search over three kernel parameters
(kernel_accel, kernel_loops, kernel_threads) using actual GPU kernel launches, costing
10-30 seconds per hash mode per device on each session start.

**Solution:** Persistent disk cache at `~/.hashcat/hashcat.autotune`, following the
dictstat binary caching pattern. Cache key: (device_name, hash_mode, attack_exec,
device_processors, kernel_accel_min/max, kernel_loops_min/max, kernel_threads_min/max,
salt_iter). On cache hit, the tuned parameters are applied directly without any GPU
kernel launches, reducing autotune time to ~0ms.

**Design decisions:**
- Cache is not used when user specifies `--force` (fallback to minimum values)
- Cache is not used when all tuning parameters are already fixed (min==max for all three)
- Cached values are validated against current device bounds before use
- Binary file format with version header for forward compatibility
- Maximum 10,000 entries (covers hundreds of devices × hash modes)
- Thread-safe: each device thread reads from shared cache; writes happen after all threads complete

#### Pinned Host Memory for Candidate Buffers (2026-04-08)

**Problem:** Host-to-device memory transfers for password candidate buffers (`pws_comp`,
`pws_idx`) use regular `calloc`-allocated memory. Non-pinned transfers require an extra
kernel-space copy to a DMA-capable staging buffer, reducing effective PCI-E bandwidth.

**Solution:** Use `cuMemAllocHost` (CUDA) and `hipHostMalloc` (HIP) for the two hot-path
candidate buffers. Pinned (page-locked) memory enables direct DMA transfers, bypassing
the staging copy. Falls back to regular `hcmalloc` if pinned allocation fails or on
OpenCL/Metal backends.

**Design decisions:**
- Only `pws_comp` and `pws_idx` are pinned — these are the two buffers transferred every
  batch in `run_copy()`. Other buffers (`pws_pre_buf`, `pws_base_buf`, `combs_buf`) are
  accessed less frequently and not worth the locked-page overhead.
- `pws_host_pinned` flag on `hc_device_param_t` tracks allocation type for correct cleanup.
- Graceful fallback: if pinned allocation fails (e.g., insufficient locked memory limit),
  partial allocations are freed and regular memory is used.
- Foundation for Phase 3: async double-buffered pipeline requires pinned memory for
  overlapped DMA transfers.

**Estimated impact:** 10-30% H2D transfer speedup. Most significant for fast hashes where
transfer time is a larger fraction of total batch time.

### Phase 3: Pipeline Parallelism (High Impact, High Complexity)
- [ ] Implement double-buffered candidate buffers per device
- [ ] Add async memory transfer support (CUDA streams / OpenCL events)
- [ ] Restructure dispatch loop for overlapped execution
- [ ] Validate correctness under multi-GPU configurations

### Phase 4: Advanced Optimizations
- [ ] SIMD-vectorized rule engine
- [ ] Adaptive work scheduling (replace static proportional with runtime feedback)
- [ ] Kernel specialization for common GPU architectures
- [ ] Investigate kernel fusion opportunities for fast hashes

---

## 6. Benchmarking Methodology

All experiments will follow this protocol:

1. **Baseline:** Unmodified hashdog build, `make clean && make`
2. **Test system:** Document exact GPU model, driver version, OS kernel, VRAM
3. **Hash modes tested:**
   - Fast: MD5 (mode 0), SHA1 (mode 100), SHA256 (mode 1400)
   - Medium: bcrypt (mode 3200), PBKDF2-SHA256 (mode 10900)
   - Slow: scrypt (mode 8900), Argon2 (mode varies)
4. **Metrics:**
   - Hashes/second (H/s) — primary throughput metric
   - GPU utilization % — from hardware monitoring
   - Kernel execution time vs. total batch time — pipeline efficiency
   - Rule application throughput (candidates/sec on CPU)
5. **Statistical rigor:** Minimum 5 runs per configuration, report mean ± stddev
6. **Reproducibility:** All benchmarks scripted, committed to repo

---

## 7. Related Work

- Hashcat documentation and source (hashcat.net)
- Elcomsoft publications on GPU password recovery
- Academic work on GPGPU optimization patterns (coalesced access, occupancy tuning)
- NVIDIA best practices guide for CUDA optimization
- OpenCL optimization guides (AMD, Intel, ARM)

---

## Appendix A: Critical Source File Reference

| File | Lines | Role |
|------|-------|------|
| src/dispatch.c | 110-146 | `get_work()` — serialized work allocation |
| src/dispatch.c | 416-1932 | `calc()` — main dispatch hot loop |
| src/backend.c | 2519-3139 | `run_kernel()` — GPU kernel launch |
| src/backend.c | 3673-3754 | `run_copy()` — H2D candidate transfer |
| src/backend.c | 4089-4200 | `run_cracker()` — salt/innerloop iteration |
| src/backend.c | 9445-10136 | `load_kernel()` — kernel compilation |
| src/backend.c | 13402+ | `backend_session_begin()` — buffer allocation |
| src/autotune.c | 37-82 | `try_run()` — kernel timing measurement |
| src/autotune.c | 100-614 | `autotune()` — parameter search |
| src/rp_cpu.c | 1172-1883 | `_old_apply_rule()` — CPU rule engine |
| src/wordlist.c | 54-105 | `load_segment()` — buffered wordlist I/O |
| src/feeds/feed_wordlist.c | 190 | mmap-based wordlist I/O |
| src/slow_candidates.c | 18-349 | CPU-side candidate expansion |
| src/hashcat.c | 61-512 | Inner loop / session orchestration |
| src/monitor.c | 112-349 | 1-sec monitor loop |
| src/bitmap.c | 73-145 | Bitmap rejection filter construction |

## Appendix B: Key Constants and Parameters

| Parameter | Default | Location | Effect |
|-----------|---------|----------|--------|
| `target_msec` | 100 | autotune.c:108 | Autotune target kernel time |
| `kernel_accel` | auto | Per-device tuned | Parallelism multiplier |
| `kernel_loops` | auto | Per-device tuned | Iterations per kernel launch |
| `kernel_threads` | auto | Per-device tuned | Work-group size |
| `segment_size` | ~32MB | user_options | Wordlist read buffer |
| `bitmap_min/max` | 16-24 bits | bitmap.c | Rejection filter size |
| `MAKEFLAGS -j` | 8 | src/Makefile:86 | Build parallelism |
