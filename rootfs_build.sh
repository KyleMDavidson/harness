#!/usr/bin/env bash
# rootfs_build.sh — Build a minimal Alpine-based ext4 rootfs image for the Firecracker VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
ROOTFS_IMAGE="${ARTIFACTS_DIR}/rootfs.ext4"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-2048}"   # 2 GiB default; override with env var
ALPINE_VERSION="${ALPINE_VERSION:-3.19}"
ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_MINI_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"

# Networking config written into the rootfs
VM_IP="172.16.0.2"
VM_GATEWAY="172.16.0.1"
VM_NETMASK="255.255.255.0"
VM_HOSTNAME="fc-agent"

# Agent service settings
AGENT_PORT="${AGENT_PORT:-8080}"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (needed for mount/chroot)." >&2
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in wget mkfs.ext4 mount umount chroot; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required tools: ${missing[*]}" >&2
        echo "       Install with: apt-get install -y e2fsprogs wget" >&2
        exit 1
    fi
}

cleanup() {
    local mnt="${1:-}"
    if [[ -n "$mnt" ]] && mountpoint -q "$mnt" 2>/dev/null; then
        echo "[rootfs] Unmounting ${mnt}..."
        # Unmount any bind mounts first
        for sub in proc sys dev/pts dev; do
            umount "${mnt}/${sub}" 2>/dev/null || true
        done
        umount "$mnt" 2>/dev/null || true
    fi
    [[ -n "$mnt" ]] && rm -rf "$mnt"
}

build_rootfs() {
    mkdir -p "${ARTIFACTS_DIR}"

    # ---- Download Alpine minirootfs tarball ----
    local tarball="${ARTIFACTS_DIR}/alpine-minirootfs.tar.gz"
    if [[ ! -f "$tarball" ]]; then
        echo "[rootfs] Downloading Alpine ${ALPINE_VERSION} minirootfs..."
        wget -q --show-progress -O "$tarball" "${ALPINE_MINI_URL}"
    else
        echo "[rootfs] Reusing cached Alpine tarball."
    fi

    # ---- Create blank ext4 image ----
    echo "[rootfs] Creating ${ROOTFS_SIZE_MB} MiB ext4 image at ${ROOTFS_IMAGE}..."
    dd if=/dev/zero of="${ROOTFS_IMAGE}" bs=1M count="${ROOTFS_SIZE_MB}" status=progress
    mkfs.ext4 -F -L "rootfs" "${ROOTFS_IMAGE}"

    # ---- Mount image ----
    local mnt
    mnt="$(mktemp -d /tmp/fc-rootfs-XXXXXX)"
    trap "cleanup '${mnt}'" EXIT

    mount -o loop "${ROOTFS_IMAGE}" "$mnt"

    # ---- Extract Alpine ----
    echo "[rootfs] Extracting Alpine minirootfs..."
    tar -xzf "$tarball" -C "$mnt"

    # ---- Bind mounts for chroot ----
    mount -t proc proc "${mnt}/proc"
    mount -t sysfs sysfs "${mnt}/sys"
    mount --bind /dev "${mnt}/dev"
    mount -t devpts devpts "${mnt}/dev/pts"

    # ---- Configure networking inside rootfs ----
    echo "[rootfs] Configuring network (static IP ${VM_IP})..."
    cat > "${mnt}/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${VM_IP}
    netmask ${VM_NETMASK}
    gateway ${VM_GATEWAY}
EOF

    # DNS
    cat > "${mnt}/etc/resolv.conf" <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

    echo "${VM_HOSTNAME}" > "${mnt}/etc/hostname"

    cat >> "${mnt}/etc/hosts" <<EOF
127.0.0.1   localhost
${VM_IP}    ${VM_HOSTNAME}
EOF

    # ---- Install packages via apk in chroot ----
    echo "[rootfs] Installing packages inside chroot..."
    chroot "$mnt" /bin/sh -c "
        set -e
        apk update
        apk add --no-cache \
            openrc \
            busybox-initscripts \
            python3 \
            py3-pip \
            nodejs \
            npm \
            git \
            curl \
            bash \
            ca-certificates \
            openssh-server \
            procps
    "

    # ---- Set up OpenRC for boot ----
    chroot "$mnt" /bin/sh -c "
        set -e
        # Enable essential services
        rc-update add networking boot
        rc-update add hostname boot
        rc-update add syslog boot
        rc-update add sshd default
    " 2>/dev/null || true

    # ---- Create agent user ----
    chroot "$mnt" /bin/sh -c "
        adduser -D -s /bin/bash -h /home/agent agent 2>/dev/null || true
        mkdir -p /home/agent/agent
        chown -R agent:agent /home/agent
    "

    # ---- Agent placeholder service script ----
    mkdir -p "${mnt}/home/agent/agent"
    cat > "${mnt}/home/agent/agent/server.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Master agent HTTP service — placeholder.
Replace this with your actual agent implementation.
"""
import http.server
import json
import os
import subprocess

PORT = int(os.environ.get("AGENT_PORT", "8080"))

class AgentHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[agent] {self.address_string()} - {fmt % args}")

    def send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok"})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self.send_json(400, {"error": "invalid JSON"})
            return

        if self.path == "/run":
            prompt = data.get("prompt", "")
            # TODO: wire in your actual agent logic here
            result = {"response": f"Echo: {prompt}"}
            self.send_json(200, result)
        else:
            self.send_json(404, {"error": "not found"})

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), AgentHandler)
    print(f"[agent] Master agent listening on :{PORT}")
    server.serve_forever()
PYEOF
    chroot "$mnt" chown -R agent:agent /home/agent

    # ---- OpenRC init script for the agent ----
    cat > "${mnt}/etc/init.d/agent" <<'INITEOF'
#!/sbin/openrc-run

name="agent"
description="Master agent HTTP service"
command="/usr/bin/python3"
command_args="/home/agent/agent/server.py"
command_user="agent"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/agent.log"
error_log="/var/log/agent.log"

depend() {
    need net
    after networking
}
INITEOF
    chmod +x "${mnt}/etc/init.d/agent"
    chroot "$mnt" rc-update add agent default 2>/dev/null || true

    # ---- inittab: serial console for Firecracker ----
    cat > "${mnt}/etc/inittab" <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

    # ---- Root password (change in production!) ----
    chroot "$mnt" /bin/sh -c "echo 'root:root' | chpasswd" 2>/dev/null || true

    echo "[rootfs] Build complete: ${ROOTFS_IMAGE}"
    echo "[rootfs]   Size:     ${ROOTFS_SIZE_MB} MiB"
    echo "[rootfs]   VM IP:    ${VM_IP}"
    echo "[rootfs]   Hostname: ${VM_HOSTNAME}"
    echo "[rootfs]   Agent:    http://${VM_IP}:${AGENT_PORT}"

    # Cleanup is handled by trap
}

require_root
check_deps
build_rootfs
