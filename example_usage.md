# Example Usage

## Scenario

We want the master to drive the slave to completion on a coding goal. The master loops — sending tasks, reviewing results, and following up — until it decides the goal is satisfied.

**Goal:** implement a small Python module with a working test suite. The master considers the goal done when all tests pass.

---

## 1. Start the VM

```bash
sudo ./setup_vm.sh start
```

The slave (`server.py`) starts automatically inside the VM via OpenRC. Once the health check passes, the system is ready.

---

## 2. Run the master

```bash
./venv/bin/python master.py "
Implement a Python module at /home/agent/workspace/stats.py that provides three
functions: mean(numbers), median(numbers), and stdev(numbers). Also write a test
file at /home/agent/workspace/test_stats.py that covers normal cases and edge
cases (empty list, single element, duplicates). Keep looping until you can confirm
that all tests pass by running them.
"
```

---

## 3. What happens

**Master receives the task.** Its system prompt tells it to communicate with the slave via curl:

```
You are a master orchestrator. You have a slave agent running at http://172.16.0.2:8080.
To send a task to the slave, use bash:
  curl -s -X POST http://172.16.0.2:8080/run \
    -H 'Content-Type: application/json' \
    -d '{"prompt": "your instruction here"}'
```

**Iteration 1 — implement the module:**

Master curls the slave with a focused prompt:

```
POST /run {"prompt": "Create /home/agent/workspace/stats.py with mean(), median(),
and stdev() functions. Then create test_stats.py with comprehensive tests covering
normal cases, empty input, single element, and duplicates. Run the tests and report
the output."}
```

Slave runs its Claude loop (Bash, Read, Write, Edit, Glob, Grep in `/home/agent/workspace`):
- Writes `stats.py`
- Writes `test_stats.py`
- Runs `python -m pytest test_stats.py -v`
- Returns the test output as its result

Master receives the result. Two tests are failing — `stdev` of a single element raises `ZeroDivisionError`.

**Iteration 2 — fix the bug:**

Master sends a follow-up:

```
POST /run {"prompt": "stdev() raises ZeroDivisionError for a single-element list.
Fix stats.py to return 0.0 in that case, then re-run the tests and confirm they all pass."}
```

Slave edits `stats.py`, re-runs pytest, all tests pass. Returns:

```
All 12 tests passed.

PASSED test_stats.py::test_mean_basic
PASSED test_stats.py::test_mean_empty
PASSED test_stats.py::test_median_odd
PASSED test_stats.py::test_median_even
PASSED test_stats.py::test_stdev_basic
PASSED test_stats.py::test_stdev_single
...
```

**Master evaluates the result.** It sees all tests passed — the condition is met. It summarizes and exits:

```
Task complete. Implemented stats.py with mean(), median(), and stdev(). Fixed a
ZeroDivisionError in stdev() for single-element input. All 12 tests pass.
```

---

## 4. The termination condition

The master never runs a fixed number of iterations. Claude (running as the master) reads each result and decides:

- **Tests still failing** → compose a targeted follow-up and loop
- **All tests passing** → summarize and exit
- **Slave reports an unrecoverable error** → report back to the user and exit

The condition is expressed in natural language in the initial prompt. The master infers when it's met. If you want a stricter condition (e.g. "must pass with zero warnings and coverage above 80%"), include that in the task.

---

## 5. Variation: goal without explicit tests

The condition doesn't have to be test-based. For example:

```bash
./venv/bin/python master.py "
Write a bash script at /home/agent/workspace/backup.sh that tarballs a given
directory and uploads it to /tmp/backups/. Verify it works by running it on
/home/agent/workspace itself and confirming the archive exists and is non-empty.
Loop until the script works correctly end-to-end.
"
```

Master loops until it can confirm the archive exists and `tar -tzf` lists real files.

---

## 6. Inspecting the workspace after the run

The slave's work lives inside the VM at `/home/agent/workspace`. To inspect it:

```bash
# SSH into the VM (if sshd is running and you've set up keys)
ssh agent@172.16.0.2

# Or read files out via the slave's HTTP endpoint
curl -s -X POST http://172.16.0.2:8080/run \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Print the contents of every file in /home/agent/workspace."}'
```
