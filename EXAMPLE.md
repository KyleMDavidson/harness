# Using the Harness — Practical Guide

## Setup (once per machine)

```bash
# 1. One-time host setup
sudo ./install.sh

# 2. Start the VM (persists until you stop it or reboot)
sudo ./setup_vm.sh start

# 3. Confirm the slave is alive
./status.sh
```

---

## How you talk to the master

The master is a **CLI process**, not an HTTP server. You give it a task and it runs to completion:

```bash
./venv/bin/python master.py "your task here"
```

The master (Claude) then drives the slave over HTTP internally — you don't interact with that layer directly. When it's done, the master prints a summary of what was accomplished and exits.

The slave is the HTTP server (`172.16.0.2:8080`). You generally don't talk to it directly — but you can if you want to test or inspect things:

```bash
# Health check
curl http://172.16.0.2:8080/health

# Send a one-off prompt directly to the slave, bypassing the master
curl -s -X POST http://172.16.0.2:8080/run \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "List all files in your workspace."}'
```

---

## Where the slave does its work

The slave operates in `/home/agent/workspace` **inside the VM** — this is not a directory on your host. Files the slave creates live there, isolated from your machine.

To work on a real repository, you need to get the code into the slave's workspace first. The simplest way is to tell the master to do it:

```bash
./venv/bin/python master.py "
Clone the repository at https://github.com/your-org/your-repo.git into
/home/agent/workspace/repo, then implement the following feature: ...
"
```

Or if the repo is private and you've set up SSH keys inside the VM, the slave can clone with its own credentials. Alternatively, for a local repo, you can push it to a remote the slave can reach and have it pull.

---

## Observing what the slave did

**Option 1 — Ask the master.** The master's final summary describes what was accomplished. For details, give it an explicit instruction:

```bash
./venv/bin/python master.py "
... your task ...
When complete, output the full contents of every file you created or modified.
"
```

**Option 2 — Query the slave directly.** After the master finishes, the slave is still running. Ask it to show you its work:

```bash
curl -s -X POST http://172.16.0.2:8080/run \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Show me every file in /home/agent/workspace and its contents."}'
```

**Option 3 — SSH into the VM** (if you've configured SSH keys in the rootfs):

```bash
ssh agent@172.16.0.2
ls /home/agent/workspace/
```

---

## Getting results back to your host

The slave's filesystem is ephemeral — it resets on `reset_rootfs.sh`. To get output back to your host:

- Ask the master to have the slave print the final file contents in its summary (easiest).
- Have the slave push a git branch to your remote — then pull it on the host.
- Have the slave POST results to a local HTTP server you're running on the host (reachable at `172.16.0.1` from inside the VM).

---

## Practical tips

**Be specific about the success condition.** The master loops until Claude decides the task is done. Give it something concrete to verify against:

```bash
# Vague — master may stop too early or loop forever
./venv/bin/python master.py "add error handling to the parser"

# Better — master can confirm completion objectively
./venv/bin/python master.py "
Add error handling to parser.py so it raises ValueError with a descriptive
message when input is None or empty. Write tests in test_parser.py and loop
until all tests pass with zero errors.
"
```

**Use `--max-iterations` to bound runaway loops:**

```bash
./venv/bin/python master.py --max-iterations 5 "your task"
```

**The VM persists between master runs.** Workspace files from a previous run are still there. This is useful for iterating on the same codebase across multiple master invocations. Run `reset_rootfs.sh` only when you want a clean slate.

**Check status at any time:**

```bash
./status.sh
```

**To stop everything:**

```bash
sudo ./stop.sh
```
