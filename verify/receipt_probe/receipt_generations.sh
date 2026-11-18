#!/bin/bash
# Read-only: per official release tag, does hermes_cli/update_receipt.py exist, and does it read
# HERMES_UPDATE_CORRELATION_ID? (git show only; gc/maintenance disabled for these reads)
# usage: bash verify/receipt_probe/receipt_generations.sh [upstream hermes-agent checkout]
UP="${1:-${HERMES_UPSTREAM_REPO:-/home/computebox/.hermes/hermes-agent}}"
G="git -c gc.auto=0 -c maintenance.auto=false -C $UP"
for t in $($G tag --list | grep -E '^v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(\.[0-9]+)?)$'); do
    if src=$($G show "$t:hermes_cli/update_receipt.py" 2>/dev/null); then
        r=1
        c=$(printf '%s\n' "$src" | grep -c 'HERMES_UPDATE_CORRELATION_ID')
        ln=$(printf '%s\n' "$src" | grep -n 'os.environ.get("HERMES_UPDATE_CORRELATION_ID"' | head -1 | cut -d: -f1)
    else
        r=0; c=0; ln=-
    fi
    printf '%s receipt_module=%s correlation_refs=%s env_read_line=%s\n' "$t" "$r" "$c" "${ln:--}"
done | sort -t. -k1,1 -V
