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

Pure Swift: AppKit shell + SwiftUI content + SwiftData. No Rust, no packages. Entitlements: App Sandbox + `network.client` (relay connection) only. Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — pure helpers that must run off the main actor (e.g. `DayKey`, `String.isBlankText`) are marked `nonisolated`.

Sources sit in root folders (`App/`, `Assistant/`, `Models/`, `Views/`, `Resources/`), tests in `Tests/` — keep it flat; the user dislikes nested `littlelog/…` folders.

- `App/LittlelogApp.swift` — AppKit `@main` (no SwiftUI `App`); accessory app (`LSUIElement`), no Dock icon.
- `App/AppDelegate` — opens the SwiftData container (on failure shows an alert and quits; never falls back to an empty store), status item menu, hidden main menu whose Edit items make ⌘C/⌘V/⌘Z work in the panel.
- `App/PanelController` — `.nonactivatingPanel` NSPanel hosting `RootView`. The panel takes key without activating the app, so the previous app regains focus on hide. All panel shortcuts (Esc, ⌘1/2/N/F/W, ↑/↓) are intercepted in `LittlelogPanel.sendEvent` before SwiftUI/NSTextView see them (NSTextView would swallow Esc). Hides on real focus loss (deferred `NSApp.keyWindow == nil` check) or a global outside-click monitor.
- `App/HotkeyManager` — Carbon `RegisterEventHotKey` (no Accessibility permission needed).
- `Models/Library` — `@Observable`, owns the model context, undo manager, current Day (`dayKey`/`day`, midnight/time-zone notifications) and every rule about Notes and Tasks: create/rename/move/delete (with ⌘Z), `addTasks` (dedupes, so retries are idempotent), `resolveDay`, search, saving (`save()` swallows after surfacing `errorMessage`; throwing `commit()` is for callers like ChatGPT tools that must report failure; typing saves are debounced). The panel and ChatGPT both go through it — put new Note/Task rules here, not in AppState or the tools. Autosave is disabled.
- `App/AppState` — the Panel's state only: section, open note, inline task edit, search, keyboard highlight, focus (`requestFocus(_:)` → `RootView` applies it to one `@FocusState<FocusTarget?>`). Keyboard behavior is one entry point: `perform(_ PanelCommand) -> Bool` (`false` = nothing to do, so Escape hides the panel / arrows reach the text field). `PanelController` only maps key events to commands. Library tells AppState about day rollovers and removed tasks via callbacks.
- Today filtering: tasks carry a `dateKey` (`yyyy-MM-dd` local day via `DayKey`); `AppState.dayKey` refreshes on panel show and on day/time-zone/clock-change notifications (no timers).
- `App/StatusMenuController` — menu bar item, rebuilt on every open (`menuNeedsUpdate`): open panel, assistant access, Open at Login (`SMAppService`), quit.

### ChatGPT access (MCP) — `Assistant/` and `relay/`

