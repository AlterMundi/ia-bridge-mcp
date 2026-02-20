#!/usr/bin/env node
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const execFileAsync = promisify(execFile);
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.resolve(__dirname, "..");
const scriptsDir = path.join(root, "marketplace", "plugins", "peer-opinion", "scripts");
const secondOpinionScript = path.join(scriptsDir, "claude-second-opinion.sh");
const iaBridgeScript = path.join(scriptsDir, "ia-bridge.sh");
const defaultSessionsDir = path.join(os.homedir(), ".claude", "ia-bridge", "sessions");

const tools = [
  {
    name: "ia_bridge_run",
    description: "Run full Claude↔Codex bridge protocol session",
    inputSchema: {
      type: "object",
      properties: {
        task: { type: "string" },
        resume: { type: "string", description: "Resume an interrupted session by directory path. Skips completed rounds." },
        constraints: { type: "string" },
        claude_model: { type: "string" },
        codex_model: { type: "string" },
        timeout_seconds: { type: "integer" },
        max_diff_lines: { type: "integer" },
        log_dir: { type: "string" },
        cwd: { type: "string", description: "Working directory (git auto-detected if available)" }
      },
      required: []
    }
  },
  {
    name: "single_opinion_run",
    description: "Run a structured single-pass second opinion with reviewer=claude|codex",
    inputSchema: {
      type: "object",
      properties: {
        task: { type: "string" },
        reviewer: { type: "string", enum: ["claude", "codex"] },
        constraints: { type: "string" },
        model: { type: "string" },
        timeout_seconds: { type: "integer" },
        max_diff_lines: { type: "integer" },
        log_dir: { type: "string" },
        cwd: { type: "string", description: "Working directory (git auto-detected if available)" }
      },
      required: ["task"]
    }
  },
  {
    name: "ia_bridge_list_sessions",
    description: "List recent IA bridge sessions",
    inputSchema: {
      type: "object",
      properties: {
        log_dir: { type: "string" },
        limit: { type: "integer" }
      }
    }
  },
  {
    name: "ia_bridge_read_file",
    description: "Read a file from an IA bridge session directory",
    inputSchema: {
      type: "object",
      properties: {
        session_dir: { type: "string" },
        file_name: { type: "string" }
      },
      required: ["session_dir", "file_name"]
    }
  }
];

function argsToFlags(args) {
  const cmd = [];
  for (const [key, value] of Object.entries(args ?? {})) {
    if (value === null || value === undefined || value === "") continue;
    const flag = `--${key.replaceAll("_", "-")}`;
    if (typeof value === "boolean") {
      if (value) cmd.push(flag);
      continue;
    }
    cmd.push(flag, String(value));
  }
  return cmd;
}

async function runScript(scriptPath, args, cwd) {
  const cmdArgs = argsToFlags(args);
  try {
    await fs.access(scriptPath);
  } catch {
    return { ok: false, stdout: "", stderr: `Script not found: ${scriptPath}`, exit_code: 127 };
  }

  // Strip CLAUDECODE env var to allow spawning claude/codex from within a Claude Code session
  const cleanEnv = { ...process.env };
  delete cleanEnv.CLAUDECODE;

  const execOpts = { encoding: "utf8", env: cleanEnv };
  if (cwd) execOpts.cwd = cwd;

  try {
    const { stdout, stderr } = await execFileAsync(scriptPath, cmdArgs, execOpts);
    return {
      ok: true,
      stdout: truncateText(stdout ?? ""),
      stderr: truncateText(stderr ?? ""),
      exit_code: 0,
      command: [scriptPath, ...cmdArgs].join(" ")
    };
  } catch (error) {
    return {
      ok: false,
      stdout: truncateText(error.stdout ?? ""),
      stderr: truncateText(error.stderr ?? error.message ?? "Unknown error"),
      exit_code: typeof error.code === "number" ? error.code : 1,
      command: [scriptPath, ...cmdArgs].join(" ")
    };
  }
}

function truncateText(text) {
  const maxChars = 8000;
  if (!text || text.length <= maxChars) return text;
  const remaining = text.length - maxChars;
  return `${text.slice(0, maxChars)}\n...[truncated ${remaining} chars]`;
}

const server = new Server(
  { name: "ia-bridge-mcp", version: "2.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const toolName = request.params.name;
  const args = request.params.arguments ?? {};

  // Extract cwd before passing remaining args as CLI flags
  const cwd = args.cwd ? String(args.cwd) : undefined;
  const scriptArgs = { ...args };
  delete scriptArgs.cwd;

  let result;
  if (toolName === "ia_bridge_run") {
    result = await runScript(iaBridgeScript, scriptArgs, cwd);
  } else if (toolName === "single_opinion_run") {
    result = await runScript(secondOpinionScript, scriptArgs, cwd);
  } else if (toolName === "ia_bridge_list_sessions") {
    const base = args.log_dir ? String(args.log_dir) : defaultSessionsDir;
    try {
      const items = await fs.readdir(base, { withFileTypes: true });
      const sessions = items
        .filter((d) => d.isDirectory())
        .map((d) => d.name)
        .sort((a, b) => b.localeCompare(a));
      const limit = Number.isInteger(args.limit) ? Number(args.limit) : 20;
      result = { ok: true, sessions: sessions.slice(0, limit), log_dir: base };
    } catch {
      result = { ok: true, sessions: [], log_dir: base };
    }
  } else if (toolName === "ia_bridge_read_file") {
    if (!args.session_dir || !args.file_name) {
      result = { ok: false, stderr: "session_dir and file_name are required", stdout: "", exit_code: 2 };
    } else {
      const filePath = path.join(String(args.session_dir), String(args.file_name));
      try {
        const content = await fs.readFile(filePath, "utf8");
        result = { ok: true, content: truncateText(content), path: filePath };
      } catch (error) {
        result = { ok: false, stderr: error.message ?? String(error), stdout: "", exit_code: 1 };
      }
    }
  } else {
    result = { ok: false, stderr: `Unknown tool: ${toolName}`, stdout: "", exit_code: 2 };
  }

  return {
    content: [{ type: "text", text: JSON.stringify(result, null, 2) }]
  };
});

const transport = new StdioServerTransport();
await server.connect(transport);
setInterval(() => {}, 60_000);
