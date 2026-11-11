# Keylight

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

A fast macOS launcher for apps and local commands.
Search matches abbreviations and learns from your app choices on this Mac.

Type `add` to choose a project, create or append a pending request, or select one and press ⌘Return to send it. `proj` creates and sends a one-off request. Sent files remain; pending ones appear next time. Configure scope, pins, queue and presets in Settings → Requests. Defaults: `gpt-6.1-terra`, `high`, `Development`.

The optional request workflow requires a configured Godspeed Projects service; sending also requires a compatible signed-in ChatGPT desktop app. When enabled in Settings, `clip` opens local text history, and `emp` opens a mouse-confirmed Trash action. See the [guide](docs/guide.md) for limits and permissions.

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
