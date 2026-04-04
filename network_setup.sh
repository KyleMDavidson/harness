#!/usr/bin/env bash
# network_setup.sh — Create Linux bridge, tap device, and firewall rules for Firecracker VM
set -euo pipefail

BRIDGE="fcbr0"
TAP="fctap0"
BRIDGE_IP="172.16.0.1"
BRIDGE_CIDR="${BRIDGE_IP}/24"
VM_IP="172.16.0.2"
HOST_IFACE="${HOST_IFACE:-$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)}"

usage() {
    echo "Usage: $0 [up|down]"
    echo "  up    Create bridge, tap, and firewall rules (default)"
    echo "  down  Tear down bridge, tap, and firewall rules"
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root." >&2
        exit 1
    fi
}

net_up() {
    echo "[network] Detected host interface: ${HOST_IFACE}"

    # --- Bridge ---
    if ip link show "${BRIDGE}" &>/dev/null; then
        echo "[network] Bridge ${BRIDGE} already exists, skipping creation."
    else
        echo "[network] Creating bridge ${BRIDGE}..."
        ip link add name "${BRIDGE}" type bridge
        ip link set "${BRIDGE}" up
        ip addr add "${BRIDGE_CIDR}" dev "${BRIDGE}"
        echo "[network] Bridge ${BRIDGE} created with IP ${BRIDGE_CIDR}."
    fi

    # --- TAP device ---
    if ip link show "${TAP}" &>/dev/null; then
        echo "[network] TAP device ${TAP} already exists, skipping creation."
    else
        echo "[network] Creating TAP device ${TAP}..."
        ip tuntap add dev "${TAP}" mode tap
        ip link set "${TAP}" master "${BRIDGE}"
        ip link set "${TAP}" up
        echo "[network] TAP device ${TAP} attached to bridge ${BRIDGE}."
    fi

    # --- IP forwarding ---
    echo "[network] Enabling IPv4 forwarding..."
    sysctl -q -w net.ipv4.ip_forward=1

    # --- iptables: NAT (masquerade outbound from VM subnet) ---
    echo "[network] Configuring iptables rules..."

    # Guard against duplicate rules
    if ! iptables -t nat -C POSTROUTING -s "${BRIDGE_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "${BRIDGE_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE
    fi

    # Allow forwarding: host -> VM
    if ! iptables -C FORWARD -i "${HOST_IFACE}" -o "${BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "${HOST_IFACE}" -o "${BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi

    # Allow forwarding: VM -> host
    if ! iptables -C FORWARD -i "${BRIDGE}" -o "${HOST_IFACE}" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "${BRIDGE}" -o "${HOST_IFACE}" -j ACCEPT
    fi

    # Allow intra-bridge traffic (VM <-> bridge)
    if ! iptables -C FORWARD -i "${BRIDGE}" -o "${BRIDGE}" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "${BRIDGE}" -o "${BRIDGE}" -j ACCEPT
    fi

    # Accept traffic from TAP (for HTTP to master agent on port 8080)
    if ! iptables -C INPUT -i "${TAP}" -j ACCEPT 2>/dev/null; then
        iptables -A INPUT -i "${TAP}" -j ACCEPT
    fi

    echo "[network] Network setup complete."
    echo "[network]   Bridge:     ${BRIDGE}  (${BRIDGE_CIDR})"
    echo "[network]   TAP:        ${TAP}"
    echo "[network]   VM IP:      ${VM_IP}"
    echo "[network]   Host iface: ${HOST_IFACE}"
}

net_down() {
    echo "[network] Tearing down network resources..."

    # Remove iptables rules (best-effort)
    iptables -t nat -D POSTROUTING -s "${BRIDGE_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "${HOST_IFACE}" -o "${BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${BRIDGE}" -o "${HOST_IFACE}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${BRIDGE}" -o "${BRIDGE}" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -i "${TAP}" -j ACCEPT 2>/dev/null || true

    # Remove TAP
    if ip link show "${TAP}" &>/dev/null; then
        ip link set "${TAP}" down 2>/dev/null || true
        ip tuntap del dev "${TAP}" mode tap 2>/dev/null || true
        echo "[network] Removed TAP device ${TAP}."
    fi

    # Remove bridge
    if ip link show "${BRIDGE}" &>/dev/null; then
        ip link set "${BRIDGE}" down 2>/dev/null || true
        ip link del "${BRIDGE}" 2>/dev/null || true
        echo "[network] Removed bridge ${BRIDGE}."
    fi

    echo "[network] Teardown complete."
}

require_root

case "${1:-up}" in
    up)   net_up ;;
    down) net_down ;;
    *)    usage ;;
esac
