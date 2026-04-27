# Agentics macOS App

**Portfolio Documentation**

*Active Development • macOS • SwiftUI*

---

## Overview

Agentics is a custom macOS desktop application for managing and interacting with multiple AI agents through a polished, iMessage-style chat interface. It connects to the OpenClaw gateway over WebSocket, enabling real-time streaming conversations with multiple agents running different AI models simultaneously.

v2 shifted focus from feature building to system reliability: diagnosing and fixing real concurrency bugs, building context preservation across model switches, and adding a test suite that validates behavior the UI can't surface on its own.

---

## Impact Statement

This project demonstrates the ability to diagnose and fix concurrency bugs in real-time multi-agent systems, design fault-tolerant client architectures that survive partial failures, and apply QA thinking to a production-style codebase — not just consume APIs. Every major system was built with failure modes in mind: what breaks silently, what recovers automatically, and what requires explicit human approval.

---

## Engineering Highlights

- Diagnosed and fixed a real token stream mixing bug under concurrent agent load — tokens from Eve's response were landing in Orion's chat bubble due to a shared mutable handler being overwritten; token corruption is now impossible by design
- Replaced the single handler with sessionKey-keyed dictionaries so each agent's token routing is isolated by key, not by timing — deterministic routing under any load
- Built a two-safety-net BOOTSTRAP.md cleanup strategy ensuring stale context never persists across model switches — cleared at restart start and again on WebSocket reconnect, eliminating an entire class of context bleed bugs
- Designed a state model resilient to SwiftUI view rebuilds by moving all streaming state into a shared `AppState` object — streaming behavior now survives agent switches correctly
- Caught and fixed silent false positives in the test suite — tests were passing on empty results because the frame format was wrong and no tokens were being delivered at all; the test infrastructure itself required debugging before the feature could be considered verified
- Implemented fault-tolerant context preservation using GPT-4.1 Nano summarization before model switches — new model always starts with full conversation history regardless of how long the previous session was
- Implemented the WebSocket auth handshake and token routing by reading gateway behavior directly — the protocol was partially undocumented, requiring inspection of raw frames to determine correct field names, signing format, and event sequencing

---

## What This Project Demonstrates

- **Real-world WebSocket client implementation:** Custom Ed25519 auth handshake, streaming event handling, and sessionKey-based token routing against a partially undocumented protocol
- **Concurrency debugging:** Diagnosing and fixing a real token stream mixing bug caused by a shared mutable handler under concurrent agent load
- **Multi-agent AI architecture:** Per-agent model selection, session isolation, context preservation across model switches, and persistent memory across separate workspaces
- **Resilient system design:** Two-safety-net cleanup strategy, three-tier avatar generation fallback, and gateway restart handling that survives partial failures
- **QA thinking applied to a real system:** Writing tests that catch silent false positives, validating behavior under concurrent load, and identifying failure modes the UI can't surface
- **Native macOS SwiftUI development:** Custom animations, adaptive UI, system framework integration (LocalAuthentication, CryptoKit, Security)
- **Security-conscious design:** Touch ID gating for credential reveal and agent deletion, environment variable conflict detection, atomic file writes to prevent data corruption
- **Ability to work with undocumented protocols:** Reading raw gateway behavior to determine correct frame formats, routing keys, signing requirements, and event sequencing — no SDK, no reference implementation

---

## Technical Stack

- **Language:** Swift
- **Framework:** SwiftUI (macOS)
- **AI Providers:** Anthropic (Claude Haiku 4.5, Claude Sonnet 4.6), OpenAI (GPT-4o-mini, GPT-4.1 Nano), Google (Gemini — mood detection and avatar description)
- **Image Generation:** DALL-E 3 (agent avatars, dream entry banners)
- **Transport:** WebSocket (`ws://127.0.0.1:18789`)
- **Auth:** Ed25519 device signing with challenge/response handshake
- **Data:** JSON-based chat history per agent workspace
- **Security:** LocalAuthentication (Touch ID), CryptoKit, atomic file writes
- **Testing:** XCTest

---

## Agents

The app manages three persistent AI agents, each with a distinct role. Each agent runs in its own isolated workspace with separate memory, session history, personality configuration, and generated avatar. Models can be switched at runtime via the in-app model picker — changes persist to `openclaw.json` and take effect after a gateway restart.

| Agent | Default Model | Role | Heartbeat |
|-------|--------------|------|-----------|
| Eve | Claude Haiku 4.5 | Daily driver | User-defined |
| Nova | Claude Sonnet 4.6 | Deep technical work | User-defined |
| Orion | GPT-4o-mini | Lightweight tasks | User-defined |

