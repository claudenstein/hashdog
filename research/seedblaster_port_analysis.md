# Porting SeedBlaster Kernel Optimizations into Hashdog

**Scope:** which of the GPU-kernel optimizations developed in the sister project *SeedBlaster*
(an OpenCL BIP-39 → BIP-32 → secp256k1 seed-recovery tool) can be ported into hashdog's
Bitcoin/cryptocurrency hash modes, and which cannot.
**Method:** cross-codebase analysis — every SeedBlaster optimization (applied, rejected, or
proposed) was catalogued from its kernels and research docs, mapped against hashdog's actual
crypto/EC surface, and the portable claims were adversarially re-verified against the real
source in both repositories.
**Status:** read-only analysis. No kernels were modified. The one actionable item is recorded
as *Phase F* of `research/wallet_optimization_research.md` for later evaluation behind a flag.

---

## 1. Executive summary

- **One optimization genuinely ports and is worth evaluating: `EC_LEAN_REDUCE`** — collapsing
  the redundant second omega-fold loop in `mul_mod` (`OpenCL/inc_ecc_secp256k1.cl:697–715`). It
  is pure `u32`/`u64` arithmetic (no PTX/asm), bit-exact, and verified bit-for-bit (350K+ random
  products plus edge cases in SeedBlaster, and re-derived by hand here). It touches only the 14
  secp256k1-in-kernel "derive-address" modes.
- **The realistic payoff is small and diluted, not a headline.** SeedBlaster measured
  **+0.71 % full-pipeline / +2.3 % EC-stage**. In hashdog the gain lands near the EC-stage
  figure only on the **no-KDF Bitcoin-key modes** (28501–28506, 30901–30906); for the two
  Electrum modes (21700/21800) it is gated behind PBKDF2-HMAC-SHA512 and disappears into the
  noise (< 0.1 %); for **every non-EC wallet mode it is exactly zero** (they never call
  `mul_mod`).
- **Almost everything else SeedBlaster reports as a "win" is already in hashdog**, because
  SeedBlaster forked its secp256k1 and SHA-512 kernels *from hashcat*. The PTX add/sub carry
  chains (its single biggest "+14 %"), the width-4 wNAF + 96-word table, the rolling SHA-512
  schedule, bitselect Ch/Maj, and HMAC ipad/opad midstate reuse are all present in hashdog
  already. Porting them is a no-op.
- **Several primitive-level ideas are tested-and-rejected or audit-undercut.** 5-bit wNAF
  measured **−0.9 % pipeline / −2.8 % EC** on Ampere; GLV is unimplemented and predicted
  flat-to-negative in exactly hashdog's register-capped regime; the gECC PTX-into-`mul_mod` idea
  was found redundant (ptxas already emits `IMAD.WIDE`) and a hand-PTX attempt regressed 27 %.
  None should be ported.
- **The structurally interesting ideas (batch inversion, two-phase filter→derive, CKDpub /
  serP-hoist, BIP-39 glue) have no matching hashdog mode.** They amortize work across a *per-seed
  address window* that hashdog's single-key validator modes do not have. They become relevant
  only if hashdog adds a brand-new BIP-39/Electrum mnemonic seed-recovery mode — a new
  feed/bridge feature, not an optimization of existing kernels.

**Single best opportunity:** `EC_LEAN_REDUCE` into `inc_ecc_secp256k1.cl`'s `mul_mod`, validated
against the existing self-test vectors for modes 28501/30901/21700. Low difficulty, low-to-medium
risk, modest but free gain on the pure-EC Bitcoin-key modes.

---

## 2. Background: the fork relationship and why it shapes the answer

SeedBlaster is an OpenCL BIP-39 → BIP-32 → secp256k1 seed-recovery tool. Critically, **its
elliptic-curve and SHA kernels were forked directly from hashcat** — the same lineage hashdog
descends from. This is not inferred; it is observable at the byte level:

- SeedBlaster's `kernel/ec.cl` uses the **identical** secp256k1 precomputed generator table and
  the same byte-swapped curve constants (`0x79be667e…`, `0x16f81798…`) as hashcat/hashdog's
  `inc_ecc_secp256k1.cl`.
