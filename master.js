#!/usr/bin/env bun
/**
 * Master orchestrator — HTTP server on the host.
 *
 * Endpoints:
 *   GET  /health  — liveness check
 *   POST /run     — {"prompt": "...", "maxIterations": N} → {"result": "..."}
 */

import { query } from "@anthropic-ai/claude-agent-sdk";

const AGENT_HOST = process.env.AGENT_HOST ?? "172.16.0.2";
const AGENT_PORT = process.env.AGENT_PORT ?? "8080";
const AGENT_URL = `http://${AGENT_HOST}:${AGENT_PORT}`;

const MASTER_PORT = parseInt(process.env.MASTER_PORT ?? "3000");
const DEFAULT_MAX_ITERATIONS = parseInt(process.env.MASTER_MAX_ITERATIONS ?? "20");

function buildSystemPrompt(maxIterations) {
  return `\
You are a master orchestrator. You have a slave agent running at ${AGENT_URL}.

To send a task to the slave, use bash:
  curl -s -X POST ${AGENT_URL}/run \\
    -H 'Content-Type: application/json' \\
    -d '{"prompt": "your instruction here"}'

The slave will carry out the task using its own tools (bash, file read/write, etc.)
and return a JSON response with a "result" field.

Your job:
1. Break the overall task into steps if needed.
2. Send each step to the slave and review its output.
3. Follow up with corrections or next steps as needed.
4. When the task is fully complete, summarize what was accomplished.

IMPORTANT: You may send at most ${maxIterations} requests to the slave. \
If you reach this limit, stop and report whatever partial progress has been made.`;
}

async function runMaster(prompt, maxIterations) {
  let result = "(no result)";
  for await (const message of query({
    prompt,
    options: {
      allowedTools: ["Bash"],
      systemPrompt: buildSystemPrompt(maxIterations),
      permissionMode: "bypassPermissions",
    },
  })) {
    if (message.type === "result") {
      result = message.result;
    }
  }
  return result;
}

const server = Bun.serve({
  port: MASTER_PORT,
  async fetch(req) {
    const url = new URL(req.url);

    if (req.method === "GET" && url.pathname === "/health") {
      return Response.json({ status: "ok" });
    }

    if (req.method === "POST" && url.pathname === "/run") {
      let body;
      try {
        body = await req.json();
      } catch {
        return Response.json({ error: "Invalid JSON" }, { status: 400 });
      }
      if (!body.prompt) {
        return Response.json({ error: "Missing prompt" }, { status: 400 });
      }
      const maxIterations = body.maxIterations ?? DEFAULT_MAX_ITERATIONS;
      try {
        const result = await runMaster(body.prompt, maxIterations);
        return Response.json({ result });
      } catch (err) {
        return Response.json({ error: String(err) }, { status: 500 });
      }
    }

    return new Response("Not Found", { status: 404 });
  },
});

console.log(`[master] Listening on http://localhost:${server.port}`);
console.log(`[master] Slave: ${AGENT_URL}`);
