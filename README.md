# Agentics macOS App

Portfolio Documentation  
*Active Development • macOS SwiftUI • Single-File Architecture*

---

# Overview

Agentics is a custom macOS desktop application built to manage and interact with multiple AI agents through a polished, iMessage-style chat interface. The app connects to the OpenClaw gateway — an open-source self-hosted AI assistant platform — over WebSocket, enabling real-time streaming conversations with multiple AI agents running different models (Claude Haiku, Claude Sonnet, GPT-4o-mini).

The goal was to go beyond the default OpenClaw web interface and build something that feels native, fast, and visually distinct — while exploring what a multi-agent AI experience should look like on desktop.

---

# Technical Stack

- Language: Swift  
- Framework: SwiftUI (macOS)  
- Architecture: Single-file app (`AgenticsApp.swift`)  
- AI Providers: Anthropic (Claude Haiku 4.5, Claude Sonnet 4.6), OpenAI (GPT-4o-mini)  
- Transport: WebSocket (`ws://127.0.0.1:18789`)  
- Auth: Ed25519 device signing with challenge/response handshake  
- Data: JSON-based chat history (`CHAT.json` per agent workspace)

---

# Agents

The app manages three persistent AI agents, each with a distinct role and model. Each agent runs in its own isolated workspace with separate memory, session history, and configuration.

| Agent | Model | Role |
|----------|----------|----------|
| Eve | Claude Haiku 4.5 | Daily driver |
| Nova | Claude Sonnet 4.6 | Deep technical work |
| Orion | GPT-4o-mini | Lightweight tasks |

---

# Key Features

- Native macOS chat UI with animated gradient bubbles (Apple Intelligence-inspired styling)  
- Real-time streaming responses with adaptive typewriter effect  
- Thinking state with dynamic animation tied to response lifecycle  
- Multi-agent sidebar with live message previews and timestamps  
- Inline markdown rendering (bold, italic, code)  
- Large message collapsing for improved readability   
- Per-agent chat persistence with capped history  
- Scroll anchoring system for consistent streaming behavior  
- Shared WebSocket manager preventing cross-agent stream conflicts  
- In-app API key manager — reads and writes directly to each agent's auth profile, with Touch ID required to reveal the current stored key  

---

# Engineering Challenges

**Real-time streaming architecture**  
The initial HTTP-based approach caused token bloat by resending full conversation history on each request. Migrated to WebSocket transport, enabling streaming responses and significantly reducing token usage.

**Custom WebSocket authentication**  
The OpenClaw gateway required a specific Ed25519 challenge/response handshake that was not clearly documented. Implemented full protocol support by reverse-engineering expected message flow and signing process.

**Scroll synchronization in SwiftUI**  
LazyVStack introduced race conditions when scrolling to the latest message. Replaced ID-based scrolling with a sentinel-based anchoring approach, ensuring consistent positioning across loads and agent switches.

**Multi-agent stream isolation**  
Early multi-agent implementation caused token streams to mix between agents. Resolved by consolidating to a single shared WebSocket manager and routing responses through a controlled handler.

---

# What This Project Demonstrates

- Real-time WebSocket client implementation with streaming event handling  
- Multi-agent AI architecture with session isolation and persistent memory  
- Native macOS SwiftUI development with custom animations and system integration  
- Practical debugging of concurrency, networking, and UI timing issues  
- Ability to work with partially documented systems by analyzing behavior and source code  
- Product-focused thinking applied to AI tooling and user experience  

---

# Lessons Learned

- WebSockets enable efficient streaming and reduce token overhead compared to HTTP  
- SwiftUI view lifecycle requires careful state management across rebuilds  
- Shared application state should live in ObservableObject, not local view state  
- UI timing issues often require structural solutions rather than delays  
- Real-world systems require defensive handling of inconsistent external data  

---

# Roadmap

## Near Term
- Enhanced personality system (SOUL.md, IDENTITY.md, USER.md support)  
- File attachment support  
- Touch ID gating for sensitive operations  
- Dynamic AI agent avatars — headless avatar generation using ImagePlayground and NaturalLanguage frameworks; analyzes conversation sentiment and keywords every 8 messages to evolve each agent's contact photo automatically  

## Long Term
- iOS app (SwiftUI port with remote gateway support)  
- visionOS spatial multi-agent interface  
- Voice input (push-to-talk)  
- Multi-agent orchestration (Council Mode)  

---

# Additional Documentation

A full technical deep dive — including detailed problem breakdowns, debugging process, and architectural decisions — is available in `PORTFOLIO.md`.

