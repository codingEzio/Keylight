# Keylight

[简体中文](../README.zh-CN.md) · [繁體中文](../README.zh-TW.md)

A small native macOS launcher for apps and local commands. Press ⌘ Space, type, and press Return. If the shortcut is unavailable, open Keylight again from Finder to reach search and settings. Change the shortcut, search theme, app folders and exclusions in Settings. The default folders include /Applications, /System/Applications, ~/Applications, and ~/Applications/Chrome Apps.localized. Missing default personal app folders are skipped and will be scanned when they are created. Keylight watches configured app and command folders and refreshes when they change; Press ⌘R in search or use Refresh Apps in Settings to rescan manually. Press ⌘Q in search or use Quit Keylight in Settings to quit. Four search themes follow the system light/dark appearance and change both appearance and typography. Press ⌘, in the search window to open Settings. Use the arrow keys or click once to select a result; press Return or click it again to open it. Press ⌘M to exclude the selected app and move to the next result; ⌘Z undoes the most recent action, including exclusions and text edits. In App aliases, select an app and add or remove alternative search terms. Exclusions are per app; app bundles are not searched internally.

Search also matches letters in order, so `clc` finds Calculator; `cal` initially prioritizes the macOS Calendar app. When an app opens successfully from a search result, Keylight learns from recent choices for that search and ranks them ahead of ordinary matches. Case, accents and character width are normalized. A short rolling history adapts when your choices change. Learning is local, limited to 100 searches and eight recent app openings per search, and does not include commands. Queries over 128 UTF-8 bytes and app paths over 1,024 bytes are not recorded. Reset it in Settings or with `keylight config learning reset`; this leaves aliases and other settings intact and restores the initial Calendar priority. Learning is stored separately in `~/Library/Application Support/Keylight/config.json.search-history.json` and is not included in settings exports; with `KEYLIGHT_CONFIG`, it sits beside that configuration file.

## Local development requests

Type `add` then Space, Tab or Return to capture a request in the shared inbox.
Type `proj` then Space, Tab or Return to choose a project before writing. The
command and selected project become editable chips in the same launcher. Use
arrows and Return, or click a project. Escape goes back; an empty input also
supports Backspace. Return saves; Shift Return inserts a line break. Requests
stay local and do not start a model or coding agent.

In Settings → Requests, choose the queue folder, project root and Godspeed
Projects endpoint (`/api/projects?group=all`). The default scope is JobOSS, OSS
and Private. Other catalog categories are explicit opt-ins. Current/canonical
repository checkouts and project-level observed checkouts are used; historical
and former checkouts are ignored. Only existing direct children of the selected
root are selectable. Missing checkouts remain visible with an explanation.
Pin projects and use the up action to order them. The model ID and reasoning
effort are editable; defaults are `gpt-6.1-terra` and `high`. They are stored
request preferences, not a claim about model availability or account access.

Each request becomes `<local-date>_<time>-<UUID>/request.md`, with a versioned
header containing ID, timestamp with timezone, project ID/name/path, model and
reasoning effort, followed by the exact input text. The local limit is 1 MB per
request. Files use mode 0600 and request directories use 0700. A request is
acknowledged after file synchronization and readback. Interrupted pending writes
and retries reuse the request ID; conflicting content preserves the original.
Leave the queue in a private, trusted directory outside public source control.
There is no automatic queue execution, cleanup or synchronization.

The project catalog is cached beside the settings and remains available offline.
Refresh errors leave the previous cache intact and show its timestamp. Refresh
happens when entering a request flow or explicitly requesting it, never on a
timer or per keystroke. Drafts are saved when leaving the flow and before a
submission, including pending request identity for restart/retry. Settings
exports include request preferences and local paths; they exclude the catalog,
drafts and queue contents.

```sh
keylight config requests root "$HOME/Projects"
keylight config requests queue "$HOME/Keylight Requests"
keylight config requests source 'http://127.0.0.1:50000/api/projects?group=all'
keylight config requests scope 'joboss,oss,private'
keylight config requests model gpt-6.1-terra
keylight config requests effort high
keylight config requests pins 'example-project-id'
keylight projects refresh
keylight projects list
keylight request add 'Investigate the startup error'
keylight request add --project example-project-id 'Fix keyboard navigation'
```

