#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import tempfile
import time
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
                assert "activeRunningCount" in sc["live"]
                assert len(sc["usage"]["heatmapWeeks"]) == 52
                assert "projectSummariesByPeriod" in sc["usage"]
                assert "sessionSummariesByPeriod" in sc["usage"]
            elif tool_name == "open_pilot_usage":
                assert sc["initialTab"] == "usage"
                assert sc["initialPeriod"] == "days7"
                assert len(sc["usage"]["heatmapWeeks"]) == 52
                assert "desktopArchiveCount" in sc["usage"]
                assert "cliArchiveCount" in sc["usage"]
                today_tot = sc["usage"]["totalsByPeriod"]["today"]
                for k in ("over200kRequestCount", "over200kTokens", "over200kPremiumUSD", "cacheSavingsUSD"):
                    assert k in today_tot, f"Missing {k} in totalsByPeriod.today"
            elif tool_name == "pilot_get_live_snapshot":
                assert "proxyConfig" in sc and "proxyHealth" in sc
                assert "activeRunningCount" in sc
            elif tool_name == "pilot_probe_proxy":
                assert "proxyHealth" in sc
            elif tool_name == "pilot_get_usage_history":
                assert len(sc["heatmapWeeks"]) == 52
                assert len(sc["heatmapWeeks"][0]) == 7
                assert "projectSummariesByPeriod" in sc
                assert "sessionSummariesByPeriod" in sc
                assert "subscriptionTier" in sc
                all_tot = sc["totalsByPeriod"]["all"]
                for k in ("over200kRequestCount", "over200kTokens", "over200kPremiumUSD", "cacheSavingsUSD"):
                    assert k in all_tot, f"Missing {k} in totalsByPeriod.all"

            print(f"[PASS] tools/call {tool_name} succeeded ({sc_bytes} bytes)")

        proc.stdin.close()
        rc = proc.wait(timeout=5)
        assert rc == 0, f"Server exited with {rc}"
        print("[PASS] MCP server exited cleanly on EOF")

        # 7. --hook-event CLI fast-path checks
        with tempfile.TemporaryDirectory() as tmpdir:
            events_file = Path(tmpdir) / "hook_events.jsonl"

            t_start = time.monotonic()
            stop_res = subprocess.run(
                [str(MCP_BIN), "--hook-event", "stop", "--events-file", str(events_file)],
                input=json.dumps({
                    "conversationId": "conv-stop-1",
                    "workspacePaths": ["/tmp/demo-ws"],
                    "terminationReason": "NO_TOOL_CALL",
                    "fullyIdle": True,
                    "continuationActive": False,
                }).encode("utf-8"),
                capture_output=True,
                timeout=5,
            )
            elapsed = time.monotonic() - t_start
            assert stop_res.returncode == 0
            assert elapsed < 0.5, f"Hook stop took too long: {elapsed:.3f}s"
            assert json.loads(stop_res.stdout.decode("utf-8")) == {}

            cancel_res = subprocess.run(
                [str(MCP_BIN), "--hook-event", "stop", "--events-file", str(events_file)],
                input=json.dumps({
                    "conversationId": "conv-cancel-1",
                    "terminationReason": "USER_CANCELED",
                    "fullyIdle": True,
                }).encode("utf-8"),
                capture_output=True,
                timeout=5,
            )
            assert cancel_res.returncode == 0
            assert json.loads(cancel_res.stdout.decode("utf-8")) == {}

            ask_res = subprocess.run(
                [str(MCP_BIN), "--hook-event", "pre-tool", "--events-file", str(events_file)],
                input=json.dumps({
                    "conversationId": "conv-ask-1",
                    "toolCall": {"name": "ask_question", "args": {"questions": [{"question": "Continue?"}]}},
                }).encode("utf-8"),
                capture_output=True,
                timeout=5,
            )
            assert ask_res.returncode == 0
            assert json.loads(ask_res.stdout.decode("utf-8")) == {"decision": "allow"}

            cmd_res = subprocess.run(
                [str(MCP_BIN), "--hook-event", "pre-tool", "--events-file", str(events_file)],
                input=json.dumps({
                    "conversationId": "conv-cmd-1",
                    "toolCall": {"name": "run_command", "args": {"CommandLine": "ls"}},
                }).encode("utf-8"),
                capture_output=True,
                timeout=5,
            )
            assert cmd_res.returncode == 0
            assert json.loads(cmd_res.stdout.decode("utf-8")) == {}

            lines = [json.loads(line) for line in events_file.read_text("utf-8").splitlines() if line.strip()]
            assert len(lines) == 2, f"Expected 2 recorded hook events, got {len(lines)}"
            assert lines[0]["kind"] == "task_completed"
            assert lines[1]["kind"] == "approval_needed"
            print(f"[PASS] --hook-event CLI checks succeeded ({elapsed * 1000:.1f}ms)")

        return 0
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    raise SystemExit(main())
