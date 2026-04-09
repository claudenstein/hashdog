#!/usr/bin/env python3
"""Generate categorized markdown tables from comparison results."""
import csv
import sys

results = []
with open('/home/kartofel/Claude/hashdog/research/results/full_robust_20260409_121441/full_comparison.csv') as f:
    reader = csv.DictReader(f)
    for row in reader:
        results.append(row)

# Load categories (first entry only)
categories = {}
with open('/tmp/mode_categories.tsv') as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) == 3:
            if parts[0] not in categories:
                categories[parts[0]] = parts[2]


def category_for(r):
    return categories.get(r['mode'], 'Unknown')


def fmt_speed(h_s):
    h = int(h_s)
    if h >= 1_000_000_000:
        return f"{h/1_000_000_000:.2f} GH/s"
    elif h >= 1_000_000:
        return f"{h/1_000_000:.2f} MH/s"
    elif h >= 1_000:
        return f"{h/1_000:.2f} kH/s"
    return f"{h} H/s"


# Group by category
grouped = {}
for r in results:
    cat = category_for(r)
    grouped.setdefault(cat, []).append(r)

# Sort categories: Raw Hash first, then Operating System, etc.
preferred_order = [
    'Raw Hash',
    'Raw Hash salted and/or iterated',
    'Raw Hash authenticated',
    'Raw Cipher, Known-plaintext attack',
    'Raw Checksum',
    'Generic KDF',
    'Network Protocol',
    'Operating System',
    'FTP, HTTP, SMTP, LDAP Server',
    'Database Server',
    'Enterprise Application Software (EAS)',
    'Forums, CMS, E-Commerce',
    'Framework',
    'Document',
    'Password Manager',
    'Cryptocurrency Wallet',
    'Full-Disk Encryption (FDE)',
    'Archive',
    'Private Key',
]

ordered_cats = [c for c in preferred_order if c in grouped]
for c in sorted(grouped.keys()):
    if c not in ordered_cats:
        ordered_cats.append(c)

for cat in ordered_cats:
    print(f"\n#### {cat}\n")
    print("| Mode | Algorithm | hashcat | hashdog | Δ |")
    print("|-----:|-----------|--------:|--------:|---:|")
    for r in sorted(grouped[cat], key=lambda r: int(r['mode'])):
        h = fmt_speed(r['hashcat_h_s'])
        d = fmt_speed(r['hashdog_h_s'])
        delta = r['delta_pct']
        if delta == 'N/A':
            delta_disp = 'N/A'
        else:
            f = float(delta)
            if f >= 1.0:
                delta_disp = f"**{delta}%**"
            else:
                delta_disp = f"{delta}%"
        name = r['name'][:50]
        print(f"| {r['mode']} | {name} | {h} | {d} | {delta_disp} |")