- The `add`/`sub` borrow-and-carry chains, the schoolbook 8×8 `mul_mod` with the `0x3d1`
  (= 977) omega reduction, `sub_mod`/`add_mod`, the Jacobian `point_double` sequence, and the
  binary-GCD `inv_mod` are **line-for-line equivalent** between the two repos.
- SeedBlaster's own documentation states its headline **+14 % EC win was "restored hashcat's
  add.cc/addc carry chains"** that it had previously *stripped* during its fork. That is a
  measurement against its own broken intermediate state — it re-attained the hashcat baseline
  that hashdog never lost.

This single fact reorganizes the entire analysis. A SeedBlaster optimization is only a *real*
porting candidate if **both** of the following hold:

1. **It was added by SeedBlaster beyond the hashcat baseline** (not merely re-attained), AND
2. **It targets code that a hashdog mode actually executes.**

Most SeedBlaster "wins" fail test (1) — they are the shared hashcat ancestry. A second large
class fails test (2) — they optimize a per-seed multi-address derivation pipeline (BIP-32 CKD,
gap-limit address sweep) that **no hashcat/hashdog mode has**, because hashdog's Bitcoin modes
are single-key validators, not on-GPU address scanners.

Exactly **one** item passes both tests: the lean `mul_mod` reduction tail.

---

## 3. Hashdog crypto/EC surface: what bounds applicability

The audit is definitive: **exactly 14 hashdog modes do secp256k1 point math in-kernel**
(`computation_type = derive-address`). They form three families, all sharing the engine
`OpenCL/inc_ecc_secp256k1.cl` (+ `inc_bignum_operations.cl`):

| Family | Modes | KDF before EC? | EC share of runtime |
|---|---|---|---|
| Electrum Salt-Type 4 & 5 | 21700, 21800 | **Yes** — PBKDF2-HMAC-SHA512, then one `point_mul` + SHA256-HMAC | EC is a *small* fraction; KDF dominates |
| Bitcoin WIF private key | 28501, 28502, 28503, 28504, 28505, 28506 | **No** — base58 WIF brute, then `point_mul_xy` + SHA256 + RIPEMD160 | EC + hash160 is essentially the *whole* per-candidate cost |
| Bitcoin raw private key | 30901, 30902, 30903, 30904, 30905, 30906 | **No** — raw 32-byte hex brute, then `point_mul_xy` + hash160 | EC + hash160 is essentially the *whole* cost |

Kernel-sharing detail (relevant to where to apply the patch and how to test): **28503/28504
carry no own `.cl` file** (`KERN_TYPE` = 28501/28502); **30903/30904** likewise reuse
30901/30902. 28505/28506 and 30905/30906 have their own kernels. All 14 nonetheless
`#include inc_ecc_secp256k1.cl` and call `mul_mod` via `point_mul`/`point_mul_xy`, so a change to
the shared header reaches every one.

**Every other "crypto wallet" mode does no EC** and is therefore *out of scope for any EC
change*:

- **KDF-then-AES-decrypt** (`computation_type = decrypt`): 11300 (wallet.dat),
  12700/15200/34700 (Blockchain.com), 15600/15700/16300 (Ethereum keystore), 16600 (older
  Electrum salt 1–3 — note: **does not** use EC, unlike 21700/21800), 22500/22700/27700/29800
  (MultiBit/Bisq), 26600/26610/31900 (MetaMask), 28200 (Exodus), 29600 (Terra), 32500
  (Dogechain), 25500 (Stellar — ed25519, AES-GCM-decrypt only).
- **KDF-only hash/compare**: 18800, 21000.
- **Generic/bridged scrypt**: 08900, 09300, 70100, 70200.
- **Not cryptocurrency at all**: 01500 (descrypt), 22400 (AES Crypt), 24000 (BestCrypt).

This bounds the entire report: **any EC-kernel optimization can affect at most these 14 modes,
and only proportionally to each mode's EC share** — high for 28501–28506/30901–30906, low for
21700/21800.

A second structural fact bounds the *batching*-style ideas: every one of these 14 modes performs
**exactly one `point_mul`/`point_mul_xy` per candidate, one candidate per work-item**, with one
final `inv_mod` (Jacobian → affine). There is no per-seed address window, no BIP-32 child-key
derivation, and no gap-limit sweep anywhere in hashdog. Confirmed directly: `m30901_a0-pure.cl`,
`m28501_a0-pure.cl`, `m21700-pure.cl` each call `point_mul*` exactly once.

