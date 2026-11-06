#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/keylight-first-run-build.XXXXXX")
cleanup() { status=$?; if [ "$status" -eq 0 ]; then rm -rf "$work"; else printf 'Retained diagnostic fixture: %s\n' "$work" >&2; fi; }
trap cleanup EXIT
swiftc -module-cache-path "$work/module-cache" Sources/Config.swift Sources/AppClassification.swift Sources/Search.swift Sources/CLI.swift Tests/FirstRunSmoke.swift -o "$work/check"
"$work/check"
