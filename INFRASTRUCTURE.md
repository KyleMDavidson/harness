# Model          (VM lifecycle)
[ Master ]  ─────────────→  [ Orchestrator ]
     ↑                            ↓
     │                        (start VM)
     │                            ↓
     │                        [ Firecracker VM ]
     │                            ↑
     └─────────────── HTTP ───────┘
               (run tasks)


The Master controls stauting up / shutting down VMs via the Orchestrator.
There are three distinct OS-level users in this system: `fc-master` (master),
`fc-orch` (orchestrator) on the host, and `agent` inside each VM.
Their scopes do not overlap.

---

## Host: `fc-master` (master process)

The master is the application-level controller — it decides when to start or
stop VMs and dispatches tasks to agents via HTTP. It has no special OS
capabilities. It cannot touch the network interfaces, the Firecracker binary,
or the VM images directly. Its only privileges are:

1. The ability to invoke the orchestrator through a tightly scoped `sudo` rule
   (just `setup_vm.sh`, nothing else).
2. Network access to the VM subnet (`172.16.0.0/24`) to send HTTP requests.

### Setup

```bash
# Create the user — no login shell, no home directory
sudo useradd --system --no-create-home --shell /usr/sbin/nologin fc-master

# Allow fc-master to run only setup_vm.sh as fc-orch, no password, nothing else
# Add this line via: sudo visudo -f /etc/sudoers.d/fc-master
echo "fc-master ALL=(fc-orch) NOPASSWD: /home/kyle/harness/setup_vm.sh" \
    | sudo tee /etc/sudoers.d/fc-master
sudo chmod 440 /etc/sudoers.d/fc-master
```

Invoke the orchestrator from the master process like this:

```bash
sudo -u fc-orch /home/kyle/harness/setup_vm.sh start
sudo -u fc-orch /home/kyle/harness/setup_vm.sh stop
```

### Capabilities & scope

| Capability | fc-master |
|---|---|
| Read/write host filesystem | No — no home directory, no owned paths |
| Modify network interfaces | No — no capabilities granted |
| Start/stop VMs directly | No — must go through `setup_vm.sh` via sudo rule |
| Invoke any other host script as fc-orch | No — sudo rule is scoped to `setup_vm.sh` only |
| Send HTTP to VMs | Yes — normal network access to `172.16.0.0/24` |
| Receive HTTP responses from VMs | Yes |

---

## Host: `fc-orch` (orchestrator process)

Runs the orchestrator scripts (`setup_vm.sh`, etc.) on the host. Has no login
shell and no home directory outside the harness. Its only job is to manage the
Firecracker process and the host network interfaces that connect to VMs.
Needs access to taps and /dev/kvm, so this runs on the host OS

### Setup

```bash
# Create the user
sudo useradd --system --no-create-home --shell /usr/sbin/nologin fc-orch

# /dev/kvm access — required for Firecracker to start VMs
sudo usermod -aG kvm fc-orch

# CAP_NET_ADMIN on the firecracker binary only — allows creating bridge/TAP
# without giving the user blanket root network access
sudo setcap cap_net_admin+ep /usr/local/bin/firecracker

# Own only the harness artifacts directory
sudo chown -R fc-orch:fc-orch /home/kyle/harness/artifacts
sudo chmod 750 /home/kyle/harness/artifacts

# Dedicated socket directory, inaccessible to other users
sudo mkdir -p /run/firecracker
sudo chown fc-orch:fc-orch /run/firecracker
sudo chmod 700 /run/firecracker
```

Update `config.env` to move the socket under that directory:

```bash
FC_SOCKET=/run/firecracker/firecracker.socket
```

Run the orchestrator as this user:

```bash
sudo -u fc-orch ./setup_vm.sh start
```

### Capabilities & scope

| Capability | fc-orch |
|---|---|
| Read/write arbitrary host files | No — owns only `artifacts/` |
| Modify the host OS / install packages | No — no sudo, no package manager access |
| Spawn arbitrary processes | No — no login shell |
| Create/destroy network interfaces | Yes — `CAP_NET_ADMIN` scoped to the firecracker binary |
| Start/stop VMs | Yes — `/dev/kvm` group membership |
| Communicate with VMs over HTTP | Yes — via bridge IP `172.16.0.1` |
| Access VM filesystem directly | No — rootfs is an opaque file in `artifacts/` |

---

## Guest: `agent` (slave process inside each VM)

Runs `server.py` inside the Firecracker VM. Created during `rootfs_build.sh`.
Has no login shell and owns only `/home/agent`. It is entirely contained within
the VM — it has no knowledge of or access to the host filesystem, host
processes, or the Firecracker API socket.

### Setup (performed automatically by `rootfs_build.sh`)

```bash
# Inside the VM (Alpine), during rootfs build:
adduser -D -s /bin/bash -h /home/agent agent
chown -R agent:agent /home/agent
```

The agent service is managed by OpenRC and runs as this user:

```ini
# /etc/init.d/agent (inside VM)
command_user="agent"
```

### Capabilities & scope

| Capability | agent |
|---|---|
| Access host filesystem | No — VM boundary enforced by Firecracker/KVM |
| Access host processes or sockets | No |
| Communicate with the host | Yes — HTTP only, via gateway `172.16.0.1` |
| Write to VM filesystem | Yes — owns `/home/agent`, can write workspace files |
| Install packages inside VM | Only if explicitly granted (not by default) |
| Persist state across resets | Yes — until `reset_rootfs.sh` is run |



# Agentic Coding Harness — VM Scripts Overview

This directory contains four shell scripts that together provision and run a Firecracker microVM hosting a master agent HTTP service. The host communicates with the agent exclusively via HTTP on `http://172.16.0.2:8080`.

---

## Scripts

### `install.sh` — One-time Host Setup

Run once on a fresh host before anything else. Must be run as root.

- Creates OS users `fc-master` and `fc-orch` (system users, no login shell).
- Adds `fc-orch` to the `kvm` group for `/dev/kvm` access.
- Sets `CAP_NET_ADMIN` on the Firecracker binary so `fc-orch` can manage network interfaces without full root.
- Creates `/run/firecracker` (socket directory, owned by `fc-orch`).
- Creates `artifacts/` (owned by `fc-orch`).
- Writes `/etc/sudoers.d/fc-master` so `fc-master` can invoke `setup_vm.sh` via sudo.
- Creates a Python venv at `harness/venv` and installs `claude-agent-sdk` into it.

---

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
