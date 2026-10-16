# littlelog

A tiny, keyboard-first macOS utility for notes and today's tasks.
Open. Write. Done. Disappear.

littlelog lives in the menu bar (no Dock icon) and opens as a floating panel with **⌘⇧L** from any app.

## Requirements

- macOS 26 or newer, Apple Silicon
- Xcode 26 or newer (built with Xcode 27.1)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen` — the Xcode project is generated from `project.yml`

## Build and run

```bash
make run                          # generate the project, build, and launch
make test                         # all tests; narrow with ONLY=OAuthTests or ONLY=OAuthTests/pkceIsRequired
make generate                     # after adding or moving files (littlelog.xcodeproj is generated, not committed)
make icon                         # re-render the app icon
make clean
```

To work in Xcode: `make generate`, then open `littlelog.xcodeproj` and press ⌘R.

## License

MIT — see [LICENSE](LICENSE).

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

- it listens only on this Mac; ChatGPT on the web reaches it through a tunnel you run (below);
- every request needs a token: littlelog's own (Codex) or a sign-in you approved on the Mac (ChatGPT);
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

ChatGPT's servers can't reach `127.0.0.1`, so littlelog needs a public HTTPS address, and ChatGPT signs in with
standard MCP OAuth (dynamic client registration + PKCE). You approve each sign-in in the littlelog panel on your Mac.

1. Get a free [ngrok](https://ngrok.com) account, then `brew install ngrok` and
   `ngrok config add-authtoken <your token>`. The free plan includes one permanent domain.
2. Menu bar → **Copy ngrok Command for ChatGPT Web**, run it (`ngrok http 48177`) and keep it running.
   Note the `https://….ngrok-free.app` address it shows.
3. In ChatGPT, turn on Developer mode (Settings → Apps/Plugins → Advanced; needs a plan that includes it), go to
   [chatgpt.com/plugins](https://chatgpt.com/plugins) → **+** → **Add custom MCP server**, use
   `https://….ngrok-free.app/mcp` as the server URL and **OAuth** as authentication, then create and install it.
4. ChatGPT opens a sign-in window (click through ngrok's one-time notice). littlelog pops up on your Mac:
   **Allow**. Done — type `@littlelog` in a chat.

Your Mac must be awake with littlelog and ngrok running. **Disconnect All Apps…** signs every app out at once.
**Open at Login** keeps littlelog (and the server) available after restarts.

## Data

Notes and tasks are stored locally with SwiftData in the app's sandbox container
(`~/Library/Containers/dev.littlelog.app/Data/Library/Application Support/littlelog.store`), next to the
assistant access token and sign-ins (`littlelog/assistant-token`, `littlelog/oauth.json` — hashes only — readable only by you).
There is no sync or telemetry, and nothing is sent anywhere unless you turn on assistant access and connect a client.
Past days' tasks are kept; Today shows only the current local day.
