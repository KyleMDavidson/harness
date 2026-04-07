#!/usr/bin/env python3
"""
Slave agent server — runs inside the Firecracker VM as the `agent` user.
Listens on 0.0.0.0:8080.

Endpoints:
  GET  /health  — liveness check
  POST /run     — {"prompt": "..."} → {"result": "..."}

Uses the Claude Code Agent SDK to carry out tasks. Claude Code CLI must be
installed and authenticated inside the VM (handled by rootfs_build.sh).
"""

import asyncio
import json
import os
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer

from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage

PORT = int(os.environ.get("AGENT_PORT", "8080"))
WORKSPACE = "/home/agent/workspace"

os.makedirs(WORKSPACE, exist_ok=True)

SYSTEM = """\
You are an implementation agent running inside an isolated VM.
You receive tasks from a master orchestrator and carry them out completely.

Working directory: /home/agent/workspace
Use your tools to write code, run it, check output, and fix errors.
Your final text response is returned to the master as your result.\
"""


async def run_agent(prompt: str) -> str:
    result = "(no result)"
    async for message in query(
        prompt=prompt,
        options=ClaudeAgentOptions(
            allowed_tools=["Bash", "Read", "Write", "Edit", "Glob", "Grep"],
            cwd=WORKSPACE,
            system_prompt=SYSTEM,
            permission_mode="bypassPermissions",
        ),
    ):
        if isinstance(message, ResultMessage):
            result = message.result
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok"})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/run":
            self.send_json(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self.send_json(400, {"error": "invalid JSON"})
            return

        prompt = payload.get("prompt", "").strip()
        if not prompt:
            self.send_json(400, {"error": "prompt is required"})
            return

        print(f"run: {prompt[:120]}{'...' if len(prompt) > 120 else ''}", flush=True)
        try:
            result = asyncio.run(run_agent(prompt))
            self.send_json(200, {"result": result})
        except Exception as e:
            traceback.print_exc()
            self.send_json(500, {"error": str(e)})


if __name__ == "__main__":
    print(f"Agent listening on 0.0.0.0:{PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
