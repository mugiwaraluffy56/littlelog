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

## ChatGPT

Ask ChatGPT on the web or phone things like "add buy milk tomorrow" or "what's left today?", and it works with
littlelog on your Mac through a [Model Context Protocol](https://modelcontextprotocol.io) connection.

**Setup (once):**

1. littlelog menu bar icon → **Allow ChatGPT Access**, then **Copy ChatGPT Link**.
2. On [chatgpt.com/plugins](https://chatgpt.com/plugins) (Developer mode on) → **+** → **Add custom MCP server** →
   paste the link, authentication **OAuth** → create and install.
3. ChatGPT asks you to sign in; littlelog shows **Allow** on your Mac. Done — type `@littlelog` in a chat.

**How it works:** ChatGPT can only reach servers on the internet, so a tiny relay ([`relay/`](relay), a Cloudflare
Worker) forwards its requests to littlelog, which keeps one connection open to it. The relay stores nothing but a
hash of this Mac's secret; tasks never leave your Mac except in answers to ChatGPT. Sign-in is standard MCP OAuth
(dynamic client registration + PKCE) and every sign-in must be approved on the Mac.

- Changes go through the app, so they appear live in the panel, and deletions can be undone with ⌘Z.
- Tasks ChatGPT adds show a small ✦ in Today.
- Your Mac must be awake with littlelog running; otherwise ChatGPT is told littlelog is offline.
  **Open at Login** keeps it available after restarts. **Sign Out All Apps…** revokes every sign-in.

| Tool | Does |
|---|---|
| `list_tasks` | A day's tasks in order (`today`, `tomorrow`, `yesterday` or `YYYY-MM-DD`) |
| `add_tasks` | Appends tasks; anything already on that day's list is skipped, so retries never duplicate |
| `set_task_completed` / `update_task` / `move_task` | Tick off, rename, reorder |
| `delete_task` | Deletes (marked destructive, so ChatGPT confirms first) |
| `search_notes` / `read_note` | Read-only access to notes — ChatGPT can't change notes |

**Self-hosting the relay:** `cd relay && npm install && npx wrangler deploy`, then
`defaults write dev.littlelog.app relayURL https://<your-worker>.workers.dev` and restart littlelog.

## Data

Notes and tasks are stored locally with SwiftData in the app's sandbox container
(`~/Library/Containers/dev.littlelog.app/Data/Library/Application Support/littlelog.store`), next to
the relay identity and ChatGPT sign-ins (`littlelog/relay-device.json`, `littlelog/oauth.json` — token hashes only), readable only by you.
There is no sync or telemetry; nothing leaves the Mac unless you turn on ChatGPT access.
Past days' tasks are kept; Today shows only the current local day.
