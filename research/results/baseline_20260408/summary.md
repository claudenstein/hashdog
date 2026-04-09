# Baseline Measurements — 2026-04-08

## System Configuration
- GPU: NVIDIA GeForce RTX 3090 (24GB, 82 MCU)
- CUDA: 13.1
- OS: Linux 6.17.0-20-generic
- Build: hashdog v7.1.2 + HASHDOG_PERF instrumentation

## Benchmark Mode (Brute-Force / Mask Attack)

In benchmark mode, candidates are generated on-GPU via mask expansion.
The dispatch loop only does `get_work → run_copy → run_cracker`.

| Mode | Hash | Speed | GPU Util | Copy % | Cracker % |
|------|------|-------|----------|--------|-----------|
| 0    | MD5         | 70,686 MH/s | 99.1% | 0.9% | 99.1% |
| 100  | SHA1        | 24,706 MH/s | 99.6% | 0.4% | 99.6% |
| 1400 | SHA256      |  9,360 MH/s | 99.9% | 0.1% | 99.9% |
| 1700 | SHA512      |  3,182 MH/s | 100.0% | 0.0% | 100.0% |
| 400  | phpass      |  21,742 kH/s | 99.3% | 0.7% | 99.3% |

**Finding:** In brute-force mode, GPU utilization is 99-100%. The pipeline is
already saturated because candidate generation happens on the GPU. Copy overhead
is minimal (0-1%). There is essentially no optimization opportunity for
brute-force benchmark mode.

## Dictionary + Rules Attack (Slow Candidates Mode)

MD5 mode 0, example.dict (128K words) + best66.rule (66 rules), --slow-candidates:

| Stage     | Time (ms) | % of Total |
|-----------|-----------|------------|
| generate  | 1436.3    | 94.1%      |
| copy      | 83.9      | 5.5%       |
| cracker   | 6.7       | 0.4%       |
| **total** | **1526.9**|            |

**GPU utilization: 0.4%**

**Finding:** In dictionary+rules mode with slow-candidates, the GPU is almost
completely idle. 94% of time is spent in CPU-side candidate generation
(rule application via `_old_apply_rule()`). This is where optimization matters:

1. Pipeline parallelism (generate batch N+1 while GPU processes batch N)
2. Vectorized rule engine (SIMD-accelerated rule application)
3. Move rule application to GPU (already done in non-slow-candidates mode)

## Key Insight

The bottleneck is **attack-mode dependent**:

- **Brute-force/mask:** GPU-saturated, ~100% utilization. Optimization must target
  the GPU kernels themselves (algorithmic, occupancy, vectorization).
- **Dictionary+rules (slow):** CPU-starved, <1% GPU utilization. Optimization must
  target the candidate generation pipeline (parallelism, vectorization, GPU rules).
- **Dictionary (fast path):** Uses GPU-side rule amplification, expected high util.

The most impactful optimization target is the **slow-candidates pipeline**, where
the GPU sits idle 99.6% of the time waiting for CPU candidate generation.
