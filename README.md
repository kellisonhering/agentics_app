# Agentics

**A native macOS AI agent interface built with SwiftUI**

`Active Development` • `macOS` • `SwiftUI` • `Single-File Architecture`

---

## Overview

Agentics is a custom macOS desktop app for managing and chatting with multiple AI agents through a polished, iMessage-style interface. It connects to a self-hosted [OpenClaw](https://openclaw.ai) gateway over WebSocket, enabling real-time streaming conversations with agents running different AI models simultaneously.

Built to go beyond what the default OpenClaw web UI offers — native, fast, and visually distinct.

---

## Demo

**Streaming response with animated gradient bubbles**
> *GIF placeholder — replace with demo.gif*

![Streaming response demo](assets/streaming.gif)

---

**Thinking animation — pulse speeds up while agent responds**
> *GIF placeholder — replace with thinking.gif*

![Thinking animation demo](assets/thinking.gif)

---

**Agent sidebar with last message preview**
> *GIF placeholder — replace with sidebar.gif*

![Sidebar demo](assets/sidebar.gif)

---

## Agents

| Agent | Model | Role |
|-------|-------|------|
| Eve | Claude Haiku 4.5 | Daily driver |
| Nova | Claude Sonnet 4.6 | Deep technical work |
| Orion | GPT-4o-mini | Lightweight tasks |

Each agent runs in its own isolated workspace with separate memory, session history, and configuration.

---

## Features

- iMessage-style animated gradient chat bubbles using Apple Intelligence color palette
- Thinking animation — gradient pulse speeds up while agent is responding
- Gleam effect on the latest agent message bubble
- Streaming responses with typewriter effect (adaptive speed, drains fully on completion)
- Typing indicator ("Eve is thinking…")
- Agent sidebar with last message preview and timestamp
- Inline markdown rendering — bold, italic, and code formatting inside bubbles
- Large paste detection — text over 10 lines collapses into a compact pill UI
- Settings panel with heartbeat editor and personality matrix editor
- Chat history persisted per agent with 500 message cap
- Sentinel-based scroll anchoring — timing-independent scroll to bottom
- Text selection enabled on all chat bubbles
- Single shared WebSocket manager — prevents token stream mixing between agents

---

## Technical Stack

- **Language:** Swift
- **Framework:** SwiftUI (macOS)
- **Architecture:** Single-file app (`AgenticsApp.swift`)
- **AI Providers:** Anthropic (Claude Haiku 4.5, Claude Sonnet 4.6), OpenAI (GPT-4o-mini)
- **Transport:** WebSocket (`ws://127.0.0.1:18789`)
- **Auth:** Ed25519 device signing with challenge/response handshake
- **Data:** JSON-based chat history (`CHAT.json` per agent workspace)

---

## Roadmap

**Near Term**
- Council Mode — Eve spawns Nova and Orion in parallel and synthesizes their responses
- Core ML agent routing — on-device classifier suggests the best agent as you type
- Touch ID gating for sensitive agent file operations
- File attachment support

**Long Term**
- iOS app (SwiftUI port + Tailscale for remote gateway access)
- visionOS app — spatial multi-agent interface, one floating panel per agent
- Voice input via push-to-talk

---

## Documentation

See [PORTFOLIO.md](PORTFOLIO.md) for a full technical write-up including architecture decisions, problems encountered, and lessons learned.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

