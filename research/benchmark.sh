#!/usr/bin/env bash

##
## hashdog benchmark harness
##
## Runs hashcat benchmark across representative hash modes and
## collects both standard performance metrics and hashdog-perf
## pipeline timing data.
##
## Usage:
##   ./research/benchmark.sh              # full benchmark suite
##   ./research/benchmark.sh --quick      # fast subset only
##   ./research/benchmark.sh --mode 0     # single mode
##
## Prerequisites:
##   Build with: CFLAGS="-DHASHDOG_PERF" make clean && make
##
## Output:
##   research/results/<timestamp>/         — per-run directory
##     benchmark_<mode>.txt                — hashcat stdout
##     perf_<mode>.txt                     — hashdog-perf stderr
##     summary.csv                         — structured results
##

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BIN="${ROOT_DIR}/hashcat"

# Representative hash modes across speed categories
FAST_MODES="0 100 1400 1700"                          # MD5, SHA1, SHA256, SHA512
MEDIUM_MODES="400 1800 3200 10900"                     # phpass, sha512crypt, bcrypt, PBKDF2-SHA256
SLOW_MODES="8900 15700"                                # scrypt, Ethereum Wallet

ALL_MODES="${FAST_MODES} ${MEDIUM_MODES} ${SLOW_MODES}"

RUNS=3                    # repetitions per mode
RUNTIME=10                # seconds per benchmark run

# Parse arguments
MODE_FILTER=""
QUICK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)  QUICK=1; shift ;;
    --mode)   MODE_FILTER="$2"; shift 2 ;;
    --runs)   RUNS="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    *)        echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -n "$MODE_FILTER" ]]; then
  ALL_MODES="$MODE_FILTER"
elif [[ "$QUICK" -eq 1 ]]; then
  ALL_MODES="$FAST_MODES"
fi

# Create output directory
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${SCRIPT_DIR}/results/${TIMESTAMP}"
mkdir -p "$OUTDIR"

# System info
echo "=== hashdog benchmark ===" | tee "$OUTDIR/system_info.txt"
echo "Date:     $(date -Iseconds)" | tee -a "$OUTDIR/system_info.txt"
echo "Kernel:   $(uname -r)" | tee -a "$OUTDIR/system_info.txt"
echo "CPU:      $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'unknown')" | tee -a "$OUTDIR/system_info.txt"
echo "Binary:   $BIN" | tee -a "$OUTDIR/system_info.txt"

# Check if binary has HASHDOG_PERF compiled in (heuristic: run with empty hash)
echo "Modes:    $ALL_MODES" | tee -a "$OUTDIR/system_info.txt"
echo "Runs:     $RUNS" | tee -a "$OUTDIR/system_info.txt"
echo "Runtime:  ${RUNTIME}s per run" | tee -a "$OUTDIR/system_info.txt"
echo "" | tee -a "$OUTDIR/system_info.txt"

# Detect available devices
echo "--- Devices ---" | tee -a "$OUTDIR/system_info.txt"
"$BIN" -I 2>/dev/null | head -30 | tee -a "$OUTDIR/system_info.txt" || echo "(no OpenCL/CUDA devices detected — benchmark will use CPU or fail)" | tee -a "$OUTDIR/system_info.txt"
echo ""

# CSV header
CSV="$OUTDIR/summary.csv"
echo "mode,run,hash_name,speed_hs,speed_unit,exec_time_ms" > "$CSV"

for mode in $ALL_MODES; do
  echo ">>> Benchmarking mode $mode ($RUNS runs, ${RUNTIME}s each) ..."

  for run_num in $(seq 1 $RUNS); do
    BENCH_OUT="$OUTDIR/benchmark_${mode}_run${run_num}.txt"
    PERF_OUT="$OUTDIR/perf_${mode}_run${run_num}.txt"

    # Run benchmark with runtime limit
    "$BIN" -b -m "$mode" \
      --runtime="$RUNTIME" \
      --machine-readable \
      --quiet \
      --potfile-disable \
      --logfile-disable \
      --self-test-disable \
      > "$BENCH_OUT" 2> "$PERF_OUT" || true

    # Parse machine-readable output: DEVICE:HASH_TYPE:EXEC_MS:SPEED:SPEED_UNIT
    # hashcat benchmark machine-readable format varies, extract what we can
    if [[ -s "$BENCH_OUT" ]]; then
      while IFS=: read -r device hash_type exec_ms speed speed_unit rest; do
        echo "$mode,$run_num,$hash_type,$speed,$speed_unit,$exec_ms" >> "$CSV"
      done < "$BENCH_OUT"
    else
      echo "$mode,$run_num,,,," >> "$CSV"
    fi

    # Show perf data if present
    if grep -q "hashdog-perf" "$PERF_OUT" 2>/dev/null; then
      echo "  run $run_num: perf data captured"
    else
      echo "  run $run_num: no perf data (build without -DHASHDOG_PERF?)"
    fi
  done
done

echo ""
echo "=== Results saved to $OUTDIR ==="
echo "  summary.csv:     structured benchmark data"
echo "  perf_*.txt:      per-device pipeline timing breakdowns"
echo "  system_info.txt: hardware/software configuration"

# Quick summary
if [[ -s "$CSV" ]]; then
  echo ""
  echo "--- Quick Summary ---"
  column -t -s, "$CSV" 2>/dev/null || cat "$CSV"
fi
