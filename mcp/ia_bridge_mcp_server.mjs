#!/usr/bin/env node
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import path from "node:path";
import os from "node:os";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { CallToolRequestSchema, ListToolsRequestSchema, ListResourcesRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const execFileAsync = promisify(execFile);
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.resolve(__dirname, "..");
const scriptsDir = path.join(root, "marketplace", "plugins", "peer-opinion", "scripts");
const secondOpinionScript = path.join(scriptsDir, "second-opinion.sh");
const forumScript = path.join(scriptsDir, "forum.sh");
const bridgeAiDir = path.join(os.homedir(), ".bridge-ai");
const defaultSessionsDir = path.join(bridgeAiDir, "sessions");
const defaultOpinionsDir = path.join(bridgeAiDir, "opinions");
const defaultJobsDir = path.join(bridgeAiDir, "jobs");
const configPath = path.join(bridgeAiDir, "config.json");
const maxSessionListLimit = 200;
const maxTextChars = 8000;
const maxJobExcerptChars = 16000;
const jobs = new Map();

let bridgeConfig = null;
let enabledAgentIds = ["claude", "codex"];
let defaultReviewer = "claude";
let defaultAgentA = "claude";
let defaultAgentB = "codex";
let defaultSynthesizer = "codex";
let registeredClients = ["claude", "codex"];

const bridgeV2Defaults = {
  version: 2,
  agents: {
    claude: { enabled: true, name: "Claude Code", default_model: "opus", supports_mcp_registration: true },
    codex: { enabled: true, name: "Codex", default_model: "o3", supports_mcp_registration: true },
    hermes: { enabled: true, name: "Hermes Agent", default_model: "anthropic/claude-sonnet-4", supports_mcp_registration: false }
  },
  forum: { agent_a: "claude", agent_b: "codex", synthesizer: "codex" },
  mcp: { registered_clients: ["claude", "codex"] },
  runtime: { timeout_seconds: 300 }
};

async function loadConfig() {
  let raw = null;
  try {
    const content = await fs.readFile(configPath, "utf8");
    raw = JSON.parse(content);
  } catch {
    raw = null;
  }

  let config;
  if (raw && (raw.version ?? 0) < 2) {
    config = deepMerge(raw, bridgeV2Defaults);
  } else if (raw) {
    config = deepMerge(raw, bridgeV2Defaults);
  } else {
    config = JSON.parse(JSON.stringify(bridgeV2Defaults));
  }

  bridgeConfig = config;
  enabledAgentIds = Object.entries(config.agents || {})
    .filter(([, v]) => v.enabled)
    .map(([k]) => k);
  defaultReviewer = enabledAgentIds[0] || "claude";
  defaultAgentA = config.forum?.agent_a || "claude";
  defaultAgentB = config.forum?.agent_b || "codex";
  defaultSynthesizer = config.forum?.synthesizer || "codex";
  registeredClients = config.mcp?.registered_clients || ["claude", "codex"];
}

function deepMerge(user, defaults) {
  if (user == null) return JSON.parse(JSON.stringify(defaults));
  if (Array.isArray(user)) return user;
  if (typeof user !== "object" || typeof defaults !== "object") return user;
  const result = {};
  for (const key of new Set([...Object.keys(defaults), ...Object.keys(user)])) {
    if (key in user) {
      result[key] = deepMerge(user[key], defaults[key]);
    } else {
      result[key] = JSON.parse(JSON.stringify(defaults[key]));
    }
  }
  return result;
}

function buildTools() {
  const reviewerEnum = enabledAgentIds.length > 0 ? enabledAgentIds : ["claude", "codex"];
  return [
    {
      name: "ia_bridge_run",
      description: "Run or resume full multi-agent bridge protocol and persist session artifacts",
      inputSchema: {
        type: "object",
        properties: {
          task: { type: "string" },
          resume: { type: "string", description: "Resume an interrupted session by directory path. Skips completed rounds." },
          constraints: { type: "string" },
          agent_a: { type: "string", enum: reviewerEnum, description: "First agent (default: from config)." },
          agent_b: { type: "string", enum: reviewerEnum, description: "Second agent (default: from config)." },
          synthesizer: { type: "string", enum: reviewerEnum, description: "Synthesis agent (default: from config)." },
          model_overrides: {
            type: "object",
            additionalProperties: { type: "string" },
            description: "Map of agent-id to model override, e.g. {claude: \"opus\", codex: \"o3\"}."
          },
          timeout_seconds: { type: "integer" },
          max_diff_lines: { type: "integer" },
          log_dir: { type: "string" },
          cwd: { type: "string", description: "Working directory (git auto-detected if available)" },
          mode: { type: "string", enum: ["async"], description: "Execution mode. ia_bridge_run only supports async." }
        },
        required: []
      }
    },
    {
      name: "single_opinion_run",
      description: "Run a structured single-pass second opinion with reviewer=<agent-id> and save a markdown log",
      inputSchema: {
        type: "object",
        properties: {
          task: { type: "string" },
          reviewer: { type: "string", enum: reviewerEnum, description: `Reviewer agent id (default: ${defaultReviewer}).` },
          constraints: { type: "string" },
          model: { type: "string", description: "Override model for the selected reviewer." },
          model_overrides: {
            type: "object",
            additionalProperties: { type: "string" },
            description: "Map of agent-id to model override."
          },
          timeout_seconds: { type: "integer" },
          max_diff_lines: { type: "integer" },
          log_dir: { type: "string" },
          cwd: { type: "string", description: "Working directory (git auto-detected if available)" },
          mode: { type: "string", enum: ["sync", "async"], description: "Execution mode (default: async)." }
        },
        required: ["task"]
      }
    },
    {
      name: "ia_bridge_job_status",
      description: "Get execution status for a bridge/opinion job",
      inputSchema: {
        type: "object",
        properties: {
          job_id: { type: "string" }
        },
        required: ["job_id"]
      }
    },
    {
      name: "ia_bridge_job_result",
      description: "Get final result details for a bridge/opinion job, including output path/content when available",
      inputSchema: {
        type: "object",
        properties: {
          job_id: { type: "string" },
          include_content: { type: "boolean", description: "Include truncated output file content (default: true)." }
        },
        required: ["job_id"]
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
}

function argsToFlags(args) {
  const cmd = [];
  for (const [key, value] of Object.entries(args ?? {})) {
    if (value === null || value === undefined || value === "") continue;
    const flag = `--${key.replaceAll("_", "-")}`;

    if (key === "model_overrides" && typeof value === "object" && !Array.isArray(value)) {
      for (const [agentId, model] of Object.entries(value)) {
        if (model !== null && model !== undefined && model !== "") {
          cmd.push("--model-override", `${agentId}:${model}`);
        }
      }
      continue;
    }

    if (key === "model_override") {
      const list = Array.isArray(value) ? value : [value];
      for (const item of list) {
        if (item !== null && item !== undefined && item !== "") {
          cmd.push("--model-override", String(item));
        }
      }
      continue;
    }

    if (typeof value === "boolean") {
      if (value) cmd.push(flag);
      continue;
    }
    cmd.push(flag, String(value));
  }
  return cmd;
}

function truncateText(text, maxChars = maxTextChars) {
  if (!text || text.length <= maxChars) return text;
  const remaining = text.length - maxChars;
  return `${text.slice(0, maxChars)}\n...[truncated ${remaining} chars]`;
}

function clipTail(text, maxChars = maxJobExcerptChars) {
  if (!text) return "";
  return text.length <= maxChars ? text : text.slice(-maxChars);
}

function normalizePath(inputPath) {
  return path.resolve(String(inputPath));
}

function normalizePossiblyRelativePath(rawPath, baseDir) {
  if (!rawPath) return null;
  const cleaned = String(rawPath).trim();
  if (!cleaned) return null;
  if (path.isAbsolute(cleaned)) return normalizePath(cleaned);
  return normalizePath(path.join(baseDir ?? process.cwd(), cleaned));
}

function nowIso() {
  return new Date().toISOString();
}

function parseLimit(raw, fallback = 20) {
  if (raw === undefined || raw === null) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) return fallback;
  return Math.min(value, maxSessionListLimit);
}

function parseMode(raw, fallback, allowed) {
  if (raw === undefined || raw === null || raw === "") return fallback;
  const mode = String(raw);
  return allowed.includes(mode) ? mode : null;
}

function makeJobId(prefix) {
  return `${prefix}-${Date.now()}-${randomUUID().slice(0, 8)}`;
}

function jobFilePath(jobId) {
  return path.join(defaultJobsDir, `${jobId}.json`);
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function writeJobFile(job) {
  await fs.mkdir(defaultJobsDir, { recursive: true });
  const filePath = jobFilePath(job.job_id);
  const tmpPath = `${filePath}.tmp`;
  await fs.writeFile(tmpPath, JSON.stringify(job, null, 2), "utf8");
  await fs.rename(tmpPath, filePath);
}

async function upsertJob(job) {
  const merged = {
    ...job,
    updated_at: nowIso()
  };
  jobs.set(merged.job_id, merged);
  await writeJobFile(merged);
  return merged;
}

async function getJob(jobId) {
  if (jobs.has(jobId)) return jobs.get(jobId);
  try {
    const raw = await fs.readFile(jobFilePath(jobId), "utf8");
    const parsed = JSON.parse(raw);
    jobs.set(jobId, parsed);
    return parsed;
  } catch {
    return null;
  }
}

async function loadPersistedJobs() {
  try {
    await fs.mkdir(defaultJobsDir, { recursive: true });
    const entries = await fs.readdir(defaultJobsDir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
      const filePath = path.join(defaultJobsDir, entry.name);
      try {
        const raw = await fs.readFile(filePath, "utf8");
        const parsed = JSON.parse(raw);
        if (parsed?.job_id) jobs.set(parsed.job_id, parsed);
      } catch {
        // ignore malformed records
      }
    }
  } catch {
    // ignore startup load errors
  }
}

function parseSingleOpinionOutput(stdout, baseDir) {
  const outputMatch = stdout.match(/^Second opinion saved to:\s*(.+)$/m);
  const outputPath = normalizePossiblyRelativePath(outputMatch?.[1], baseDir);
  return {
    output_path: outputPath,
    result_path: outputPath,
    session_dir: outputPath ? path.dirname(outputPath) : null
  };
}

function parseBridgeOutput(stdout, baseDir) {
  const sessionMatch = stdout.match(/^IA bridge session completed:\s*(.+)$/m);
  const openMatch = stdout.match(/^Open:\s*(.+)$/m);

  const sessionDir = normalizePossiblyRelativePath(sessionMatch?.[1], baseDir);
  const synthesisPath = normalizePossiblyRelativePath(openMatch?.[1], baseDir);

  return {
    session_dir: sessionDir,
    result_path: synthesisPath,
    output_path: synthesisPath
  };
}

async function validateScriptAndCwd(scriptPath, cwd) {
  try {
    await fs.access(scriptPath, fsSync.constants.X_OK);
  } catch {
    return { ok: false, stderr: `Script not found or not executable: ${scriptPath}`, exit_code: 127 };
  }

  if (!cwd) return { ok: true };

  try {
    const stat = await fs.stat(cwd);
    if (!stat.isDirectory()) {
      return { ok: false, stderr: `cwd is not a directory: ${cwd}`, exit_code: 2 };
    }
  } catch {
    return { ok: false, stderr: `cwd does not exist or is not accessible: ${cwd}`, exit_code: 2 };
  }

  return { ok: true };
}

async function runScript(scriptPath, args, cwd) {
  const cmdArgs = argsToFlags(args);
  const scriptCheck = await validateScriptAndCwd(scriptPath, cwd);
  if (!scriptCheck.ok) {
    return {
      ok: false,
      stdout: "",
      stderr: scriptCheck.stderr,
      exit_code: scriptCheck.exit_code,
      command: [scriptPath, ...cmdArgs].join(" ")
    };
  }

  const cleanEnv = { ...process.env };
  delete cleanEnv.CLAUDECODE;

  const execOpts = { encoding: "utf8", env: cleanEnv, maxBuffer: 10 * 1024 * 1024 };
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

async function runScriptSyncJob(job, scriptPath, args, cwd) {
  const running = await upsertJob({
    ...job,
    status: "running",
    started_at: nowIso()
  });

  const execResult = await runScript(scriptPath, args, cwd);

  const finished = {
    ...running,
    status: execResult.ok ? "succeeded" : "failed",
    finished_at: nowIso(),
    exit_code: execResult.exit_code,
    command: execResult.command,
    stdout_excerpt: execResult.stdout ?? "",
    stderr_excerpt: execResult.stderr ?? ""
  };

  if (execResult.ok) {
    const parsed = job.tool_name === "single_opinion_run"
      ? parseSingleOpinionOutput(execResult.stdout ?? "", cwd ?? process.cwd())
      : parseBridgeOutput(execResult.stdout ?? "", cwd ?? process.cwd());

    finished.output_path = parsed.output_path;
    finished.result_path = parsed.result_path;
    finished.session_dir = parsed.session_dir;
  }

  const saved = await upsertJob(finished);

  return {
    ...execResult,
    job_id: saved.job_id,
    mode: saved.mode,
    status: saved.status,
    output_path: saved.output_path ?? null,
    result_path: saved.result_path ?? null,
    session_dir: saved.session_dir ?? null,
    message: saved.status === "succeeded"
      ? "Completed synchronously."
      : "Synchronous execution failed."
  };
}

async function runScriptBackgroundJob(job, scriptPath, args, cwd) {
  const cmdArgs = argsToFlags(args);
  const scriptCheck = await validateScriptAndCwd(scriptPath, cwd);
  if (!scriptCheck.ok) {
    const failed = await upsertJob({
      ...job,
      status: "failed",
      started_at: nowIso(),
      finished_at: nowIso(),
      exit_code: scriptCheck.exit_code,
      stderr_excerpt: scriptCheck.stderr,
      error: scriptCheck.stderr,
      command: [scriptPath, ...cmdArgs].join(" ")
    });

    return {
      ok: false,
      job_id: failed.job_id,
      mode: failed.mode,
      status: failed.status,
      stderr: scriptCheck.stderr,
      exit_code: failed.exit_code
    };
  }

  await fs.mkdir(defaultJobsDir, { recursive: true });

  const stdoutLog = path.join(defaultJobsDir, `${job.job_id}.stdout.log`);
  const stderrLog = path.join(defaultJobsDir, `${job.job_id}.stderr.log`);

  const cleanEnv = { ...process.env };
  delete cleanEnv.CLAUDECODE;

  const spawnOpts = {
    env: cleanEnv,
    stdio: ["ignore", "pipe", "pipe"]
  };
  if (cwd) spawnOpts.cwd = cwd;

  const initial = await upsertJob({
    ...job,
    status: "running",
    started_at: nowIso(),
    stdout_log: stdoutLog,
    stderr_log: stderrLog,
    command: [scriptPath, ...cmdArgs].join(" ")
  });

  return await new Promise((resolve) => {
    let resolved = false;
    let stdoutExcerpt = "";
    let stderrExcerpt = "";

    const stdoutStream = fsSync.createWriteStream(stdoutLog, { flags: "a" });
    const stderrStream = fsSync.createWriteStream(stderrLog, { flags: "a" });

    const child = spawn(scriptPath, cmdArgs, spawnOpts);

    const safeResolve = (payload) => {
      if (!resolved) {
        resolved = true;
        resolve(payload);
      }
    };

    const closeStreams = () => {
      stdoutStream.end();
      stderrStream.end();
    };

    if (child.stdout) {
      child.stdout.on("data", (chunk) => {
        stdoutStream.write(chunk);
        stdoutExcerpt = clipTail(stdoutExcerpt + chunk.toString("utf8"));
      });
    }

    if (child.stderr) {
      child.stderr.on("data", (chunk) => {
        stderrStream.write(chunk);
        stderrExcerpt = clipTail(stderrExcerpt + chunk.toString("utf8"));
      });
    }

    child.once("error", (error) => {
      void (async () => {
        closeStreams();
        const message = error?.message ?? String(error);
        const failed = await upsertJob({
          ...initial,
          status: "failed",
          finished_at: nowIso(),
          exit_code: 1,
          error: message,
          stdout_excerpt: truncateText(stdoutExcerpt, maxJobExcerptChars),
          stderr_excerpt: truncateText(clipTail(`${stderrExcerpt}\n${message}`), maxJobExcerptChars)
        });

        safeResolve({
          ok: false,
          job_id: failed.job_id,
          mode: failed.mode,
          status: failed.status,
          stderr: failed.stderr_excerpt,
          exit_code: failed.exit_code
        });
      })().catch(() => {
        safeResolve({ ok: false, job_id: initial.job_id, mode: initial.mode, status: "failed", stderr: "Spawn failed", exit_code: 1 });
      });
    });

    child.once("spawn", () => {
      void (async () => {
        const running = await upsertJob({
          ...initial,
          pid: child.pid
        });

        safeResolve({
          ok: true,
          background: true,
          job_id: running.job_id,
          mode: running.mode,
          status: running.status,
          pid: running.pid,
          log_dir: running.log_dir,
          message: `Job ${running.job_id} started in background (pid ${running.pid}). Poll ia_bridge_job_status and ia_bridge_job_result.`
        });
      })().catch(() => {
        safeResolve({ ok: true, background: true, job_id: initial.job_id, mode: initial.mode, status: "running", pid: child.pid, log_dir: initial.log_dir });
      });
    });

    child.once("close", (exitCode, signal) => {
      void (async () => {
        closeStreams();

        const latest = (await getJob(initial.job_id)) ?? initial;
        const completed = {
          ...latest,
          status: exitCode === 0 ? "succeeded" : "failed",
          finished_at: nowIso(),
          exit_code: typeof exitCode === "number" ? exitCode : 1,
          signal: signal ?? null,
          stdout_excerpt: truncateText(stdoutExcerpt, maxJobExcerptChars),
          stderr_excerpt: truncateText(stderrExcerpt, maxJobExcerptChars)
        };

        if (completed.status === "succeeded") {
          const parsed = completed.tool_name === "single_opinion_run"
            ? parseSingleOpinionOutput(stdoutExcerpt, cwd ?? process.cwd())
            : parseBridgeOutput(stdoutExcerpt, cwd ?? process.cwd());
          completed.output_path = parsed.output_path;
          completed.result_path = parsed.result_path;
          completed.session_dir = parsed.session_dir;
        }

        await upsertJob(completed);
      })().catch(() => {
        // best effort background accounting
      });
    });

    child.unref();
  });
}

async function refreshJobHealth(job) {
  if (!job || job.status !== "running") return job;
  if (!job.pid || isPidAlive(job.pid)) return job;

  const refreshed = await upsertJob({
    ...job,
    status: "failed",
    finished_at: nowIso(),
    error: job.error ?? "Background process is no longer alive.",
    stderr_excerpt: job.stderr_excerpt ?? "Background process is no longer alive."
  });
  return refreshed;
}

async function buildJobResult(job, includeContent = true) {
  let resolvedPath = job.result_path ?? job.output_path ?? null;

  if (!resolvedPath && job.tool_name === "ia_bridge_run" && job.session_dir) {
    const fallback = path.join(job.session_dir, "50-final-synthesis.md");
    if (await fileExists(fallback)) resolvedPath = fallback;
  }

  let outputContent = null;
  if (includeContent && resolvedPath && await fileExists(resolvedPath)) {
    try {
      outputContent = truncateText(await fs.readFile(resolvedPath, "utf8"), maxJobExcerptChars);
    } catch {
      outputContent = null;
    }
  }

  return {
    ok: true,
    ready: job.status === "succeeded" || job.status === "failed",
    job_id: job.job_id,
    tool_name: job.tool_name,
    mode: job.mode,
    status: job.status,
    pid: job.pid ?? null,
    exit_code: job.exit_code ?? null,
    signal: job.signal ?? null,
    error: job.error ?? null,
    created_at: job.created_at ?? null,
    started_at: job.started_at ?? null,
    finished_at: job.finished_at ?? null,
    cwd: job.cwd ?? null,
    log_dir: job.log_dir ?? null,
    session_dir: job.session_dir ?? null,
    output_path: job.output_path ?? null,
    result_path: resolvedPath,
    stdout_log: job.stdout_log ?? null,
    stderr_log: job.stderr_log ?? null,
    stdout_excerpt: job.stdout_excerpt ?? null,
    stderr_excerpt: job.stderr_excerpt ?? null,
    output_content: outputContent
  };
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

await loadConfig();
await loadPersistedJobs();

const tools = buildTools();

const server = new Server(
  { name: "ia-bridge-mcp", version: "2.3.0" },
  { capabilities: { tools: {}, resources: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));
server.setRequestHandler(ListResourcesRequestSchema, async () => ({ resources: [] }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const toolName = request.params.name;
  const args = request.params.arguments ?? {};

  const cwd = args.cwd ? String(args.cwd) : undefined;
  const scriptArgs = { ...args };
  delete scriptArgs.cwd;

  let result;

  if (toolName === "ia_bridge_run") {
    const mode = parseMode(args.mode, "async", ["async"]);
    if (!mode) {
      result = { ok: false, stderr: "ia_bridge_run only supports mode=async", exit_code: 2 };
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    }

    delete scriptArgs.mode;

    const logDir = args.log_dir ? normalizePath(String(args.log_dir)) : defaultSessionsDir;
    scriptArgs.log_dir = logDir;

    const job = {
      job_id: makeJobId("bridge"),
      tool_name: "ia_bridge_run",
      mode,
      status: "queued",
      created_at: nowIso(),
      cwd: cwd ?? null,
      log_dir: logDir,
      args: scriptArgs
    };

    await upsertJob(job);
    result = await runScriptBackgroundJob(job, forumScript, scriptArgs, cwd);
  } else if (toolName === "single_opinion_run") {
    const mode = parseMode(args.mode, "async", ["sync", "async"]);
    if (!mode) {
      result = { ok: false, stderr: "single_opinion_run mode must be sync or async", exit_code: 2 };
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    }

    delete scriptArgs.mode;

    const logDir = args.log_dir ? normalizePath(String(args.log_dir)) : defaultOpinionsDir;
    scriptArgs.log_dir = logDir;

    // Backwards compatibility: translate old reviewer string to current default
    if (!scriptArgs.reviewer && scriptArgs.reviewer !== "") {
      scriptArgs.reviewer = defaultReviewer;
    }

    const job = {
      job_id: makeJobId("opinion"),
      tool_name: "single_opinion_run",
      mode,
      status: "queued",
      created_at: nowIso(),
      cwd: cwd ?? null,
      log_dir: logDir,
      args: scriptArgs
    };

    await upsertJob(job);

    if (mode === "sync") {
      result = await runScriptSyncJob(job, secondOpinionScript, scriptArgs, cwd);
    } else {
      result = await runScriptBackgroundJob(job, secondOpinionScript, scriptArgs, cwd);
    }
  } else if (toolName === "ia_bridge_job_status") {
    if (!args.job_id) {
      result = { ok: false, stderr: "job_id is required", exit_code: 2 };
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    }

    const job = await getJob(String(args.job_id));
    if (!job) {
      result = { ok: false, stderr: `job not found: ${args.job_id}`, exit_code: 1 };
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    }

    const refreshed = await refreshJobHealth(job);
    result = {
      ok: true,
      job_id: refreshed.job_id,
      tool_name: refreshed.tool_name,
      mode: refreshed.mode,
      status: refreshed.status,
      pid: refreshed.pid ?? null,
      exit_code: refreshed.exit_code ?? null,
      signal: refreshed.signal ?? null,
      error: refreshed.error ?? null,
      created_at: refreshed.created_at ?? null,
      started_at: refreshed.started_at ?? null,
      finished_at: refreshed.finished_at ?? null,
      log_dir: refreshed.log_dir ?? null,
      session_dir: refreshed.session_dir ?? null,
      result_path: refreshed.result_path ?? refreshed.output_path ?? null
    };
  } else if (toolName === "ia_bridge_job_result") {
    if (!args.job_id) {
      result = { ok: false, stderr: "job_id is required", exit_code: 2 };
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    }

    const includeContent = args.include_content !== false;
    const job = await getJob(String(args.job_id));
    if (!job) {
      result = { ok: false, stderr: `job not found: ${args.job_id}`, exit_code: 1 };
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    }

    const refreshed = await refreshJobHealth(job);
    result = await buildJobResult(refreshed, includeContent);
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
setInterval(() => { }, 60_000);
