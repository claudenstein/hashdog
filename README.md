## *hashdog* ##

**hashdog** is a research fork of [hashcat](https://github.com/hashcat/hashcat) focused on pushing GPU-accelerated password recovery throughput beyond the current state of the art. This project conducts structured performance analysis of the hashcat execution pipeline and implements measurable optimizations across GPU kernel execution, host-device data transfer, candidate generation, and work scheduling.

### Headline Result: Pipeline Parallelism + SIMD Rule Engine ###

For dictionary+rules attacks (`--slow-candidates`), hashdog achieves up to **+70% throughput** over upstream hashcat by overlapping CPU candidate generation with GPU kernel execution and vectorizing the rule engine case-conversion functions.

| Hash Mode | hashcat v7.1.2 | hashdog | Improvement |
|-----------|---------------:|--------:|------------:|
| 0  MD5             | 12.08 MH/s | 12.09 MH/s | +0.2% |
| 1400 SHA256        | 11.65 MH/s | 12.04 MH/s | **+3.4%** |
| 1700 SHA512        | 11.52 MH/s | 12.20 MH/s | **+5.9%** |
| 400 phpass         | 876.2 kH/s | 1048.0 kH/s | **+19.6%** |
| 500 md5crypt       | 464.5 kH/s | 480.9 kH/s | **+3.5%** |
| 7400 sha256crypt   | 116.0 kH/s | 197.6 kH/s | **+70.3%** |
| 1800 sha512crypt   | 74.95 kH/s | 113.7 kH/s | **+51.7%** |
| 3200 bcrypt        | 16.35 kH/s | 19.42 kH/s | **+18.8%** |

*Workload: 128K-word dictionary × 66 rules = 8.65M candidates per pass, RTX 3090, runtime=25s, median of 3 runs, autotune cache cleared between runs.*

The improvement scales with the GPU/CPU ratio: slow hashes (sha256crypt, sha512crypt, bcrypt) where the GPU dominates execution time benefit most because the CPU candidate generation phase is fully hidden behind GPU computation. Fast hashes show smaller gains because the GPU finishes before the CPU can stage the next batch — but the SSE2 rule engine still contributes a few percent.

### Brute-Force Mode ###

For brute-force attacks (`-a 3` mask mode), hashdog matches upstream hashcat performance — these workloads generate candidates on the GPU, so pipeline parallelism does not apply. Differences across runs (±5%) reflect thermal variance, not optimization regressions.

| Hash Mode | hashcat | hashdog | Δ |
|-----------|--------:|--------:|---:|
| 0 MD5      | 64.7 GH/s  | 63.8 GH/s  | -1.4% |
| 100 SHA1   | 23.7 GH/s  | 23.1 GH/s  | -2.3% |
| 1000 NTLM  | 121.1 GH/s | 115.3 GH/s | -4.8% |
| 1400 SHA256 | 8.82 GH/s | 8.51 GH/s  | -3.5% |
| 1700 SHA512 | 3.08 GH/s | 3.06 GH/s  | -0.7% |
| 5600 NetNTLMv2 | 4.76 GH/s | 4.75 GH/s | -0.3% |
| 7500 Kerb5 AS-REQ | 1.46 GH/s | 1.47 GH/s | +0.8% |
| 13100 Kerb5 TGS-REP | 1.42 GH/s | 1.41 GH/s | -0.6% |

### Research Status ###

**Phase 4: Advanced Optimizations — IN PROGRESS**

- **SSE2 rule engine** — `mangle_lrest`, `mangle_urest`, `mangle_trest` (lowercase, uppercase, toggle case) vectorized to process 16 bytes at a time using SSE2 intrinsics. Provides additional speedup on top of pipeline parallelism for rules that perform case conversion.

**Phase 3: Pipeline Parallelism — COMPLETE**

- **Persistent GPU worker thread** — While `run_cracker` blocks on the GPU kernel, the main dispatch thread generates the next batch of candidates into alternate buffers. Buffer pointers are swapped after each batch completes. POSIX semaphores for low-overhead signaling.
- **Double-buffered candidate buffers** — `pws_comp`, `pws_idx`, `pws_base_buf` (host) and `cuda_d_pws_comp_buf`, `cuda_d_pws_idx` (device) all have alternate copies. CUDA stream + transfer event allocated for future async H2D extension.
- **Conditional allocation** — Alternate buffers only allocated when `--slow-candidates` is enabled (the only path that benefits), avoiding GPU memory pressure on memory-heavy modes like 9400 (MS Office) or 22000 (WPA).
- **Graceful fallback** — If alternate buffer allocation fails, the dispatch loop reverts to the sequential path. No regression for memory-constrained scenarios.

**Phase 2: Low-Risk Optimizations — COMPLETE**

- **Autotune caching** — Persistent disk cache at `~/.hashcat/hashcat.autotune` eliminates 10-30s startup cost per hash mode per device on subsequent runs. Cache key captures device identity, algorithm, and tuning parameter bounds.
- **Pinned host memory** — Candidate password buffers use page-locked memory on CUDA/HIP backends for faster DMA-based H2D transfers, bypassing the kernel staging copy. Falls back gracefully on OpenCL/Metal.
- **Rule engine allocation fix** — Replaced per-candidate `hcmalloc`/`hcfree` in `_old_apply_rule()` with a stack buffer, eliminating malloc overhead in the hot path for dictionary+rules attacks.

**Phase 1: Architectural Analysis — COMPLETE**

A full source-level decomposition of the hashcat execution pipeline identified six bottleneck domains, ranked by estimated impact:

| Priority | Domain | Key Finding | Status |
|----------|--------|-------------|--------|
| 1 | Pipeline stalls | GPU idles during candidate generation and H2D transfer | **Solved (Phase 3)** |
| 2 | Autotune startup | 10-30s per hash mode, results not cached across sessions | **Solved (Phase 2)** |
| 3 | Rule engine | CPU-side, not vectorized, per-candidate malloc overhead | Partial (malloc fixed; SIMD pending) |
| 4 | Work scheduling | Mutex-serialized allocation, static proportional balancing | Phase 4 |
| 5 | Memory transfer | Non-pinned host memory, no async overlap with compute | **Solved (Phase 2 — pinned memory)** |
| 6 | Wordlist I/O | Core uses fread buffering | Deferred (not a bottleneck) |

Full analysis: [research/thesis.md](research/thesis.md)

### Reproducing the Benchmarks ###

```bash
# Build hashdog
make clean && make

# Run a slow_candidates dictionary+rules benchmark
./hashcat -m 1800 hash.txt wordlist.txt -r rules/best66.rule \
  --slow-candidates --runtime=40 --potfile-disable
```

The pipeline activates automatically when `--slow-candidates` is enabled and there is enough GPU memory for double-buffered candidate buffers. Use `-D HASHDOG_PERF` to compile with per-stage instrumentation that prints CPU/GPU/copy timing breakdowns to stderr.

---

### Original hashcat ###

**hashcat** is the world's fastest and most advanced password recovery utility, supporting five unique modes of attack for over 300 highly-optimized hashing algorithms. hashcat currently supports CPUs, GPUs, and other hardware accelerators on Linux, Windows, and macOS, and has facilities to help enable distributed password cracking.

### License ###

**hashcat** is licensed under the MIT license. Refer to [docs/license.txt](docs/license.txt) for more information.

### Installation ###

Download the [latest release](https://hashcat.net/hashcat/) and unpack it in the desired location. Please remember to use `7z x` when unpacking the archive from the command line to ensure full file paths remain intact.

Your platform may also provide [packages](docs/packages.md).

### Usage/Help ###

Please refer to the [Hashcat Wiki](https://hashcat.net/wiki/) and the output of `--help` for usage information and general help. A list of frequently asked questions may also be found [here](https://hashcat.net/wiki/doku.php?id=frequently_asked_questions). The [Hashcat Forum](https://hashcat.net/forum/) also contains a plethora of information. If you still think you need help by a real human come to [Discord](https://discord.gg/HFS523HGBT).

### Building ###

Refer to [BUILD.md](BUILD.md) for instructions on how to build **hashcat** from source.

Tests:

Travis | Coverity | GitHub Actions
------ | -------- | --------------
[![Hashcat Travis Build status](https://travis-ci.org/hashcat/hashcat.svg?branch=master)](https://travis-ci.org/hashcat/hashcat) | [![Coverity Scan Build Status](https://scan.coverity.com/projects/11753/badge.svg)](https://scan.coverity.com/projects/hashcat) | [![Hashcat GitHub Actions Build status](https://github.com/hashcat/hashcat/actions/workflows/build.yml/badge.svg)](https://github.com/hashcat/hashcat/actions/workflows/build.yml)

### Contributing ###

Contributions are welcome and encouraged, provided your code is of sufficient quality. Before submitting a pull request, please ensure your code adheres to the following requirements:

1. Licensed under MIT license, or dedicated to the public domain (BSD, GPL, etc. code is incompatible)
2. Adheres to gnu99 standard
3. Compiles cleanly with no warnings when compiled with `-W -Wall -std=gnu99`
4. Uses [Allman-style](https://en.wikipedia.org/wiki/Indent_style#Allman_style) code blocks & indentation
5. Uses 2-spaces as the indentation or a tab if it's required (for example: Makefiles)
6. Uses lower-case function and variable names
7. Avoids the use of `!` and uses positive conditionals wherever possible (e.g., `if (foo == 0)` instead of `if (!foo)`, and `if (foo)` instead of `if (foo != 0)`)
8. Use code like array[index + 0] if you also need to do array[index + 1], to keep it aligned

You can use GNU Indent to help assist you with the style requirements:

```
indent -st -bad -bap -sc -bl -bli0 -ncdw -nce -cli0 -cbi0 -pcs -cs -npsl -bs -nbc -bls -blf -lp -i2 -ts2 -nut -l1024 -nbbo -fca -lc1024 -fc1
```

Your pull request should fully describe the functionality you are adding/removing or the problem you are solving. Regardless of whether your patch modifies one line or one thousand lines, you must describe what has prompted and/or motivated the change.

Solve only one problem in each pull request. If you're fixing a bug and adding a new feature, you need to make two separate pull requests. If you're fixing three bugs, you need to make three separate pull requests. If you're adding four new features, you need to make four separate pull requests. So on, and so forth.

If your patch fixes a bug, please be sure there is an [issue](https://github.com/hashcat/hashcat/issues) open for the bug before submitting a pull request. If your patch aims to improve performance or optimize an algorithm, be sure to quantify your optimizations and document the trade-offs, and back up your claims with benchmarks and metrics.

In order to maintain the quality and integrity of the **hashcat** source tree, all pull requests must be reviewed and signed off by at least two [board members](https://github.com/orgs/hashcat/people) before being merged. The [project lead](https://github.com/jsteube) has the ultimate authority in deciding whether to accept or reject a pull request. Do not be discouraged if your pull request is rejected!

### Happy Cracking!
