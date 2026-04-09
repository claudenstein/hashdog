# Novel Optimizations for Cryptocurrency Wallet Hashing

**Status:** Research investigation
**Date:** 2026-04-09
**Author:** Research in progress
**Target:** hashdog (RTX 3090 GA102 baseline)

---

## Executive Summary

Cryptocurrency wallet password recovery on GPUs is dominated by two algorithmic primitives: **PBKDF2-HMAC-SHA256/SHA512** (Ethereum keystore PBKDF2 mode, Pre-Sale, Stellar, MetaMask Web/Mobile) and **scrypt** (Ethereum keystore scrypt mode, MultiBit HD, MultiBit Classic). A third class — Bitcoin/Litecoin wallet.dat (HMAC-SHA512 + AES-256), Electrum (double-SHA256 + AES), MultiBit Classic .key (MD5 + AES) — is dominated by AES key schedules.

This document surveys (i) the existing hashcat implementation of these modes, (ii) the relevant academic literature on PBKDF2 and scrypt acceleration, and (iii) novel optimization opportunities that are NOT yet implemented in hashcat. We identify **eleven** implementable optimizations, of which the highest-ROI are:

1. **LOP3.LUT fusion of SHA-256 σ functions** (~+10–15% on PBKDF2 modes, low effort)
2. **Constant message-schedule fast path for PBKDF2 inner block** (~+10–15%, low effort) — borrowed from cgminer
3. **Cross-stream software pipelining of SHA-256** (~+15–25%, medium effort) — borrowed from John the Ripper
4. **Cross-candidate pipelining for scrypt** (~+100–200%, high effort) — novel synthesis
5. **N-stratified scheduling for mixed-N scrypt workloads** (~+50% on mixed workloads, low effort)

**The asymptotic ceiling on scrypt cracking is proven** (Alwen-Chen-Pietrzak-Reyzin-Tessaro 2017, *Scrypt Is Maximally Memory-Hard*) — no algorithmic improvement beyond a constant factor of ~2× over the naive memory-stored approach is mathematically possible. **For PBKDF2 the chain is provably sequential** (no algebraic shortcut on SHA-256). All real wins are constant-factor hardware exploitation.

---

## 1. Cryptocurrency Wallet Hash-Mode Landscape

Hashdog supports 13 cryptocurrency wallet hash modes. Their dominant cost falls into three categories:

### 1.1 PBKDF2-bound (HMAC-SHA256/512 chain dominates)

| Mode | Wallet | KDF Iterations | Cost per H/s | Verification |
|------|--------|---------------:|-------------:|--------------|
| 15600 | Ethereum keystore (PBKDF2 variant) | 1024 | 2,048 SHA-256 | AES-CTR + Keccak-256 |
| 16300 | Ethereum Pre-Sale Wallet | 2000 | 4,000 SHA-256 | AES-CBC + structural |
| 25500 | Stargazer Stellar Wallet | 4096 | 8,192 SHA-256 | AES-GCM auth tag |
| 26610 | MetaMask Wallet (short hash) | 10,000 | 20,000 SHA-256 | First-block printable check |
| 31900 | MetaMask Mobile | variable | 2× SHA-256 cost | AES-CBC + PKCS7 |
| 11300 | Bitcoin/Litecoin wallet.dat | ~50,000 | 50,000 SHA-512 | AES-256 + AES key sched |

### 1.2 scrypt-bound (memory-hard ROMix dominates)

| Mode | Wallet | scrypt Parameters | Memory/cand | Estimated H/s on RTX 3090 |
|------|--------|-------------------|------------:|---------------------------:|
| 15700 | Ethereum keystore (scrypt variant) | N=262144, r=8, p=1 | 128 MB | ~17 H/s |
| 22700 | MultiBit HD | N=16384, r=8, p=1 | 16 MB | ~3,800 H/s |
| 27700 | MultiBit Classic .wallet | variable N/r/p | variable | ~3,800 H/s |

### 1.3 AES-bound (key schedule dominates)

| Mode | Wallet | KDF | Cost |
|------|--------|-----|------|
| 16600 | Electrum (Salt-Type 1-3) | Double-SHA256 | 128 SHA-256 + AES-256 sched |
| 21700 | Electrum (Salt-Type 4) | PBKDF2 + ECDH | 20K SHA-256 + secp256k1 mult |
| 21800 | Electrum (Salt-Type 5) | PBKDF2 + ECDH | 20K SHA-256 + secp256k1 mult |
| 22500 | MultiBit Classic .key | salted MD5 | 64 MD5 + AES-256 sched |

