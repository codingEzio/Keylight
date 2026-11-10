#!/usr/bin/env python3
"""Isolated app-server/desktop peers; never connect to a user's AI session."""
import json
import os
from pathlib import Path
import socket
import struct
import sys
import uuid

root = Path.cwd()
thread = "00000000-0000-7000-8000-000000000001"


def record(value):
    with (root / "calls.jsonl").open("a") as out:
        out.write(json.dumps(value) + "\n")


if "--stdio" in sys.argv:
    for line in sys.stdin:
        message = json.loads(line)
        if "id" not in message:
            continue
        method, params = message["method"], message["params"]
        record({"appServer": method, "params": params})
        if method == "initialize":
            result = {}
        elif method == "permissionProfile/list":
            result = {"data": [{"id": "Development", "allowed": not (root / "deny-profile").exists()}]}
        elif method == "thread/start":
            assert params["permissions"] == "Development"
            assert params["runtimeWorkspaceRoots"] == [str(root)]
            result = {"thread": {"id": thread}, "cwd": str(root), "model": params["model"],
                      "reasoningEffort": params["config"]["model_reasoning_effort"],
                      "activePermissionProfile": {"id": "Development"}}
        elif method == "thread/name/set":
            assert params["threadId"] == thread and params["name"] == "Example · exact request 🧩"
            result = {}
        elif method == "thread/read":
            assert params == {"threadId": thread, "includeTurns": False}
            result = {"thread": {"id": thread, "turns": []}}
        else:
            raise RuntimeError(method)
        print(json.dumps({"id": message["id"], "result": result}), flush=True)
    sys.exit(0)


def readn(connection, count):
    value = b""
    while len(value) < count:
        part = connection.recv(count - len(value))
        if not part:
            raise EOFError
        value += part
    return value


server = socket.socket(socket.AF_UNIX)
server.bind(str(root / "desktop.sock"))
os.chmod(root / "desktop.sock", 0o600)
server.listen(2)
(root / "ready").touch()
with server.accept()[0] as connection:
    while True:
        try:
            message = json.loads(readn(connection, struct.unpack("<I", readn(connection, 4))[0]))
        except EOFError:
            break
        method, params = message["method"], message["params"]
        record({"desktop": method, "params": params})
        if method == "initialize":
            discovery = {"type": "client-discovery-request", "requestId": "fixture-discovery", "request": {"method": "unrelated-request"}}
            payload = json.dumps(discovery).encode()
            connection.sendall(struct.pack("<I", len(payload)) + payload)
            refusal = json.loads(readn(connection, struct.unpack("<I", readn(connection, 4))[0]))
            assert refusal == {"type": "client-discovery-response", "requestId": "fixture-discovery", "response": {"canHandle": False}}
            result = {"clientId": "keylight-fixture"}
        elif method == "thread-owner-discovery":
            result = {"supportsUntrustedAppInput": True}
        elif method == "thread-follower-update-thread-settings":
            assert params["threadSettings"] == {"cwd": str(root), "model": "gpt-6.1-terra", "effort": "high", "permissions": "Development"}
            result = {"applied": True}
        elif method == "thread-follower-start-turn":
            turn = params["turnStart"]["request"]
            assert turn["threadId"] == thread
            assert turn["model"] == "gpt-6.1-terra" and turn["effort"] == "high"
            assert turn["cwd"] == str(root) and turn["permissions"] == "Development"
            assert turn["input"] == [{"type": "text", "text": "  exact request 🧩\n", "text_elements": []}]
            uuid.UUID(turn["clientUserMessageId"])
            if (root / "drop-ack").exists():
                break
            result = {"result": {"turn": {"id": "fixture-turn"}}}
        else:
            raise RuntimeError(method)
        reply = {"type": "response", "requestId": message["requestId"], "resultType": "success", "method": method,
                 "handledByClientId": "fixture-owner", "result": result}
        value = json.dumps(reply).encode()
        frame = struct.pack("<I", len(value)) + value
        # Exercise fragmented reads, including multiple protocol responses.
        connection.sendall(frame[:2])
        connection.sendall(frame[2:])
