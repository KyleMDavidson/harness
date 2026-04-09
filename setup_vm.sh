#!/usr/bin/env bash
# setup_vm.sh — Orchestrate Firecracker VM setup for the agentic coding harness
#
# Usage:
#   sudo ./setup_vm.sh [start|stop|restart|status]
#
# The slave agent HTTP service will be reachable at http://${VM_IP}:${AGENT_PORT}
# from the host after a successful start.
#
# Environment variables (all optional, sourced from config.env):
#   FC_BINARY       Firecracker binary name/path  (default: firecracker)
#   FC_SOCKET       Firecracker API socket path   (default: /run/firecracker/firecracker.socket)
#   FC_PID_FILE     PID file path                 (default: /tmp/firecracker.pid)
#   FC_LOG_FILE     Log file path                 (default: /tmp/fc-logs/firecracker-boot.log)
#   KERNEL_IMAGE    Path to vmlinux kernel        (default: artifacts/vmlinux)
#   ROOTFS_IMAGE    Path to rootfs ext4 image     (default: artifacts/rootfs.ext4)
#   VM_VCPUS        Number of vCPUs               (default: 2)
#   VM_MEM_MB       Memory in MiB                 (default: 512)
#   VM_IP           Guest IP address              (default: 172.16.0.2)
#   AGENT_PORT      Slave HTTP port               (default: 8080)
#
# Arguments:
#   start    Start the VM (default if omitted)
#   stop     Gracefully halt the guest and tear down the network
#   restart  stop then start
#   status   Show VM state and slave health
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
# shellcheck source=config.env
source "${SCRIPT_DIR}/config.env"

# ---- Helpers ----

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root." >&2
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in "$FC_BINARY" curl ip iptables; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required binaries: ${missing[*]}" >&2
        echo "" >&2
        echo "Install Firecracker:" >&2
        echo "  ARCH=x86_64" >&2
        echo "  VER=\$(curl -s https://api.github.com/repos/firecracker-microvm/firecracker/releases/latest | grep tag_name | cut -d'\"' -f4)" >&2
        echo "  curl -L \"https://github.com/firecracker-microvm/firecracker/releases/download/\${VER}/firecracker-\${VER}-\${ARCH}.tgz\" | tar xz" >&2
        echo "  mv release-\${VER}-\${ARCH}/firecracker-\${VER}-\${ARCH} /usr/local/bin/firecracker && chmod +x /usr/local/bin/firecracker" >&2
        exit 1
    fi
}

check_kvm() {
    if [[ ! -e /dev/kvm ]]; then
        echo "ERROR: /dev/kvm not found. KVM is required for Firecracker." >&2
        echo "       Ensure the host supports nested virtualisation or has KVM loaded:" >&2
        echo "         modprobe kvm_intel  # or kvm_amd" >&2
        exit 1
    fi
}

download_kernel_if_missing() {
    if [[ -f "${KERNEL_IMAGE}" ]]; then
        return
    fi
    echo "[setup] Kernel not found at ${KERNEL_IMAGE}."
    echo "[setup] Downloading a pre-built Firecracker-compatible kernel..."
    mkdir -p "${ARTIFACTS_DIR}"

    local kernel_url="https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"
    echo "[setup] Kernel URL: ${kernel_url}"
    curl -fL --progress-bar -o "${KERNEL_IMAGE}" "${kernel_url}"
    echo "[setup] Kernel saved to ${KERNEL_IMAGE}."
}

