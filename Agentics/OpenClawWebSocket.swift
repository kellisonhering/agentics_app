// OpenClawWebSocket.swift
// Agentics
//
// All networking in one place:
//   - OpenClawAuth    — device keypair, keychain storage, challenge signing
//   - OpenClawWebSocket — WebSocket connection, token routing, lifecycle handling

import Foundation
import CryptoKit

// MARK: - Helpers

private func toHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func toBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - OpenClaw Device Auth

class OpenClawAuth {

    private static let keychainService             = "com.kellisonjames.openclawapp"
    private static let keychainPrivateKeyAccount   = "device-private-key"
    private static let keychainDeviceIDAccount     = "device-id"

    static func deviceID() -> String {
        if let saved = loadFromKeychain(account: keychainDeviceIDAccount) { return saved }
        let (_, id) = createAndStoreKeypair()
        return id
    }

    static func publicKeyHex() -> String? {
        guard let privateKey = loadPrivateKey() else { return nil }
        return toBase64URL(privateKey.publicKey.rawRepresentation)
    }

    static func signChallenge(nonce: String, clientMode: String = "ui", role: String = "operator", scopes: String = "operator.read,operator.write", token: String = "") -> (signature: String, publicKey: String, deviceID: String, signedAtMs: Int)? {
        guard let privateKey = loadPrivateKey() else {
            print("[OpenClawAuth] No private key found in Keychain")
            return nil
        }
        let id         = deviceID()
        let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        let payload    = "v2|\(id)|openclaw-macos|\(clientMode)|\(role)|\(scopes)|\(signedAtMs)|\(token)|\(nonce)"
        guard let payloadData = payload.data(using: .utf8) else { return nil }
        do {
            let signature = try privateKey.signature(for: payloadData)
            print("[OpenClawAuth] Signed payload: \(payload)")
            return (
                signature: toBase64URL(signature),
                publicKey: toBase64URL(privateKey.publicKey.rawRepresentation),
                deviceID:  id,
                signedAtMs: signedAtMs
            )
        } catch {
            print("[OpenClawAuth] Signing failed: \(error)")
            return nil
        }
    }

    @discardableResult
    private static func createAndStoreKeypair() -> (publicKeyHex: String, deviceID: String) {
        let privateKey  = Curve25519.Signing.PrivateKey()
        let pubKeyData  = privateKey.publicKey.rawRepresentation
        let privKeyData = privateKey.rawRepresentation
        let hash        = SHA256.hash(data: pubKeyData)
        let deviceID    = hash.compactMap { String(format: "%02x", $0) }.joined()
        saveToKeychain(data: privKeyData, account: keychainPrivateKeyAccount)
        saveToKeychain(string: deviceID,  account: keychainDeviceIDAccount)
        print("[OpenClawAuth] 🔑 Generated new keypair — DeviceID: \(deviceID.prefix(16))…")
        return (toHex(pubKeyData), deviceID)
    }

    private static func loadPrivateKey() -> Curve25519.Signing.PrivateKey? {
        if let data = loadDataFromKeychain(account: keychainPrivateKeyAccount) {
            return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        createAndStoreKeypair()
        return loadDataFromKeychain(account: keychainPrivateKeyAccount)
            .flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
    }

    private static func saveToKeychain(data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    keychainService,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[OpenClawAuth] ⚠️ Keychain save failed for \(account): \(status)")
        }
    }

    private static func saveToKeychain(string: String, account: String) {
        guard let data = string.data(using: .utf8) else { return }
        saveToKeychain(data: data, account: account)
    }

