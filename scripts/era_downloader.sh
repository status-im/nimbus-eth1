#!/bin/bash

# Copyright (c) 2025 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Usage: ./download_era.sh <download_url> <download_path>
set -eo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <download_url> <download_path>"
  exit 1
fi

DOWNLOAD_URL="$1"
DOWNLOAD_DIR="$2"

if ! command -v aria2c > /dev/null 2>&1; then
  echo "❌ aria2c is not installed. Install via: brew install aria2 (macOS) or sudo apt install aria2 (Linux)"
  exit 1
fi

mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR" || exit 1

# Generate safe temp files for URL lists
URLS_RAW_FILE=$(mktemp)
URLS_FILE=$(mktemp)

# Scrape and filter
curl -s "$DOWNLOAD_URL" | \
grep -Eo 'href="[^"]+"' | \
cut -d'"' -f2 | \
grep -Ei '\.(era|era1|txt)$' | \
sort -u > "$URLS_RAW_FILE"

# Remove trailing file (like index.html) to get actual base path
BASE_URL=$(echo "$DOWNLOAD_URL" | sed -E 's|/[^/]*\.[a-zA-Z0-9]+$||')

# 🔧 Normalize base URL (handle trailing slash or index.html)
case "$DOWNLOAD_URL" in
  */index.html) BASE_URL="${DOWNLOAD_URL%/index.html}" ;;
  */)           BASE_URL="${DOWNLOAD_URL%/}" ;;
  *)            BASE_URL="$DOWNLOAD_URL" ;;
esac

# Prepend full URL
awk -v url="$BASE_URL" '{ print url "/" $0 }' "$URLS_RAW_FILE" > "$URLS_FILE"

TOTAL_FILES=$(wc -l < "$URLS_FILE")

if [ "$TOTAL_FILES" -eq 0 ]; then
  echo "❌ No .era, .era1, or .txt files found at $DOWNLOAD_URL"
  exit 1
fi

aria2c -x 8 -j 5 -c -i "$URLS_FILE" \
  --dir="." \
  --console-log-level=warn \
  --quiet=true \
  --summary-interval=0 \
  > /dev/null 2>&1 &

ARIA_PID=$!

echo "📥 Starting download of $TOTAL_FILES files..."
while kill -0 "$ARIA_PID" 2> /dev/null; do
  COMPLETED=$(find . -type f \( -name '*.era' -o -name '*.era1' -o -name '*.txt' \) | wc -l)
  PERCENT=$(awk "BEGIN { printf \"%.1f\", ($COMPLETED/$TOTAL_FILES)*100 }")
  echo -ne "📦 Download Progress: $PERCENT% complete ($COMPLETED / $TOTAL_FILES files)     \r"
  sleep 1
done

COMPLETED=$(find . -type f \( -name '*.era' -o -name '*.era1' -o -name '*.txt' \) | wc -l)
echo -ne "📦 Download Progress: 100% complete ($COMPLETED / $TOTAL_FILES files)     \n"

# ✅ Cleanup temp files
rm -f "$URLS_RAW_FILE" "$URLS_FILE"

echo "✅ All files downloaded to: $DOWNLOAD_DIR"
