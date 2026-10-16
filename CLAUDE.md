# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make generate        # required after adding/removing/moving files; littlelog.xcodeproj is git-ignored
make build
make test            # ONLY=AppStateTests or ONLY=AppStateTests/<testName> to narrow
make run             # build and relaunch the app
```

Tests use Swift Testing (`import Testing`) and are hosted in the app; `AppDelegate` skips all setup when `XCTestConfigurationFilePath` is set, so tests never touch the real store or register the hotkey.

## Architecture

Pure Swift: AppKit shell + SwiftUI content + SwiftData. No Rust, no packages. Entitlements: App Sandbox, `network.server` (loopback MCP), `files.user-selected.read-write` (Codex config setup). Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — pure helpers that must run off the main actor (e.g. `DayKey`, `String.isBlankText`) are marked `nonisolated`.

Sources sit in root folders (`App/`, `Assistant/`, `Models/`, `Views/`, `Resources/`), tests in `Tests/` — keep it flat; the user dislikes nested `littlelog/…` folders.

- `App/LittlelogApp.swift` — AppKit `@main` (no SwiftUI `App`); accessory app (`LSUIElement`), no Dock icon.
- `App/AppDelegate` — opens the SwiftData container (on failure shows an alert and quits; never falls back to an empty store), status item menu, hidden main menu whose Edit items make ⌘C/⌘V/⌘Z work in the panel.
- `App/PanelController` — `.nonactivatingPanel` NSPanel hosting `RootView`. The panel takes key without activating the app, so the previous app regains focus on hide. All panel shortcuts (Esc, ⌘1/2/N/F/W, ↑/↓) are intercepted in `LittlelogPanel.sendEvent` before SwiftUI/NSTextView see them (NSTextView would swallow Esc). Hides on real focus loss (deferred `NSApp.keyWindow == nil` check) or a global outside-click monitor.
- `App/HotkeyManager` — Carbon `RegisterEventHotKey` (no Accessibility permission needed).
- `App/AppState` — single `@Observable` owner of all UI state *and* every mutation of the store. Views call its methods; they don't mutate models except via `@Bindable` text bindings followed by `noteDidChange`/`taskTextDidChange`. Autosave is disabled; saves are explicit (`save()`, debounced `scheduleSave()` while typing) and failures surface via `errorMessage`. Focus is driven by `requestFocus(_:)` → `RootView` applies it to a single `@FocusState<FocusTarget?>`. Undo of deletes uses `state.undoManager`, which is also the panel's window undo manager.
- Today filtering: tasks carry a `dateKey` (`yyyy-MM-dd` local day via `DayKey`); `AppState.dayKey` refreshes on panel show and on day/time-zone/clock-change notifications (no timers).
- `App/StatusMenuController` — menu bar item, rebuilt on every open (`menuNeedsUpdate`): open panel, assistant access, Open at Login (`SMAppService`), quit.

### Assistant access (MCP) — `Assistant/`

ChatGPT/Codex talk to littlelog over MCP. The MCP layer is written in-house (the official Swift SDK pulls in SwiftNIO etc.); it implements only what's needed, to spec 2025-11-25. Web ChatGPT is the user's top priority.
- `LocalHTTPServer` — `nonisolated`, Network.framework, bound to `127.0.0.1:48177` (`requiredInterfaceType = .loopback`), strict HTTP/1.1 parser in `HTTP.swift` (Content-Length only, size limits, keep-alive).
- `MCPServer` (MainActor) — stateless Streamable HTTP: POST → one JSON-RPC message → one `application/json` reply; GET/DELETE → 405; notifications → 202. `baseURL(for:)` accepts loopback hosts, or a public host only when a tunnel marks it `X-Forwarded-Proto: https` (DNS-rebinding guard). `/mcp` then checks Origin, bearer token (static token, constant-time, *or* an OAuth access token), method, `MCP-Protocol-Version`, Content-Type; a 401 carries `resource_metadata` so ChatGPT can discover sign-in.
- OAuth for ChatGPT web (it can't send custom headers): `OAuthEndpoints` serves RFC 9728/8414 metadata, DCR (`/oauth/register`), `/oauth/authorize` (waits on `AccessApprovals` — Allow/Don't Allow banner in the panel, which pops open; 90 s timeout) and `/oauth/token` (code + PKCE S256, rotating refresh tokens). `OAuthStore` persists clients and SHA-256-hashed tokens in `Application Support/littlelog/oauth.json`. Public address comes from the user's `ngrok http 48177`.
- `AssistantTools` — tool definitions (schemas, `outputSchema`, read-only/destructive annotations) and execution. Argument/lookup/save problems return `isError: true` tool results, not JSON-RPC errors. Notes are read-only by design.
- `AppState+Assistant` — the operations; they reuse `AppState` (`insertTask`, `removeTask` with undo, `commit()` which throws) so assistant edits show live in the panel. `add_tasks` dedupes against the day's list (case/diacritic-insensitive) so retries are idempotent. Assistant-created tasks set `DailyTask.addedByAssistant` (shown as ✦).
- `AssistantAccess` — opt-in flag (`UserDefaults` `assistantAccessEnabled`), token in the container at `Application Support/littlelog/assistant-token` (0600; not Keychain because ad-hoc rebuilds re-prompt), Codex config block and the ngrok command. `CodexConfig` merges into `~/.codex/config.toml` replacing only `[mcp_servers.littlelog*]` tables; the sandbox writes it via a user-picked NSOpenPanel URL (`files.user-selected.read-write`), in place (not atomic).
- Manual check against the running app: token from the file above, then `xh POST http://127.0.0.1:48177/mcp "Authorization:Bearer $TOKEN" jsonrpc=2.0 id:=1 method=tools/list`. Validate Codex config parsing with a throwaway `CODEX_HOME=<tmp> codex mcp list` — never edit the user's real `~/.codex` from the shell.

