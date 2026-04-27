# Agentics

**A native macOS AI agent interface built with SwiftUI**

`Active Development` • `macOS` • `SwiftUI`

---

## Overview

Agentics is a native macOS application for running and managing multiple AI agents 
simultaneously over a real-time WebSocket connection. It solves the concurrency and 
streaming challenges that arise when multiple agents are active at once: token routing, 
state isolation, and context preservation across model switches, wrapped in a polished, 
iMessage-style interface.

Connects to a self-hosted [OpenClaw](https://openclaw.ai) gateway. Built to go beyond 
what the default OpenClaw web UI offers: native, fast, and visually distinct.

---

## Why This Project Matters

This project focuses on real-world system behavior rather than just UI or features. It 
demonstrates debugging and stabilizing a real-time application where issues like race 
conditions, state inconsistencies, and streaming failures occur under specific timing 
conditions.

Key areas explored include:
- Handling asynchronous UI updates and maintaining consistent state across multiple active 
  agents
- Debugging race conditions in real-time streaming environments
- Working with partially documented protocols and implementing WebSocket-based communication
- Identifying and reproducing edge cases through repeated testing and real usage patterns
- Thinking from a QA perspective: focusing on failure modes, reproducibility, and system 
  reliability

The goal was not just to build a functional app, but to understand and resolve the kinds 
of issues that arise in real production systems.

---

## Requirements

Agentics connects to a self-hosted [OpenClaw](https://openclaw.ai) gateway via WebSocket.

To run the full app experience, you will need:
- OpenClaw installed and running
- A valid gateway token configured for the OpenClaw gateway

Without the gateway, the UI can still be explored, but agent responses will not function.

---

## Demo

**Dream Diary**

*A native macOS AI agent system with memory consolidation and personality-driven agents. Features a "Dream Diary" that transforms interaction history into reflective narratives.*

[screenshot]

---

**AI-generated agent avatars**

*AI-generated agent portraits that update based on mood. Each agent has a unique visual identity that evolves with the conversation.*

[screenshot]

---

## Agents

| Agent | Default Model | Role |
|-------|--------------|------|
| Eve | Claude Haiku 4.5 | Daily driver |
| Nova | Claude Sonnet 4.6 | Deep technical work |
| Orion | GPT-4o-mini | Lightweight tasks |

Each agent runs in its own isolated workspace with separate memory, session history, 
personality configuration, and generated avatar. Models can be switched at runtime via 
the in-app model picker.

---

## Engineering Highlights

- Built a chat summarization and context injection system using GPT-4.1 Nano: 
  before every model switch, the full conversation is compressed into a structured 
  handoff note and written to BOOTSTRAP.md; the new model reads it automatically on 
  restart so context is never lost, even across completely different AI providers
- Replaced a single shared WebSocket handler with per-agent sessionKey dictionaries, 
  eliminating token stream mixing between agents under concurrent load
- Designed a two-safety-net BOOTSTRAP.md cleanup strategy to ensure stale context never 
  persists across sessions, cleared at restart start and again on WebSocket reconnect
- Established concurrent streaming across multiple agents using a shared WebSocket manager 
  with sessionKey-based routing for correct token isolation per agent
- Built a scroll system that stays anchored during asynchronous layout updates, 
  eliminating mid-conversation jumps caused by SwiftUI's incremental rendering
- Implemented adaptive streaming UI (typewriter + drain completion) to balance 
  responsiveness with readability during high-frequency updates

---

## Testing

Unit tests cover the core systems most likely to fail silently or under concurrent load:

**WebSocket token routing** (`WebSocketManagerTests.swift`)
- Single agent token delivery
- Concurrent streams — Eve and Nova receive interleaved tokens, each only gets their own
- Tokens arriving after `lifecycle:end` are silently dropped
- Orphan tokens with no registered handler do not crash

**Global key storage** (`KeyStoreTests.swift`)
- 8 unit tests for the `.env`-based key storage system

**Chat summarization** (`SummaryServiceTests.swift`)
- 5 unit tests — no network required, no real API key needed
- Covers empty message handling, conversation formatting, file write, and file clear

All tests operate without a live gateway connection.

---

## Core Features

**AI & Agents**
- AI-generated agent avatars via DALL-E 3 with per-agent DNA prompts and history strip
- Image upload — attach PNG, JPEG, GIF, HEIC, or WebP with cost-ranked agent suggestion
- Model picker — switch agent models at runtime, persisted to openclaw.json
- Chat context preserved on model switch via GPT-4.1 Nano summarization and BOOTSTRAP.md
- Dream Diary — visualizes agent dreams generated by OpenClaw's nightly memory 
  consolidation system, with optional DALL-E 3 cinematic banners per entry
- Streaming responses with typewriter effect (adaptive speed, drains fully on completion)
- Typing indicator ("Eve is thinking…")

**System**
- Touch ID-gated agent delete with confirmation dialog
- In-app API Key Manager — Anthropic, OpenAI, Gemini keys with Touch ID reveal and ENV 
  conflict warnings
- Heartbeat editor with gateway restart on save
- Personality Matrix — separate editors for Agent Soul and Agent Identity with undo and 
  backup
- Chat history persisted per agent with 500 message cap
- Scroll system stays anchored during asynchronous layout updates, eliminating 
  mid-conversation jumps caused by SwiftUI's incremental rendering
- Atomic file writes throughout

**UX**
- Agent sidebar with live last message preview and timestamp — updates in real time
- Inline markdown rendering — bold, italic, and code formatting inside bubbles
- Large paste detection — text over 10 lines collapses into a compact pill UI
- Text selection enabled on all chat bubbles
- Auto-selects first agent on launch — no dark flash on startup

---

## UX & Polish

- iMessage-style animated gradient chat bubbles using Apple Intelligence color palette
- Thinking animation — gradient pulse speeds up while agent is responding
- Gleam effect on the latest agent message bubble
- Animated agent status dot — distinct pulse speeds for thinking and responding
- Frosted glass avatar popover with history strip and save controls
- Animated gradient ring around the avatar button while generation is in progress
- Links in chat bubbles styled in pink with underline
- Bubble animations limited to last 10 messages for smooth scrolling on long conversations

---

## Technical Stack

- **Language:** Swift
- **Framework:** SwiftUI (macOS)
- **AI Providers:** Anthropic (Claude Haiku 4.5, Claude Sonnet 4.6), OpenAI (GPT-4o-mini, 
  GPT-4.1 Nano), Google (Gemini, mood detection and avatar description)
- **Image Generation:** DALL-E 3 (agent avatars, dream banners)
- **Transport:** WebSocket (`ws://127.0.0.1:18789`)
- **Auth:** Ed25519 device signing with challenge/response handshake
- **Data:** JSON-based chat history per agent workspace
- **Security:** LocalAuthentication (Touch ID), CryptoKit, atomic file writes
- **Testing:** XCTest

---

## Other Projects in This Repo

**IBM Quantum MCP Server** (`quantum-mcp/`)
A Python MCP server that exposes IBM Quantum hardware to AI agents as tools. Agents can 
build and run quantum circuits, submit jobs to real IBM hardware, and retrieve results. 
Designed as the foundation for a research agent that collects simulator vs real hardware 
divergence data, a dataset no existing LLM has been trained on.

---

## Roadmap

**v3 — Planned**
- Per-agent WebSocket connections — true parallel streaming across agents
- Council Mode — Eve orchestrates Nova and Orion in parallel and synthesizes their 
  responses into one reply
- Quantum Research Agent — IBM Quantum MCP integration for running circuits on real 
  hardware and collecting simulator vs hardware divergence data
- Agent creation flow — full redesign with AI-generated interview questions and animated 
  hatching screen

**Future**
- iOS app (SwiftUI port + Tailscale for remote gateway access)
- visionOS app — spatial multi-agent interface, one floating panel per agent
- Voice input via push-to-talk
- HomeKit AI agent (Harmony) — proactive smart home concierge with camera analysis

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## License

MIT License — see [LICENSE](LICENSE) for details.
