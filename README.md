# Agentics

**A native macOS AI agent interface built with SwiftUI**

`Active Development` • `macOS` • `SwiftUI`

---

## Overview

Agentics is a custom macOS desktop app for managing and chatting with multiple AI agents through a polished, iMessage-style interface. It connects to a self-hosted [OpenClaw](https://openclaw.ai) gateway over WebSocket, enabling real-time streaming conversations with agents running different AI models simultaneously.

Built to go beyond what the default OpenClaw web UI offers — native, fast, and visually distinct.

## Why This Project Matters

This project focuses on real-world system behavior rather than just UI or features. It demonstrates debugging and stabilizing a real-time application where issues like race conditions, state inconsistencies, and streaming failures occur under specific timing conditions.

Key areas explored include:
- Handling asynchronous UI updates and maintaining consistent state across multiple active agents  
- Debugging race conditions in real-time streaming environments  
- Working with partially documented protocols and implementing WebSocket-based communication  
- Identifying and reproducing edge cases through repeated testing and real usage patterns  
- Thinking from a QA perspective: focusing on failure modes, reproducibility, and system reliability  

The goal was not just to build a functional app, but to understand and resolve the kinds of issues that arise in real production systems.

---

## Demo

**Streaming response with animated gradient bubbles**

<div align="center">

https://github.com/user-attachments/assets/ab7162ad-89b0-4c4f-851e-a0dd6b5e24dd
  
</div>

---

**Thinking animation — pulse speeds up while agent responds**

<div align="center">
  
https://github.com/user-attachments/assets/0d246bdc-3f59-498a-a52f-05111bd85497

</div>

---

**Settings — Personality Matrix & Heartbeat Editor**

<div align="center">

https://github.com/user-attachments/assets/eca02a0b-e990-4a22-9ce6-199ca3c000f5

</div>

---

## Agents

| Agent | Model | Role |
|-------|-------|------|
| Eve | Claude Haiku 4.5 | Daily driver |
| Nova | Claude Sonnet 4.6 | Deep technical work |
| Orion | GPT-4o-mini | Lightweight tasks |

Each agent runs in its own isolated workspace with separate memory, session history, and configuration.

---

## Engineering Highlights

- Solved concurrent streaming across multiple agents without token mixing by using a single shared WebSocket manager and controlled stream routing
- Built timing-independent scroll behavior using a sentinel-based anchoring system to reliably keep the view pinned during real-time updates
- Designed cross-agent interaction guards to prevent UI and state conflicts when multiple agents are active simultaneously
- Implemented adaptive streaming UI (typewriter + drain completion) to balance responsiveness with readability during high-frequency updates

---

## Core Features

- Streaming responses with typewriter effect (adaptive speed, drains fully on completion)
- Typing indicator ("Eve is thinking…")
- Agent sidebar with live last message preview and timestamp — updates in real time
- Cross-agent streaming guard — blocks sending to a second agent while the first is still responding
- Inline markdown rendering — bold, italic, and code formatting inside bubbles
- Large paste detection — text over 10 lines collapses into a compact pill UI
- Settings panel with heartbeat editor and Personality Matrix editor
- Personality Matrix — separate editors for Agent Soul and Agent Identity, each with undo and backup
- In-app API key manager (Agentics menu → API Keys…) — Anthropic and OpenAI keys, Touch ID to reveal masked keys, env variable conflict detection
- Chat history persisted per agent with 500 message cap
- Sentinel-based scroll anchoring — timing-independent scroll to bottom
- Text selection enabled on all chat bubbles
- Single shared WebSocket manager — prevents token stream mixing between agents

---

## UX & Polish

- iMessage-style animated gradient chat bubbles using Apple Intelligence color palette
- Thinking animation — gradient pulse speeds up while agent is responding
- Gleam effect on the latest agent message bubble
- Animated agent status dot — distinct pulse speeds for thinking and responding, solid green on idle
- Links in chat bubbles styled in pink with underline
- Bubble animations limited to last 10 messages for smooth scrolling on long conversations

---

## Technical Stack

- **Language:** Swift
- **Framework:** SwiftUI (macOS)
- **AI Providers:** Anthropic (Claude Haiku 4.5, Claude Sonnet 4.6), OpenAI (GPT-4o-mini)
- **Transport:** WebSocket (`ws://127.0.0.1:18789`)
- **Auth:** Ed25519 device signing with challenge/response handshake
- **Data:** JSON-based chat history (`CHAT.json` per agent workspace)
- **Security:** LocalAuthentication (Touch ID), CryptoKit, atomic file writes

---

## Roadmap

**Near Term**
- USER.md tab in Personality Matrix
- Council Mode — Eve spawns Nova and Orion in parallel and synthesizes their responses
- Core ML agent routing — on-device classifier suggests the best agent as you type
- Model picker dropdown
- Dynamic agent avatars — uses NaturalLanguage to analyze conversation sentiment every 8 messages and regenerates each agent's photo automatically via Apple's ImageCreator API

**Long Term**
- File attachment support
- Touch ID gating for sensitive agent file write operations
- iOS app (SwiftUI port + Tailscale for remote gateway access)
- visionOS app — spatial multi-agent interface, one floating panel per agent
- Voice input via push-to-talk

---

## Documentation

See [PORTFOLIO.md](PORTFOLIO.md) for a full technical write-up including architecture decisions, problems encountered, and lessons learned.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

