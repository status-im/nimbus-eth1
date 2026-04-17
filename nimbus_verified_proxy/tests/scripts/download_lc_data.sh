#!/bin/bash

# Downloads Light Client test data from a beacon node.
# Usage: ./download_lc_data.sh <beacon-url>
# Example: ./download_lc_data.sh https://lodestar-mainnet.chainsafe.io
#
# After running, update TRUSTED_BLOCK_ROOT and TEST_LC_SLOT in
# nimbus_verified_proxy/tests/test_beacon_backend.nim with the printed values.

BEACON_URL="${1:?Usage: $0 <beacon-url> <trusted-block-root>}"
TRUSTED_BLOCK_ROOT="${2:?Usage: $0 <beacon-url> <trusted-block-root>}"
DOWNLOAD_FOLDER="../data"

block_root="$TRUSTED_BLOCK_ROOT"

# Get slot for that root (for informational output only)
echo "Fetching slot for block root $block_root..."
slot=$(curl -sf "$BEACON_URL/eth/v1/beacon/headers/$block_root" \
  -H "Accept: application/json" | jq -r '.data.header.message.slot')

# Download LC bootstrap
echo "Downloading lc_bootstrap.json..."
curl -sf "$BEACON_URL/eth/v1/beacon/light_client/bootstrap/$block_root" \
  -H "Accept: application/json" > "$DOWNLOAD_FOLDER/lc_bootstrap.json" || {
    echo "ERROR: failed to download bootstrap" >&2; exit 1; }

# Download LC optimistic update
echo "Downloading lc_optimistic.json..."
curl -sf "$BEACON_URL/eth/v1/beacon/light_client/optimistic_update" \
  -H "Accept: application/json" > "$DOWNLOAD_FOLDER/lc_optimistic.json" || {
    echo "ERROR: failed to download optimistic update" >&2; exit 1; }

# Download LC finality update
echo "Downloading lc_finality.json..."
curl -sf "$BEACON_URL/eth/v1/beacon/light_client/finality_update" \
  -H "Accept: application/json" > "$DOWNLOAD_FOLDER/lc_finality.json" || {
    echo "ERROR: failed to download finality update" >&2; exit 1; }

# Extract optimistic slot from downloaded file
optimistic_slot=$(jq -r '.data.attested_header.beacon.slot' "$DOWNLOAD_FOLDER/lc_optimistic.json")

# Download LC updates for the period covering the optimistic slot
SLOTS_PER_PERIOD=8192
period=$((optimistic_slot / SLOTS_PER_PERIOD))
echo "Downloading lc_updates.json (period=$period)..."
curl -sf "$BEACON_URL/eth/v1/beacon/light_client/updates?start_period=${period}&count=1" \
  -H "Accept: application/json" > "$DOWNLOAD_FOLDER/lc_updates.json" || {
    echo "ERROR: failed to download LC updates" >&2; exit 1; }

echo ""
echo "=== Update test_beacon_backend.nim with ==="
echo "TRUSTED_BLOCK_ROOT = $block_root"
echo "TEST_LC_SLOT       = $optimistic_slot  (bootstrap slot: $slot)"
