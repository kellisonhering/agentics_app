# Agentics macOS App

**Portfolio Documentation**

*Active Development • macOS • SwiftUI*

---

## Overview

Agentics is a custom macOS desktop application built to manage and interact with multiple AI agents through a polished, iMessage-style chat interface. The app connects to the OpenClaw gateway — an open-source self-hosted AI assistant platform — over WebSocket, allowing real-time streaming conversations with multiple AI agents running different models (Claude Haiku, Claude Sonnet, GPT-4o-mini).

The goal was to go beyond what the default OpenClaw web interface offers and build something that feels native, fast, and visually distinct — while demonstrating meaningful integration of multi-agent AI in a real macOS app.

## Technical Stack

- **Language:** Swift
- **Framework:** SwiftUI (macOS)
- **AI Providers:** Anthropic (Claude Haiku 4.5, Claude Sonnet 4.6), OpenAI (GPT-4o-mini)
- **Transport:** WebSocket (`ws://127.0.0.1:18789`)
- **Auth:** Ed25519 device signing with challenge/response handshake
- **Data:** JSON-based chat history (`CHAT.json` per agent workspace)
- **Security:** LocalAuthentication (Touch ID), CryptoKit, atomic file writes

## Agents

The app manages three persistent AI agents, each with a distinct role and model. Each agent runs in its own isolated workspace with separate memory, session history, and configuration. Heartbeat intervals are user-configurable directly within the app.

| Agent | Model | Role | Heartbeat |
|-------|-------|------|-----------|
| Eve | Claude Haiku 4.5 | Daily driver | User-defined |
| Nova | Claude Sonnet 4.6 | Deep technical work | User-defined |
| Orion | GPT-4o-mini | Lightweight tasks | User-defined |

## Features Built

### Core Chat & Streaming

Agent sidebar with live last message preview and timestamp — updates in real time after each message. iMessage-style animated gradient chat bubbles using Apple Intelligence color palette. Streaming responses with typewriter effect with adaptive speed and full buffer drain on completion. Typing indicator showing agent name while thinking. Inline markdown rendering — bold, italic, and code formatting displayed correctly in bubbles. Text selection enabled on all chat bubbles. Large paste detection — text over 10 lines collapses into a compact pill UI rather than filling the input field. Links in chat bubbles are styled in pink with underline for visual distinction.

### Agent Status & Animations

Animated agent status dot with gradient pulse animation matching bubble colors, with distinct speeds for thinking (slow pulse) and responding (fast pulse), transitioning to solid green on idle. Thinking animation — gradient pulse speeds up while agent is responding. Gleam effect on the latest agent message bubble. Bubble animations limited to the 10 most recent messages for smooth scrolling performance on long conversations.

### Settings & Configuration

Settings panel (collapsible, right edge) with Heartbeat editor and Personality Matrix editor. Heartbeat editor — 8-button grid, highlights current setting, saves to `openclaw.json`. Personality Matrix panel with separate editors for Agent Soul (`SOUL.md`) and Agent Identity (`IDENTITY.md`) — each with undo/backup support. In-app API key manager accessible from the Agentics menu bar — supports Anthropic and OpenAI keys, writes to each agent's `auth-profiles.json`, includes Touch ID reveal for masked key fields, and detects shell environment variable conflicts that could override saved keys.

### Architecture & Reliability

Single shared WebSocket manager across all agents — prevents token stream mixing between agent sessions. Streaming state (`isStreaming`) stored in `AppState` as a `Set<String>` — persists correctly across agent switches without resetting. Cross-agent streaming guard — if one agent is responding and you switch to another, a banner shows above the input bar and sending is blocked until the stream completes. Flexible JSON decoder — handles both string and object model field shapes from `openclaw.json`. Agent names auto-capitalized from config regardless of how they are stored in the gateway. Chat history persisted to `CHAT.json` per agent (500 message cap). History loaded on app launch, sidebar reflects last message. Scroll to bottom on conversation load and new messages (sentinel-based, timing-independent).

## Key Engineering Decisions

### 1. Transport Architecture: HTTP → WebSocket

**Decision:** Migrate from HTTP to WebSocket for all agent communication.