---

## 4. Findings

### Portable (adds real, currently-missing capability)

| Optimization | Verdict | Target modes | Difficulty | Risk | Expected impact |
|---|---|---|---|---|---|
| **`EC_LEAN_REDUCE`** — lean `mul_mod` second-fold reduction tail | **Portable, primitive-level** | 21700, 21800, 28501–28506, 30901–30906 (via shared header; a0/a1/a3 kernels) | Low | Low–Medium | +0.5–0.7 % on no-KDF Bitcoin-key modes; < 0.1 % / noise on 21700/21800; **0 on all non-EC modes** |

### Already present (SeedBlaster merely re-attains the hashcat baseline hashdog has)

| Optimization | Why it is a no-op |
|---|---|
| NVIDIA PTX `add.cc/addc` & `sub.cc/subc` carry chains in `add`/`sub` | `inc_ecc_secp256k1.cl:110–126, 164–180`, `IS_NV`-gated with portable `#else`. SeedBlaster's "+14 %" is recovery of a baseline it stripped. |
| Width-4 wNAF + 96-u32 `{1,3,5,7}·G` table, Jacobian, Comba `mul`, binary-GCD `inv_mod` | Byte-identical to hashdog; this *is* the shared ancestry. |
| Rolling 16-word SHA-512 message schedule | `inc_hash_sha512.h` (`SHA512_EXPAND_S`). The file SeedBlaster forked from. |
| Bitselect Ch/Maj (`F0o`/`F1o`) for SHA-512/256 | `inc_hash_sha512.h` under `USE_BITSELECT`. On SHA-256 hashdog is *ahead* of SeedBlaster. |
| HMAC-SHA512 ipad/opad midstate precompute | `sha512_hmac_ctx_t` with separate `.ipad/.opad`; standard hashcat HMAC. |
| Inline immediate SHA-512/256 round constants | Compile-time literals; on SHA-256 hashdog beats SeedBlaster's `__constant K_256[]`. |
| PBKDF2-HMAC-SHA512 inner loop ("near-optimal, ~82 % of SHA-512 ceiling") | All three sub-techniques already in `inc_hash_sha512`; SeedBlaster concludes no further single-thread win exists. |
| `LOCAL=64` launch geometry | hashdog's `src/autotune.c` sweeps `kernel_threads` per device/kernel; a hardcoded 64 would *hurt* portability. |
| Multi-GPU candidate-range sharding | `src/dispatch.c` + `src/brain.c` + `--skip/--limit`. Host orchestration, not a kernel technique. |
| Intra-thread SIMD / vector-width batching | hashdog autotunes `vector_width`, selects 1 on NVIDIA (= SeedBlaster's design), wider on AMD/CPU. |
| keccak256-of-pubkey (ETH address) | hashdog implements Keccak/SHA3 for 15600/15700/16300; the ETH-spec pad/layout bits are not optimizations. |
| hash160 packing / RIPEMD-160 single-block-of-32 B | 28501/28505 families already do shift-packed `ripemd160(sha256(pubkey))` with constant pad/length. |

### Not applicable (tested-and-rejected, audit-undercut, or no matching mode)

| Optimization | Why it does not port |
|---|---|
| 5-bit wNAF (width-5, 192-word table) | **Measured −0.9 % pipeline / −2.8 % EC** on RTX 3090. SeedBlaster ships it default-OFF. Bigger table = register pressure the latency-bound 255-reg kernel can't absorb. |
| GLV / λ-endomorphism scalar split | Never implemented in SeedBlaster; docs-only proposal. Predicted flat-to-negative by analogy to the rejected 5-bit wNAF, in exactly hashdog's register regime. Also needs φ(basepoint) per-point for runtime-basepoint modes. |
| gECC-style PTX into `mul_mod` (`mad.lo.cc/madc.hi.cc` Comba) | Unimplemented in both repos. ptxas **already** lowers the portable Comba to `IMAD.WIDE.U32`+`IMAD.X`; a hand-PTX Comba came out **27 % worse**. NV-only, per-card SASS audit required. |
| Batch / Montgomery simultaneous z-inversion | SeedBlaster measured only **+1.44 %** and dropped it from production. Requires a per-seed address window to amortize over; hashdog has one inversion per candidate (n = 1). |
| serP-hoist out of gap-limit address loop | No per-candidate multi-address loop exists to hoist out of. |
| CKDpub point-addition for gap-limit sweep (+ `point_add_affine_rt`) | Needs a parent point + address window; with one `point_mul`/candidate there is nothing to add onto. Primitive would be dead code. |
| Two-phase filter→compact→derive missing-word search | Real and structurally interesting, but needs a cheap high-rejection checksum gating an expensive inner loop — i.e. a **new** BIP-39/Electrum mnemonic mode (feed/bridge plugin), not a tweak to 28505/30901. |
| BIP-39 entropy bit-packing / mnemonic build | BIP-39-specific host glue; no mnemonic mode exists. Cost negligible vs PBKDF2 even if added. |
| Precompute hashes of fixed leading mnemonic words | Measured < 0.05 %; the PBKDF2 loop is irreducible. A negative structural result. |
| `maxrregcount` sweep / latency-bound diagnosis | Methodology finding, no artifact. Register capping was monotonically slower; hashdog's autotune already avoids it. |
| Cloud GPU spot-fleet sharding | Ops/economics, not a kernel change. hashdog already has `brain.c` + `--restore`. |

---

## 5. Deep-dive: the one genuinely portable item — `EC_LEAN_REDUCE`

### 5.1 What it is

hashdog's `mul_mod` (`inc_ecc_secp256k1.cl:593`) reduces a 256×256 → 512-bit schoolbook product
modulo `SECP256K1_P = 2²⁵⁶ − 2³² − 977` using two omega folds (exploiting
`2²⁵⁶ ≡ 2³² + 977 (mod p)`, i.e. ω = `0x1000003d1` split as `0x3d1` + carry).

The **first fold** (lines 671–689) folds the top 8 limbs `t[8..15]` back down into `tmp[0..9]`.
After it, the overflow above `2²⁵⁶` can land **only in `tmp[8]` and `tmp[9]`** — `tmp[10..15]`
are provably zero. (Independently confirmed: across 350K random products plus `P−1000..P` edges,
`tmp[10..15] == 0` in 100 % of cases.)

The **second fold** (lines 697–715) is the inefficiency: it runs a **full 8-iteration loop**
`p = 0x3d1*tmp[8+i] + c2` over `tmp[8..15]`, multiplying **zero by `0x3d1` for 6 of 8
iterations**, then sets `t[8]=c2; add(t+1,t+1,tmp+8); t[9]=c2;`. Those high words `t[8]/t[9]`
are then **never read** — the final tail `add(r, r, t)` is an 8-limb operation (`add` only
touches `r[0..7]`), so they are **dead writes**.

### 5.2 What to change, and where

Inside `mul_mod`, after the first fold computes `tmp[]` and `c = add(r, t, tmp)` (~line 689),
replace the second-fold loop and the `t[8]/t[9]` writes (lines 697–710) with a minimal scalar
fold of the two nonzero overflow words, immediately before `c2 = add(r, r, t);`:

```c
u64 TMP = (u64) tmp[8] + ((u64) tmp[9] << 32);   // the only nonzero overflow
u64 f   = 977ul * TMP;                           // low part of TMP * (2^32 + 977)
t[0] = (u32) f;
u64 a1 = (f  >> 32) + (u64) tmp[8]; t[1] = (u32) a1;
u64 a2 = (a1 >> 32) + (u64) tmp[9]; t[2] = (u32) a2;
t[3] = (u32) (a2 >> 32);
t[4] = 0; t[5] = 0; t[6] = 0; t[7] = 0;
```

Then **keep the existing tail unchanged**: `c2 = add(r, r, t); c += c2;` (lines 715–717)
followed by the conditional-subtraction-of-P loop (lines 719–743). Gate behind
`#ifdef EC_LEAN_REDUCE` for clean A/B; the fold is unconditionally safe to inline.

**Correctness derivation.** The original second fold computes, in the low 256 bits,
`t = 0x3d1·TMP + TMP·2³² = TMP·(2³² + 977)` where `TMP = tmp[8] + tmp[9]·2³²`. The lean form
computes the identical value directly: `f = 977·TMP` supplies the low part, and adding
`TMP·2³²` shifts `tmp[8]`/`tmp[9]` into limbs 1/2 with carry into limb 3. Verified bit-exact by
hand over the full `tmp[8]` range with `tmp[9] ∈ {0,1}`, and by SeedBlaster's oracle (Python
`ecdsa`, 300+ keys; 350K random products including `tmp8 = tmp9 = 0xFFFFFFFF` and `SECP_P`
edges) → **0 mismatches** on both `r[0..7]` and the carry into the final subtract loop. Use `+`
(not `|`) per the verified source operator.