## UI conventions

Prefer system components over custom ones — the user rejected hand-built controls as "not Apple". The panel's content is an `NSHostingController` with `sceneBridgingOptions = [.toolbars, .title]`, so SwiftUI `.toolbar`, `.searchable` and the `NavigationStack` back button become a real NSToolbar (native Liquid Glass). The panel is `.titled` + `.fullSizeContentView` with a transparent titlebar and `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`, so the glass backdrop runs under the toolbar (no dark strip). SwiftUI then only reserves the title bar height, so stack content uses `.clearsWindowToolbar()` (measures the real toolbar inset from the window). The app ships a neutral `AccentColor` so focus rings/selection are never blue. Notes is a `List(.inset)` of `NavigationLink(value: UUID)` rows (Apple Notes layout); the stack's path mirrors `state.openNote`. Today is a `ScrollView` + `LazyVStack` drawn like an inset list (separators via `RowSeparator`, reorder via `onDrag`/`TaskDropDelegate`) with Reminders-style circle toggles — never put text fields in a `List`: macOS paints an opaque black band behind them. Use system text styles (`.headline`, `.body`, `.title2`), Title Case labels, `ContentUnavailableView` for empty states. Toolbar actions go trailing via `ToolbarSpacer(.flexible)`. No grey anywhere: the user rejected the segmented control's grey pill and the List's grey selection (the panel never becomes the active app, so selection always draws in its inactive grey). So the section switch is `SectionSwitcher` — a clear glass bubble that morphs between tabs via `glassEffectID`, in a toolbar item with `.sharedBackgroundVisibility(.hidden)` — and the notes List has no selection; the arrow-key highlight is a clear-glass `listRowBackground`, set only by ↑/↓. The translucent backdrop is `PanelBackground` (`NSVisualEffectView`, `.popover`) — the user explicitly wants it kept. Scroll indicators are hidden.

The user tests UI interactions manually: don't drive the app with synthetic keystrokes (osascript/System Events).
