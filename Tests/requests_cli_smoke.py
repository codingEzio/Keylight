#!/usr/bin/env python3
"""Exercise catalog transport, offline capture and settings through separate CLI runs."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

exe = Path(__file__).resolve().parents[1] / "dist/Keylight.app/Contents/MacOS/Keylight"
with tempfile.TemporaryDirectory(prefix="keylight-request-cli-") as temporary:
    root = Path(temporary)
    workspace = root / "Projects"
    checkout = workspace / "X-Fixture"
    checkout.mkdir(parents=True)
    env = dict(os.environ, KEYLIGHT_CONFIG=str(root / "settings/config.json"))

    def run(*args, expected=0):
        result = subprocess.run([str(exe), *args], env=env, capture_output=True, text=True, timeout=20)
        assert result.returncode == expected, (args, result.stdout, result.stderr)
        return result.stdout

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            assert self.path == "/api/projects?group=all"
            payload = {"schema": "godspeed.project-groups/v1", "total": 2, "items": [
                {"id": "fixture", "name": "Fixture", "summary": "Local project", "category": "joboss",
                 "repositories": [], "project_checkouts": [{"state": "observed", "path": str(checkout)}]},
                {"id": "missing", "name": "Missing", "summary": "No checkout", "category": "private",
                 "repositories": [], "project_checkouts": []},
            ]}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for field, value in [("root", str(workspace)), ("queue", str(root / "Queue")),
                             ("source", f"http://127.0.0.1:{server.server_port}/api/projects?group=all"),
                             ("pins", "missing,fixture"), ("permissions", "Development")]:
            run("config", "requests", field, value)
        assert "2 projects cached" in run("projects", "refresh")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    assert run("projects", "list").splitlines()[0].startswith("missing\t")
    assert str(checkout) in run("projects", "list", "fixture")
    cached = Path(env["KEYLIGHT_CONFIG"] + ".projects.json").read_bytes()
    run("projects", "refresh", expected=1)
    assert Path(env["KEYLIGHT_CONFIG"] + ".projects.json").read_bytes() == cached
    text = "  修正搜尋 🧩\n保留換行。\n"
    receipt = json.loads(run("request", "add", "--project", "fixture", text))
    saved = Path(receipt["file"]).read_text()
    assert saved.endswith(text) and 'project_id: "fixture"' in saved
    assert 'model: "gpt-6.1-terra"' in saved and 'reasoning_effort: "high"' in saved
    assert 'permission_profile: "Development"' in saved
    inbox = json.loads(run("request", "add", "Inbox request"))
    assert "project_path: null" in Path(inbox["file"]).read_text()
    run("request", "add", "--project", "missing", "do not save", expected=1)
    run("request", "add", " \n", expected=1)
    assert len(list((root / "Queue").glob("*/request.md"))) == 2
    before = run("config", "show")
    run("config", "requests", "effort", "invalid", expected=1)
    run("config", "requests", "wrong-field", "invalid", expected=1)
    assert run("config", "show") == before
    run("config", "requests", "scope", "oss")
    assert run("projects", "list") == ""
    run("request", "add", "--project", "fixture", "outside scope", expected=1)
    print("PASS: CLI catalog transport, offline cache/capture, receipts, project scope and invalid settings")