---

## Features Built

### Core Systems

**WebSocket token routing** — per-agent sessionKey dictionaries ensure tokens are delivered to the correct agent regardless of concurrent load. Stream completion is signaled by `lifecycle:end` with `chat:final` as a guaranteed fallback so no agent ever gets stuck.

**Chat context preservation on model switch** — before a gateway restart, GPT-4.1 Nano summarizes the full conversation and writes it to `BOOTSTRAP.md`. OpenClaw loads this file automatically at session start. Two independent safety nets ensure stale content never persists across sessions.

**API Key Manager** — manages Anthropic, OpenAI, and Gemini keys in a single shared `~/.openclaw/.env`. Detects shell environment variable conflicts that would silently override saved values. Gateway token field with Touch ID reveal and random token generator. Saving keys restarts the gateway automatically.

**Model picker** — switches agent models at runtime, writes directly to `openclaw.json` via `JSONSerialization`, persists across restarts. Inline restart banner with one-click gateway restart via `Process()` on a background thread.

**Image upload** — `NSOpenPanel` filtered to PNG, JPEG, GIF, HEIC, and WebP with a 5MB size limit. Cost-ranked agent suggestion chip filters to Anthropic-only agents when an image is attached — OpenAI agents are hidden due to a confirmed gateway bug in the attachment conversion layer.

**Touch ID-gated agent delete** — two explicit gates: biometric auth followed by a confirmation dialog. Workspace files are intentionally left on disk so the operation is recoverable.

**Dream Diary** — parses `DREAMS.md` generated by OpenClaw's nightly memory consolidation system. Optional DALL-E 3 cinematic banner per entry. Images are indexed (`dream-YYYY-MM-DD-{index}.png`) so multiple dreams on the same night each get their own image.

**Three-tier avatar generation** — Gemini available → rich mood description; Gemini quota exceeded → keyword-based mood detection on last 3 messages; no Gemini key → silent fallback. Each tier degrades gracefully with no errors surfaced when unnecessary.

**Code organization** — `AgenticsCore.swift` was split from 2,944 lines into focused, single-responsibility files (`HeartbeatService.swift`, `MessageBubbleView.swift`, `OpenClawWebSocket.swift`, `InputBarView.swift`, `AgentSettingsPanel.swift`). Each file has a clear ownership boundary and can be read independently.

---

### Chat & UI

Agent sidebar with live last message preview and timestamp. iMessage-style animated gradient chat bubbles. Streaming responses with typewriter effect and adaptive speed. Inline markdown rendering — bold, italic, code. Text selection on all chat bubbles. Large paste detection — text over 10 lines collapses into a compact pill. Animated agent status dot with distinct speeds for thinking and responding. Bubble animations limited to the 10 most recent messages for scroll performance. AI-generated agent avatars via DALL-E 3 with per-agent DNA prompts, history strip, and permanent save option.

---

## Key Engineering Decisions

### 1. Transport Architecture: HTTP → WebSocket

**Decision:** Migrate from HTTP to WebSocket for all agent communication.

**Why:** HTTP required sending the full conversation history with every message, burning through API quota at roughly 100k tokens per request. Beyond cost, it made real-time streaming impossible — each request was a discrete round-trip with no way to receive incremental token output.

**Tradeoff:** WebSocket introduced a stateful connection requiring a full challenge/response handshake using Ed25519 signing. The gateway protocol was partially documented, so the implementation required direct inspection of gateway behavior: receive `connect.challenge` with nonce, sign a v2 payload, send a connect request with base64url-encoded public key and signature, then route chat messages using `sessionKey` and `idempotencyKey`.

**Result:** Token usage dropped dramatically. Real-time streaming became possible, enabling the typewriter effect and live status updates that define the app's feel.

---

### 2. WebSocket Token Routing — Diagnosing and Fixing a Real Concurrency Bug

**The bug:** Under concurrent load — Eve and Orion both active — tokens from one agent's response would land in the other agent's chat bubble. The bug was intermittent, timing-dependent, and difficult to reproduce consistently.

**Root cause:** The WebSocket manager used a single `pendingTokenHandler` slot. When a second agent sent a message before the first finished streaming, the new handler overwrote the old one. Remaining tokens from the first agent were then delivered to the second agent's UI.

**How it was found:** A debug print added to `handleFrame` revealed the gateway was already sending a `sessionKey` (e.g. `agent:eve:main`) and `runId` in every token event. The routing data was always there — the app just wasn't using it.