Web ChatGPT is the user's top priority (not Codex). ChatGPT can only reach internet servers, so `relay/` (a Cloudflare Worker + one Durable Object per Mac) forwards `https://<relay>/d/<device>/…` to the Mac over a WebSocket the app keeps open; the relay stores only a hash of the device secret. The MCP layer is written in-house (the official Swift SDK pulls in SwiftNIO etc.), to spec 2025-11-25. No local listener, no ngrok, no static tokens.
- `RelayClient` — `@MainActor`, `URLSessionWebSocketTask` to `wss://<relay>/connect` with the `DeviceIdentity` (id + secret in `Application Support/littlelog/relay-device.json`, 0600). Frames are `RelayRequestFrame`/`RelayResponseFrame` JSON (base64 bodies); requests are answered concurrently. Pings every 25 s, backoff 1→60 s, reconnects on wake. The wire format must stay in sync with `relay/src/index.ts`.
- `MCPServer` (MainActor) — owns the one route table (`Route`: metadata, register, authorize, token, mcp → method + handler; `OAuthEndpoints` supplies the sign-in handlers). Stateless Streamable HTTP: POST → one JSON-RPC message → one `application/json` reply; notifications → 202. `baseURL(for:)` builds `https://<host><x-forwarded-prefix>` and refuses requests without the relay's headers. `/mcp` requires an OAuth access token; a 401 carries `resource_metadata` so ChatGPT finds sign-in.
- OAuth (ChatGPT can't send custom headers): `OAuthEndpoints` serves RFC 9728/8414 metadata (the relay also routes path-inserted `/.well-known/<x>/d/<device>`), DCR (`/oauth/register`), `/oauth/authorize` (waits on `AccessApprovals` — Allow/Don't Allow banner in the panel, which pops open; 90 s timeout, relay waits 100 s) and `/oauth/token` (code + PKCE S256, rotating refresh). `OAuthStore` persists clients and SHA-256-hashed tokens in `Application Support/littlelog/oauth.json`.
- `AssistantTools` — each tool is one `Tool` value (name, schemas, read-only/destructive annotations, and its `run` closure); dispatch is a lookup by name, and a test calls every advertised tool. Argument/lookup/save problems return `isError: true` tool results. Notes are read-only by design.
- `AssistantAccess` — opt-in flag (`assistantAccessEnabled`), connector URL, relay URL (`relayURL` default overrides `defaultRelayURL`; plain `http` only for 127.0.0.1/localhost).
- Relay dev loop: `cd relay && npx tsc --noEmit && npx wrangler dev --port 8799 --local`, then `defaults write ~/Library/Containers/dev.littlelog.app/Data/Library/Preferences/dev.littlelog.app relayURL http://127.0.0.1:8799` and restart the app. Deploy with `npx wrangler deploy`.
- Relay wire contract: `relay/src/frames.ts` (pure) is the relay side; `RelayClient.swift`'s frames are the app side; `relay/contract/frames.json` is the shared fixture. `npm run check` (in `relay/`) tests the TS side; `RelayContractTests` (fixture bundled as a test resource) tests the Swift side. Change a frame, header allow-list or route → update the fixture and both sides.

## UI conventions

Prefer system components over custom ones — the user rejected hand-built controls as "not Apple". The panel's content is an `NSHostingController` with `sceneBridgingOptions = [.toolbars, .title]`, so SwiftUI `.toolbar`, `.searchable` and the `NavigationStack` back button become a real NSToolbar (native Liquid Glass). The panel is `.titled` + `.fullSizeContentView` with a transparent titlebar and `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`, so the glass backdrop runs under the toolbar (no dark strip). SwiftUI then only reserves the title bar height, so stack content uses `.clearsWindowToolbar()` (measures the real toolbar inset from the window). The app ships a neutral `AccentColor` so focus rings/selection are never blue. Notes is a `List(.inset)` of `NavigationLink(value: UUID)` rows (Apple Notes layout); the stack's path mirrors `state.openNote`. Today is a `ScrollView` + `LazyVStack` drawn like an inset list (separators via `RowSeparator`, reorder via `onDrag`/`TaskDropDelegate`) with Reminders-style circle toggles — never put text fields in a `List`: macOS paints an opaque black band behind them. Use system text styles (`.headline`, `.body`, `.title2`), Title Case labels, `ContentUnavailableView` for empty states. Toolbar actions go trailing via `ToolbarSpacer(.flexible)`. No grey anywhere: the user rejected the segmented control's grey pill and the List's grey selection (the panel never becomes the active app, so selection always draws in its inactive grey). So the section switch is `SectionSwitcher` — a clear glass bubble that morphs between tabs via `glassEffectID`, in a toolbar item with `.sharedBackgroundVisibility(.hidden)` — and the notes List has no selection; the arrow-key highlight is a clear-glass `listRowBackground`, set only by ↑/↓. The translucent backdrop is `PanelBackground` (`NSVisualEffectView`, `.popover`) — the user explicitly wants it kept. Scroll indicators are hidden.

The user tests UI interactions manually: don't drive the app with synthetic keystrokes (osascript/System Events).