**Why:** HTTP required sending the full conversation history with every message, burning through API quota at roughly 100k tokens per request. Beyond cost, it made real-time streaming impossible — each request was a discrete round-trip with no way to receive incremental token output.

**Tradeoff:** WebSocket introduced a stateful connection requiring a full challenge/response handshake using Ed25519 signing. The gateway protocol was partially documented, so the implementation required direct inspection of gateway behavior: receive `connect.challenge` with nonce, sign a v2 payload, send a connect request with base64url-encoded public key and signature, then route chat messages using `sessionKey` and `idempotencyKey`.

**Result:** Token usage dropped dramatically. Real-time streaming became possible, enabling the typewriter effect and live status updates that define the app's feel.

### 2. Multi-Agent Stream Routing

**Decision:** Replace per-agent WebSocket instances with a single shared manager.

**Why:** An early implementation maintained a dictionary of per-agent WebSocket connections. With multiple agents connected simultaneously, incoming token events were occasionally delivered to the wrong agent's handler — mixing responses between conversations in ways that were difficult to reproduce and debug.

**Tradeoff:** A single shared connection means only one `pendingTokenHandler` is active at a time, keyed to the most recently sent message. This serializes token routing but sacrifices true parallelism — a worthwhile tradeoff given that the gateway itself processes one agent session at a time.

**Result:** Token streams are always routed to the correct conversation. The failure mode (wrong agent receiving tokens) is eliminated entirely.

### 3. Global State Management Across Agent Switches

**Decision:** Move streaming state out of local view state and into a shared `AppState` `ObservableObject`.

**Why:** The `isStreaming` flag lived inside `InputBarView` as `@State`. When the user switched agents mid-stream, SwiftUI rebuilt `InputBarView` for the new agent, resetting `isStreaming` to false and re-enabling the input bar while a response was still arriving. A related issue: the model field in `openclaw.json` was sometimes stored as a plain string and sometimes as an object depending on which CLI command created the config. Swift's `Codable` failed silently, causing the entire agent list to fall back to a single hardcoded entry.

**Tradeoff:** Centralizing state in `AppState` increases coupling between views and the app state layer. In SwiftUI this is the correct tradeoff — state that must survive view rebuilds cannot live inside a view.

**Result:** Streaming state persists correctly across agent switches. Config loading handles both field shapes via a custom `AgentModelField` enum with a flexible `init(from:)` decoder.

### 4. Authentication & Environment Conflicts

**Decision:** Build active environment variable conflict detection into the in-app API key manager.

**Why:** Two auth failures had the same root: a gap between where keys are stored and where the gateway reads them. In one case, a corrupted `auth-profiles.json` caused Orion to silently fall back to Claude Sonnet. In another, a valid key in `auth-profiles.json` was being overridden by a stale `OPENAI_API_KEY` in `~/.zshrc` — causing persistent 401 errors with no obvious cause from the app's side.

**Tradeoff:** Detecting shell environment variables from a sandboxed macOS app requires reading the process environment at launch. This only reflects variables inherited at app start, so conflicts added after launch won't be caught until next open.

**Result:** The API key manager shows an orange warning badge next to any provider where an environment variable override is active, surfacing the conflict before it causes a confusing auth failure.

### 5. Scroll Position Under Async Layout

**Problem:** Calling `scrollTo` with a message ID caused the view to land mid-history on long conversations. SwiftUI's `LazyVStack` measures cells incrementally, so scroll targets aren't reliably addressable before layout completes. Switching agents also caused a brief flicker — the conversation appeared empty for a frame because SwiftUI reused the same view instance.

**Fix:** Replaced ID-based `scrollTo` with a zero-height sentinel view at the bottom of the list. Scrolling to the sentinel has no dependency on cell layout timing. Added `.id(agent.id)` to `ChatView` so SwiftUI treats each agent's conversation as a fully separate instance, eliminating the flicker.

**Result:** Scroll position is correct on load, agent switch, and new message arrival — regardless of layout timing.

### 6. Animation Reliability Under Rapid State Transitions

**Problem:** The agent status dot would intermittently stop animating when transitioning from idle to thinking — remaining stuck solid green even while a response was streaming. Once stuck, it wouldn't recover until the app relaunched or the user switched agents. Root cause: SwiftUI's `repeatForever` animation engine silently drops state during rapid transitions.