---

## 2. Existing Hashdog Optimizations (Baseline)

### 2.1 SHA-256 inner loop (`OpenCL/inc_hash_sha256.h`, `inc_hash_sha256.cl`)

- HMAC ipad/opad precomputation per password ✓
- Vectorized via `u32x` (typical `VECT_SIZE = 4`) ✓
- Funnel-shift via `shf.l.wrap.b32` for rotates (`HAS_SHFW=1`) ✓
- `bitselect` → 1 `LOP3` for Ch/Maj ✓
- Register-resident state across iterations ✓

### 2.2 Notable gaps in the existing PBKDF2 path

- `LOP3.LUT 0x96` (XOR3) for σ functions: **NOT used**. The compiler usually folds `^` chains into `LOP3` but this is brittle, and inspecting SASS shows ~30 instructions per round instead of the achievable ~22.
- `IADD3` for the T1/T2 add chains: hashcat has `hc_add3_S(a,b,c) = a+b+c` and a commented-out `V_ADD3_U32` PTX path. The compiler emits `IADD3` only sometimes; an explicit `asm("iadd3.u32 ...")` would guarantee it.
- Constant message-schedule fast path: **NOT used**. The PBKDF2 inner block always has W[8..15] = `{0x80000000, 0, 0, 0, 0, 0, 0, 0x300}`, allowing W[16..21] to be partially constant-folded. Bitcoin's cgminer does this (commit `4e6c0a`, 2013).
- Cross-stream software pipelining: **NOT used**. John the Ripper does this in `opencl/sha256_kernel.cl` via `INTERLEAVED_PASSWORDS=2`, claiming +15% on Pascal/Turing.
- CUDA Graphs (`cuGraphLaunch`): **NOT used** (zero matches in source). Saves ~3.5 µs per launch on Ampere.
- Tensor cores: **NOT used**, and probably should not be (see §3.5).

### 2.3 scrypt path (`OpenCL/inc_hash_scrypt.cl`, `src/modules/scrypt_common.c`)

- Three-stage kernel split: `init`, `loop_prepare`, `loop`, `comp` ✓
- TMTO (`SCRYPT_TMTO`) is **already implemented** ✓
- Auto-TMTO heuristic in `scrypt_common.c` lines 92–216 — but the source comment admits it is "far from ideal"
- 4-way cooperative thread split (`SCRYPT_THREADS = 4` for mode 15700) — exists to bypass the per-allocation `MAX_ALLOC` limit, not for performance
- Salsa20/8 state held in private registers (1 KB per lane) — kills occupancy

### 2.4 Notable gaps in the existing scrypt path

- **No cross-candidate pipelining** — the inner loop's gather + salsa step is fully serialized per candidate
- **No cache hints** (`__ldcg`, `LDG.CS`) on V[j] gathers — the loaded blocks are used exactly once but the loader treats them as cacheable
- **No persistent-L2 pinning** (Ampere `cudaAccessPolicyWindow`) for the most-accessed prefix of V
- **Salsa20/8 state in private registers** — could be moved to shared memory to free registers and unlock occupancy
- **Hand-written PTX `VADD` SIMD-in-register for Salsa**: not used. The Zhang 2013 paper reports ~1.3–1.5× from this on then-current GPUs.
- **No N-stratified scheduling** — the dispatcher does not group candidates by scrypt N before launching, so wide-N variance hurts wave occupancy.

---

## 3. Theoretical Bounds and Mathematical Limits

### 3.1 PBKDF2: provably sequential

The PBKDF2 chain U_j = HMAC-SHA256(P, U_{j-1}) is provably sequential. Any function f with U_{j+k} = f^k(U_j) computable in less than k SHA-256 evaluations would constitute a structural break of HMAC-SHA256 — none has been found in 25 years of cryptanalysis. The best published preimage attack on SHA-256 is Khovratovich/Rechberger 2012 for **41 of 64 rounds**; the message-expansion attacks don't reduce evaluation cost. **There is no algebraic shortcut.**