### 5.3 Expected gain (honest)

- SeedBlaster measured **+0.71 % full pipeline (456.1 → 459.4 K/s), +2.3 % EC stage in
  isolation**, control delta +0.01 % (drift-cancelled).
- In hashdog the realized gain is the EC-stage figure **scaled by each mode's EC share**:
  - **28501–28506, 30901–30906** (no password KDF): approach the full ~+0.5–0.7 %. hash160 and
    base58/bech32 dilute it somewhat below the bare 2.3 % EC-stage number.
  - **21700, 21800**: gated behind PBKDF2-HMAC-SHA512 with one `point_mul`; expect **well under
    0.1 %**, likely in the noise.
  - **All ~30 non-EC wallet modes**: exactly **zero** — they never `#include inc_ecc_secp256k1.cl`.

Do **not** advertise "+0.7 %" as a global number — it is per-mode and concentrated on the
no-KDF Bitcoin-key modes.

### 5.4 How to validate bit-exactly

1. **On-device diff:** run unmodified `mul_mod` vs lean `mul_mod` over a large random `(a,b)`
   corpus on each backend, asserting `r[0..7]` and the carry `c` are identical. (Off-device this
   has already been re-derived over 300K–350K products plus all-`0xFFFFFFFF` and `SECP_P` edges
   → 0 mismatches.)