    private static func loadDataFromKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func loadFromKeychain(account: String) -> String? {
        guard let data = loadDataFromKeychain(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - OpenClaw WebSocket Manager

class OpenClawWebSocket: NSObject, URLSessionWebSocketDelegate {

    typealias TokenHandler = (String) -> Void
    typealias ErrorHandler = (String) -> Void

    private let gatewayURL: URL
    private let configPath: String
    private let testToken: String?

    private var authToken: String {
        if let token = testToken { return token }
        return OpenClawLoader.shared.readGatewayToken(configPath: configPath) ?? ""
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var isReady     = false

    private var pendingMessage:      String?
    private(set) var pendingAgentID: String?
    private var pendingAttachments:  [[String: Any]]?

    // Session-keyed handlers — routes tokens to the correct agent conversation
    private var tokenHandlers:    [String: TokenHandler] = [:]
    private var errorHandlers:    [String: ErrorHandler] = [:]
    private var runToSession:     [String: String]        = [:] // runId → sessionKey
    private var activeSessionKey: String?                       // last-dispatched session, used for chat:final fallback

    /// Broadcasts an error to every registered error handler and clears them.
    private func broadcastError(_ message: String) {
        let handlers = Array(errorHandlers.values)
        errorHandlers.removeAll()
        tokenHandlers.removeAll()
        DispatchQueue.main.async { handlers.forEach { $0(message) } }
    }

    private var connectRequestID: String?
    private var chatRequestID:    String?

    // Default init for production use — reads token from config
    override init() {
        self.gatewayURL = URL(string: "ws://127.0.0.1:18789")!
        self.configPath = "~/.openclaw/openclaw.json"
        self.testToken = nil
        super.init()
    }

    // Test init — accepts a dummy token, no config file needed
    init(authToken: String) {
        self.gatewayURL = URL(string: "ws://127.0.0.1:18789")!
        self.configPath = "~/.openclaw/openclaw.json"
        self.testToken = authToken
        super.init()
    }

    func send(message: String, agentID: String, attachments: [[String: Any]]? = nil, onToken: @escaping TokenHandler, onError: @escaping ErrorHandler) {
        let sessionKey = "agent:\(agentID):main"
        pendingMessage     = message
        pendingAgentID     = agentID
        pendingAttachments = attachments
        tokenHandlers[sessionKey] = onToken
        errorHandlers[sessionKey] = onError

        if webSocketTask == nil {
            connect()
        } else if isReady {
            dispatchPendingMessage()
        }
    }

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

        // If any streams were active when the socket closed, their token events are
        // gone forever (gateway does not replay events). Clear the handlers and notify
        // AppState so it can show a "connection interrupted" notice in the affected chats.
        if !tokenHandlers.isEmpty {
            let interruptedIds = tokenHandlers.keys.compactMap { key -> String? in
                let parts = key.split(separator: ":")
                return parts.count >= 2 ? String(parts[1]) : nil
            }
            tokenHandlers.removeAll()
            errorHandlers.removeAll()
            activeSessionKey = nil
            print("[OpenClawWS] ⚠️ Socket closed with active streams: \(interruptedIds)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .gatewayDidInterrupt,
                    object: nil,
                    userInfo: ["agentIds": interruptedIds]
                )
            }
        }
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
            broadcastError("Failed to sign connect challenge")
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

    private func receiveNextFrame() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                print("[OpenClawWS] ❌ Receive error: \(error)")
                self.broadcastError("Connection error: \(error.localizedDescription)")
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
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .gatewayDidReconnect, object: nil)
                    }
                } else {
                    let errorObj = json["error"] as? [String: Any]
                    let reason   = errorObj?["message"] as? String ?? "connect rejected"
                    print("[OpenClawWS] ❌ Connect failed: \(reason)")
                    broadcastError("Connect failed: \(reason)")
                    cleanup()
                }
            } else if frameID == chatRequestID {
                if !ok {
                    let reason = (json["payload"] as? [String: Any])?["reason"] as? String ?? "chat.send failed"
                    self.broadcastError("Chat error: \(reason)")
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
                let sessionKey = payload?["sessionKey"] as? String ?? ""
                let runId      = payload?["runId"]      as? String ?? ""
                let stream     = payload?["stream"]     as? String ?? ""

                // Track runId → sessionKey so we can clean up on lifecycle end
                if !runId.isEmpty && !sessionKey.isEmpty {
                    runToSession[runId] = sessionKey
                }

                if stream == "assistant", let handler = tokenHandlers[sessionKey] {
                    let data  = payload?["data"] as? [String: Any]
                    let delta = data?["delta"] as? String ?? ""
                    if !delta.isEmpty {
                        print("[OpenClawWS] Token → \(sessionKey): \(delta)")
                        DispatchQueue.main.async { handler(delta) }
                    }
                } else if stream == "lifecycle" {
                    let phase = (payload?["data"] as? [String: Any])?["phase"] as? String ?? ""
                    if phase == "end" && !sessionKey.isEmpty {
                        print("[OpenClawWS] Stream complete → \(sessionKey)")
                        let handler = tokenHandlers.removeValue(forKey: sessionKey)
                        errorHandlers.removeValue(forKey: sessionKey)
                        if !runId.isEmpty { runToSession.removeValue(forKey: runId) }
                        DispatchQueue.main.async { handler?("") }
                    }
                }

            case "chat":
                let state = payload?["state"] as? String ?? ""
                if state == "final" {
                    self.chatRequestID = nil
                    // Fallback: if lifecycle:end didn't already clean up, signal
                    // completion now so the sending agent is never stuck "responding".
                    if let key = self.activeSessionKey,
                       let handler = self.tokenHandlers.removeValue(forKey: key) {
                        self.errorHandlers.removeValue(forKey: key)
                        self.activeSessionKey = nil
                        print("[OpenClawWS] chat.final fallback → completing \(key)")
                        DispatchQueue.main.async { handler("") }
                    } else {
                        self.activeSessionKey = nil
                        print("[OpenClawWS] chat.final received (lifecycle:end already handled)")
                    }
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

    private func dispatchPendingMessage() {
        guard let message = pendingMessage, let agentID = pendingAgentID else { return }

        let reqID = UUID().uuidString
        chatRequestID = reqID

        var params: [String: Any] = [
            "sessionKey":     "agent:\(agentID):main",
            "message":        message,
            "idempotencyKey": UUID().uuidString
        ]
        if let attachments = pendingAttachments, !attachments.isEmpty {
            params["attachments"] = attachments
        }

        sendJSON([
            "type":   "req",
            "id":     reqID,
            "method": "chat.send",
            "params": params
        ])
        activeSessionKey = "agent:\(agentID):main"
        if let attachments = params["attachments"] as? [[String: Any]] {
            print("[OpenClawWS] 📤 chat.send → agent=\(agentID) with \(attachments.count) attachment(s): \(attachments.map { $0["mimeType"] ?? $0["type"] ?? "unknown" })")
        } else {
            print("[OpenClawWS] 📤 chat.send → agent=\(agentID) session=\(activeSessionKey!) (no attachments)")
        }

        pendingMessage     = nil
        pendingAgentID     = nil
        pendingAttachments = nil
    }

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