**Fix:** Replaced the single handler with three dictionaries keyed by `sessionKey`:
- `tokenHandlers: [String: TokenHandler]` — delivers tokens to the correct agent
- `errorHandlers: [String: ErrorHandler]` — routes errors the same way
- `runToSession: [String: String]` — maps `runId` to `sessionKey` for lifecycle cleanup

Stream completion is signaled by `lifecycle:end` (primary) with `chat:final` as a guaranteed fallback. If `lifecycle:end` never arrives, `chat:final` completes the stream so no agent gets stuck.

**Result:** Token stream mixing is eliminated by design. Each agent's handler lives under its own key — a second agent registering a handler cannot affect the first.

---

### 3. Global State Management Across Agent Switches

**Decision:** Move streaming state out of local view state and into a shared `AppState` `ObservableObject`.

**Why:** The `isStreaming` flag lived inside `InputBarView` as `@State`. When the user switched agents mid-stream, SwiftUI rebuilt `InputBarView` for the new agent, resetting `isStreaming` to false and re-enabling the input bar while a response was still arriving. A related issue: the model field in `openclaw.json` was sometimes stored as a plain string and sometimes as an object depending on which CLI command created the config. Swift's `Codable` failed silently, causing the entire agent list to fall back to a single hardcoded entry.

**Tradeoff:** Centralizing state in `AppState` increases coupling between views and the app state layer. In SwiftUI this is the correct tradeoff — state that must survive view rebuilds cannot live inside views.

**Result:** Streaming state persists correctly across agent switches. Config loading handles both field shapes via a custom `AgentModelField` enum with a flexible `init(from:)` decoder.

---

### 4. Authentication & Environment Conflicts

**Decision:** Build active environment variable conflict detection into the in-app API key manager.

**Why:** Two auth failures had the same root: a gap between where keys are stored and where the gateway reads them. In one case, a corrupted `auth-profiles.json` caused Orion to silently fall back to Claude Sonnet. In another, a valid key in `auth-profiles.json` was being overridden by a stale `OPENAI_API_KEY` in `~/.zshrc` — causing persistent 401 errors with no obvious cause from the app's side.

**Tradeoff:** Detecting shell environment variables from a sandboxed macOS app requires reading the process environment at launch. This only reflects variables inherited at app start, so conflicts added after launch won't be caught until next open.

**Result:** The API key manager shows an orange warning badge next to any provider where an environment variable override is active, surfacing the conflict before it causes a confusing auth failure.

---

### 5. Scroll Position Under Async Layout

**Problem:** Calling `scrollTo` with a message ID caused the view to land mid-history on long conversations. SwiftUI's `LazyVStack` measures cells incrementally, so scroll targets aren't reliably addressable before layout completes. Switching agents also caused a brief flicker — the conversation appeared empty for a frame because SwiftUI reused the same view instance.

**Fix:** Replaced ID-based `scrollTo` with a zero-height sentinel view at the bottom of the list. Scrolling to the sentinel has no dependency on cell layout timing. Added `.id(agent.id)` to `ChatView` so SwiftUI treats each agent's conversation as a fully separate instance, eliminating the flicker.

**Result:** Scroll position is correct on load, agent switch, and new message arrival — regardless of layout timing.

---

### 6. Animation Reliability Under Rapid State Transitions

**Problem:** The agent status dot would intermittently stop animating when transitioning from idle to thinking — remaining stuck solid green even while a response was streaming. Once stuck, it wouldn't recover until the app relaunched or the user switched agents. Root cause: SwiftUI's `repeatForever` animation engine silently drops state during rapid transitions.

**Fix:** Added `.id(agent.status)` at both dot call sites (sidebar and chat header). This forces SwiftUI to fully recreate the view on each status change, which guarantees `onAppear` fires fresh and the animation restarts cleanly.

**Result:** Status dot animates correctly on every transition with no stuck states.

---

### 7. Large Paste Freezing the Input Bar

Pasting large blocks of text — the full app source at 76,000+ characters being the extreme case — froze the app completely. SwiftUI's `TextField` with `axis: .vertical` re-measures and re-lays out on every character insertion during a paste, making it O(n) in layout passes for large inputs. The fix intercepts the paste in `onChange` before SwiftUI can process it: anything over 10 lines is captured into a separate state variable and the `TextField` is cleared immediately. A compact pill UI appears above the input bar showing the line count. The agent receives the full content on send; the conversation history shows only the pill.

---

### 8. BOOTSTRAP.md Context Injection — Surviving Model Switches

