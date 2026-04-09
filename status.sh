#!/usr/bin/env bash
# status.sh — Show the current state of the harness.
#
# Environment variables (all optional, sourced from config.env):
#   FC_PID_FILE     Firecracker PID file      (default: /tmp/firecracker.pid)
#   VM_IP           Slave IP address          (default: 172.16.0.2)
#   AGENT_PORT      Slave HTTP port           (default: 8080)
#   MASTER_PORT     Master HTTP port          (default: 3000)
#
# Arguments: none
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
source "${SCRIPT_DIR}/config.env"

AGENT_URL="http://${VM_IP}:${AGENT_PORT}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}UP${NC}      $1"; }
down() { echo -e "  ${RED}DOWN${NC}    $1"; }
info() { echo -e "  ${YELLOW}INFO${NC}    $1"; }

echo "=== Harness Status ==="
echo ""

# ---- Firecracker VM ----
echo "Firecracker VM:"
if [[ -f "${FC_PID_FILE}" ]]; then
    pid=$(cat "${FC_PID_FILE}")
    if kill -0 "$pid" 2>/dev/null; then
        ok "Running (PID ${pid})"
    else
        down "PID file exists but process ${pid} is gone"
    fi
else
    down "Not running (no PID file)"
fi

# ---- Master process ----
echo ""
echo "Master (master.js on port ${MASTER_PORT}):"
master_pids=$(pgrep -f "master\.js" 2>/dev/null || true)
if [[ -n "$master_pids" ]]; then
    while IFS= read -r pid; do
        cmdline=$(ps -p "$pid" -o args= 2>/dev/null || echo "(unknown)")
        ok "Running (PID ${pid}): ${cmdline}"
    done <<< "$master_pids"
else
    info "Not running"
fi

# ---- Slave agent ----
echo ""
echo "Slave agent (${AGENT_URL}):"
response=$(curl -sf --max-time 3 "${AGENT_URL}/health" 2>/dev/null || true)
if [[ -n "$response" ]]; then
    ok "/health responded: ${response}"
else
    down "/health unreachable"
fi


echo ""
