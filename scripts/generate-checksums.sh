#!/usr/bin/env bash
# Generate SHA256 checksums for all module files and write to scripts/checksums.txt

set -euo pipefail

OUT_FILE="$(dirname "$0")/checksums.txt"
MODULE_GLOB="$(dirname "$0")/modules/*"

echo "Generating checksums to $OUT_FILE"
rm -f "$OUT_FILE"
for f in $MODULE_GLOB; do
  if [ -f "$f" ]; then
    sha256sum "$f" | awk '{print $1 "  " $2}' >> "$OUT_FILE"
  fi
done

echo "Checksums generated. Preview:" 
sed -n '1,200p' "$OUT_FILE" || true
