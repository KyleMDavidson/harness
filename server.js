#!/usr/bin/env node
/**
 * Slave agent server — runs inside the Firecracker VM as the `agent` user.
 * Listens on 0.0.0.0:${AGENT_PORT}.
 *
 * Endpoints:
 *   GET  /health  — liveness check
 *   POST /run     — {"prompt": "..."} → {"result": "..."}
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { createServer } from "node:http";
import { mkdirSync } from "node:fs";

const PORT = parseInt(process.env.AGENT_PORT ?? "8080");
const WORKSPACE = "/home/agent/workspace";

mkdirSync(WORKSPACE, { recursive: true });

const SYSTEM = `\
You are an implementation agent running inside an isolated VM.
You receive tasks from a master orchestrator and carry them out completely.

Working directory: /home/agent/workspace
Use your tools to write code, run it, check output, and fix errors.
Your final text response is returned to the master as your result.`;

async function runAgent(prompt) {
  let result = "(no result)";
  for await (const message of query({
    prompt,
    options: {
      allowedTools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"],
      cwd: WORKSPACE,
      systemPrompt: SYSTEM,
      permissionMode: "bypassPermissions",
    },
  })) {
    if (message.type === "result") {
      result = message.result;
    }
  }
  return result;
}

const server = createServer(async (req, res) => {
  const { pathname } = new URL(req.url, "http://localhost");
  res.setHeader("Content-Type", "application/json");

  if (req.method === "GET" && pathname === "/health") {
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  if (req.method === "POST" && pathname === "/run") {
    let body = "";
    for await (const chunk of req) body += chunk;
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      res.statusCode = 400;
      res.end(JSON.stringify({ error: "Invalid JSON" }));
      return;
    }
    if (!parsed.prompt) {
      res.statusCode = 400;
      res.end(JSON.stringify({ error: "Missing prompt" }));
      return;
    }
    try {
      const result = await runAgent(parsed.prompt);
      res.end(JSON.stringify({ result }));
    } catch (err) {
      res.statusCode = 500;
      res.end(JSON.stringify({ error: String(err) }));
    }
    return;
  }

  res.statusCode = 404;
  res.end(JSON.stringify({ error: "Not Found" }));
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[agent] Listening on 0.0.0.0:${PORT}`);
});