2. **Known-answer recovery via the existing self-tests** (free oracle): `tools/test.sh -m 28501`,
   `-m 30901`, `-m 21700` — extend to all own-kernel modes (28501/28502/28505/28506,
   30901/30902/30905/30906) across attack modes **a0/a1/a3**, since the patch lives in the shared
   header and reaches every variant.
3. **Cross-vendor smoke test:** because the selling point is *no `IS_NV` gate*, diff a handful of
   `k·G` outputs before/after on at least one **AMD/HIP** backend.
4. **Benchmark** 28501 and 30901 (pure-EC) to confirm a small positive delta; expect no
   measurable change on 21700/21800.

### 5.5 Risks

- **Medium blast radius despite low difficulty:** `mul_mod` is the hottest inner EC primitive
  (~256× per scalar-mult). Any off-by-one in limb indexing, the constant, or carry accounting
  corrupts **every** EC result, and the modest +0.7 % ceiling means a subtle regression could
  hide. Mitigation is the bit-for-bit diff (1) plus the full self-test matrix (2).
- **Transcription is the only real failure mode** — the math is *proven* equal. Copy the
  expression verbatim.
- **Origin:** the omega-fold structure is a general number-theoretic identity, not
  hashcat-derived, so this is a genuine addition rather than a re-attainment.

---

## 6. Honest negatives: what looks portable but is not

**Pipeline / launch geometry is already hashcat's job.** `LOCAL=64`, multi-GPU sharding, and
vector-width selection are all auto-discovered by hashdog (`src/autotune.c` sweeps
`kernel_threads`; `src/dispatch.c`/`src/brain.c` shard the keyspace; `backend.c` picks
`vector_width`). SeedBlaster needs hardcoded constants *because it has no autotuner*. Baking
`LOCAL=64` into hashdog would override the per-device tuner and **regress** on cards that prefer
otherwise.

**Address-derivation optimizations have no matching multi-address mode.** Batch/Montgomery
inversion, CKDpub point-addition, and the serP-hoist all amortize work across a **per-seed
gap-limit address window**. That structure lives in SeedBlaster's `benchmark.cl`
(`find_ckd_scan_batch`, `derive_change_node_bip84`), where one seed derives many sequential
child addresses sharing a parent node. **No hashcat/hashdog mode has this shape** — each
candidate is independent, one per work-item, one `point_mul` + one `inv_mod`. With n = 1 there is
nothing to batch. Even SeedBlaster, on its *favorable* workload, measured batch inversion at only
**+1.44 %** and left it out of production.

