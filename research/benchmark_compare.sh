#!/bin/bash
# Robust A/B comparison: 3 runs per mode, take median
# Caches cleared between runs for fair autotune

OUTDIR=/home/kartofel/Claude/hashdog/research/results/robust_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUTDIR"

# Test hashes (uncrackable)
python3 -c "import hashlib, os; print(hashlib.md5(os.urandom(16)).hexdigest())" > /tmp/comp_md5.txt
python3 -c "import hashlib, os; print(hashlib.sha256(os.urandom(16)).hexdigest())" > /tmp/comp_sha256.txt
python3 -c "import hashlib, os; print(hashlib.sha512(os.urandom(16)).hexdigest())" > /tmp/comp_sha512.txt
echo '$P$BmuuPNCdcvNs0iaCZHCGyy3GnvMCQu0' > /tmp/comp_phpass.txt
echo '$1$WGmSZRVD$9DxJJOAU.Hk0eJZD9ZuUI/' > /tmp/comp_md5crypt.txt
echo '$5$rounds=5000$hashcatsalt$rW5BRsGXYsx5cPM23P5SZB95k7BC9zNk1MTw3aUvEnA' > /tmp/comp_sha256crypt.txt
echo '$6$hashcatsalt$YyR.UKr3CJFjEvk/0OKH6M4ZJtlBN.WJsBI6RFx0f4RxGm3.tnFEWP2XxaL4.xmXdQxzLSifTGh5YjF.H31K21' > /tmp/comp_sha512crypt.txt
echo '$2a$05$MBCzKhG1KhezLh.0LRa0Kuw12nLJtpIabFEoYAz3V1T2rUG.W6kJO' > /tmp/comp_bcrypt.txt

WORDLIST=/tmp/big_wordlist.txt
RULES=/home/kartofel/Claude/hashdog/rules/best66.rule

run_one() {
  local binary_dir=$1
  local mode=$2
  local hashfile=$3

  rm -f ~/.hashcat/hashcat.autotune ~/.hashcat/hashcat.dictstat2
  rm -f /home/kartofel/Claude/hashdog/hashcat.autotune /home/kartofel/Claude/hashdog/hashcat.dictstat2
  rm -f "$binary_dir/hashcat.autotune" "$binary_dir/hashcat.dictstat2"

  cd "$binary_dir"
  local raw=$(timeout 35 ./hashcat -m $mode "$hashfile" "$WORDLIST" -r "$RULES" \
    --potfile-disable --logfile-disable --self-test-disable \
    --slow-candidates -o /dev/null --runtime=25 2>&1 \
    | grep -E "Speed.#01" | tail -1 \
    | grep -oP 'Speed\.#01\.+:\s*\K[0-9.]+\s*[kMG]?')

  python3 -c "
s = '$raw'.strip().replace(' ', '')
if not s: print(0); exit()
mult = 1
if s.endswith('G'): mult = 1000000000; s = s[:-1]
elif s.endswith('M'): mult = 1000000; s = s[:-1]
elif s.endswith('k'): mult = 1000; s = s[:-1]
print(int(float(s) * mult))
"
}

run_median() {
  local binary_dir=$1
  local mode=$2
  local hashfile=$3
  local r1=$(run_one "$binary_dir" "$mode" "$hashfile")
  local r2=$(run_one "$binary_dir" "$mode" "$hashfile")
  local r3=$(run_one "$binary_dir" "$mode" "$hashfile")
  python3 -c "print(sorted([$r1, $r2, $r3])[1])"
}

echo "=== Robust comparison: hashcat vs hashdog (median of 3 runs) ===" | tee "$OUTDIR/results.txt"
echo "Date: $(date)" | tee -a "$OUTDIR/results.txt"
echo "Workload: 128K words × 66 rules, 25s runtime, 3 runs each" | tee -a "$OUTDIR/results.txt"
echo "" | tee -a "$OUTDIR/results.txt"

echo "mode,name,hashcat_h_s,hashdog_h_s,improvement_pct" > "$OUTDIR/comparison.csv"

declare -A HASH_FILES MODE_NAMES
HASH_FILES[0]=/tmp/comp_md5.txt;            MODE_NAMES[0]="MD5"
HASH_FILES[1400]=/tmp/comp_sha256.txt;       MODE_NAMES[1400]="SHA256"
HASH_FILES[1700]=/tmp/comp_sha512.txt;       MODE_NAMES[1700]="SHA512"
HASH_FILES[400]=/tmp/comp_phpass.txt;        MODE_NAMES[400]="phpass"
HASH_FILES[500]=/tmp/comp_md5crypt.txt;      MODE_NAMES[500]="md5crypt"
HASH_FILES[7400]=/tmp/comp_sha256crypt.txt;  MODE_NAMES[7400]="sha256crypt"
HASH_FILES[1800]=/tmp/comp_sha512crypt.txt;  MODE_NAMES[1800]="sha512crypt"
HASH_FILES[3200]=/tmp/comp_bcrypt.txt;       MODE_NAMES[3200]="bcrypt"

for mode in 0 1400 1700 400 500 7400 1800 3200; do
  hashfile=${HASH_FILES[$mode]}
  name=${MODE_NAMES[$mode]}

  echo ">>> Mode $mode ($name) — running 3 iterations each" | tee -a "$OUTDIR/results.txt"

  HASHCAT=$(run_median /tmp/hashcat_original $mode "$hashfile")
  HASHDOG=$(run_median /tmp/hashdog_optimized_dist $mode "$hashfile")

  if [[ "$HASHCAT" != "0" && "$HASHDOG" != "0" ]]; then
    IMPROV=$(python3 -c "print(f'{($HASHDOG - $HASHCAT) / $HASHCAT * 100:+.1f}')")
  else
    IMPROV="N/A"
  fi

  echo "  hashcat (median): $HASHCAT H/s    hashdog (median): $HASHDOG H/s    improvement: ${IMPROV}%" | tee -a "$OUTDIR/results.txt"
  echo "$mode,$name,$HASHCAT,$HASHDOG,$IMPROV" >> "$OUTDIR/comparison.csv"
done

echo ""
echo "=== Final CSV ==="
cat "$OUTDIR/comparison.csv"
echo "Saved to: $OUTDIR"
