#!/usr/bin/env python3
"""End-to-end CLI test against disposable settings, apps, and scripts."""
import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile

exe = Path(__file__).resolve().parents[1] / "dist/Keylight.app/Contents/MacOS/Keylight"
with tempfile.TemporaryDirectory(prefix="keylight-test-") as tmp:
    root = Path(tmp)
    apps, scripts = root / "Apps", root / "Scripts"
    apps.mkdir(); scripts.mkdir()
    for name in ("Alpha", "Hidden", ".DotApp", "Preview", "AirPort Utility", "Mastermind"):
        contents = apps / (name + ".app") / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_text('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>' + name + '</string></dict></plist>')
    for name, extra in (("HelperService", {"LSBackgroundOnly": True}), ("MenuBarTool", {"LSUIElement": True}), ("Install Example", {}), ("Audio MIDI Setup", {}), ("InstallAssistant", {})):
        contents = apps / (name + ".app") / "Contents"; contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as f: plistlib.dump({"CFBundleName": name, **extra}, f)
    marker = root / "marker"
    script = scripts / "Hello"
    script.write_text('#!/bin/sh\nprintf ok > "' + str(marker) + '"\n')
    script.chmod(0o755)
    failure = scripts / "Fail"
    failure.write_text('#!/bin/sh\nexit 7\n'); failure.chmod(0o755)
    config = {"version": 1, "theme": "Nothing", "modifier": "⌘", "key": "Space", "folders": [str(apps)], "excluded": [str(apps / "Hidden.app")], "scripts": str(scripts)}
    source = root / "input.json"; source.write_text(json.dumps(config))
    env = dict(os.environ, KEYLIGHT_CONFIG=str(root / "config.json"))
    def run(*args, expected=0, binary=exe):
        p = subprocess.run([str(binary), *args], env=env, text=True, capture_output=True, timeout=20)
        assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
        return p.stdout
    assert "config import" in run("--help"); run("unknown-command", expected=1)
    run("config", "import", str(source))
    config.update({"aliases": {}, "iconStyle": "Original", "requests": {"projectRoot": "", "catalogURL": "", "queueFolder": "", "categories": ["joboss", "oss", "private"], "pinnedProjects": [], "model": "gpt-6.1-terra", "reasoningEffort": "high"}})
    assert json.loads(run("config", "show")) == config
    results = run("search")
    assert "Alpha\t" in results and "Hidden\t" not in results and "DotApp\t" in results and "Hello\t" in results
    assert "com.apple.Wallpaper-Settings.extension" in run("search", "wallpaper")
    assert "com.apple.LoginItems-Settings.extension" in run("search", "startup")
    assert "com.apple.Wallpaper-Settings.extension" in run("search", "桌布")
    before_preview = json.loads(run("config", "show"))
    all_apps = run("apps", "all"); assert "hide\tHidden\t" in all_apps and "show\tAlpha\t" in all_apps
    background = run("apps", "background"); assert "HelperService" in background and "MenuBarTool" not in background
    installer = run("apps", "installers"); assert "Install Example" in installer and "InstallAssistant" in installer and "HelperService" not in installer and "Audio MIDI Setup" not in installer
    assert "Alpha" in run("apps", "all", "Alp") and "Hidden" not in run("apps", "all", "Alp")
    assert json.loads(run("config", "show")) == before_preview
    run("run", "Hello"); assert marker.read_text() == "ok"
    run("run", "Fail", expected=7); run("run", "absent", expected=1)
    exported = root / "export.json"; run("config", "export", str(exported))
    assert json.loads(exported.read_text()) == config
    bad = root / "invalid.json"; bad.write_text('{"version":999}')
    run("config", "import", str(bad), expected=1)
    assert json.loads(run("config", "show")) == config
    run("config", "theme", "Windows XP"); run("config", "theme", "invalid", expected=1)
    assert json.loads(run("config", "show"))["theme"] == "Windows XP"
    run("config", "folder", "add", str(root / "Extra")); run("search", expected=1); run("config", "folder", "remove", str(root / "Extra"))
    run("config", "exclude", "add", str(apps / "Alpha.app")); assert "Alpha\t" not in run("search")
    run("config", "exclude", "remove", str(apps / "Alpha.app")); assert "Alpha\t" in run("search")
    run("config", "shortcut", "⌘", "Space")
    run("config", "alias", "add", str(apps / "Alpha.app"), "term")
    assert "Alpha\tapp" in run("search", "term")
    assert run("search", "p").splitlines()[0].startswith("Preview\t")
    term_results = run("search", "term").splitlines()
    assert term_results[0].startswith("Alpha\t") and any(line.startswith("Mastermind\t") for line in term_results)
    rich_export = root / "with-aliases.json"; run("config", "export", str(rich_export))
    rich = json.loads(rich_export.read_text()); assert list(rich["aliases"].values()) == [["term"]] and rich["iconStyle"] == "Original"
    run("config", "alias", "add", str(apps / "Alpha.app"), " ", expected=1)
    assert json.loads(run("config", "show")) == rich
    run("config", "exclude", "add", str(apps / "Alpha.app")); assert "Alpha\t" not in run("search", "term")
    run("config", "exclude", "remove", str(apps / "Alpha.app")); assert "Alpha\t" in run("search", "term")
    run("config", "alias", "remove", str(apps / "Alpha.app"), "TERM"); assert "Alpha\t" not in run("search", "term")
    run("config", "icons", "System"); assert json.loads(run("config", "show"))["iconStyle"] == "System"
    run("config", "icons", "invalid", expected=1); assert json.loads(run("config", "show"))["iconStyle"] == "System"
    before_reset = json.loads(run("config", "show"))
    learning = root / "config.json.search-history.json"
    learning.write_text(json.dumps({"version": 1, "queries": [{"text": "a", "apps": [str(apps / "Alpha.app")]}]}))
    assert run("search", "a").splitlines()[0].startswith("Alpha\t")
    run("config", "learning", "reset")
    assert json.loads(learning.read_text())["queries"] == []
    assert json.loads(run("config", "show")) == before_reset
    assert run("search", "a").splitlines()[0].startswith("AirPort Utility\t")
    alias = root / "keylight"; alias.symlink_to(exe)
    assert "Toggle Dark Mode\tcommand" in run("search", "Toggle Dark Mode", binary=alias)
    print("PASS: app previews, old config migration, aliases and exclusions, icons, search, scripts, import/export, failure")