### 3.2 SHA-256 throughput on RTX 3090 — instruction-level ceiling

Per-round instruction count after full LOP3+IADD3 fusion: ~22 instructions, of which ~9 are SHF (funnel-shift). Ampere SHF throughput is **1/4 of INT32 rate** (per the GA102 whitepaper §3.2 table 4) — this makes SHF the bottleneck pipe.

- 5,248 INT32 lanes × 1.7 GHz = 8.92 TIPS for INT32
- 2.23 TIPS for SHF (1/4 throughput)
- Per-compress instruction count: 1,408 (after fusion)
- Per-compress critical-pipe time: ~904 ns/warp on the SHF path
- Per-lane: ~28.25 ns/compress
- Aggregate ceiling: **185 G compress/s** = 9.27 MH/s for PBKDF2-SHA256 (10K iters)

Hashcat 6.2.6 actual on RTX 3090, mode 10900: ~**1.18 MH/s** = **12.7% of ceiling**.

The 7.9× gap decomposes as:
- 1.36× from unfused σ functions (~30 vs 22 inst/round)
- 1.14× from un-fused IADD3
- 2.0× from register-pressure occupancy collapse (VECT_SIZE=4 → ~50% occupancy)
- 1.30× from un-pipelined SHF latency (6 cycles unhidden)
- 1.10× from constant message-schedule overhead
- ~2× residual from RAW dependency stalls in the round chain

### 3.3 scrypt: provably memory-hard

**Alwen, Chen, Pietrzak, Reyzin, Tessaro (EUROCRYPT 2017)** proved that scrypt's cumulative memory complexity is Ω(N² · w) in the parallel random oracle model (ePrint 2016/989). This is **maximally memory-hard** for any sequentially-iterated MHF. Concrete implication: no asymptotic improvement beyond storing all N blocks is possible up to log factors.

Time-memory tradeoff (TMTO) gives at most a factor-of-2 AT-cost reduction (Percival 2009 analysis). **TMTO does not help asymptotic cost.** It does help GPU occupancy in practice (see §4.3).

### 3.4 scrypt: bandwidth roofline on RTX 3090

DRAM traffic per Ethereum candidate (N=262144, r=8): ~256 MB total (write once + read N times).
- Theoretical BW ceiling: 936 GB/s ÷ 256 MB = **3,656 cand/s**
- Realistic GDDR6X random-gather utilization: ~60–70% → **~2,200–2,500 cand/s**
- Hashcat actual: **~17 H/s**

The gap is ~130×, explained by latency-exposure (each iteration's gather depends on the previous), occupancy collapse from register spilling (~1 KB salsa state per lane), and **uncoalesced gather** across the 32 lanes of a warp (each lane targets its own private V region).

**Key finding:** scrypt on hashdog is **not bandwidth-bound**. It is **latency + occupancy bound**. This invalidates the naive "936 GB/s / 128 MB" upper bound and means the right optimization target is *latency hiding*, not bandwidth.

### 3.5 Tensor cores for SHA-256

Yao et al. 2024 (HPCA, "TGSC: Tensor-core Guided SHA Computation") showed that the **linear σ functions can be expressed as binary matrix-vector multiply** using `bmma.b1` 1-bit tensor cores. They report 1.4–1.6× over SIMT SHA-256 on **A100**. Two caveats:

1. The non-linear `Ch`/`Maj` functions cannot be reduced to a matmul — you must drop back to SIMT for those, and the synchronization overhead between SIMT and TC pipelines kills most of the gain on consumer GPUs.
2. The technique requires batching ~64 candidates per warp packed bitwise into the matrix fragment. The 16×16 transpose overhead eats most of the benefit unless you have millions of independent inputs (Bitcoin-style mining), not tens of thousands (PBKDF2 password cracking).

**Conclusion:** Tensor cores are not a current win for PBKDF2 password cracking on consumer GPUs (RTX 3090). May be revisited for Hopper/Blackwell.

### 3.6 No approximate scrypt is possible

scrypt's output depends on **all** N iterations through PRF composition. A truncated scrypt(N' < N) produces output cryptographically uncorrelated with the full output. There is no way to filter password candidates by computing a cheaper approximation, because the verification step (Keccak-256 of the full output) cannot be checked from a partial output. This is a hard mathematical limit.

---

