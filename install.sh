#!/usr/bin/env bash
# install.sh — One-time host setup for the Firecracker agentic harness.
#
# Creates OS users, sets capabilities, configures sudo, and installs
# Python dependencies for the master process.
#
# Usage:
#   sudo ./install.sh
#
# Safe to re-run — all steps are idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run as root: sudo ./install.sh" >&2
        exit 1
    fi
}

# ---- OS users ----

setup_users() {
    echo "[install] Creating OS users..."

    if ! id fc-orch &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin fc-orch
        echo "[install]   Created fc-orch"
    else
        echo "[install]   fc-orch already exists"
    fi

    if ! id fc-master &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin fc-master
        echo "[install]   Created fc-master"
    else
        echo "[install]   fc-master already exists"
    fi
}

# ---- KVM access for fc-orch ----

setup_kvm() {
    echo "[install] Granting fc-orch access to /dev/kvm..."
    if groups fc-orch | grep -qw kvm; then
        echo "[install]   fc-orch already in kvm group"
    else
        usermod -aG kvm fc-orch
        echo "[install]   Added fc-orch to kvm group"
    fi
}

# ---- CAP_NET_ADMIN on Firecracker binary ----

setup_caps() {
    local fc_bin
    fc_bin="$(command -v firecracker 2>/dev/null || true)"
    if [[ -z "$fc_bin" ]]; then
        echo "[install] WARNING: firecracker binary not found in PATH — skipping CAP_NET_ADMIN setup."
        echo "[install]          Install Firecracker first, then re-run this script."
        return
    fi
    echo "[install] Setting CAP_NET_ADMIN on ${fc_bin}..."
    setcap cap_net_admin+ep "$fc_bin"
    echo "[install]   Done"
}

# ---- Firecracker socket directory ----

setup_socket_dir() {
    echo "[install] Setting up Firecracker socket directory..."
    mkdir -p /run/firecracker
    chown fc-orch:fc-orch /run/firecracker
    chmod 700 /run/firecracker
    echo "[install]   /run/firecracker ready"
}

# ---- Artifacts directory ----

setup_artifacts_dir() {
    echo "[install] Setting up artifacts directory..."
    mkdir -p "${SCRIPT_DIR}/artifacts"
    chown -R fc-orch:fc-orch "${SCRIPT_DIR}/artifacts"
    chmod 750 "${SCRIPT_DIR}/artifacts"
    echo "[install]   ${SCRIPT_DIR}/artifacts ready"
}

# ---- sudo rule: fc-master may run setup_vm.sh as fc-orch ----

setup_sudo() {
    echo "[install] Configuring sudo rule for fc-master..."
    local rule="fc-master ALL=(fc-orch) NOPASSWD: ${SCRIPT_DIR}/setup_vm.sh"
    local sudoers_file="/etc/sudoers.d/fc-master"
    echo "$rule" > "$sudoers_file"
    chmod 440 "$sudoers_file"
    echo "[install]   Wrote ${sudoers_file}"
}

# ---- Python venv for master.py ----

setup_venv() {
    echo "[install] Setting up Python venv for master..."
    local venv="${SCRIPT_DIR}/venv"

    if [[ ! -d "$venv" ]]; then
        python3 -m venv "$venv"
        echo "[install]   Created venv at ${venv}"
    else
        echo "[install]   Venv already exists at ${venv}"
    fi

    "$venv/bin/pip" install --quiet --upgrade pip
    "$venv/bin/pip" install --quiet claude-agent-sdk
    echo "[install]   Installed: claude-agent-sdk"

    chown -R fc-master:fc-master "$venv"
    echo "[install]   Ownership set to fc-master"
}

# ---- Summary ----

print_summary() {
    echo ""
    echo "=== Install complete ==="
    echo ""
    echo "To start the VM:"
    echo "  sudo ANTHROPIC_API_KEY=\$ANTHROPIC_API_KEY ${SCRIPT_DIR}/setup_vm.sh start"
    echo ""
    echo "To run a task:"
    echo "  ${SCRIPT_DIR}/venv/bin/python ${SCRIPT_DIR}/master.py \"your task here\""
    echo ""
}

require_root
setup_users
setup_kvm
setup_caps
setup_socket_dir
setup_artifacts_dir
setup_sudo
setup_venv
print_summary
