# Keylight

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

A fast macOS launcher for apps and local commands.
Search matches abbreviations and learns from your app choices on this Mac.

Type `add` to capture a local request, or `proj` to choose a project first. Configure the project scope, pins, model and queue in Settings → Requests. Requests are plain text files; no model is started.

![Keylight search](docs/images/search.png)

## Get started

Requires macOS 26+ and Swift 6.2+. Build and open:

```sh
scripts/build.sh
open dist/Keylight.app
```

## Shortcuts

| | |
|---|---|
| ⌘ Space | Open Keylight |
| ↑ ↓ / Return | Select / open a result |
| ⌘ M / ⌘ Z | Exclude selected app / undo |
| ⌘ , | Open settings |
| ⌘ R / ⌘ Q | Refresh apps / quit Keylight |

More options, CLI, permissions and font attribution: [Guide](docs/guide.md) (English). Source: [GPL-3.0-only](LICENSE). Doto font: [SIL OFL 1.1](Resources/Doto-OFL.txt).