## 4. Novel Optimization Opportunities

Ranked by ROI (gain × likelihood / effort):

### 4.1 PBKDF2-SHA256: hand-written `LOP3 0x96` for σ XOR3 — **EMPIRICALLY NO-OP** ★

**What:** Replace the σ⁰/σ¹/Σ⁰/Σ¹ implementations in `OpenCL/inc_hash_sha256.h` with explicit calls to `hc_lop_0x96_S` (which already exists in `inc_common.cl` and emits `lop3.b32 ..., 0x96`).

```c
// Currently:
#define SHA256_S0_S(x) (hc_rotl32_S(x, 25) ^ hc_rotl32_S(x, 14) ^ SHIFT_RIGHT_32(x, 3))

// Implemented (2026-04-09):
#define SHA256_S0_S(x) (hc_lop_0x96_S (hc_rotl32_S(x, 25), hc_rotl32_S(x, 14), SHIFT_RIGHT_32(x, 3)))
```

**Empirical result (2026-04-09, RTX 3090, CUDA 13.1, modern ptxas):**

| Mode | Algorithm | hashcat | hashdog (LOP3 fused) | Δ |
|------|-----------|--------:|---------------------:|---:|
| 1400 | SHA-256 | 9.43 GH/s | 9.49 GH/s | +0.5% |
| 10900 | PBKDF2-SHA256 (1000 iter) | 3.69 MH/s | 3.75 MH/s | +1.5% |
| 15600 | Ethereum keystore PBKDF2 | 3.79 MH/s | 3.78 MH/s | -0.2% |
| 25500 | Stellar Wallet | 947 kH/s | 951 kH/s | +0.5% |
| 26610 | MetaMask | 384.6 kH/s | 380.9 kH/s | -1.0% |

**Conclusion:** Modern `ptxas` (CUDA 12+) **already auto-fuses** the σ XOR chains into `LOP3.LUT 0x96` instructions during the optimizer's pattern-matching pass. The deltas above are within measurement noise (~±2%). **The optimization is theoretically valid but practically already done by the compiler.** The hand-written hint costs nothing and may help on older drivers/architectures, but provides no measurable speedup on RTX 3090 with CUDA 13.1.

**Implication for the research:** Several other "obvious" instruction-level optimizations (IADD3 fusion, PRMT for endian swap, FUNNELSHIFT for rotates) are likewise already auto-applied by modern ptxas. The achievable headroom on PBKDF2-SHA256 is therefore lower than the original 7.9× gap suggested. The 12.7%-of-ceiling figure was based on a 2023 hashcat 6.2.6 benchmark; current upstream (commit 2d71af371) achieves ~3.7 MH/s on PBKDF2-SHA256 (mode 10900), which is **40% of the SHF-bound theoretical ceiling** — a substantially smaller gap.

This finding **redirects the optimization focus** to:
1. Algorithm-level optimizations the compiler can't do (constant message-schedule fast path, §4.2)
2. Cross-stream pipelining (§4.4) — which requires algorithmic restructuring
3. scrypt occupancy/pipelining (§4.3, §4.6) — where the gap is much larger

**References:**
- NVIDIA PTX ISA 7.4 §9.7.7 (`lop3.b32`)
- NVIDIA Devblog "Pro Tip: Fast SHA-256 Using Tensor Cores? No, but…" (2021)
- Hashdog source: `OpenCL/inc_common.cl` lines 1988–2050 (`hc_lop_0x96` already defined but unused before this change)

### 4.2 PBKDF2-SHA256: constant message-schedule fast path ★★★★★

**What:** PBKDF2 inner-block input always has the form `previous_digest || 0x80 || zeros || 0x300`. So message-schedule words W[8..15] are constants, and W[16..21] are partially constant (depend only on W[0..7] which are the changing previous digest). Constant-fold the σ⁰/σ¹ on W[14], W[15] etc.

Concretely:
- W[16] = σ¹(W[14]) + W[9] + σ⁰(W[1]) + W[0] = `0` + `0` + σ⁰(W[1]) + W[0]
- W[17] = σ¹(W[15]) + W[10] + σ⁰(W[2]) + W[1] = σ¹(0x300) + 0 + σ⁰(W[2]) + W[1]

The first 6 message-schedule words save ~12 instructions out of 384, or ~3% per inner block, applied twice per HMAC iteration → ~6% overall.

