# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hashdog is a fork of [hashcat](https://github.com/hashcat/hashcat), the world's fastest password recovery utility. It supports GPU-accelerated cracking via OpenCL/CUDA/HIP/Metal backends for 300+ hashing algorithms. Licensed under MIT.

## Build Commands

**Requirements:** Python 3.12+, GCC (Linux) or Clang (macOS), standard C build tools.

```bash
make clean && make          # Full build (frontend + modules + bridges + feeds)
make                        # Incremental build
make clean                  # Remove build artifacts
make install                # Install (Linux/macOS only)
DEBUG=1 make                # Debug build (-Og -ggdb, disables LTO)
DEBUG=2 make                # Debug build with AddressSanitizer
SHARED=1 make               # Build as shared library (libhashcat.so)
```

**Cross-compilation:**
```bash
make win                    # Cross-compile for Windows from Linux/macOS
make linux                  # Cross-compile Linux binaries
```

**Individual targets:**
```bash
make modules                # Build only hash modules (.so plugins)
make bridges                # Build only bridge plugins
make feeds                  # Build only feed plugins
```

## Testing

Requires a built hashcat binary and an OpenCL runtime. Install Perl/Python test dependencies first:
```bash
tools/install_modules.sh              # Install cpanm + pip deps needed by test suite
```

```bash
tools/test.sh -m all                  # Run full test suite (all hash modes)
tools/test.sh -m 0                    # Test a single hash mode (e.g., 0 = MD5)
tools/test.sh -m 0 -a 0              # Test specific mode + attack mode (0=stdin, 1=combinator, 3=brute, 6=dict+mask, 7=mask+dict)
tools/test.pl single 0               # Generate test vectors for mode 0 (types: single, multi, passthrough, verify, edge)
tools/test_rules.pl                   # Test rule engine
```

**Rust components** (in `Rust/` subdirectories):
```bash
cd Rust/bridges/generic_hash && cargo test
cd Rust/hashcat-sys && cargo check    # FFI bindings (no tests, just check)
```

## Code Style

- **C standard:** gnu99 (`-std=gnu99`)
- **Indentation:** 2 spaces (no tabs except in Makefiles)
- **Block style:** Allman-style braces
- **Naming:** lowercase functions and variables, snake_case
- **Conditionals:** Prefer positive checks (`if (foo == 0)` not `if (!foo)`, `if (foo)` not `if (foo != 0)`)
- **Array alignment:** Use `array[index + 0]` when also accessing `array[index + 1]`
- **Compiler warnings:** Must compile cleanly with `-W -Wall -std=gnu99`
- **Rust:** Edition 2021, formatted with `rustfmt`, linted with clippy. Minimum Rust 1.88.
- **Auto-format (C):** `indent -st -bad -bap -sc -bl -bli0 -ncdw -nce -cli0 -cbi0 -pcs -cs -npsl -bs -nbc -bls -blf -lp -i2 -ts2 -nut -l1024 -nbbo -fca -lc1024 -fc1`

## Architecture

### Plugin System (Dynamically Loaded .so/.dll)

The core binary loads three types of plugins at runtime via `dlopen`/`dlsym`:

1. **Modules** (`src/modules/module_NNNNN.c` -> `modules/module_NNNNN.so`): Each file defines one hash mode (e.g., module_00000.c = MD5). Modules implement the `module_ctx_t` interface from `include/modules.h` — they export functions like `module_hash_decode`, `module_hash_encode`, `module_kern_type`, etc. Interface version: `MODULE_INTERFACE_VERSION = 700`.

2. **Bridges** (`src/bridges/bridge_*.c` -> `bridges/bridge_*.so`): Connect the hashcat core to external compute implementations (Argon2, scrypt, Python, Rust). Each bridge has a companion `.mk` file for build rules. Interface version: `BRIDGE_INTERFACE_VERSION = 700`.

3. **Feeds** (`src/feeds/feed_*.c` -> `feeds/feed_*.so`): Supply candidate passwords to the cracking engine. Interface version: `FEEDS_INTERFACE_VERSION = 713`.

### Core Components

- `src/main.c` — Entry point, invokes `hashcat_session_execute`
- `src/hashcat.c` — Session lifecycle orchestration
- `src/backend.c` — GPU/compute backend abstraction (OpenCL, CUDA, HIP, Metal)
- `src/dispatch.c` — Work distribution to backend devices
- `src/interface.c` — Module loading and hash mode configuration
- `src/generic.c` — Generic plugin system for bridges/feeds
- `src/brain.c` — Distributed cracking coordinator (enabled with `ENABLE_BRAIN=1`)
- `include/types.h` — Central type definitions (`hashcat_ctx_t`, `hashconfig_t`, etc.)

### GPU Kernels

`OpenCL/` contains ~1600 OpenCL kernel files (`.cl` + `.h`). Naming convention:
- `m0NNNN_a0-optimized.cl` — Optimized kernel for hash mode NNNNN, attack mode 0
- `inc_hash_*.cl/h` — Shared hash primitive implementations
- `inc_cipher_*.cl/h` — Shared cipher implementations

### Rust Integration

`Rust/` contains Rust crates that integrate via C FFI:
- `Rust/hashcat-sys/` — `bindgen`-based FFI bindings to hashcat C headers
- `Rust/bridges/generic_hash/` and `Rust/bridges/dynamic_hash/` — Rust bridge implementations
- `Rust/feeds/dummy/` — Example feed plugin in Rust

Bridge `.mk` files in `src/bridges/` define how Rust crates get built and linked (via `cargo build`).

### Python Integration

`Python/` contains Python bridge scripts (`generic_hash_sp.py`, `generic_hash_mp.py`) that implement hash algorithms in Python, loaded via the Python bridge plugins in `src/bridges/`.

### Dependencies (vendored in `deps/`)

LZMA-SDK, zlib, OpenCL-Headers, xxHash, unrar, phc-winner-argon2, scrypt-jane, yescrypt, sse2neon. Controlled via `USE_SYSTEM_*` make variables.

### Build System

The top-level `Makefile` just includes `src/Makefile`, which contains all build logic. The build produces:
- `hashcat` (or `hashcat.exe`) — the frontend binary
- `modules/*.so` — hash mode plugins
- `bridges/*.so` — bridge plugins  
- `feeds/*.so` — feed plugins
- Optionally `libhashcat.so` (when `SHARED=1`)

Parallel build is default (`-j 8`). LTO is enabled by default (`ENABLE_LTO=1`).

### Tools

`tools/` contains test infrastructure, hash format converters (`*2hashcat.py/pl`), and code generators. Test modules live in `tools/test_modules/`.
