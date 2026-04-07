# Architecture Overview (V2)

This system has two distinct layers. Understanding them separately resolves most naming confusion.

---

## Layer 1 — Infrastructure (OS security model)

Three OS-level users. Their scopes do not overlap.

```
[ fc-master ]  ──sudo setup_vm.sh──→  [ fc-orch ]
                                            │
                                     (manages Firecracker,
                                      network interfaces)
                                            │
                                            ↓
                                    [ Firecracker VM ]
                                      (agent user inside)
```

| User | Host/Guest | Responsibility |
|---|---|---|
| `fc-master` | Host | Runs `master.py`. No OS privileges beyond a scoped sudo rule and network access to the VM subnet. |
| `fc-orch` | Host | Runs `setup_vm.sh`. Owns the Firecracker binary, TAP/bridge interfaces, API socket, and rootfs artifacts. |
| `agent` | Inside VM | Runs `server.py`. Owns `/home/agent`. Cannot see the host filesystem or host processes. |

**The orchestrator (`fc-orch`) is infrastructure-only.** It starts and stops VMs; it plays no role in the application task loop. Once a VM is running, `fc-orch` is idle.

---

## Layer 2 — Application (task loop)

Two participants. The orchestrator is not involved here.

```
[ master.py ]  ──POST /run──→  [ server.py ]
      ↑                               │
      └──────── result ───────────────┘
```

**`master.py`** (runs as `fc-master` on the host)
- Takes a task description as input (CLI arg or stdin)
- Uses the Claude Code Agent SDK with a single tool: `Bash`
- Claude drives the loop — it curls `POST http://172.16.0.2:8080/run` to send steps to the slave, reviews the results, and decides when the task is done
- Prints the final summary and exits

**`server.py`** (runs as `agent` inside the VM)
- Listens on `0.0.0.0:8080`
- Endpoints: `GET /health` (liveness), `POST /run` (accepts `{"prompt": "..."}`, returns `{"result": "..."}`)
- On `POST /run`, runs its own Claude Code Agent SDK loop with tools: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep` — all operating in `/home/agent/workspace`
- Runs with `permission_mode="bypassPermissions"` (isolated inside the VM)

---

## Authentication

Both master and slave use the **Claude Code CLI** via the Agent SDK — no `ANTHROPIC_API_KEY` needed. Authentication is via OAuth session tokens stored in `~/.claude/`.

- **Master**: tokens in the invoking user's `~/.claude/` on the host
- **Slave**: tokens copied from the invoking user's `~/.claude/` into the rootfs at build time (`/home/agent/.claude/`). Tokens will expire eventually; rebuild the rootfs to refresh them.

---

## Current topology

One master, one VM, one slave. The master and slave have a direct 1:1 relationship. The orchestrator is purely transparent infrastructure.

```
[ master.py ]  ←──────────────────────────────────────────────────────────────┐
      │                                                                        │
      │  POST /run {"prompt": "..."}                                           │
      ↓                                                                        │
[ server.py ]  →  Claude loop (Bash, Read, Write, Edit, Glob, Grep)           │
      │                                                                        │
      └───────────────────────── {"result": "..."} ────────────────────────────┘
```

---

## Script inventory

| Script | Run by | Purpose |
|---|---|---|
| `master.py` | `fc-master` | Application loop — drives the task |
| `server.py` | `agent` (inside VM) | Slave — carries out tasks using Claude + tools |
| `install.sh` | root | One-time host setup: OS users, venv, kvm group, sudo rules |
| `setup_vm.sh` | root / `fc-orch` | VM lifecycle: start, stop, restart, status |
| `stop.sh` | root | Kill Firecracker and tear down network (convenience wrapper) |
| `network_setup.sh` | root / `fc-orch` | Bridge and TAP interface management |
| `rootfs_build.sh` | root | Builds the ext4 guest image (atomic: builds to `.tmp`, renames on success) |
| `configure_firecracker.sh` | root / `fc-orch` | Configures the VM via the Firecracker API socket |
| `reset_rootfs.sh` | root | Deletes and rebuilds the rootfs image |
| `test.sh` | root | Smoke test: start VM, verify slave health, test Claude auth, test round trip. Pass `--rebuild` to force a rootfs rebuild. |

---

## Running a task

```bash
# 1. One-time setup (creates OS users, venv, etc.)
sudo ./install.sh

# 2. Start the VM
sudo ./setup_vm.sh start

# 3. Run a task
./venv/bin/python master.py "Write a Python function that parses JSON and handles errors"

# 4. Stop the VM when done
sudo ./stop.sh
```

```bash
# Smoke test (start fresh, verify everything works end-to-end)
sudo ./test.sh

# Force a rootfs rebuild (e.g. after changing server.py or credentials expired)
sudo ./test.sh --rebuild
```
