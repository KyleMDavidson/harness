#!/usr/bin/env bash
# test.sh — Smoke test for the harness.
#
# 1. Starts the VM (which starts the slave via OpenRC)
# 2. Waits for the slave health endpoint
# 3. Sends a minimal prompt to verify the slave can make an authenticated Claude request
# 4. Runs the master with a minimal task to verify the full round trip
#
# Usage:
#   sudo ./test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
source "${SCRIPT_DIR}/config.env"

REBUILD=false
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=true ;;
    esac
done

AGENT_URL="http://${VM_IP}:${AGENT_PORT}"
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; ((FAIL++)) || true; }

# ---- 1. Start VM ----

echo "=== 1. Starting VM ==="
# Ensure clean state before starting
"${SCRIPT_DIR}/stop.sh" 2>/dev/null || true

if $REBUILD; then
    echo "[test] --rebuild: removing existing rootfs..."
    rm -f "${ROOTFS_IMAGE}"
fi
"${SCRIPT_DIR}/setup_vm.sh" start

# ---- 2. Wait for slave health ----

echo ""
echo "=== 2. Waiting for slave ==="
healthy=false
for i in $(seq 1 30); do
    if curl -sf --max-time 3 "${AGENT_URL}/health" >/dev/null 2>&1; then
        healthy=true
        break
    fi
    echo "  [${i}/30] not yet..."
    sleep 3
done

if $healthy; then
    pass "slave /health"
else
    fail "slave /health — timed out after 90s"
    echo "Check VM console: ${FC_LOG_FILE}"
    exit 1
fi

# ---- 3. Slave: authenticated Claude request ----

echo ""
echo "=== 3. Slave Claude auth ==="
response=$(curl -sf --max-time 60 -X POST "${AGENT_URL}/run" \
    -H 'Content-Type: application/json' \
    -d '{"prompt": "Reply with exactly the word AUTHENTICATED and nothing else."}' \
    2>&1) || true

if echo "$response" | grep -qi "AUTHENTICATED"; then
    pass "slave Claude request"
else
    fail "slave Claude request"
    echo "  response: $response"
fi

# ---- 4. Full round trip: master → slave ----

echo ""
echo "=== 4. Master → slave round trip ==="
result=$("${SCRIPT_DIR}/venv/bin/python" "${SCRIPT_DIR}/master.py" \
    "Send the slave a request asking it to reply with exactly the word ROUNDTRIP and nothing else. Report what it replied." \
    2>&1) || true

if echo "$result" | grep -qi "ROUNDTRIP"; then
    pass "master → slave round trip"
else
    fail "master → slave round trip"
    echo "  result: $result"
fi

# ---- Summary ----

echo ""
echo "================================"
echo "  ${PASS} passed   ${FAIL} failed"
echo "================================"
[[ $FAIL -eq 0 ]]
