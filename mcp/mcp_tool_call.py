#!/usr/bin/env python3
import argparse
import json
import select
import subprocess
import sys
from typing import Dict, List


def parse_tool_args(tokens: List[str]) -> Dict[str, object]:
    args: Dict[str, object] = {}
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if not token.startswith("--"):
            i += 1
            continue
        key = token[2:].replace("-", "_")
        if i + 1 >= len(tokens) or tokens[i + 1].startswith("--"):
            args[key] = True
            i += 1
            continue
        value = tokens[i + 1]
        args[key] = int(value) if value.isdigit() else value
        i += 2
    return args


def send_jsonl(proc: subprocess.Popen, payload: Dict[str, object]) -> None:
    assert proc.stdin
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()


def read_jsonl(proc: subprocess.Popen, timeout_seconds: int = 60) -> Dict[str, object]:
    assert proc.stdout and proc.stderr
    ready, _, _ = select.select([proc.stdout, proc.stderr], [], [], timeout_seconds)
    if not ready:
        raise TimeoutError("Timed out waiting for MCP server response")
    if proc.stderr in ready:
        err_line = proc.stderr.readline().strip()
        if err_line:
            raise RuntimeError(err_line)
    line = proc.stdout.readline()
    if not line:
        raise EOFError("MCP server closed stdout")
    return json.loads(line)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", default="node")
    parser.add_argument("--server", required=True)
    parser.add_argument("--tool", required=True)
    parser.add_argument("tool_args", nargs=argparse.REMAINDER)
    ns = parser.parse_args()

    tokens = ns.tool_args
    if tokens and tokens[0] == "--":
        tokens = tokens[1:]
    arguments = parse_tool_args(tokens)

    proc = subprocess.Popen(
        [ns.node, ns.server],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    try:
        send_jsonl(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "ia-bridge-cli", "version": "2.0.0"},
                },
            },
        )
        init_resp = read_jsonl(proc)
        if "error" in init_resp:
            print(init_resp["error"], file=sys.stderr)
            return 1

        send_jsonl(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send_jsonl(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": ns.tool, "arguments": arguments},
            },
        )
        resp = read_jsonl(proc)
        if "error" in resp:
            print(resp["error"], file=sys.stderr)
            return 1

        result = resp.get("result", {})
        content = result.get("content", [])
        if content:
            text = content[0].get("text", "")
            if text:
                print(text)

        send_jsonl(proc, {"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}})
    finally:
        if proc.stdin and not proc.stdin.closed:
            proc.stdin.close()
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except Exception:
            proc.kill()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
