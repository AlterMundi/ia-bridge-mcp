#!/usr/bin/env node
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const execFileAsync = promisify(execFile);
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.resolve(__dirname, "..");
const scriptsDir = path.join(root, "marketplace", "plugins", "peer-opinion", "scripts");
const secondOpinionScript = path.join(scriptsDir, "claude-second-opinion.sh");
const iaBridgeScript = path.join(scriptsDir, "ia-bridge.sh");
const defaultSessionsDir = path.join(os.homedir(), ".claude", "ia-bridge", "sessions");
const maxSessionListLimit = 200;

const tools = [
  {
    name: "ia_bridge_run",
    description: "Run or resume full Claude↔Codex bridge protocol and persist session artifacts",
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
    description: "Run a structured single-pass second opinion with reviewer=claude|codex and save a markdown log",
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
    description: "List recent IA bridge sessions (newest first)",
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
    description: "Read a file from a session directory (path traversal blocked)",
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
  if (cwd) {
    try {
      const stat = await fs.stat(cwd);
      if (!stat.isDirectory()) {
        return { ok: false, stdout: "", stderr: `cwd is not a directory: ${cwd}`, exit_code: 2 };
      }
      execOpts.cwd = cwd;
    } catch {
      return { ok: false, stdout: "", stderr: `cwd does not exist or is not accessible: ${cwd}`, exit_code: 2 };
    }
  }

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

function normalizePath(inputPath) {
  return path.resolve(String(inputPath));
}

function parseLimit(raw, fallback = 20) {
  if (raw === undefined || raw === null) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) return fallback;
  return Math.min(value, maxSessionListLimit);
}

class CompatStdioServerTransport {
  constructor(stdin = process.stdin, stdout = process.stdout) {
    this.stdin = stdin;
    this.stdout = stdout;
    this.buffer = Buffer.alloc(0);
    this.mode = null;
    this.started = false;

    this.onmessage = undefined;
    this.onerror = undefined;
    this.onclose = undefined;

    this.handleData = (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.processBuffer();
    };
    this.handleError = (error) => {
      this.onerror?.(error);
    };
    this.handleEnd = () => {
      this.onclose?.();
    };
  }

  async start() {
    if (this.started) {
      throw new Error("CompatStdioServerTransport already started");
    }
    this.started = true;
    this.stdin.on("data", this.handleData);
    this.stdin.on("error", this.handleError);
    this.stdin.on("end", this.handleEnd);
    this.stdin.on("close", this.handleEnd);
    this.stdin.resume();
  }

  processBuffer() {
    while (true) {
      if (!this.mode) {
        this.mode = this.detectMode();
        if (!this.mode) break;
      }

      try {
        const msg = this.mode === "content-length" ? this.readContentLengthMessage() : this.readJsonLineMessage();
        if (!msg) break;
        this.onmessage?.(msg);
      } catch (error) {
        this.onerror?.(error instanceof Error ? error : new Error(String(error)));
        if (this.mode === "jsonl") {
          const nl = this.buffer.indexOf(0x0a);
          if (nl === -1) {
            this.buffer = Buffer.alloc(0);
            break;
          }
          this.buffer = this.buffer.subarray(nl + 1);
        } else {
          this.buffer = Buffer.alloc(0);
          this.mode = null;
          break;
        }
      }
    }
  }

  detectMode() {
    const preview = this.buffer.toString("utf8", 0, Math.min(this.buffer.length, 128)).replace(/^\s+/, "");
    if (!preview) return null;
    if (/^content-length:/i.test(preview)) return "content-length";
    if (preview.startsWith("{") || preview.startsWith("[")) return "jsonl";
    return null;
  }

  readJsonLineMessage() {
    const nl = this.buffer.indexOf(0x0a);
    if (nl === -1) return null;
    const line = this.buffer.toString("utf8", 0, nl).replace(/\r$/, "");
    this.buffer = this.buffer.subarray(nl + 1);
    if (!line.trim()) return null;
    return JSON.parse(line);
  }

  readContentLengthMessage() {
    let sep = this.buffer.indexOf("\r\n\r\n");
    let sepLen = 4;
    if (sep === -1) {
      sep = this.buffer.indexOf("\n\n");
      sepLen = 2;
    }
    if (sep === -1) return null;

    const headers = this.buffer.toString("utf8", 0, sep);
    const m = headers.match(/(?:^|\r?\n)content-length:\s*(\d+)/i);
    if (!m) {
      throw new Error("Missing Content-Length header");
    }

    const len = Number(m[1]);
    if (!Number.isFinite(len) || len < 0) {
      throw new Error("Invalid Content-Length header");
    }

    const bodyStart = sep + sepLen;
    if (this.buffer.length < bodyStart + len) return null;

    const body = this.buffer.toString("utf8", bodyStart, bodyStart + len);
    this.buffer = this.buffer.subarray(bodyStart + len);
    return JSON.parse(body);
  }

  async send(message) {
    const payload = JSON.stringify(message);
    const out = this.mode === "content-length"
      ? `Content-Length: ${Buffer.byteLength(payload, "utf8")}\r\n\r\n${payload}`
      : `${payload}\n`;

    return new Promise((resolve) => {
      if (this.stdout.write(out)) {
        resolve();
      } else {
        this.stdout.once("drain", resolve);
      }
    });
  }

  async close() {
    this.stdin.off("data", this.handleData);
    this.stdin.off("error", this.handleError);
    this.stdin.off("end", this.handleEnd);
    this.stdin.off("close", this.handleEnd);
    this.stdin.pause();
    this.buffer = Buffer.alloc(0);
    this.onclose?.();
  }
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
    const base = args.log_dir ? normalizePath(args.log_dir) : defaultSessionsDir;
    try {
      const items = await fs.readdir(base, { withFileTypes: true });
      const sessions = items
        .filter((d) => d.isDirectory())
        .map((d) => d.name)
        .sort((a, b) => b.localeCompare(a));
      const limit = parseLimit(args.limit, 20);
      result = { ok: true, sessions: sessions.slice(0, limit), log_dir: base };
    } catch {
      result = { ok: true, sessions: [], log_dir: base };
    }
  } else if (toolName === "ia_bridge_read_file") {
    if (!args.session_dir || !args.file_name) {
      result = { ok: false, stderr: "session_dir and file_name are required", stdout: "", exit_code: 2 };
    } else {
      const sessionDir = normalizePath(args.session_dir);
      const fileName = String(args.file_name);
      const filePath = normalizePath(path.join(sessionDir, fileName));
      const sessionPrefix = sessionDir.endsWith(path.sep) ? sessionDir : `${sessionDir}${path.sep}`;
      if (!(filePath === sessionDir || filePath.startsWith(sessionPrefix))) {
        result = {
          ok: false,
          stderr: "file_name escapes session_dir; traversal is not allowed",
          stdout: "",
          exit_code: 2
        };
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }]
        };
      }
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

const transport = new CompatStdioServerTransport();
await server.connect(transport);
setInterval(() => {}, 60_000);