Recheck with `sh Tests/requests_smoke.sh` and
`python3 Tests/requests_cli_smoke.py` and `sh Tests/request_draft_smoke.sh`;
all use disposable local data.

## Command line

After building, run `dist/Keylight.app/Contents/MacOS/Keylight --help`. To use the shorter `keylight` command below, add a symlink to that executable in a directory on your `PATH`. CLI commands do not show a window:

```sh
keylight --help
keylight search calendar
keylight apps all
keylight apps background
keylight apps installers
keylight run "Toggle Dark Mode"
keylight config show
keylight config theme Nothing
keylight config shortcut '⌘' Space
keylight config folder add "$HOME/Applications"
keylight config exclude add /Applications/Example.app
keylight config alias add /Applications/Ghostty.app term
keylight config alias remove /Applications/Ghostty.app term
keylight config learning reset
keylight config icons Original   # or System
keylight config scripts "$HOME/Commands"
keylight config export "$HOME/Keylight.json"
keylight config import "$HOME/Keylight.json"
```

App icons default to Original: Keylight loads an app’s bundled .icns or declared asset-catalog icon, using available light/dark appearances instead of Clear. If neither original is available, it falls back to the system icon. Choose System to follow the system icon style. Settings provides a searchable per-app visibility list. Background preview uses the app’s `LSBackgroundOnly` metadata, not the agent/menu-bar flag; installer preview is a name-based suggestion and may be incomplete. Selecting a preview never changes exclusions: use an app’s switch to hide or restore it. `keylight apps` offers the same read-only previews. Only executable regular files directly inside the selected commands folder appear. Commands run with your account's access. Import validates the complete JSON before replacing the settings and never executes a command. Settings are local at `~/Library/Application Support/Keylight/config.json`; `KEYLIGHT_CONFIG` overrides that path for isolated CLI use. Do not share an export without checking its local paths. Settings and learning saves use POSIX mode `0600`. Their directory must be owned by the current user, not writable by others, and have no ACL; a temporary file with an ACL is rejected before data is written. Existing files retain their permissions until the next successful save. Keep ancestor directories trusted. Exported files are separate and their permissions depend on the destination.

## Build and permissions

Requires macOS 26+ and Swift 6.2+. Run `scripts/build.sh` to stage `dist/Keylight.app` (this does not install the app or CLI); `KEYLIGHT_SIGN_IDENTITY` selects a signing identity (default: ad hoc). `KEYLIGHT_SWIFTPM_NO_SANDBOX=1` is available for environments that cannot create a nested SwiftPM sandbox. Run `python3 Tests/cli_smoke.py`, `Tests/asset_icon_smoke.sh`, `Tests/first_run_smoke.sh`, `Tests/folder_watch_smoke.sh`, `Tests/search_learning_smoke.sh`, and `Tests/search_launch_smoke.sh` after building. The launch test opens a temporary windowless fixture app and requires a macOS GUI session.

Global shortcuts use Carbon and do not need Accessibility access. If ⌘ Space is already in use, change the other shortcut in System Settings or choose another combination in Keylight. Toggle Dark Mode uses System Events and may ask for Automation permission when first run. Other commands may require their own permissions. Configuration stays on this Mac.

Doto font: [Google Fonts source](https://github.com/google/fonts/tree/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl/doto), bundled in `Resources/Doto.ttf` (SHA-256 `6f4fe7d37853b91df3698daa84cde2dbe1c9695d88c986e6510134910337d426`), SIL Open Font License 1.1 in `Resources/Doto-OFL.txt`. No network is needed at runtime.

Keylight source is licensed under [GPL-3.0-only](../LICENSE). The bundled Doto font remains under SIL OFL 1.1.

App icon: generated with OpenAI image generation and stored as `Assets/Keylight.png`.

## System Settings shortcuts

Search for Wallpaper or Login Items & Extensions (also searchable as startup) to open that pane directly. The shared catalog in `Sources/SystemSettings.swift` contains their names, search terms, icons and macOS extension identifiers. Availability depends on macOS.