**Problem:** OpenClaw locks each session to the model active when it was created. Switching models requires a gateway restart and starts a completely blank session — the new model has no knowledge of what was discussed before.

**Design:** Before restarting, GPT-4.1 Nano summarizes the full chat history into a structured handoff note. The note is written to `BOOTSTRAP.md` in the agent's workspace. OpenClaw loads `BOOTSTRAP.md` automatically at session start, so the new model begins with context immediately.

**Cleanup problem:** The first implementation placed the `clearBootstrapMD()` call after the restart `Process()` exited. The gateway shutdown event closes the WebSocket before the process exits cleanly, so the clear sometimes never ran — leaving stale context on disk for future restarts.

**Fix:** Two independent safety nets:
- **Option A:** Clear `BOOTSTRAP.md` at the very start of `restartGateway()` before writing new content — removes any stale content from a previous run
- **Option B:** `AppState.init()` observes a `gatewayDidReconnect` notification posted when the WebSocket handshake completes — clears `BOOTSTRAP.md` for all agents the moment the new session is live

**Result:** Context is preserved across model switches. Stale content has two independent opportunities to be cleared before it could affect a future session.

---

## Testing

Unit tests cover the systems most likely to fail silently or under concurrent load — not just the happy path.

### WebSocket Token Routing (`WebSocketManagerTests.swift`)

The original tests were feeding frames without `sessionKey` or `runId`, so every handler lookup found nothing and tests passed on empty results rather than real token delivery — silent false positives. This was caught and fixed before the routing fix was considered complete.

After fixing the test helpers to match the real gateway frame format:
- Single agent token delivery
- Concurrent streams — Eve and Nova receive interleaved tokens, each only gets their own
- Tokens arriving after `lifecycle:end` are silently dropped
- Orphan tokens with no registered handler do not crash

### Global Key Storage (`KeyStoreTests.swift`)

8 unit tests for the `.env`-based key storage system.

### Chat Summarization (`SummaryServiceTests.swift`)

5 unit tests — no network required, no real API key needed:
- Returns nil safely when no OpenAI key is configured
- Conversation formatted correctly as `User:` / `AgentName:` pairs
- `writeBootstrapMD()` produces correct file content
- `clearBootstrapMD()` produces an empty file
- No crash when called with zero messages

All tests operate without a live gateway connection.

---

## Engineering Principles Learned

*These aren't general programming advice — they're specific lessons that came from hitting real failures in this system and having to reason through why they happened.*

- **Streaming requires stateful transport.** Request/response protocols are fundamentally incompatible with real-time token streaming. WebSocket isn't just a performance optimization — it's an architectural requirement for any system that needs to deliver incremental output as it's generated.
- **Shared mutable state must have a single owner.** In reactive UI frameworks, state that must survive view rebuilds belongs in a dedicated state object — not inside views themselves. Views are ephemeral; state is not. Violating this produces bugs that only surface under specific interaction sequences.
- **Silent failures in distributed systems require active visibility.** Auth errors, config mismatches, and environment conflicts don't announce themselves — they produce confusing downstream symptoms. The right fix isn't better error messages; it's surfacing the conflict at the point where the user can act on it.
- **Tests that pass on empty results are worse than no tests.** A test suite that silently validates nothing gives false confidence. The routing tests were passing before the fix — but only because the frame format was wrong and no tokens were being delivered at all. Validating the test infrastructure is as important as validating the feature.
- **Human-in-the-loop controls are essential in autonomous agent systems.** When agents can modify their own configuration, the system needs explicit approval boundaries — not just trust. Security and stability in multi-agent systems require the same discipline as distributed systems: define boundaries, enforce them explicitly, and never assume good intent from any automated process.

---

## Roadmap

### v3 — Planned

- **Per-agent WebSocket connections** — each agent gets its own dedicated connection for true parallel streaming
- **Council Mode** — Eve orchestrates Nova and Orion in parallel and synthesizes their responses into one reply; depends on per-agent connections being built first
- **Quantum Research Agent** — IBM Quantum MCP integration for running circuits on real hardware and collecting simulator vs hardware divergence data
- **Agent creation flow** — full redesign with AI-generated interview questions and animated hatching screen

### Future

- **iOS app:** SwiftUI port, same WebSocket protocol, Tailscale for remote gateway access
- **visionOS app:** Spatial multi-agent interface, one floating panel per agent
- **Voice input:** Push-to-talk in input bar
- **HomeKit AI agent (Harmony):** Proactive smart home concierge with camera analysis and nightly memory consolidation
