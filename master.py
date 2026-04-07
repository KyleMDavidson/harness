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

import os
import sys
import anyio
from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage

AGENT_HOST = os.environ.get("AGENT_HOST", "172.16.0.2")
AGENT_PORT = os.environ.get("AGENT_PORT", "8080")
AGENT_URL = f"http://{AGENT_HOST}:{AGENT_PORT}"

SYSTEM = f"""\
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
4. When the task is fully complete, summarize what was accomplished.\
"""


async def main() -> None:
    if len(sys.argv) > 1:
        task = " ".join(sys.argv[1:])
    elif not sys.stdin.isatty():
        task = sys.stdin.read().strip()
    else:
        print("Usage: python master.py \"<task>\"", file=sys.stderr)
        sys.exit(1)

    if not task:
        print("No task provided.", file=sys.stderr)
        sys.exit(1)

    async for message in query(
        prompt=task,
        options=ClaudeAgentOptions(
            allowed_tools=["Bash"],
            system_prompt=SYSTEM,
        ),
    ):
        if isinstance(message, ResultMessage):
            print(message.result)


anyio.run(main)
