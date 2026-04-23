#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../" && pwd)"
WASM_DIR="$SCRIPT_DIR/../"
BUILD_DIR="$REPO_ROOT/build/libverifproxy_wasm"

echo "==> Repo root: $REPO_ROOT"
echo ""

# ── Check build artefacts ──────────────────────────────────────────────────────

echo "==> Checking for WASM build artefacts in $BUILD_DIR ..."

missing=0
for f in verifproxy_wasm.js verifproxy_wasm.wasm; do
    if [ ! -f "$BUILD_DIR/$f" ]; then
        echo "    MISSING: $f"
        missing=1
    fi
done

if [ "$missing" -eq 1 ]; then
    echo ""
    echo "    Build the WASM module first:"
    echo "      ./env.sh make -f nimbus_verified_proxy/bindings/wasm/build_wasm.mk wasm"
    exit 1
fi

echo "    Found verifproxy_wasm.js and verifproxy_wasm.wasm"
echo ""

# ── Copy artefacts into examples/ and clean up on exit ────────────────────────

COPIED=(
    "$SCRIPT_DIR/wasm_glue.js"
    "$SCRIPT_DIR/verifproxy_wasm.js"
    "$SCRIPT_DIR/verifproxy_wasm.wasm"
)

cleanup() {
    echo ""
    echo "==> Cleaning up copied artefacts ..."
    for f in "${COPIED[@]}"; do
        rm -f "$f" && echo "    Removed $f"
    done
}

trap cleanup EXIT

echo "==> Copying artefacts into $SCRIPT_DIR ..."
cp "$WASM_DIR/wasm_glue.js"          "$SCRIPT_DIR/"
cp "$BUILD_DIR/verifproxy_wasm.js"   "$SCRIPT_DIR/"
cp "$BUILD_DIR/verifproxy_wasm.wasm" "$SCRIPT_DIR/"
echo "    Done"
echo ""

# ── Start server ───────────────────────────────────────────────────────────────

PORT=8080

echo "==> Starting demo server on http://localhost:$PORT"
echo ""
echo "    Open: http://localhost:$PORT/index.html"
echo ""
echo "    The server proxies Ethereum API calls through /proxy?url=<target>"
echo "    so the browser can reach local or remote nodes without CORS issues."
echo ""
echo "    Press Ctrl-C to stop."
echo ""

python3 "$SCRIPT_DIR/server.py"
