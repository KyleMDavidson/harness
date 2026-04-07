#!/usr/bin/env python3
"""
Master process — orchestrates the agent loop.

Usage:
    python master.py "Build a Python web scraper that..."
    echo "Your task here" | python master.py

Environment variables (all optional, default to config.env values):
    AGENT_HOST      IP of the agent VM   (default: 172.16.0.2)
    AGENT_PORT      Port of the agent    (default: 8080)
    MAX_ITERATIONS  Loop limit           (default: 10)

The master:
1. Waits for the agent to be ready
2. Sends the initial task to the agent via HTTP POST /run
3. Reviews the agent's output with Claude
4. Either accepts the result or sends a follow-up prompt
5. Repeats until done or MAX_ITERATIONS is reached
"""

import json
import os
import sys
import time

import anthropic
import requests

AGENT_HOST = os.environ.get("AGENT_HOST", "172.16.0.2")
AGENT_PORT = os.environ.get("AGENT_PORT", "8080")
AGENT_URL = f"http://{AGENT_HOST}:{AGENT_PORT}"
MAX_ITERATIONS = int(os.environ.get("MAX_ITERATIONS", "10"))

MASTER_SYSTEM = """\
You are a master orchestrator reviewing an agent's work on a task.

Your job:
1. Evaluate whether the agent has fully and correctly completed the instructions.
2. If complete, respond ONLY with valid JSON:
   {"done": true, "result": "<concise summary or final answer>"}
3. If not complete, respond ONLY with valid JSON:
   {"done": false, "next_prompt": "<clear, specific instruction for what the agent should do next>"}

Rules:
- Respond with raw JSON only — no markdown, no explanation outside the JSON.
- Only mark done:true when the task is genuinely and fully complete.
- next_prompt should be actionable and specific, building on what the agent already did.\
"""


def wait_for_agent(timeout: int = 60) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = requests.get(f"{AGENT_URL}/health", timeout=5)
            if r.ok:
                return True
        except requests.exceptions.ConnectionError:
            pass
        time.sleep(2)
    return False


def call_agent(prompt: str) -> str:
    response = requests.post(
        f"{AGENT_URL}/run",
        json={"prompt": prompt},
        timeout=300,
    )
    response.raise_for_status()
    return response.json().get("result", "")


def review(client: anthropic.Anthropic, instructions: str, history: list[dict]) -> tuple[bool, str]:
    history_text = "\n\n".join(
        f"--- Iteration {i + 1} ---\nPrompt sent to agent:\n{h['prompt']}\n\nAgent output:\n{h['output']}"
        for i, h in enumerate(history)
    )

    user_message = (
        f"Task instructions:\n{instructions}\n\n"
        f"Agent work so far:\n{history_text}\n\n"
        "Is the task complete? Respond with JSON only."
    )

    with client.messages.stream(
        model="claude-opus-4-6",
        max_tokens=4096,
        thinking={"type": "adaptive"},
        system=MASTER_SYSTEM,
        messages=[{"role": "user", "content": user_message}],
    ) as stream:
        response = stream.get_final_message()

    raw = next((b.text for b in response.content if b.type == "text"), "").strip()

    # Strip markdown fences if Claude wrapped the JSON
    if raw.startswith("```"):
        raw = raw.split("```")[1]
        if raw.startswith("json"):
            raw = raw[4:]
        raw = raw.strip()

    decision = json.loads(raw)
    done = bool(decision.get("done", False))
    payload = decision.get("result") if done else decision.get("next_prompt", "")
    return done, payload


def main() -> None:
    if len(sys.argv) > 1:
        instructions = " ".join(sys.argv[1:])
    elif not sys.stdin.isatty():
        instructions = sys.stdin.read().strip()
    else:
        print("Usage: python master.py \"<task instructions>\"", file=sys.stderr)
        sys.exit(1)

    if not instructions:
        print("No instructions provided.", file=sys.stderr)
        sys.exit(1)

    print(f"Task: {instructions}\n", flush=True)
    print("Waiting for agent...", flush=True)

    if not wait_for_agent():
        print("Agent did not become available.", file=sys.stderr)
        sys.exit(1)

    print("Agent ready.\n", flush=True)

    client = anthropic.Anthropic()
    history: list[dict] = []
    current_prompt = instructions

    for iteration in range(1, MAX_ITERATIONS + 1):
        print(f"=== Iteration {iteration}/{MAX_ITERATIONS} ===", flush=True)
        preview = current_prompt[:200] + ("..." if len(current_prompt) > 200 else "")
        print(f"→ Agent: {preview}\n", flush=True)

        output = call_agent(current_prompt)
        print(f"← Agent:\n{output}\n", flush=True)

        history.append({"prompt": current_prompt, "output": output})

        print("Reviewing...", flush=True)
        done, next_step = review(client, instructions, history)

        if done:
            print("\n=== DONE ===")
            print(next_step)
            return

        if iteration == MAX_ITERATIONS:
            print(f"\nMax iterations ({MAX_ITERATIONS}) reached.", file=sys.stderr)
            sys.exit(1)

        current_prompt = next_step
        preview = current_prompt[:200] + ("..." if len(current_prompt) > 200 else "")
        print(f"Not done. Next: {preview}\n", flush=True)


if __name__ == "__main__":
    main()