**The SHA wins are the file SeedBlaster forked from.** Rolling schedule, bitselect Ch/Maj, HMAC
midstate reuse, inline round constants — all in `inc_hash_sha512`/`inc_hash_sha256` already. On
SHA-256, hashdog is *ahead* (inline constants and bitselect vs SeedBlaster's `__constant K_256[]`
and boolean Ch/Maj). The TRIM8/fixed-words idea measured **+0.6 % noise and was reverted** even
on the source project.

**The PTX-into-`mul_mod` idea is audit-undercut.** SeedBlaster's own `cuobjdump`/ptxas audit
(sm_86) found the portable `(ulong)`-Comba **already** lowers to fused `IMAD.WIDE.U32` (73×) +
`IMAD.X` (58×). The only theoretically-capturable delta is carry-scaffolding fusion, and a naive
hand-PTX Comba came out **27 % worse** (304 vs 240 SASS) by blocking ptxas scheduling. Do not
port.

**GLV and 5-bit wNAF lose in this regime.** 5-bit wNAF is directly measured at **−0.9 % pipeline
/ −2.8 % EC** (the strongest empirical signal). GLV is unimplemented and predicted
flat-to-negative by analogy — its second `__constant` β-table and lattice-decomposed scalar state
add exactly the register pressure that sinks 5-bit wNAF, on the same 255-reg latency-bound
kernels.

---

## 7. Prioritized recommendations

| Priority | Action | Effort | Impact | Recommendation |
|---|---|---|---|---|
| **1** | Evaluate **`EC_LEAN_REDUCE`** in `inc_ecc_secp256k1.cl` `mul_mod` (behind `#ifdef`); validate with `tools/test.sh -m {28501,28502,28505,28506,30901,30902,30905,30906,21700,21800}` across a0/a1/a3 + an AMD/HIP `k·G` diff. Recorded as *Phase F* in `wallet_optimization_research.md`. | Low | +0.5–0.7 % on no-KDF Bitcoin-key modes; 0 elsewhere | **Candidate to evaluate** — the one clean, bit-exact, vendor-portable, currently-missing primitive win. |
| **2** | Leave the PTX carry chains, width-4 wNAF, SHA-512/256 cores, autotuner, dispatcher, and `vector_width` selection untouched. | Trivial | 0 | **No action** — already optimal or ahead; porting would be a no-op or a regression. |
| **3** | Record 5-bit wNAF (−0.9 %/−2.8 %), GLV (predicted negative), PTX-`mul_mod` (audit-undercut, −27 % hand-PTX), `maxrregcount` capping as **tested/predicted-and-rejected**. | Trivial | 0 | **Document, do not implement.** Prevents re-litigation. |
| **4** | Treat batch/Montgomery inversion, CKDpub, serP-hoist as **known non-ports** (no matching mode; +1.4 % ceiling on a more favorable workload). | — | ~0 | **Skip** unless a multi-address mode is built. |
| **5** | *If* a future BIP-39/Electrum **mnemonic seed-recovery mode** is added: the two-phase filter→derive pattern, CKDpub gap-limit sweep, batch inversion, BIP-39 bit-packing, and `point_add_affine_rt` all become relevant — as a new **feed/bridge plugin + kernel feature**, with host-owned exactly-once "found" logic. | High | New capability, not an existing-mode speedup | **Future feature track**, out of scope for porting into current modes. |

**Bottom line:** one optimization (`EC_LEAN_REDUCE`) is worth evaluating, with a small, honest,
EC-share-diluted gain on the 14 secp256k1 modes — meaningful only on the no-KDF Bitcoin-key
families. Everything else is either already in hashdog by shared hashcat ancestry,
measured/predicted to regress, or blocked on a multi-address derivation mode that hashdog does
not have.

---

## 8. Method & provenance

Produced by a multi-agent cross-codebase analysis: SeedBlaster optimizations were catalogued from
`kernel/*.cl` and `docs/{kernel-optimization-research,speed-optimization-research,address-derivation-research}.md`;
hashdog's surface was mapped by enumerating the Bitcoin/crypto modules and grepping for
`#include inc_ecc_secp256k1.cl`; each "portable" claim was adversarially re-verified against the
real source in both repositories. The `EC_LEAN_REDUCE` deep-dive's load-bearing claim — that
`mul_mod`'s second fold is redundant with dead `t[8]/t[9]` writes — was confirmed directly
against `OpenCL/inc_ecc_secp256k1.cl:593–744`.
