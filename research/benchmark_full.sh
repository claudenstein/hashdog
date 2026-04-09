#!/bin/bash
# Robust comprehensive comparison: median of 3 runs
set -u

ORIG_DIR=/tmp/hashcat_original
OPT_DIR=/tmp/hashdog_optimized_dist

OUTDIR=/home/kartofel/Claude/hashdog/research/results/full_robust_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUTDIR"

MODES=$(cat /tmp/default_modes.txt)

# Map mode -> hash type name
./hashcat -hh 2>&1 | grep -E "^\s+[0-9]+ \|" | awk -F'|' '{
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1);
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
  print $1 "\t" $2
}' > /tmp/mode_names.tsv

get_name() {
  awk -F'\t' -v m="$1" '$1 == m {print $2; exit}' /tmp/mode_names.tsv | head -1
}

run_one() {
  local binary_dir=$1
  local mode=$2
  rm -f ~/.hashcat/hashcat.autotune ~/.hashcat/hashcat.dictstat2 2>/dev/null
  rm -f /home/kartofel/Claude/hashdog/hashcat.autotune /home/kartofel/Claude/hashdog/hashcat.dictstat2 2>/dev/null
  rm -f "$binary_dir/hashcat.autotune" "$binary_dir/hashcat.dictstat2" 2>/dev/null
  local out
  out=$(cd "$binary_dir" && timeout 30 ./hashcat -b -m "$mode" \
    --machine-readable --quiet --potfile-disable --logfile-disable \
    --self-test-disable --runtime=6 2>/dev/null | head -1 | cut -d: -f6)
  echo "${out:-0}"
}

run_median() {
  local r1=$(run_one "$1" "$2")
  local r2=$(run_one "$1" "$2")
  local r3=$(run_one "$1" "$2")
  python3 -c "print(sorted([$r1, $r2, $r3])[1])"
}

echo "=== Robust comprehensive benchmark (median of 3) ===" | tee "$OUTDIR/summary.txt"
echo "Date: $(date)" | tee -a "$OUTDIR/summary.txt"
echo "" | tee -a "$OUTDIR/summary.txt"

echo "mode,name,hashcat_h_s,hashdog_h_s,delta_pct" > "$OUTDIR/full_comparison.csv"

I=0
TOTAL=$(echo $MODES | wc -w)
for mode in $MODES; do
  I=$((I+1))
  name=$(get_name "$mode")
  printf "[%3d/%3d] Mode %5d (%-40s) " "$I" "$TOTAL" "$mode" "${name:0:40}"

  H=$(run_median "$ORIG_DIR" "$mode")
  D=$(run_median "$OPT_DIR" "$mode")

  if [[ -n "$H" && -n "$D" && "$H" != "0" && "$D" != "0" ]]; then
    DELTA=$(python3 -c "print(f'{($D - $H) / $H * 100:+.1f}')")
  else
    DELTA="N/A"
  fi

  printf "hc=%-15s hd=%-15s Δ=%s%%\n" "$H" "$D" "$DELTA"
  echo "$mode,\"$name\",$H,$D,$DELTA" >> "$OUTDIR/full_comparison.csv"
done

echo ""
echo "=== Saved to: $OUTDIR ==="