**Fix:** Added `.id(agent.status)` at both dot call sites (sidebar and chat header). This forces SwiftUI to fully recreate the view on each status change, which guarantees `onAppear` fires fresh and the animation restarts cleanly.

**Result:** Status dot animates correctly on every transition with no stuck states.

### 7. Large Paste Freezing the Input Bar

Pasting large blocks of text — the full app source at 76,000+ characters being the extreme case — froze the app completely. SwiftUI's `TextField` with `axis: .vertical` re-measures and re-lays out on every character insertion during a paste, making it O(n) in layout passes for large inputs. The fix intercepts the paste in `onChange` before SwiftUI can process it: anything over 10 lines is captured into a separate state variable and the `TextField` is cleared immediately. A compact pill UI appears above the input bar showing the line count. The agent receives the full content on send; the conversation history shows only the pill.

## What This Project Demonstrates

- **Real-world WebSocket client implementation:** Including custom Ed25519 auth handshake and streaming event handling.
- **Multi-agent AI architecture:** Per-agent model selection, session isolation, and persistent memory across separate workspaces.
- **Native macOS SwiftUI development:** Custom animations, adaptive UI, system framework integration (LocalAuthentication, CryptoKit, Security).
- **Practical problem-solving:** API token efficiency, authentication debugging, scroll timing bugs, animation reliability, and agent security.
- **Understanding of OpenClaw's gateway architecture:** Workspace files, session keys, heartbeat cron, agent auth profiles, and multi-agent routing.
- **Security-conscious design:** Touch ID gating for sensitive credential reveal, environment variable conflict detection, atomic file writes to prevent data corruption.
- **Ability to work with undocumented protocols:** Reading source code and gateway behavior to implement correct frame formats and event handling.
- **Forward-thinking product design:** Planning iOS, visionOS, Council Mode, and Liquid Glass on a shared codebase.

## Engineering Principles Learned

- **Streaming requires stateful transport.** Request/response protocols are fundamentally incompatible with real-time token streaming. WebSocket isn't just a performance optimization — it's an architectural requirement for any system that needs to deliver incremental output as it's generated.
- **Shared mutable state must have a single owner.** In reactive UI frameworks, state that needs to survive view rebuilds belongs in a dedicated state object — not inside views themselves. Views are ephemeral; state is not. Violating this produces bugs that only surface under specific interaction sequences.
- **Silent failures in distributed systems require active visibility.** Auth errors, config mismatches, and environment conflicts don't announce themselves — they produce confusing downstream symptoms. The right fix isn't better error messages; it's surfacing the conflict at the point where the user can act on it.
- **Human-in-the-loop controls are essential in autonomous agent systems.** When agents can modify their own configuration, the system needs explicit approval boundaries — not just trust. Security and stability in multi-agent systems require the same discipline as distributed systems: define boundaries, enforce them explicitly, and never assume good intent from any automated process.

## Planned Features

### Near Term

- **USER.md tab in Personality Matrix:** Panel already supports Agent Soul (`SOUL.md`) and Agent Identity (`IDENTITY.md`) as separate editors. `USER.md` tab planned next.
- **Council Mode:** Eve spawns Nova and Orion in parallel as subagents and synthesizes their responses; each agent loads their own workspace personality files.
- **Core ML agent routing:** On-device classifier suggests the best agent for each message as a dismissible chip above the input bar.
- **Model picker dropdown:** Using `models.list` WebSocket RPC to populate available models dynamically per agent.
- **Dynamic agent avatars:** Uses NaturalLanguage to analyze conversation sentiment every 8 messages and regenerates each agent's photo automatically via Apple's ImageCreator API.

### Long Term

- **File attachment support:** Via `chat.send` attachments field (OpenClaw gateway already supports the protocol; UI not yet built).
- **Touch ID gating for sensitive file write operations:** Foundation already built for API key reveal; extending to agent workspace file writes.
- **iOS app:** SwiftUI port, same WebSocket protocol, Tailscale for remote gateway access.
- **visionOS app:** Spatial multi-agent interface, one floating panel per agent.
- **Voice input:** Push-to-talk in input bar.
