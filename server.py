#!/usr/bin/env python3
"""
Agent server — runs inside the Firecracker VM as the `agent` user.
Listens on 0.0.0.0:8080.

Endpoints:
  GET  /health  — liveness check
  POST /run     — {"prompt": "..."} → {"result": "..."}

The agent uses Claude with bash and file tools to carry out tasks.
All file operations are relative to /home/agent/workspace.
"""

import json
import os
import subprocess
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer

import anthropic

PORT = int(os.environ.get("AGENT_PORT", "8080"))
WORKSPACE = "/home/agent/workspace"

os.makedirs(WORKSPACE, exist_ok=True)

SYSTEM = """\
You are an implementation agent running inside an isolated VM.
You receive tasks from a master orchestrator and carry them out completely.

Working directory: /home/agent/workspace
Available tools: bash, read_file, write_file

Use the tools to do real work — write code, run it, check output, fix errors.
Your final text response is returned to the master as your result.
Include relevant output, file contents, or a clear summary of what was accomplished.\
"""

TOOLS = [
    {
        "name": "bash",
        "description": (
            "Run a bash command. The working directory is /home/agent/workspace. "
            "Use this for running code, installing packages, git operations, etc."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "The bash command to run"},
            },
            "required": ["command"],
        },
    },
    {
        "name": "read_file",
        "description": "Read a file. Path is relative to /home/agent/workspace unless absolute.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "File path to read"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "write_file",
        "description": (
            "Write content to a file. Path is relative to /home/agent/workspace unless absolute. "
            "Creates parent directories as needed."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "File path to write"},
                "content": {"type": "string", "description": "Content to write"},
            },
            "required": ["path", "content"],
        },
    },
]


def run_bash(command: str) -> str:
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=60,
            cwd=WORKSPACE,
        )
        output = result.stdout + result.stderr
        if not output.strip():
            output = f"(exit {result.returncode})"
        return output[:8000]
    except subprocess.TimeoutExpired:
        return "Error: command timed out (60s)"
    except Exception as e:
        return f"Error: {e}"


def read_file(path: str) -> str:
    if not os.path.isabs(path):
        path = os.path.join(WORKSPACE, path)
    try:
        with open(path) as f:
            content = f.read()
        return content[:8000]
    except Exception as e:
        return f"Error: {e}"


def write_file(path: str, content: str) -> str:
    if not os.path.isabs(path):
        path = os.path.join(WORKSPACE, path)
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        return f"Wrote {len(content)} bytes to {path}"
    except Exception as e:
        return f"Error: {e}"


def dispatch(name: str, inp: dict) -> str:
    if name == "bash":
        return run_bash(inp["command"])
    elif name == "read_file":
        return read_file(inp["path"])
    elif name == "write_file":
        return write_file(inp["path"], inp["content"])
    return f"Unknown tool: {name}"


def run_agent(prompt: str) -> str:
    client = anthropic.Anthropic()
    messages = [{"role": "user", "content": prompt}]

    while True:
        response = client.messages.create(
            model="claude-opus-4-6",
            max_tokens=8192,
            thinking={"type": "adaptive"},
            system=SYSTEM,
            tools=TOOLS,
            messages=messages,
        )

        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason == "end_turn":
            return next(
                (b.text for b in response.content if b.type == "text"),
                "(no output)",
            )

        if response.stop_reason != "tool_use":
            return f"Unexpected stop reason: {response.stop_reason}"

        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                print(f"  tool: {block.name} {json.dumps(block.input)[:120]}", flush=True)
                result = dispatch(block.name, block.input)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result,
                })

        messages.append({"role": "user", "content": tool_results})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default logging

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
            result = run_agent(prompt)
            self.send_json(200, {"result": result})
        except Exception as e:
            traceback.print_exc()
            self.send_json(500, {"error": str(e)})


if __name__ == "__main__":
    print(f"Agent listening on 0.0.0.0:{PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
