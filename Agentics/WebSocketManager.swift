// WebSocketManager.swift
// Agentics
//
// Extracted from AgenticsCore.swift for testability.
// This is the single shared WebSocket manager that prevents
// token stream mixing between agents.

import Foundation

class OpenClawWebSocket: NSObject, URLSessionWebSocketDelegate {

    typealias TokenHandler = (String) -> Void
    typealias ErrorHandler = (String) -> Void

    private let gatewayURL: URL
    private let authToken: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private(set) var isConnected = false
    private(set) var isReady     = false

    // ── Token routing ──
    // Only ONE pending handler at a time. This is the core design
    // that prevents token mixing: whoever sent the last message
    // owns the handler until their stream completes.
    private(set) var pendingAgentID:      String?
    private var pendingMessage:           String?
    private var pendingTokenHandler:      TokenHandler?
    private var pendingErrorHandler:      ErrorHandler?

    private var connectRequestID: String?
    private var chatRequestID:    String?

    // MARK: - Init

    init(gatewayURL: URL = URL(string: "ws://127.0.0.1:18789")!,
         authToken: String) {
        self.gatewayURL = gatewayURL
        self.authToken  = authToken
        super.init()
    }

    // MARK: - Public API

    func send(message: String, agentID: String, onToken: @escaping TokenHandler, onError: @escaping ErrorHandler) {
        pendingMessage      = message
        pendingAgentID      = agentID
        pendingTokenHandler = onToken
        pendingErrorHandler = onError

        if webSocketTask == nil {
            connect()
        } else if isReady {
            dispatchPendingMessage()
        }
    }

    // MARK: - Connection

    private func connect() {
        print("[OpenClawWS] 🔌 Connecting…")
        var request = URLRequest(url: gatewayURL)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let config    = URLSessionConfiguration.default
        urlSession    = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveNextFrame()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("[OpenClawWS] ✅ Socket opened — waiting for connect.challenge")
        isConnected = true
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("[OpenClawWS] 🔴 Socket closed")
        isConnected = false
        isReady     = false
        self.webSocketTask = nil
    }

    private func sendConnectRequest(nonce: String, ts: Int) {
        let reqID = UUID().uuidString
        connectRequestID = reqID

        guard let signed = OpenClawAuth.signChallenge(
            nonce:      nonce,
            clientMode: "ui",
            role:       "operator",
            scopes:     "operator.read,operator.write",
            token:      authToken
        ) else {
            pendingErrorHandler?("Failed to sign connect challenge")
            cleanup(); return
        }

        sendJSON([
            "type":   "req",
            "id":     reqID,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": [
                    "id":       "openclaw-macos",
                    "version":  "1.0.0",
                    "platform": "macos",
                    "mode":     "ui"
                ],
                "role":   "operator",
                "scopes": ["operator.read", "operator.write"],
                "auth":   ["token": authToken],
                "device": [
                    "id":        signed.deviceID,
                    "publicKey": signed.publicKey,
                    "signature": signed.signature,
                    "signedAt":  signed.signedAtMs,
                    "nonce":     nonce
                ]
            ]
        ])
        print("[OpenClawWS] connect req sent with signed device")
    }

    // MARK: - Frame Handling

    private func receiveNextFrame() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                print("[OpenClawWS] ❌ Receive error: \(error)")
                self.pendingErrorHandler?("Connection error: \(error.localizedDescription)")
                self.cleanup()
            case .success(let msg):
                switch msg {
                case .string(let text): self.handleFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handleFrame(text) }
                @unknown default: break
                }
                self.receiveNextFrame()
            }
        }
    }

    /// Parses and routes a single WebSocket frame.
    /// `internal` (not private) so unit tests can feed simulated frames directly.
    func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[OpenClawWS] ⚠️ Unparseable frame: \(text.prefix(200))")
            return
        }

        let frameType = json["type"] as? String ?? ""
        let frameID   = json["id"]   as? String ?? ""
        print("[OpenClawWS] 📥 type=\(frameType) id=\(frameID.prefix(8))")

        switch frameType {

        case "res":
            let ok = json["ok"] as? Bool ?? false

            if frameID == connectRequestID {
                if ok {
                    print("[OpenClawWS] 🔓 Handshake complete — ready")
                    isReady = true
                    dispatchPendingMessage()
                } else {
                    let errorObj = json["error"] as? [String: Any]
                    let reason   = errorObj?["message"] as? String ?? "connect rejected"
                    print("[OpenClawWS] ❌ Connect failed: \(reason)")
                    pendingErrorHandler?("Connect failed: \(reason)")
                    cleanup()
                }
            } else if frameID == chatRequestID {
                if !ok {
                    let reason = (json["payload"] as? [String: Any])?["reason"] as? String ?? "chat.send failed"
                    DispatchQueue.main.async { self.pendingErrorHandler?("Chat error: \(reason)") }
                }
            }

        case "event":
            let event   = json["event"]   as? String ?? ""
            let payload = json["payload"] as? [String: Any]
            print("[OpenClawWS] Event: \(event.isEmpty ? "(empty)" : event)")

            switch event {

            case "connect.challenge":
                let nonce = payload?["nonce"] as? String ?? ""
                let ts    = payload?["ts"]    as? Int    ?? Int(Date().timeIntervalSince1970 * 1000)
                print("[OpenClawWS] Got challenge nonce: \(nonce.prefix(8))...")
                sendConnectRequest(nonce: nonce, ts: ts)

            case "agent":
                let stream = payload?["stream"] as? String ?? ""
                if stream == "assistant" {
                    let dataObj = payload?["data"] as? [String: Any]
                    let delta   = dataObj?["delta"] as? String ?? ""
                    if !delta.isEmpty {
                        print("[OpenClawWS] Token: \(delta)")
                        DispatchQueue.main.async { self.pendingTokenHandler?(delta) }
                    }
                }

            case "chat":
                let state = payload?["state"] as? String ?? ""
                if state == "final" {
                    print("[OpenClawWS] Stream complete")
                    let handler = self.pendingTokenHandler
                    self.pendingTokenHandler = nil
                    self.pendingErrorHandler = nil
                    self.chatRequestID       = nil
                    DispatchQueue.main.async { handler?("") }
                }

            case "health", "tick":
                break

            default:
                print("[OpenClawWS] Unhandled event: \(event)")
            }

        default:
            print("[OpenClawWS] ℹ️ Unhandled frame type: \(frameType)")
        }
    }

    // MARK: - Send Chat Message

    private func dispatchPendingMessage() {
        guard let message = pendingMessage, let agentID = pendingAgentID else { return }

        let reqID = UUID().uuidString
        chatRequestID = reqID

        sendJSON([
            "type":   "req",
            "id":     reqID,
            "method": "chat.send",
            "params": [
                "sessionKey":     "agent:\(agentID):main",
                "message":        message,
                "idempotencyKey": UUID().uuidString
            ]
        ])
        print("[OpenClawWS] 📤 chat.send → agent=\(agentID)")

        pendingMessage = nil
        pendingAgentID = nil
    }

    // MARK: - Helpers

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { error in
            if let error { print("[OpenClawWS] ❌ Send error: \(error)") }
        }
    }

    private func cleanup() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected   = false
        isReady       = false
    }
}
