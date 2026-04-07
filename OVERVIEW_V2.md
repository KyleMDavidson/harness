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
- Takes a task description as input
- Sends prompts to the slave via `POST http://172.16.0.2:8080/run`
- Uses Claude (Opus 4.6) to review the slave's output and decide:
  - Done → print result and exit
  - Not done → compose a follow-up prompt and loop
- Has a configurable iteration limit (`MAX_ITERATIONS`, default 10)

**`server.py`** (runs as `agent` inside the VM)
- Listens on `0.0.0.0:8080`
- On `POST /run`, receives a prompt and runs its own Claude agentic loop
- Has three tools: `bash`, `read_file`, `write_file` — all scoped to `/home/agent/workspace`
- Returns Claude's final text response as `{"result": "..."}`

---

## Current topology

One master, one VM, one slave. The master and slave have a direct 1:1 relationship. The orchestrator is purely transparent infrastructure.

```
[ master.py ]  ←──────────────────────────────────────────────┐
      │                                                        │
      │  POST /run {"prompt": "..."}                          │
      ↓                                                        │
[ server.py ]  →  Claude loop (bash, read_file, write_file)   │
      │                                                        │
      └────────────────── {"result": "..."} ───────────────────┘
```

---

## Script inventory

| Script | Run by | Purpose |
|---|---|---|
| `master.py` | `fc-master` | Application loop — drives the task |
| `server.py` | `agent` (inside VM) | Slave — implements tasks using Claude + tools |
| `setup_vm.sh` | `fc-orch` | VM lifecycle: start, stop, restart, status |
| `network_setup.sh` | `fc-orch` | Bridge and TAP interface management |
| `rootfs_build.sh` | root | Builds the ext4 guest image (run once) |
| `configure_firecracker.sh` | `fc-orch` | Configures the VM via the Firecracker API socket |
| `reset_rootfs.sh` | root | Deletes and rebuilds the rootfs image |

---

## Running a task

```bash
# 1. Start the VM (once)
export ANTHROPIC_API_KEY="sk-ant-..."
sudo -u fc-orch ./setup_vm.sh start

# 2. Run a task
sudo -u fc-master python3 master.py "Write a Python function that parses JSON and handles errors"

# 3. Stop the VM when done
sudo -u fc-orch ./setup_vm.sh stop
```
