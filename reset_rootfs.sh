#!/usr/bin/env bash
# reset_rootfs.sh — Wipe and rebuild the Firecracker rootfs image from scratch.
# The VM must not be running when this is called.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
# shellcheck source=config.env
source "${SCRIPT_DIR}/config.env"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Must be run as root." >&2
        exit 1
    fi
}

check_vm_stopped() {
    if [[ -f "${FC_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${FC_PID_FILE}")
        if kill -0 "$pid" 2>/dev/null; then
            echo "ERROR: Firecracker is still running (PID ${pid})." >&2
            echo "       Run 'sudo ./setup_vm.sh stop' first." >&2
            exit 1
        fi
    fi
}

require_root
check_vm_stopped

echo "[reset] Removing ${ROOTFS_IMAGE}..."
rm -f "${ROOTFS_IMAGE}"

echo "[reset] Rebuilding rootfs..."
"${SCRIPT_DIR}/rootfs_build.sh"

echo "[reset] Done. Run 'sudo ./setup_vm.sh start' to boot the fresh image."
