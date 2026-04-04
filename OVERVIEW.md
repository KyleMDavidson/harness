# Agentic Coding Harness — VM Scripts Overview

This directory contains four shell scripts that together provision and run a Firecracker microVM hosting a master agent HTTP service. The host communicates with the agent exclusively via HTTP on `http://172.16.0.2:8080`.

---

## Scripts

### `setup_vm.sh` — Orchestrator

The top-level entrypoint. Run as root with `start`, `stop`, `restart`, or `status`.

On `start` it executes the other three scripts in order:
1. Calls `network_setup.sh up` to prepare the host network.
2. Calls `rootfs_build.sh` to build the guest filesystem (skipped if `artifacts/rootfs.ext4` already exists).
3. Launches the `firecracker` binary in the background, then calls `configure_firecracker.sh` to configure the VM via its API socket, and finally sends an `InstanceStart` action to boot it.

On `stop` it gracefully halts the guest, kills the Firecracker process, and calls `network_setup.sh down`.

Key environment variable overrides: `FC_BINARY`, `FC_SOCKET`, `VM_VCPUS`, `VM_MEM_MB`, `KERNEL_IMAGE`, `ROOTFS_IMAGE`, `AGENT_PORT`.

---

### `network_setup.sh` — Host Network

Creates (or tears down) the host-side networking required for the VM.

**`up` action:**
- Creates Linux bridge `fcbr0` with IP `172.16.0.1/24`.
- Creates TAP device `fctap0` and attaches it to the bridge.
- Enables IPv4 forwarding via `sysctl`.
- Adds `iptables` rules: MASQUERADE on outbound traffic from `172.16.0.0/24`, FORWARD rules between the bridge and the detected host interface, and INPUT accept on the TAP device.

**`down` action:** removes all of the above in reverse.

The bridge IP (`172.16.0.1`) becomes the VM's default gateway. The TAP device is the virtual wire between the host kernel and the Firecracker guest NIC.

---

### `rootfs_build.sh` — Guest Filesystem

Builds the ext4 disk image (`artifacts/rootfs.ext4`) that Firecracker mounts as the guest root filesystem.

Steps:
1. Downloads the Alpine Linux 3.19 minirootfs tarball (cached after the first run).
2. Creates a blank ext4 image (`dd` + `mkfs.ext4`, default 2 GiB).
3. Mounts the image and extracts Alpine into it.
4. Bind-mounts `/proc`, `/sys`, `/dev` for `chroot`.
5. Inside the chroot, installs packages via `apk`: `openrc`, Python 3, Node.js, npm, git, curl, bash, openssh.
6. Writes static network config (`eth0` → `172.16.0.2`, gateway `172.16.0.1`) and `/etc/resolv.conf`.
7. Creates an `agent` user and drops a placeholder Python HTTP server at `/home/agent/agent/server.py`.
8. Installs an OpenRC init script (`/etc/init.d/agent`) so the agent starts automatically on boot.
9. Configures `/etc/inittab` for a `ttyS0` serial console (required by Firecracker).

---

### `configure_firecracker.sh` — VM Configuration

Configures a running (but not yet booted) Firecracker process by issuing `PUT` requests to its Unix socket API at `${FC_SOCKET}` (default `/tmp/firecracker.socket`).

Sends five API calls in order:
1. **`/machine-config`** — vCPU count and memory size.
2. **`/boot-source`** — path to the kernel (`artifacts/vmlinux`) and boot arguments (serial console, static IP via `ip=` kernel parameter, `pci=off nomodules`).
3. **`/drives/rootfs`** — path to the rootfs image, marked as root device, read-write.
4. **`/network-interfaces/eth0`** — binds `fctap0` on the host to `eth0` inside the guest with a fixed MAC address.
5. **`/logger`** — directs Firecracker logs to `/tmp/fc-logs/firecracker.log`.

This script does not start the VM; `setup_vm.sh` sends the `InstanceStart` action separately after this script returns.

---

## Relationship Diagram

```
setup_vm.sh  (orchestrator)
├── network_setup.sh       creates fcbr0 / fctap0 / iptables on the HOST
├── rootfs_build.sh        builds artifacts/rootfs.ext4 (run once)
├── [firecracker binary]   started in background, waits on API socket
└── configure_firecracker.sh  configures VM via socket, then setup_vm.sh boots it
```

---

## Artifacts Directory

Created at runtime under `harness/artifacts/`:

| File | Source |
|---|---|
| `vmlinux` | Auto-downloaded by `setup_vm.sh` if missing (AWS Firecracker quickstart kernel) |
| `rootfs.ext4` | Built by `rootfs_build.sh` |

---

## Agent Interface

Once the VM is running, the master agent is reachable from the host at:

| Endpoint | Method | Description |
|---|---|---|
| `http://172.16.0.2:8080/health` | GET | Liveness check |
| `http://172.16.0.2:8080/run` | POST | Submit a prompt (`{"prompt": "..."}`) |

The `server.py` placeholder in the rootfs is the integration point — replace it with the real agent implementation.
