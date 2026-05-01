# Changelog

## [v2.0.0] — 2026-04-18

### Engineering

#### Added
- **WebSocket token routing overhaul** — replaced single shared handler with per-agent
  sessionKey dictionaries; tokens can no longer cross between agents under concurrent load
- **Chat summarization via GPT-4.1 Nano** — before a model switch, the full conversation
  is compressed into a handoff note and written to BOOTSTRAP.md; the new model reads it
  automatically on restart so context is never lost
- **Two-safety-net BOOTSTRAP.md cleanup** — stale context is cleared both at the start of
  every restart (pre-write) and again when the WebSocket handshake completes
  (gatewayDidReconnect notification), so injected context never persists across sessions
- **Three-tier avatar generation** — Gemini available and succeeds → rich mood description;
  Gemini quota exceeded or fails → keyword-based mood detection on last 3 messages; no
  Gemini key configured → silent fallback with no error shown to the user
- **ENV variable conflict detection** — API Key Manager warns when shell-level environment
  variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENCLAW_GATEWAY_TOKEN) would override
  saved values
- **Permanent model save** — model picker writes directly to openclaw.json via
  JSONSerialization; survives app restarts
- **Gateway restart on API key save** — keys take effect immediately without manual restart
- **Touch ID-gated agent delete** — two explicit gates required: biometric auth followed by
  a confirmation dialog; workspace files intentionally left on disk for recoverability
- **Dream image generation** — DALL-E 3 generates a cinematic banner for each agent dream
  entry (part of OpenClaw's nightly memory consolidation system); images persist to disk
  and are never regenerated unless deleted
- **GPT-4.1 Nano added to model picker** — cheapest available model for lightweight tasks
  and summarization
- **Handoff log** — written to agent workspace on every model switch for audit purposes

#### Changed
- **Per-agent session independence** — removed the cross-agent streaming guard and "please
  wait" banner; each agent's send button now checks only its own streaming state; correctness
  is guaranteed by sessionKey routing, not UI-level locks
- API keys moved from per-agent `auth-profiles.json` to global `~/.openclaw/.env`
- File I/O moved off the main thread
- `AgenticsCore.swift` split from 2,944 lines into focused files: `HeartbeatService.swift`,
  `MessageBubbleView.swift`, `OpenClawWebSocket.swift`, `InputBarView.swift`,
  `AgentSettingsPanel.swift`

#### Fixed
- Token stream mixing between agents under concurrent load
- Gateway restart failing due to missing PATH and HOME environment variables
- BOOTSTRAP.md not cleared after gateway restart
- Image-only message causing silent instant failure (empty text rejected by gateway with
  no error returned)
- OpenAI agents shown in image suggestion chip despite not supporting vision (known
  OpenClaw gateway bug — app-side filter applied)
- Model picker showing unsuppressable system chevron (replaced Menu with Button + popover)

---

### Testing

#### Added
- **`WebSocketManagerTests.swift`** — validates per-agent token routing; includes
  concurrent stream test (Eve and Nova receive interleaved tokens, each only gets their
  own), post-lifecycle token drop, and orphan token crash prevention
- **`KeyStoreTests.swift`** — 8 unit tests for the global `.env`-based key storage system
- **`SummaryServiceTests.swift`** — 5 unit tests for GPT-4.1 Nano summarization service;
  no network required, no real API key needed; covers empty message handling, formatting,
  file write, and file clear
- `handleFrame()` made internal to allow direct frame injection in tests without a live
  gateway

---

### UX & Product

#### Added
- AI-generated agent avatars via DALL-E 3 with per-agent DNA prompts
- Avatar history strip — last 5 generated images saved and selectable
- Star button to permanently save an avatar to disk
- Per-agent avatar generation toggle
- Animated gradient ring that pulses while an avatar is generating
- Agent sidebar now shows generated photo instead of colored initials
- Image upload — attach PNG, JPEG, GIF, HEIC, or WebP to any message
- Cost-ranked agent suggestion chip when an image is attached (Anthropic-only)
- Model picker in agent settings panel — switch models at runtime
- "Restart required" inline banner after model change with one-click gateway restart
- Gateway Token field with Touch ID reveal and random token generator
- Gemini API key field in API Key Manager
- Auto-select first agent on launch
- Frosted glass material on avatar popover
- Animated gradient plus button for image attachment

#### Changed
- Opus and GPT-5.4 removed from model picker

#### Fixed
- Dark flash on app launch before first agent was selected
- Avatar popover using solid background instead of frosted glass

---

## [v1.0.0] — Initial Commit
- Core chat interface with sidebar agent list
- WebSocket connection to OpenClaw gateway
- Heartbeat editor
- Personality Matrix (SOUL.md) editor
- Dream Diary viewer
- Agent settings panel
