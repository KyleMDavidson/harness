#!/usr/bin/env bash
# configure_firecracker.sh — Configure a Firecracker VM via its API socket
# Must be called after the Firecracker process is started but before the VM boots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"

# Socket path must match what setup_vm.sh passes to firecracker --api-sock
FC_SOCKET="${FC_SOCKET:-/tmp/firecracker.socket}"

# VM resources
VM_VCPUS="${VM_VCPUS:-2}"
VM_MEM_MB="${VM_MEM_MB:-512}"

# Kernel & rootfs
KERNEL_IMAGE="${KERNEL_IMAGE:-${ARTIFACTS_DIR}/vmlinux}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-${ARTIFACTS_DIR}/rootfs.ext4}"

# Networking (must match network_setup.sh)
TAP_DEVICE="${TAP_DEVICE:-fctap0}"
VM_MAC="${VM_MAC:-AA:FC:00:00:00:01}"
VM_IP="172.16.0.2"

# Kernel boot args — ttyS0 console, static IP via ip= parameter
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off nomodules"
KERNEL_BOOT_ARGS+=" ip=${VM_IP}::172.16.0.1:255.255.255.0::eth0:off"

# Helper: send a PUT request to the Firecracker API via the Unix socket
fc_put() {
    local path="$1"
    local body="$2"
    local response
    response="$(curl -sf \
        --unix-socket "${FC_SOCKET}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -d "$body" \
        "http://localhost${path}")"
    echo "$response"
}

# Helper: wait for the Firecracker socket to be ready
wait_for_socket() {
    local retries=20
    local delay=0.25
    echo "[config] Waiting for Firecracker socket ${FC_SOCKET}..."
    for ((i=0; i<retries; i++)); do
        if [[ -S "${FC_SOCKET}" ]]; then
            echo "[config] Socket ready."
            return 0
        fi
        sleep "$delay"
    done
    echo "ERROR: Firecracker socket not available after ${retries} attempts." >&2
    exit 1
}

validate_artifacts() {
    local errors=0
    if [[ ! -f "${KERNEL_IMAGE}" ]]; then
        echo "ERROR: Kernel not found: ${KERNEL_IMAGE}" >&2
        echo "       Download a Firecracker-compatible kernel and place it there," >&2
        echo "       or set KERNEL_IMAGE=/path/to/vmlinux." >&2
        errors=$((errors+1))
    fi
    if [[ ! -f "${ROOTFS_IMAGE}" ]]; then
        echo "ERROR: Rootfs not found: ${ROOTFS_IMAGE}" >&2
        echo "       Run rootfs_build.sh first, or set ROOTFS_IMAGE=/path/to/rootfs.ext4." >&2
        errors=$((errors+1))
    fi
    if [[ $errors -gt 0 ]]; then
        exit 1
    fi
}

configure_vm() {
    wait_for_socket
    validate_artifacts

    echo "[config] Configuring Firecracker VM..."

    # 1. Machine configuration
    echo "[config] Setting machine config (${VM_VCPUS} vCPUs, ${VM_MEM_MB} MiB RAM)..."
    fc_put "/machine-config" "$(cat <<EOF
{
  "vcpu_count": ${VM_VCPUS},
  "mem_size_mib": ${VM_MEM_MB},
  "smt": false
}
EOF
)"

    # 2. Kernel boot source
    echo "[config] Setting kernel: ${KERNEL_IMAGE}"
    fc_put "/boot-source" "$(cat <<EOF
{
  "kernel_image_path": "${KERNEL_IMAGE}",
  "boot_args": "${KERNEL_BOOT_ARGS}"
}
EOF
)"

    # 3. Root drive (read-write)
    echo "[config] Setting rootfs drive: ${ROOTFS_IMAGE}"
    fc_put "/drives/rootfs" "$(cat <<EOF
{
  "drive_id": "rootfs",
  "path_on_host": "${ROOTFS_IMAGE}",
  "is_root_device": true,
  "is_read_only": false
}
EOF
)"

    # 4. Network interface (tap -> VM eth0)
    echo "[config] Attaching network interface (TAP: ${TAP_DEVICE}, MAC: ${VM_MAC})..."
    fc_put "/network-interfaces/eth0" "$(cat <<EOF
{
  "iface_id": "eth0",
  "guest_mac": "${VM_MAC}",
  "host_dev_name": "${TAP_DEVICE}"
}
EOF
)"

    # 5. Logger (optional, writes to /tmp/fc-logs/)
    local log_dir="/tmp/fc-logs"
    mkdir -p "$log_dir"
    fc_put "/logger" "$(cat <<EOF
{
  "log_path": "${log_dir}/firecracker.log",
  "level": "Info",
  "show_level": true,
  "show_log_origin": false
}
EOF
)" 2>/dev/null || echo "[config] Logger config skipped (non-fatal)."

    echo "[config] Configuration complete. Ready to start instance."
    echo "[config]   vCPUs:    ${VM_VCPUS}"
    echo "[config]   Memory:   ${VM_MEM_MB} MiB"
    echo "[config]   Kernel:   ${KERNEL_IMAGE}"
    echo "[config]   Rootfs:   ${ROOTFS_IMAGE}"
    echo "[config]   VM IP:    ${VM_IP}"
    echo "[config]   TAP:      ${TAP_DEVICE}"
}

configure_vm