vm_is_running() {
    if [[ -f "${FC_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${FC_PID_FILE}")
        kill -0 "$pid" 2>/dev/null
    else
        return 1
    fi
}

# ---- Actions ----

action_start() {
    echo "=== Firecracker VM Setup ==="

    check_deps
    check_kvm
    download_kernel_if_missing

    if vm_is_running; then
        echo "[setup] Firecracker is already running (PID $(cat "${FC_PID_FILE}"))."
        echo "[setup] Agent: http://${VM_IP}:${AGENT_PORT}"
        exit 0
    fi

    # Clean up stale socket
    rm -f "${FC_SOCKET}"

    # Step 1: Network
    echo ""
    echo "[setup] Step 1/3 — Configuring host network..."
    "${SCRIPT_DIR}/network_setup.sh" up

    # Step 2: Build rootfs if missing
    if [[ ! -f "${ROOTFS_IMAGE}" ]]; then
        echo ""
        echo "[setup] Step 2/3 — Building rootfs (this may take a few minutes)..."
        "${SCRIPT_DIR}/rootfs_build.sh"
    else
        echo ""
        echo "[setup] Step 2/3 — Rootfs already exists at ${ROOTFS_IMAGE}, skipping build."
    fi

    # Step 3: Start Firecracker, configure, then boot
    echo ""
    echo "[setup] Step 3/3 — Starting Firecracker..."
    mkdir -p "$(dirname "${FC_LOG_FILE}")"

    # Start Firecracker in background; it waits for config via the API socket
    FC_SOCKET="${FC_SOCKET}" \
    FC_BINARY="${FC_BINARY}" \
    "$FC_BINARY" \
        --api-sock "${FC_SOCKET}" \
        --log-path "${FC_LOG_FILE}" \
        --level Info \
        &
    echo $! > "${FC_PID_FILE}"
    echo "[setup] Firecracker PID: $(cat "${FC_PID_FILE}")"

    # Configure VM via API
    FC_SOCKET="${FC_SOCKET}" \
    KERNEL_IMAGE="${KERNEL_IMAGE}" \
    ROOTFS_IMAGE="${ROOTFS_IMAGE}" \
    VM_VCPUS="${VM_VCPUS}" \
    VM_MEM_MB="${VM_MEM_MB}" \
    "${SCRIPT_DIR}/configure_firecracker.sh"

    # Start the VM instance
    echo "[setup] Sending InstanceStart action..."
    curl -sf \
        --unix-socket "${FC_SOCKET}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -d '{"action_type": "InstanceStart"}' \
        "http://localhost/actions"

    echo ""
    echo "=== VM started ==="
    echo "  Agent endpoint: http://${VM_IP}:${AGENT_PORT}"
    echo "  Health check:   http://${VM_IP}:${AGENT_PORT}/health"
    echo "  Console log:    ${FC_LOG_FILE}"
    echo "  Firecracker PID: $(cat "${FC_PID_FILE}")"
    echo ""
    echo "  Waiting ~5 s for guest to boot, then testing /health..."
    sleep 5

    if curl -sf --max-time 5 "http://${VM_IP}:${AGENT_PORT}/health" >/dev/null 2>&1; then
        echo "  [OK] Agent is reachable."
    else
        echo "  [WARN] Agent not yet responding — it may still be booting."
        echo "         Retry: curl http://${VM_IP}:${AGENT_PORT}/health"
    fi
}

action_stop() {
    echo "[setup] Stopping Firecracker VM..."

    if vm_is_running; then
        local pid
        pid=$(cat "${FC_PID_FILE}")
        echo "[setup] Sending SendCtrlAltDel to gracefully halt guest..."
        curl -sf \
            --unix-socket "${FC_SOCKET}" \
            -X PUT \
            -H "Content-Type: application/json" \
            -d '{"action_type": "SendCtrlAltDel"}' \
            "http://localhost/actions" 2>/dev/null || true
        sleep 2
        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            echo "[setup] Force-killing Firecracker (PID ${pid})..."
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "${FC_PID_FILE}"
        echo "[setup] Firecracker stopped."
    else
        echo "[setup] No running Firecracker instance found."
    fi

    rm -f "${FC_SOCKET}"

    echo "[setup] Tearing down network..."
    "${SCRIPT_DIR}/network_setup.sh" down
}

action_restart() {
    action_stop
    sleep 1
    action_start
}

action_status() {
    echo "=== Firecracker VM Status ==="
    if vm_is_running; then
        echo "  State:   RUNNING (PID $(cat "${FC_PID_FILE}"))"
        echo "  Socket:  ${FC_SOCKET}"
        echo "  Agent:   http://${VM_IP}:${AGENT_PORT}"
        echo ""
        echo "  Health check..."
        if curl -sf --max-time 3 "http://${VM_IP}:${AGENT_PORT}/health"; then
            echo ""
        else
            echo "  (agent not responding)"
        fi
    else
        echo "  State:   STOPPED"
    fi
    echo ""
    echo "  Artifacts:"
    echo "    Kernel:  ${KERNEL_IMAGE}  $([ -f "${KERNEL_IMAGE}" ] && echo '[exists]' || echo '[MISSING]')"
    echo "    Rootfs:  ${ROOTFS_IMAGE}  $([ -f "${ROOTFS_IMAGE}" ] && echo '[exists]' || echo '[MISSING]')"
}

# ---- Entrypoint ----

require_root

case "${1:-start}" in
    start)   action_start ;;
    stop)    action_stop ;;
    restart) action_restart ;;
    status)  action_status ;;
    *)
        echo "Usage: $0 [start|stop|restart|status]"
        exit 1
        ;;
esac