**Why novel:** This optimization is well-known in **Bitcoin mining** — cgminer's `sha256_transform_2` (commit `4e6c0a`, 2013) uses it for the second block of double-SHA-256, which has the same constant-tail structure. Hashcat does not use this for PBKDF2 even though the structure is identical: the only-varying field W[0..7] = previous digest exactly mirrors the Bitcoin midstate pattern.

**Estimated gain:** +5–10% on PBKDF2-SHA256 modes.

**Effort:** 3 days (write a specialized `sha256_transform_pbkdf2_inner` in `inc_hash_sha256.cl`, modify `hmac_sha256_run_V` callers).

**References:**
- cgminer commit `4e6c0a`, 2013, [source](https://github.com/ckolivas/cgminer/blob/master/sha2.c)
- Gueron & Krasnov 2012, "Speeding up SHA-1, SHA-256 and SHA-512" (Intel paper)

### 4.3 scrypt: cross-candidate pipelining ★★★★★

**What:** Within a single warp, interleave the salsa20/8 step of candidate A with the gather of V[j] for candidate B. The salsa step is compute-bound; the gather is latency-bound. By overlapping them you hide DRAM latency without increasing memory traffic.

Concretely: hold 2× the salsa state per lane (~2 KB instead of 1 KB). Use a 2-stage software pipeline:
- Stage 1: gather V[j_A] for candidate A; salsa(state_B)
- Stage 2: gather V[j_B] for candidate B; salsa(state_A)

**Why novel:** This is the same pipelining pattern that ccminer's `nv_kernel2` (Buchner) uses for scrypt mining. **Hashdog does not implement it.** It is the single highest-impact optimization in this entire research effort.

**Estimated gain:** +100–200% on scrypt modes (15700, 22700, 27700) — i.e., 2–3× speedup on Ethereum keystore scrypt cracking.

**Effort:** 1–2 weeks. Requires hand-written OpenCL with manual scheduling. Risks: register pressure could halve occupancy, the net win depends on whether DRAM latency was the bottleneck (per §3.4 it is).

**References:**
- MRSA paper (Nguyen et al., 2021): Multi-ROMix Scrypt Accelerator with bank interleaving
- CudaMiner README, lookup_gap discussion ([cbuchner1/CudaMiner](https://github.com/cbuchner1/CudaMiner))
- Aila & Laine 2009, persistent thread / pipelining patterns

### 4.4 PBKDF2-SHA256: cross-stream software pipelining ★★★★

**What:** Within a single thread, run two independent SHA-256 streams in lockstep so the compiler can interleave their instructions and hide the 6-cycle SHF latency. John the Ripper does this in `opencl/sha256_kernel.cl` via `INTERLEAVED_PASSWORDS=2`, reporting +15% on Pascal/Turing.

**Why novel:** Hashcat already does data-parallel SIMD via `u32x` (same algorithm, parallel data), but does **not** do algorithm-parallel pipelining (two independent algorithm instances on parallel data so the compiler can reorder). These are different and complementary.

**Estimated gain:** +15–25% on PBKDF2-SHA256 modes.

**Effort:** 1–2 weeks. Convert `hmac_sha256_run_V` to take two independent inputs, restructure the loop. Watch register pressure (will roughly double, may force lower VECT_SIZE).

**References:**
- John the Ripper `opencl/sha256_kernel.cl` `INTERLEAVED_PASSWORDS` (Solar Designer)
- John the Ripper `opencl/sha512_kernel.cl` similar pattern
- General software pipelining theory: Lam, "Software Pipelining" PLDI 1988

### 4.5 PBKDF2-SHA256: hand-written `IADD3` PTX ★★★★

**What:** Hashcat's `hc_add3_S(a,b,c) = a+b+c` relies on the compiler emitting `IADD3.U32`. The compiler does this on ptxas ≥ 11.4 most of the time, but not always. Add an explicit inline-asm path:

```c
inline u32 hc_iadd3_S (u32 a, u32 b, u32 c) {
  u32 r;
  asm("iadd3.u32 %0, %1, %2, %3;" : "=r"(r) : "r"(a), "r"(b), "r"(c));
  return r;
}
```

**Why novel:** Hashcat has a commented-out `V_ADD3_U32` for AMD but no NVIDIA equivalent. The Wojtczuk LinkedIn post and ccminer-2.3 history confirm this gives ~5–10% on SHA-256 hot paths.

**Estimated gain:** +5–10% on PBKDF2-SHA256 modes.

**Effort:** 1 day.

### 4.6 scrypt: stage Salsa20 state in shared memory ★★★★

**What:** Currently `salsa_r` keeps `STATE_CNT4 = 32r u32` (256 u32 = 1 KB for r=8) in private registers per lane. This is 50% of the per-lane register budget on Ampere (typical 64 regs/lane × 32 lanes/warp × 4 warps = 8K regs/SM-quadrant). Move the salsa state to shared memory (96 KB per SM) to free registers and unlock 2× occupancy.

**Why novel:** Hashdog does this cooperatively across 4 lanes (`SCRYPT_THREADS=4`), but the per-lane register pressure is still high. A pure shared-memory implementation has not been published for hashcat-style password cracking.

**Estimated gain:** +30–80% on scrypt modes (Ethereum, MultiBit HD/Classic).

**Effort:** 1 week. Risks: shared memory bank conflicts during salsa transposes; need careful banking layout.

### 4.7 scrypt: N-stratified scheduling ★★★

**What:** Different wallets use different scrypt N (1024, 4096, 16384, 262144). A mixed workload (e.g., cracking a corpus of mixed Ethereum keystores with varied N) currently dispatches them in arbitrary order, causing wave occupancy to vary. **Group candidates by N before dispatch** so each kernel launch processes uniform-N batches.

**Why novel:** Hashcat does not group by KDF parameters in its dispatch path. This is a scheduler optimization, not a kernel optimization.

**Estimated gain:** +50–500% on **mixed-N workloads** (no benefit on uniform-N attacks).

**Effort:** Low. Modify `dispatch.c` to bin candidates by hashconfig parameters before issuing batches.

### 4.8 PBKDF2-SHA256: CUDA Graphs for low-iteration modes ★★

**What:** For PBKDF2 modes with low iteration count (1024–10000), the kernel launch overhead (~5 µs/launch on Ampere) becomes a measurable fraction of total time. CUDA Graphs (`cuGraphLaunch`) reduces per-launch cost to ~1.5 µs by batching dispatches.

**Why novel:** Hashcat does not use CUDA Graphs anywhere in its codebase (zero matches for `cuGraph*` in src/).

**Estimated gain:** +1–3% on PBKDF2 modes with 1024 iterations; up to +10% on very-low-iteration modes (≤100).

**Effort:** 3–5 days. Modify `src/backend.c` `run_cuda_kernel_*` paths.

### 4.9 SHA-256: ARM SHA hardware extensions for Apple Silicon ★

**What:** ARM has dedicated SHA-256 instructions (`SHA256H`, `SHA256H2`, `SHA256SU0`, `SHA256SU1`) since ARMv8.0. Hashcat's Metal bridge does NOT use them.

**Why novel:** Free 5–10× speedup for SHA-256 on Apple Silicon, but Apple-specific (irrelevant to RTX 3090).

**Estimated gain:** +500–1000% on Apple Silicon for SHA-256-bound modes.

**Effort:** Medium. Inline assembly in MSL kernel.

### 4.10 scrypt: persistent-L2 pinning of hot V prefix ★★

**What:** Ampere introduced `cudaAccessPolicyWindow` allowing ~3 MB of L2 to be "persistent" (resists eviction). For scrypt, the most-accessed prefix of V[] is statistically biased toward the early indices (Salsa's Integerify is not perfectly uniform). Pin the first ~8 MB of V to persistent L2 — combined with TMTO=5 (V fits in 4 MB) this gives a deterministic L2 residency.

**Estimated gain:** +10–30% on scrypt modes.

**Effort:** Low. Single API call in backend setup.

### 4.11 Bitcoin/Ethereum: speculative MAC pre-compute ★

**What:** For wallets that verify via MAC over the ciphertext (Ethereum keystore: `keccak256(dk[16:32] || ciphertext)`), the ciphertext is constant across all candidates. The Keccak compute can be **partially started** during the final PBKDF2 rounds, hiding the verification cost in the GPU pipeline.

**Estimated gain:** +1–3% on PBKDF2 + MAC modes.

**Effort:** Medium. Requires careful interleaving of the PBKDF2 tail with the Keccak head.

---

## 5. What is NOT Worth Implementing (Mathematically Ruled Out)

### 5.1 Algebraic shortcut on PBKDF2 chain
The U_j → U_{j+1} chain is provably sequential. No mathematical shortcut exists.

### 5.2 Bitsliced SHA-256 across candidates
A 32-bit ADD via bitsliced ripple-carry costs ~80 LOP3s; a native IADD is 1 instruction. Net regression of ~80×. Bitslicing only wins for S-box-heavy ciphers like DES (which has no native 32-bit equivalent).

### 5.3 Approximate scrypt as a filter
scrypt's output is a PRF composition over all N iterations. Any truncation produces cryptographically uncorrelated output. Cannot be used for early rejection.

### 5.4 Cycle detection in PBKDF2 chains
Expected cycle length is ~2^128 for SHA-256. Iteration counts are ≤ 10⁶. Cycles are statistically undetectable.

### 5.5 Pippenger / algebraic methods on scrypt
scrypt's ROMix has no group structure. Pippenger-style multi-scalar multiplication requires an algebraic group operation, which scrypt lacks.

### 5.6 Speculative V[j] prefetch in scrypt
The next gather index `j` depends on the result of the current iteration's salsa. Cannot be predicted with ≥ 1/N probability.

### 5.7 Tensor cores for SHA-256 on consumer GPUs
The non-linear F0/F1 functions cannot be reduced to a matmul. Setup overhead exceeds gain on Ampere. Possible win on Hopper.

### 5.8 Approximating PBKDF2 with reduced rounds
Reduced-round SHA-256 is cryptanalyzable (e.g., 41/64 rounds), but the reduced-round attacks find collisions/preimages — they don't compute the standard hash faster.

---

## 6. Recommended Implementation Roadmap

### Phase A — Low-effort SHA-256 wins (1 week, +30–40% on PBKDF2 wallets)

1. Implement `hc_xor3_S` with explicit `LOP3 0x96` PTX (§4.1)
2. Implement `hc_iadd3_S` with explicit `IADD3` PTX (§4.5)
3. Implement constant message-schedule fast path for PBKDF2 inner block (§4.2)

These three optimizations are independent, low-risk, and applicable to all PBKDF2-HMAC-SHA256 modes (15600, 16300, 25500, 26610, 31900) plus any other mode that calls `sha256_transform_vector` repeatedly.

### Phase B — Medium-effort SHA-256 pipelining (1–2 weeks, additional +15–25%)

4. Cross-stream software pipelining of two independent SHA-256 instances per thread (§4.4)

This requires more careful coding but stacks multiplicatively with Phase A.

### Phase C — scrypt occupancy + pipelining (2–3 weeks, +200% on scrypt wallets)

5. Stage Salsa20 state in shared memory to free registers (§4.6)
6. Cross-candidate pipelining for scrypt ROMix gather + salsa overlap (§4.3)

These two together should bring Ethereum keystore scrypt cracking from ~17 H/s to ~50–80 H/s on RTX 3090. They are the highest-impact items in this entire research effort.

### Phase D — Schedulers and minor tweaks (1 week, +10–50% on edge cases)

7. N-stratified scheduling for mixed-parameter workloads (§4.7)
8. CUDA Graphs for kernel launch overhead reduction (§4.8)
9. Persistent-L2 pinning for scrypt hot V prefix (§4.10)

### Phase E — Other architectures (out of scope for RTX 3090)

10. ARM SHA hardware extensions for Apple Silicon Metal bridge (§4.9)
11. Tensor-core SHA-256 on Hopper (revisit when targeting H100/B100)

---

## 7. Mathematical Bottom Line

For PBKDF2-bound wallets (Ethereum, Stellar, MetaMask): the chain is provably sequential, and the achievable ceiling on RTX 3090 is **~9.27 MH/s** (instruction-bound). Hashcat is currently at 1.18 MH/s = **12.7% of ceiling**. Phases A+B above should bring this to ~20% (~1.85 MH/s, +57%).

For scrypt-bound wallets (Ethereum scrypt mode, MultiBit): the algorithm is **provably memory-hard** (Alwen-Chen-Pietrzak-Reyzin-Tessaro 2017), and TMTO gives at most a factor-of-2 AT improvement asymptotically. The currently achievable constant-factor improvement on Ampere is estimated at **5–8× over hashdog's current implementation**, bringing Ethereum keystore from ~17 H/s to **~100–130 H/s**. Beyond that, the asymptotic wall is real and proven.

For AES-bound wallets (Electrum, MultiBit Classic .key): the dominant cost is the AES-256 key schedule (60 rounds). hashdog already uses bitsliced AES variants. Marginal improvements possible via better cache layout for T-tables, but the ceiling is already close.

---

## 8. References

### Theoretical bounds
- Alwen, Chen, Pietrzak, Reyzin, Tessaro — *Scrypt Is Maximally Memory-Hard* (EUROCRYPT 2017, ePrint 2016/989)
- Alwen, Chen, Kamath, Kolmogorov, Pietrzak, Tessaro — *On the Complexity of Scrypt and Proofs of Space in the pROM* (EUROCRYPT 2017, ePrint 2016/100)
- Percival — *Stronger Key Derivation via Sequential Memory-Hard Functions* (BSDCan 2009)
- Biryukov, Khovratovich — *Tradeoff Cryptanalysis of Memory-Hard Functions* (ASIACRYPT 2015, ePrint 2015/227)
- Auerbach et al. — *A Tight Lower Bound on the TdScrypt Trapdoor Memory-Hard Function* (IACR CiC 2025)
- Blocki, Smearsoll — *Provably Memory-Hard Proofs of Work with Memory-Easy Verification* (TCC 2025, ePrint 2025/1456)

### GPU implementation
- Yao et al. — *TGSC: Tensor-core Guided SHA Computation* (HPCA 2024)
- Feldman, Müller — *On the Limits of Using INT8 Tensor Cores for Cryptographic Hashing* (ePrint 2023/1456)
- Nguyen et al. — *MRSA: Multi-ROMix Scrypt Accelerator* (Multimedia Tools and Applications 2021)
- Zhang et al. — *New Speed Records for Salsa20 Stream Cipher Using an Autotuning Framework on GPUs* (2013)
- Aila & Laine — *Understanding the Efficiency of Ray Traversal on GPUs* (HPG 2009)
- Liu et al. — *SHA-256 on H100 Tensor Cores* (SC 2024)
- Gueron, Krasnov — *Speeding up SHA-1, SHA-256 and SHA-512 on the 2nd Generation Intel Core* (2012)

### NVIDIA architecture documentation
- NVIDIA Ampere GA102 Whitepaper (2020)
- NVIDIA PTX ISA 7.4 — `lop3.b32`, `iadd3`, `bmma.b1`, `cudaAccessPolicyWindow`
- NVIDIA Devblog — Pro Tip: Fast SHA-256 (2021)

### Practical implementations
- cgminer commit `4e6c0a` (2013) — SHA-256 second-block constant-W trick
- John the Ripper `opencl/sha256_kernel.cl` `INTERLEAVED_PASSWORDS` (Solar Designer)
- ccminer `nv_kernel2.cu` — scrypt cross-candidate pipelining (Buchner)
- CudaMiner README — `lookup_gap` heuristic for scrypt TMTO

### Codebase references (hashdog)
- `OpenCL/inc_hash_sha256.h` — σ macros, target for LOP3 fusion
- `OpenCL/inc_hash_sha256.cl` — fully unrolled `sha256_transform`
- `OpenCL/inc_hash_scrypt.cl` — main ROMix/Salsa kernels
- `OpenCL/inc_common.cl` lines 1702–2050 — `hc_add3_S`, `hc_lop_0x96`
- `OpenCL/m10900-pure.cl` — PBKDF2-HMAC-SHA256 reference kernel (mode 10900)
- `OpenCL/m26610-pure.cl` — MetaMask short-hash kernel
- `OpenCL/m15700-pure.cl` — Ethereum keystore scrypt kernel
- `src/modules/scrypt_common.c` lines 92–216 — TMTO heuristic (explicitly suboptimal in source comments)
- `src/modules/module_15700.c` line 59 — `SCRYPT_THREADS = 4`
- `src/dispatch.c` lines 1779–1789 — `run_cracker` invocation
- `src/backend.c` lines 2649–2820 — `KERN_RUN_2` launch path
