#!/usr/bin/env bash
# rootfs_build.sh — Build a minimal Alpine-based ext4 rootfs image for the Firecracker VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/artifacts"
# shellcheck source=config.env
source "${SCRIPT_DIR}/config.env"

ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_MINI_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ARCH}.tar.gz"

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

    # ---- Create blank ext4 image (build to tmp, move on success) ----
    local tmp_image="${ROOTFS_IMAGE}.tmp"
    echo "[rootfs] Creating ${ROOTFS_SIZE_MB} MiB ext4 image..."
    dd if=/dev/zero of="${tmp_image}" bs=1M count="${ROOTFS_SIZE_MB}" status=progress
    mkfs.ext4 -F -L "rootfs" "${tmp_image}"

    # ---- Mount image ----
    local mnt
    mnt="$(mktemp -d /tmp/fc-rootfs-XXXXXX)"
    trap "cleanup '${mnt}'; rm -f '${tmp_image}'" EXIT

    mount -o loop "${tmp_image}" "$mnt"

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

    echo "[rootfs] Installing Python dependencies..."
    chroot "$mnt" /bin/sh -c "
        set -e
        pip3 install --break-system-packages claude-agent-sdk
    "

    echo "[rootfs] Installing Claude Code CLI..."
    chroot "$mnt" /bin/sh -c "
        set -e
        npm install -g @anthropic-ai/claude-code
    "

    echo "[rootfs] Copying Claude Code credentials..."
    local claude_src=""
    if [[ -n "${SUDO_USER:-}" ]]; then
        local user_home
        user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        claude_src="${user_home}/.claude"
    else
        claude_src="${HOME}/.claude"
    fi
    if [[ -d "$claude_src" ]]; then
        mkdir -p "${mnt}/home/agent/.claude"
        cp -r "$claude_src/." "${mnt}/home/agent/.claude/"
        chroot "$mnt" chown -R agent:agent /home/agent/.claude
        echo "[rootfs]   Credentials copied from ${claude_src}"
    else
        echo "[rootfs] WARNING: No Claude Code credentials found at ${claude_src}" >&2
        echo "[rootfs]          The slave agent won't be able to authenticate." >&2
    fi

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

    # ---- Copy agent server ----
    mkdir -p "${mnt}/home/agent/agent"
    cp "${SCRIPT_DIR}/server.py" "${mnt}/home/agent/agent/server.py"
    chroot "$mnt" chown -R agent:agent /home/agent

    # ---- OpenRC conf file (environment for the agent service) ----
    cat > "${mnt}/etc/conf.d/agent" <<EOF
AGENT_PORT="${AGENT_PORT}"
EOF

    # ---- OpenRC init script for the agent ----
    cat > "${mnt}/etc/init.d/agent" <<'INITEOF'
#!/sbin/openrc-run

name="agent"
description="Agent HTTP service"
command="/usr/bin/python3"
command_args="/home/agent/agent/server.py"
command_user="agent"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/agent.log"
error_log="/var/log/agent.log"

# Pass variables from /etc/conf.d/agent into the process environment
export AGENT_PORT

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

    # ---- Unmount and promote to final path ----
    for sub in proc sys dev/pts dev; do
        umount "${mnt}/${sub}" 2>/dev/null || true
    done
    umount "$mnt"
    rm -rf "$mnt"
    trap - EXIT  # disarm trap — build succeeded

    mv "${tmp_image}" "${ROOTFS_IMAGE}"

    echo "[rootfs] Build complete: ${ROOTFS_IMAGE}"
    echo "[rootfs]   Size:     ${ROOTFS_SIZE_MB} MiB"
    echo "[rootfs]   VM IP:    ${VM_IP}"
    echo "[rootfs]   Hostname: ${VM_HOSTNAME}"
    echo "[rootfs]   Agent:    http://${VM_IP}:${AGENT_PORT}"
}

require_root
check_deps
build_rootfs
