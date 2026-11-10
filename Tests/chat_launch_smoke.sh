#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/keylight-chat-build.XXXXXX")
cleanup() { status=$?; if [ "$status" -eq 0 ]; then rm -rf "$work"; else printf 'Retained diagnostic fixture: %s\n' "$work" >&2; fi; }
trap cleanup EXIT
swiftc -module-cache-path "$work/module-cache" Sources/Config.swift Sources/Requests.swift Sources/ChatLaunch.swift Sources/RequestPool.swift Tests/ChatLaunchSmoke.swift -o "$work/check"
"$work/check"
