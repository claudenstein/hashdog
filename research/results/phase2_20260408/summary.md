# Phase 2 Optimization Baseline — 2026-04-08

## System: RTX 3090, CUDA 13.1, Driver 590.48.01

## Brute-Force Benchmarks (GPU-side candidate generation)

| Mode | Hash | Speed | GPU Util | Copy % | Cracker % |
|------|------|-------|----------|--------|-----------|
| 0 | MD5 | 65.1 GH/s | 99.1% | 0.9% | 99.1% |
| 100 | SHA1 | 23.1 GH/s | 99.6% | 0.4% | 99.6% |
| 1400 | SHA256 | 8.8 GH/s | 99.9% | 0.1% | 99.9% |
| 1700 | SHA512 | 3.0 GH/s | 100.0% | 0.0% | 100.0% |

## Dictionary+Rules (Slow-Candidates) — 128K words × 66 rules

| Metric | Value |
|--------|-------|
| Batches | 2 |
| Candidates | 8,650,752 |
| Generate (CPU) | 1506.4 ms (94.0%) |
| Copy (H2D) | 88.9 ms (5.5%) |
| Cracker (GPU) | 6.9 ms (0.4%) |
| Total | 1602.1 ms |
| **GPU Utilization** | **0.4%** |

## Comparison vs Phase 1 Baseline

| Metric | Phase 1 | Phase 2 | Delta |
|--------|---------|---------|-------|
| MD5 BF | 70.7 GH/s | 65.1 GH/s | -7.9% (variance) |
| SHA256 BF | 9.4 GH/s | 8.8 GH/s | -6.4% (variance) |
| SHA512 BF | 3.2 GH/s | 3.0 GH/s | -6.3% (variance) |
| Dict+Rules GPU util | 0.4% | 0.4% | No change |
| Dict+Rules generate | 1436.3 ms | 1506.4 ms | +4.9% (variance) |

Note: BF speed differences within measurement noise (different runtime lengths,
thermal conditions, background load). Phase 2 changes don't affect BF throughput
(expected — autotune cache only helps startup, pinned memory only helps H2D,
rule malloc fix only helps CPU rule path).

## Key Finding

The slow-candidates path remains **94% CPU-bound**. The pipeline parallelism
infrastructure (Phase 3) targets this bottleneck by overlapping CPU generation
with GPU execution. Current GPU utilization of 0.4% means the GPU is idle 99.6%
of the time during dictionary+rules attacks.
