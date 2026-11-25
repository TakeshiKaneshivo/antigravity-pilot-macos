#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MCP_BIN = ROOT / "build" / "antigravity-pilot-mcp"
HTML_PATH = ROOT / "src" / "McpAppWeb" / "dist" / "dashboard.html"


def send_rpc(proc: subprocess.Popen, req: dict) -> dict:
    line = json.dumps(req, separators=(",", ":")) + "\n"
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(line.encode("utf-8"))
    proc.stdin.flush()
    resp_line = proc.stdout.readline()
    if not resp_line:
        stderr_out = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
        raise RuntimeError(f"MCP server closed stdout unexpectedly. stderr={stderr_out}")
    return json.loads(resp_line.decode("utf-8"))


def send_notification(proc: subprocess.Popen, notif: dict) -> None:
    line = json.dumps(notif, separators=(",", ":")) + "\n"
    assert proc.stdin is not None
    proc.stdin.write(line.encode("utf-8"))
    proc.stdin.flush()


def main() -> int:
    if not MCP_BIN.exists():
        print(f"[FAIL] Missing binary: {MCP_BIN}", file=sys.stderr)
        return 1
    if not HTML_PATH.exists():
        print(f"[FAIL] Missing HTML: {HTML_PATH}", file=sys.stderr)
        return 1

    proc = subprocess.Popen(
        [str(MCP_BIN), "--html", str(HTML_PATH), "--version", "0.1.0"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    try:
        # 1. initialize
        init_resp = send_rpc(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1.0"},
                },
            },
        )
        caps = init_resp["result"]["capabilities"]
        assert "tools" in caps and "resources" in caps, f"Unexpected capabilities: {caps}"
        print("[PASS] initialize negotiated tools & resources capabilities")

        # 2. notifications/initialized (must not emit a response)
        send_notification(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        # 3. ping
        ping_resp = send_rpc(proc, {"jsonrpc": "2.0", "id": 2, "method": "ping"})
        assert ping_resp["id"] == 2 and "result" in ping_resp
        print("[PASS] ping responded without prior notification leak")

        # 4. tools/list
        tools_resp = send_rpc(proc, {"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
        tools = {t["name"]: t for t in tools_resp["result"]["tools"]}
        expected_tools = {
            "open_pilot_monitor",
            "open_pilot_usage",
            "pilot_get_live_snapshot",
            "pilot_probe_proxy",
            "pilot_get_usage_history",
        }
        assert set(tools.keys()) == expected_tools, f"Unexpected tools: {tools.keys()}"

        mon_meta = tools["open_pilot_monitor"]["_meta"]
        assert mon_meta["ui"]["resourceUri"] == "ui://pilot/dashboard.html"
        assert mon_meta["com.google.antigravity/ui"]["entrypoints"][0]["type"] == "aux_pane"

        usage_meta = tools["open_pilot_usage"]["_meta"]
        assert usage_meta["ui"]["resourceUri"] == "ui://pilot/dashboard.html"
        assert usage_meta["com.google.antigravity/ui"]["entrypoints"][0]["type"] == "global"

        for app_tool in ("pilot_get_live_snapshot", "pilot_probe_proxy", "pilot_get_usage_history"):
            assert tools[app_tool]["_meta"]["ui"]["visibility"] == ["app"], f"{app_tool} missing app-only visibility"
        print("[PASS] tools/list declared aux_pane, global entrypoints, and app-only tools")

        # 5. resources/list & resources/read
        res_list = send_rpc(proc, {"jsonrpc": "2.0", "id": 4, "method": "resources/list"})
        uris = [r["uri"] for r in res_list["result"]["resources"]]
        assert uris == ["ui://pilot/dashboard.html"]

        res_read = send_rpc(
            proc,
            {"jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": {"uri": "ui://pilot/dashboard.html"}},
        )
        content_item = res_read["result"]["contents"][0]
        assert content_item["mimeType"] == "text/html;profile=mcp-app"
        html_text = content_item["text"]
        assert 1000 < len(html_text.encode("utf-8")) < 10 * 1024 * 1024
        assert not re.search(r'<script[^>]+src\s*=\s*["\']https?://', html_text, re.I)
        assert not re.search(r'<link[^>]+href\s*=\s*["\']https?://', html_text, re.I)
        print(f"[PASS] resources/read returned self-contained MCP App HTML ({len(html_text.encode('utf-8'))} bytes)")

        # 6. tools/call checks
        call_specs = [
            (6, "open_pilot_monitor", {}),
            (7, "open_pilot_usage", {"period": "days7"}),
            (8, "pilot_get_live_snapshot", {"includeInternetCheck": False}),
            (9, "pilot_probe_proxy", {}),
            (10, "pilot_get_usage_history", {}),
        ]
        for req_id, tool_name, args in call_specs:
            resp = send_rpc(
                proc,
                {"jsonrpc": "2.0", "id": req_id, "method": "tools/call", "params": {"name": tool_name, "arguments": args}},
            )
            result = resp["result"]
            assert result.get("isError") is False, f"{tool_name} failed: {result}"
            sc = result.get("structuredContent", {})
            sc_bytes = len(json.dumps(sc).encode("utf-8"))
            assert 0 < sc_bytes < 1024 * 1024, f"{tool_name} structuredContent size invalid: {sc_bytes}"

            if tool_name == "open_pilot_monitor":
                assert sc["initialTab"] == "monitor"
                assert "proxyHealth" in sc["live"]
                assert len(sc["usage"]["heatmapWeeks"]) == 52
            elif tool_name == "open_pilot_usage":
                assert sc["initialTab"] == "usage"
                assert sc["initialPeriod"] == "days7"
                assert len(sc["usage"]["heatmapWeeks"]) == 52
            elif tool_name == "pilot_get_live_snapshot":
                assert "proxyConfig" in sc and "proxyHealth" in sc
            elif tool_name == "pilot_probe_proxy":
                assert "proxyHealth" in sc
            elif tool_name == "pilot_get_usage_history":
                assert len(sc["heatmapWeeks"]) == 52
                assert len(sc["heatmapWeeks"][0]) == 7

            print(f"[PASS] tools/call {tool_name} succeeded ({sc_bytes} bytes)")

        proc.stdin.close()
        rc = proc.wait(timeout=5)
        assert rc == 0, f"Server exited with {rc}"
        print("[PASS] MCP server exited cleanly on EOF")
        return 0
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    raise SystemExit(main())
