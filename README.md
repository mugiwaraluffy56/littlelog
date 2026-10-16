# littlelog

A tiny, keyboard-first macOS utility for notes and today's tasks.
Open. Write. Done. Disappear.

littlelog lives in the menu bar (no Dock icon) and opens as a floating panel with **⌘⇧L** from any app.

## Requirements

- macOS 26 or newer, Apple Silicon
- Xcode 26 or newer (built with Xcode 27.1)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you change the file layout: `brew install xcodegen`

## Build and run

```bash
open littlelog.xcodeproj          # then ⌘R in Xcode
```

or from the command line:

```bash
xcodebuild -project littlelog.xcodeproj -scheme littlelog -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/littlelog.app
```

The project file is generated from `project.yml`. After adding or removing source files, run:

```bash
xcodegen generate
```

## Tests

```bash
xcodebuild -project littlelog.xcodeproj -scheme littlelog -derivedDataPath build/DerivedData test
# a single suite or test:
xcodebuild ... test -only-testing:littlelogTests/AppStateTests
xcodebuild ... test -only-testing:littlelogTests/AppStateTests/deletingANoteCanBeUndoneAndRedone
```

The app icon is rendered by `swift scripts/make-icon.swift littlelog/Resources/Assets.xcassets/AppIcon.appiconset`.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌘⇧L | Show / hide littlelog (global) |
| Esc | Leave the note editor, clear search, or hide |
| ⌘1 / ⌘2 | Notes / Today |
| ⌘N | New note (Notes) · focus the task field (Today) |
| ⌘F | Search notes |
| ↑ / ↓, Return | Move through notes from the search field, open the highlighted note |
| Return | Add the task you're typing |
| ⌘Z / ⇧⌘Z | Undo / redo, including deleted notes and tasks |
| ⌘W | Hide |

The panel can be dragged from any empty area; it reopens where you left it on that display.

## ChatGPT & Codex (MCP)

littlelog can act as a [Model Context Protocol](https://modelcontextprotocol.io) server so ChatGPT and Codex
can read your day and add tasks for you. It's **off by default**.

Turn it on from the menu bar icon → **Allow Access**. littlelog then serves MCP (spec 2025-11-25, Streamable HTTP)
at `http://127.0.0.1:48177/mcp`:

- only reachable from this Mac (bound to loopback), and only with littlelog's access token;
- requests from web pages on other origins and DNS-rebinding hosts are rejected;
- every change goes through the app, so it appears live in the panel and deletions can be undone with ⌘Z;
- tasks an assistant adds show a small ✦ in Today.

| Tool | Does |
|---|---|
| `list_tasks` | A day's tasks in order (`today`, `tomorrow`, `yesterday` or `YYYY-MM-DD`) |
| `add_tasks` | Appends tasks; anything already on that day's list is skipped, so retries never duplicate |
| `set_task_completed` / `update_task` / `move_task` | Tick off, rename, reorder |
| `delete_task` | Deletes (marked destructive; Codex asks before running it) |
| `search_notes` / `read_note` | Read-only access to notes — assistants can't change notes |

### Codex CLI and the ChatGPT desktop app

Both read `~/.codex/config.toml`. Menu bar → **Set Up Codex & ChatGPT Desktop…** → choose that file; littlelog
adds its own `[mcp_servers.littlelog]` section and leaves the rest untouched. Or use **Copy Codex Configuration**
and paste it in yourself. Start a new Codex/ChatGPT session afterwards, then check with `codex mcp list`.

### ChatGPT on the web and phone

ChatGPT's servers can't reach `127.0.0.1`, so this goes through OpenAI's
[Secure MCP Tunnel](https://github.com/openai/tunnel-client) (an outbound-only connection; no ports are opened):

1. In ChatGPT, turn on Developer mode (Settings → Apps/Plugins → Advanced; needs a plan that includes it).
2. At [platform.openai.com → Tunnels](https://platform.openai.com/settings/organization/tunnels), create a tunnel and a
   restricted runtime key with Tunnels **Read + Use**, and install `tunnel-client` from there.
3. Menu bar → **Copy Tunnel Command for ChatGPT Web & Phone**, fill in the runtime key and tunnel id, and run it.
   Keep it running; your Mac must be awake with littlelog open.
4. In ChatGPT → Settings → Connectors/Plugins → create one with **Connection: Tunnel**, pick your tunnel, no authentication.

**Reset Access Token…** disconnects every client at once; set them up again afterwards. **Open at Login** keeps
littlelog (and the server) available after restarts.

## Data

Notes and tasks are stored locally with SwiftData in the app's sandbox container
(`~/Library/Containers/dev.littlelog.app/Data/Library/Application Support/littlelog.store`), next to the
assistant access token (`littlelog/assistant-token`, readable only by you).
There is no sync or telemetry, and nothing is sent anywhere unless you turn on assistant access and connect a client.
Past days' tasks are kept; Today shows only the current local day.
