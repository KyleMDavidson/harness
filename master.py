#!/usr/bin/env python3
"""
Master process — orchestrates the slave agent via the Claude Code Agent SDK.

Usage:
    python master.py "your task here"
    echo "your task" | python master.py

The master runs as a Claude Code agent on the host. It communicates with the
slave by POSTing to its HTTP endpoint via bash/curl. Claude drives the loop
itself — reviewing results and deciding when the task is complete.
"""

import argparse
import os
import sys
import anyio
from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage

AGENT_HOST = os.environ.get("AGENT_HOST", "172.16.0.2")
AGENT_PORT = os.environ.get("AGENT_PORT", "8080")
AGENT_URL = f"http://{AGENT_HOST}:{AGENT_PORT}"

DEFAULT_MAX_ITERATIONS = 10


def build_system_prompt(max_iterations: int) -> str:
    return f"""\
You are a master orchestrator. You have a slave agent running at {AGENT_URL}.

To send a task to the slave, use bash:
  curl -s -X POST {AGENT_URL}/run \\
    -H 'Content-Type: application/json' \\
    -d '{{"prompt": "your instruction here"}}'

The slave will carry out the task using its own tools (bash, file read/write, etc.)
and return a JSON response with a "result" field.

Your job:
1. Break the overall task into steps if needed.
2. Send each step to the slave and review its output.
3. Follow up with corrections or next steps as needed.
4. When the task is fully complete, summarize what was accomplished.

IMPORTANT: You may send at most {max_iterations} requests to the slave. \
If you reach this limit, stop and report whatever partial progress has been made.\
"""


async def main() -> None:
    parser = argparse.ArgumentParser(description="Master orchestrator")
    parser.add_argument("task", nargs="*", help="Task description")
    parser.add_argument(
        "--max-iterations",
        type=int,
        default=DEFAULT_MAX_ITERATIONS,
        metavar="N",
        help=f"Maximum number of requests to send to the slave (default: {DEFAULT_MAX_ITERATIONS})",
    )
    args = parser.parse_args()

    if args.task:
        task = " ".join(args.task)
    elif not sys.stdin.isatty():
        task = sys.stdin.read().strip()
    else:
        parser.print_usage(sys.stderr)
        sys.exit(1)

    if not task:
        print("No task provided.", file=sys.stderr)
        sys.exit(1)

    async for message in query(
        prompt=task,
        options=ClaudeAgentOptions(
            allowed_tools=["Bash"],
            system_prompt=build_system_prompt(args.max_iterations),
        ),
    ):
        if isinstance(message, ResultMessage):
            print(message.result)


anyio.run(main)
