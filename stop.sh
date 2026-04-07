#!/usr/bin/env bash
# stop.sh — Stop any running Firecracker VMs and tear down the network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
source "${SCRIPT_DIR}/config.env"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo ./stop.sh" >&2
    exit 1
fi

# Kill any running Firecracker processes
if pgrep -x firecracker > /dev/null 2>&1; then
    echo "[stop] Killing Firecracker..."
    pkill -x firecracker || true
    sleep 1
    echo "[stop] Done."
else
    echo "[stop] No Firecracker process found."
fi

# Clean up PID file and socket
rm -f "${FC_PID_FILE}" "${FC_SOCKET}"

# Tear down network
echo "[stop] Tearing down network..."
"${SCRIPT_DIR}/network_setup.sh" down

echo "[stop] All clear."
