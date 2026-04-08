import SwiftUI
import CryptoKit
import Security
import LocalAuthentication

// MARK: - Glass Style Helper

struct GlassBackground: ViewModifier {
    var opacity: Double = 0.12
    var cornerRadius: CGFloat = 12
    var borderOpacity: Double = 0.18

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white.opacity(opacity))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(borderOpacity), lineWidth: 0.5)
            )
    }
}

extension View {
    func glassBackground(opacity: Double = 0.12, cornerRadius: CGFloat = 12, borderOpacity: Double = 0.18) -> some View {
        self.modifier(GlassBackground(opacity: opacity, cornerRadius: cornerRadius, borderOpacity: borderOpacity))
    }
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

private func toHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func toBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - OpenClaw WebSocket Manager

class OpenClawWebSocket: NSObject, URLSessionWebSocketDelegate {

    typealias TokenHandler = (String) -> Void
    typealias ErrorHandler = (String) -> Void

    private let gatewayURL = URL(string: "ws://127.0.0.1:18789")!
    private let configPath = "~/.openclaw/openclaw.json"

    private var authToken: String {
        OpenClawLoader.shared.readGatewayToken(configPath: configPath) ?? ""
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var isReady     = false

    private var pendingMessage:      String?
    private var pendingAgentID:      String?
    private var pendingTokenHandler: TokenHandler?
    private var pendingErrorHandler: ErrorHandler?

    private var connectRequestID: String?
    private var chatRequestID:    String?

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

    private func handleFrame(_ text: String) {
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
                    let data  = payload?["data"] as? [String: Any]
                    let delta = data?["delta"] as? String ?? ""
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

// MARK: - OpenClaw JSON Models

struct OpenClawConfig: Codable {
    let agents: AgentsConfig
}

struct AgentsConfig: Codable {
    let defaults: AgentDefaults
    let list: [AgentConfig]
}

struct AgentDefaults: Codable {
    let workspace: String
}

struct AgentHeartbeat: Codable {
    let every: String
}

// Handles both string and object shapes for the model field:
// "model": "anthropic/claude-haiku-4-5"  (plain string)
// "model": { "primary": "openai/gpt-4o-mini" }  (object)
enum AgentModelField: Codable {
    case string(String)
    case object(primary: String)

    var primary: String {
        switch self {
        case .string(let s): return s
        case .object(let p): return p
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            struct ModelObject: Codable { let primary: String }
            let obj = try container.decode(ModelObject.self)
            self = .object(primary: obj.primary)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(primary)
    }
}

struct AgentConfig: Codable {
    let id: String
    let name: String
    let workspace: String?
    let agentDir: String?
    let model: AgentModelField?
    let heartbeat: AgentHeartbeat?
}

// MARK: - OpenClaw Loader

class OpenClawLoader {
    static let shared = OpenClawLoader()

    func workspacePath(for agent: AgentConfig, defaults: AgentDefaults) -> String {
        return agent.workspace ?? defaults.workspace
    }

    func soulMDPath(for agent: AgentConfig, defaults: AgentDefaults) -> String {
        let workspace = workspacePath(for: agent, defaults: defaults)
        return (workspace as NSString).appendingPathComponent("SOUL.md")
    }

    func identityMDPath(for agent: AgentConfig, defaults: AgentDefaults) -> String {
        let workspace = workspacePath(for: agent, defaults: defaults)
        return (workspace as NSString).appendingPathComponent("IDENTITY.md")
    }

    func readIdentityMD(for agentConfig: AgentConfig, defaults: AgentDefaults) -> String? {
        let path = (identityMDPath(for: agentConfig, defaults: defaults) as NSString).expandingTildeInPath
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    func writeIdentityMD(content: String, for agentConfig: AgentConfig, defaults: AgentDefaults) -> Bool {
        let path = (identityMDPath(for: agentConfig, defaults: defaults) as NSString).expandingTildeInPath
        do { try content.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    func heartbeatMDPath(for agent: AgentConfig, defaults: AgentDefaults) -> String {
        let workspace = workspacePath(for: agent, defaults: defaults)
        return (workspace as NSString).appendingPathComponent("HEARTBEAT.md")
    }

    func loadConfig(from path: String) -> OpenClawConfig? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath),
              let config = try? JSONDecoder().decode(OpenClawConfig.self, from: data) else { return nil }
        return config
    }

    func readSoulMD(for agentConfig: AgentConfig, defaults: AgentDefaults) -> String? {
        let path = (soulMDPath(for: agentConfig, defaults: defaults) as NSString).expandingTildeInPath
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    func writeSoulMD(content: String, for agentConfig: AgentConfig, defaults: AgentDefaults) -> Bool {
        let path = (soulMDPath(for: agentConfig, defaults: defaults) as NSString).expandingTildeInPath
        do { try content.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    func readHeartbeatMD(for agentConfig: AgentConfig, defaults: AgentDefaults) -> String? {
        let path = (heartbeatMDPath(for: agentConfig, defaults: defaults) as NSString).expandingTildeInPath
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    func writeHeartbeatMD(content: String, for agentConfig: AgentConfig, defaults: AgentDefaults) -> Bool {
        let path = (heartbeatMDPath(for: agentConfig, defaults: defaults) as NSString).expandingTildeInPath
        do { try content.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }

    func readGatewayToken(configPath: String) -> String? {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String else { return nil }
        return token
    }

    func writeGatewayToken(_ token: String, configPath: String) -> Bool {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath),
              var rawJson = String(data: data, encoding: .utf8) else { return false }

        let pattern = "\"token\":\\s*\"[^\"]*\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawJson, range: NSRange(rawJson.startIndex..., in: rawJson)),
              let swiftRange = Range(match.range, in: rawJson) else { return false }

        // Find the match that's inside gateway.auth (not inside agents)
        // We look for the one preceded by "mode": "token" nearby
        let matches = regex.matches(in: rawJson, range: NSRange(rawJson.startIndex..., in: rawJson))
        for m in matches {
            guard let r = Range(m.range, in: rawJson) else { continue }
            let before = rawJson[rawJson.startIndex..<r.lowerBound]
            // Check if this token field is inside gateway.auth by looking for "mode" nearby
            if before.contains("\"mode\": \"token\"") || before.contains("\"mode\":\"token\"") {
                rawJson.replaceSubrange(r, with: "\"token\": \"\(token)\"")
                do {
                    try rawJson.write(toFile: expandedPath, atomically: true, encoding: .utf8)
                    return true
                } catch { return false }
            }
        }
        return false
    }

    func chatJSONPath(for agent: AgentConfig, defaults: AgentDefaults) -> String {
        let workspace = workspacePath(for: agent, defaults: defaults)
        return (workspace as NSString).appendingPathComponent("CHAT.json")
    }

    func readChat(for agentConfig: AgentConfig, defaults: AgentDefaults) -> [Message] {
        let path = (chatJSONPath(for: agentConfig, defaults: defaults) as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let messages = try? JSONDecoder().decode([Message].self, from: data) else { return [] }
        return messages
    }

    func writeChat(_ messages: [Message], for agentConfig: AgentConfig, defaults: AgentDefaults) {
        let path = (chatJSONPath(for: agentConfig, defaults: defaults) as NSString).expandingTildeInPath
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func updateHeartbeat(agentId: String, interval: String?, configPath: String) -> Bool {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        guard var rawJson = try? String(contentsOfFile: expandedPath, encoding: .utf8) else { return false }

        let agentMarker = "\"id\": \"\(agentId)\""
        guard let markerRange = rawJson.range(of: agentMarker) else { return false }

        var openBraceIdx = rawJson.startIndex
        var foundOpenBrace = false
        var backDepth = 0
        var scanIdx = rawJson.index(before: markerRange.lowerBound)
        while scanIdx > rawJson.startIndex {
            let ch = rawJson[scanIdx]
            if ch == "}" { backDepth += 1 }
            else if ch == "{" {
                if backDepth == 0 { openBraceIdx = scanIdx; foundOpenBrace = true; break }
                backDepth -= 1
            }
            scanIdx = rawJson.index(before: scanIdx)
        }
        guard foundOpenBrace else { return false }

        var depth = 0
        var closeIdx = rawJson.endIndex
        var idx = openBraceIdx
        while idx < rawJson.endIndex {
            let ch = rawJson[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1; if depth == 0 { closeIdx = idx; break } }
            idx = rawJson.index(after: idx)
        }
        guard closeIdx != rawJson.endIndex else { return false }

        var agentBlock = String(rawJson[openBraceIdx...closeIdx])

        if interval == nil {
            let removePattern = ",?\\s*\"heartbeat\":\\s*\\{[^}]*\\}"
            if let regex = try? NSRegularExpression(pattern: removePattern),
               let match = regex.firstMatch(in: agentBlock, range: NSRange(agentBlock.startIndex..., in: agentBlock)),
               let swiftRange = Range(match.range, in: agentBlock) {
                agentBlock.removeSubrange(swiftRange)
            }
        } else {
            let heartbeatJson = "\"heartbeat\": { \"every\": \"\(interval!)\" }"
            let existingPattern = "\"heartbeat\":\\s*\\{[^}]*\\}"
            if let regex = try? NSRegularExpression(pattern: existingPattern),
               let match = regex.firstMatch(in: agentBlock, range: NSRange(agentBlock.startIndex..., in: agentBlock)),
               let swiftRange = Range(match.range, in: agentBlock) {
                agentBlock.replaceSubrange(swiftRange, with: heartbeatJson)
            } else {
                let insertIdx = agentBlock.index(before: agentBlock.endIndex)
                agentBlock.insert(contentsOf: ",\n        \(heartbeatJson)\n      ", at: insertIdx)
            }
        }

        rawJson.replaceSubrange(openBraceIdx...closeIdx, with: agentBlock)
        do { try rawJson.write(toFile: expandedPath, atomically: true, encoding: .utf8); return true }
        catch { return false }
    }
}

// MARK: - Agent Model

struct Agent: Identifiable, Hashable {
    let id: String
    var agentConfig: AgentConfig?
    var name: String
    var role: String
    var isActive: Bool
    var systemPrompt: String
    var heartbeatContent: String
    var heartbeatInterval: String
    var heartbeatMDFound: Bool
    var workspacePath: String
    var soulMDFound: Bool
    var identityContent: String
    var identityMDFound: Bool
    var lastMessage: String
    var lastMessageTime: String
    var unreadCount: Int
    var avatarColor: Color
    var status: AgentStatus

    static func == (lhs: Agent, rhs: Agent) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AgentStatus {
    case idle, thinking, responding, error

    var label: String {
        switch self {
        case .idle:       return "Idle"
        case .thinking:   return "Thinking..."
        case .responding: return "Responding..."
        case .error:      return "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle:       return .green
        case .thinking:   return .yellow
        case .responding: return .blue
        case .error:      return .red
        }
    }

    var isAnimated: Bool {
        switch self {
        case .thinking, .responding: return true
        default: return false
        }
    }

    var animationSpeed: Double {
        switch self {
        case .thinking:   return 0.8
        case .responding: return 0.4
        default:          return 3.0
        }
    }
}

// MARK: - Animated Status Dot
// .id(status) is used at every call site so SwiftUI fully recreates this view
// on each status change, guaranteeing onAppear fires fresh every time and the
// animation always starts cleanly — no onChange needed.

struct AgentStatusDot: View {
    let status: AgentStatus
    let size: CGFloat
    @State private var shift: CGFloat = 0

    var body: some View {
        ZStack {
            if status.isAnimated {
                Circle()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10), location: max(0, min(1, -0.125 + shift))),
                            .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55), location: max(0, min(1,  0.25  + shift))),
                            .init(color: Color(red: 0.95, green: 0.15, blue: 0.65), location: max(0, min(1,  0.50  + shift))),
                            .init(color: Color(red: 0.30, green: 0.55, blue: 1.00), location: max(0, min(1,  0.75  + shift))),
                            .init(color: Color(red: 0.40, green: 0.78, blue: 1.00), location: max(0, min(1,  1.0   + shift))),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: size, height: size)
                    .shadow(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.6), radius: size * 0.4)
                    .shadow(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.4), radius: size * 0.6)
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: size, height: size)
            }
        }
        .onAppear {
            guard status.isAnimated else { return }
            withAnimation(.easeInOut(duration: status.animationSpeed).repeatForever(autoreverses: true)) {
                shift = 0.5
            }
        }
    }
}

struct Message: Identifiable, Codable {
    let id: UUID
    var content: String
    var isUser: Bool
    var timestamp: Date
    var agentName: String?

    init(id: UUID = UUID(), content: String, isUser: Bool, timestamp: Date, agentName: String?) {
        self.id        = id
        self.content   = content
        self.isUser    = isUser
        self.timestamp = timestamp
        self.agentName = agentName
    }
}

// MARK: - App State

class AppState: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var selectedAgent: Agent? = nil
    @Published var messages: [String: [Message]] = [:]
    @Published var configPath: String = "~/.openclaw/openclaw.json"
    @Published var loadError: String? = nil
    @Published var isLoaded: Bool = false
    @Published var settingsPanelVisible: Bool = false
    @Published var streamingAgents: Set<String> = []
    let wsManager = OpenClawWebSocket()

    private let avatarColors: [Color] = [.purple, .cyan, .orange, .green, .blue, .pink, .yellow]
    private var agentDefaults: AgentDefaults? = nil

    init() { loadAgents() }

    func loadAgents() {
        loadError = nil
        guard let config = OpenClawLoader.shared.loadConfig(from: configPath) else {
            loadError = "Could not load config at \(configPath)"
            loadFallbackAgents()
            return
        }

        agentDefaults = config.agents.defaults
        let defaults  = config.agents.defaults

        agents = config.agents.list.enumerated().map { index, agentConfig in
            let soulContent       = OpenClawLoader.shared.readSoulMD(for: agentConfig, defaults: defaults)
            let identityContent   = OpenClawLoader.shared.readIdentityMD(for: agentConfig, defaults: defaults)
            let heartbeatContent  = OpenClawLoader.shared.readHeartbeatMD(for: agentConfig, defaults: defaults)
            let workspacePath     = OpenClawLoader.shared.workspacePath(for: agentConfig, defaults: defaults)
            let heartbeatInterval = agentConfig.heartbeat?.every ?? "off"
            let chatHistory       = OpenClawLoader.shared.readChat(for: agentConfig, defaults: defaults)
            let lastMsg           = chatHistory.last
            let lastMsgPreview    = lastMsg?.content.prefix(40).description ?? "No messages yet"
            let lastMsgTime: String = {
                guard let last = lastMsg else { return "" }
                let f = DateFormatter(); f.timeStyle = .short; return f.string(from: last.timestamp)
            }()

            if !chatHistory.isEmpty { messages[agentConfig.id] = chatHistory }

            // Capitalize first letter of agent name
            let displayName = agentConfig.name.prefix(1).uppercased() + agentConfig.name.dropFirst()

            return Agent(
                id: agentConfig.id,
                agentConfig: agentConfig,
                name: displayName,
                role: agentConfig.model?.primary ?? "Agent",
                isActive: true,
                systemPrompt: soulContent ?? "",
                heartbeatContent: heartbeatContent ?? "",
                heartbeatInterval: heartbeatInterval,
                heartbeatMDFound: heartbeatContent != nil,
                workspacePath: workspacePath,
                soulMDFound: soulContent != nil,
                identityContent: identityContent ?? "",
                identityMDFound: identityContent != nil,
                lastMessage: lastMsgPreview,
                lastMessageTime: lastMsgTime,
                unreadCount: 0,
                avatarColor: avatarColors[index % avatarColors.count],
                status: .idle
            )
        }

        isLoaded = true
    }

    func saveSoulMD(for agent: Agent) -> Bool {
        guard let agentConfig = agent.agentConfig, let defaults = agentDefaults else { return false }
        return OpenClawLoader.shared.writeSoulMD(content: agent.systemPrompt, for: agentConfig, defaults: defaults)
    }

    func saveIdentityMD(for agent: Agent) -> Bool {
        guard let agentConfig = agent.agentConfig, let defaults = agentDefaults else { return false }
        return OpenClawLoader.shared.writeIdentityMD(content: agent.identityContent, for: agentConfig, defaults: defaults)
    }

    func saveHeartbeatMD(for agent: Agent) -> Bool {
        guard let agentConfig = agent.agentConfig, let defaults = agentDefaults else { return false }
        return OpenClawLoader.shared.writeHeartbeatMD(content: agent.heartbeatContent, for: agentConfig, defaults: defaults)
    }

    func saveChat(for agent: Agent) {
        guard let agentConfig = agent.agentConfig, let defaults = agentDefaults else { return }
        let msgs = (messages[agent.id] ?? []).suffix(500)
        OpenClawLoader.shared.writeChat(Array(msgs), for: agentConfig, defaults: defaults)
    }

    func saveHeartbeatInterval(for agent: Agent) -> Bool {
        let interval = agent.heartbeatInterval == "off" ? nil : agent.heartbeatInterval
        return OpenClawLoader.shared.updateHeartbeat(agentId: agent.id, interval: interval, configPath: configPath)
    }

    func updateSidebarPreview(for agentId: String) {
        guard let idx = agents.firstIndex(where: { $0.id == agentId }),
              let last = messages[agentId]?.last else { return }
        agents[idx].lastMessage = String(last.content.prefix(40))
        let f = DateFormatter(); f.timeStyle = .short
        agents[idx].lastMessageTime = f.string(from: last.timestamp)
    }

    private func loadFallbackAgents() {
        agents = [
            Agent(id: "eve", agentConfig: nil, name: "Eve", role: "Main Agent", isActive: true,
                  systemPrompt: "", heartbeatContent: "", heartbeatInterval: "off",
                  heartbeatMDFound: false, workspacePath: "~/.openclaw/workspace", soulMDFound: false,
                  identityContent: "", identityMDFound: false,
                  lastMessage: "Config not loaded", lastMessageTime: "", unreadCount: 0,
                  avatarColor: .purple, status: .idle)
        ]
        isLoaded = false
    }
}

// MARK: - Main App View

struct ContentView: View {
    @StateObject var state = AppState()
    @State private var showAPIKeyManager = false

    var body: some View {
        NavigationSplitView {
            SidebarView().environmentObject(state)
        } detail: {
            if let agent = state.selectedAgent {
                ChatView(agent: binding(for: agent))
                    .environmentObject(state)
                    .id(agent.id)
            } else {
                EmptyStateView().environmentObject(state)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAPIKeyManager) {
            APIKeyManagerView().environmentObject(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAPIKeyManager)) { _ in
            showAPIKeyManager = true
        }
    }

    func binding(for agent: Agent) -> Binding<Agent> {
        guard let idx = state.agents.firstIndex(where: { $0.id == agent.id }) else { fatalError("Agent not found") }
        return $state.agents[idx]
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var searchText = ""

    var filteredAgents: [Agent] {
        if searchText.isEmpty { return state.agents }
        return state.agents.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.role.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.10).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Agentics")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { state.loadAgents() }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .help("Reload agents from config")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if let error = state.loadError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange).font(.system(size: 11))
                        Text(error).font(.system(size: 11)).foregroundColor(.orange).lineLimit(2)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Color.white.opacity(0.4)).font(.system(size: 13))
                    TextField("Search agents...", text: $searchText)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .glassBackground(opacity: 0.08, cornerRadius: 9, borderOpacity: 0.12)
                .padding(.horizontal, 12).padding(.bottom, 8)

                Divider().background(Color.white.opacity(0.08))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredAgents) { agent in
                            AgentRowView(agent: agent)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        state.selectedAgent = agent
                                    }
                                }
                        }
                    }
                }


            }
        }
        .frame(minWidth: 260, maxWidth: 300)
    }
}

struct AgentRowView: View {
    let agent: Agent
    @EnvironmentObject var state: AppState
    var isSelected: Bool { state.selectedAgent?.id == agent.id }
    // Read status live from AppState so the dot updates in real time
    var liveStatus: AgentStatus { state.agents.first(where: { $0.id == agent.id })?.status ?? agent.status }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(agent.avatarColor.opacity(0.15))
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(agent.avatarColor.opacity(0.3), lineWidth: 1))
                    .overlay(
                        Text(String(agent.name.prefix(1)))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundColor(agent.avatarColor)
                    )
                AgentStatusDot(status: liveStatus, size: 11)
                    .id(liveStatus)
                    .overlay(Circle().stroke(Color(red: 0.06, green: 0.06, blue: 0.10), lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(agent.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    if !agent.soulMDFound {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 10)).foregroundColor(.orange)
                            .help("Personality Matrix not found")
                    }
                    Text(agent.lastMessageTime)
                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.35))
                }
                HStack(spacing: 4) {
                    Text(agent.lastMessage)
                        .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4)).lineLimit(1)
                    Spacer()
                    if agent.heartbeatInterval != "off" {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 8)).foregroundColor(.pink.opacity(0.6))
                            .help("Heartbeat: \(agent.heartbeatInterval)")
                    }
                    if agent.unreadCount > 0 {
                        Text("\(agent.unreadCount)")
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(isSelected ? Color.blue.opacity(0.12) : Color.clear)
        .overlay(
            isSelected ? Rectangle().fill(Color.blue.opacity(0.6))
                .frame(width: 3).frame(maxWidth: .infinity, alignment: .leading) : nil
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

// MARK: - Chat View

struct ChatView: View {
    @Binding var agent: Agent
    @EnvironmentObject var state: AppState
    @State private var inputText = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var pendingCompact = false

    var messages: [Message] { Array((state.messages[agent.id] ?? []).suffix(100)) }

    func compactContext() {
        inputText = "/compact"
        pendingCompact = true
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.06, blue: 0.12), Color(red: 0.04, green: 0.04, blue: 0.09)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                ChatHeaderView(agent: $agent, onCompact: compactContext).environmentObject(state)
                Divider().background(Color.white.opacity(0.08))

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ScrollViewReader { proxy in
                            List {
                                ForEach(Array(zip(
                                    messages,
                                    messages.indices.map { i in
                                        messages[0...i].filter { $0.isUser == messages[i].isUser }.count - 1
                                    }
                                )), id: \.0.id) { message, sideIndex in
                                    let isLastAgentMsg = !message.isUser && message.id == messages.last?.id
                                    let messageIndex = messages.firstIndex(where: { $0.id == message.id }) ?? 0
                                    let shouldAnimate = messageIndex >= messages.count - 10
                                    MessageBubbleView(
                                        message: message,
                                        agent: agent,
                                        sideIndex: sideIndex,
                                        isThinking: isLastAgentMsg && message.content.isEmpty,
                                        isLatest: isLastAgentMsg && !message.content.isEmpty,
                                        shouldAnimate: shouldAnimate
                                    )
                                    .id(message.id)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                                }
                                Color.clear.frame(height: 1).id("bottom-sentinel")
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets())
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .environment(\.defaultMinListRowHeight, 0)
                            .onAppear {
                                scrollProxy = proxy
                                proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                            }
                            .onChange(of: messages.count) { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    withAnimation { proxy.scrollTo("bottom-sentinel", anchor: .bottom) }
                                }
                            }
                            .onChange(of: messages.last?.content) { _ in
                                proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                            }
                        }

                        InputBarView(inputText: $inputText, agent: $agent, pendingCompact: $pendingCompact)
                            .environmentObject(state)
                    }

                    if state.settingsPanelVisible {
                        Divider().background(Color.white.opacity(0.08))
                        AgentSettingsPanel(agent: $agent).environmentObject(state)
                            .frame(width: 290)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.settingsPanelVisible)
    }
}

struct ChatHeaderView: View {
    @Binding var agent: Agent
    @EnvironmentObject var state: AppState
    var onCompact: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(agent.avatarColor.opacity(0.15)).frame(width: 36, height: 36)
                .overlay(Circle().stroke(agent.avatarColor.opacity(0.3), lineWidth: 1))
                .overlay(
                    Text(String(agent.name.prefix(1)))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(agent.avatarColor)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                HStack(spacing: 4) {
                    AgentStatusDot(status: agent.status, size: 7)
                    .id(agent.status)
                    Text(agent.status.label).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                }
            }

            Spacer()

            Button(action: { onCompact?() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                    Text("Compact")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color.white.opacity(0.45))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
            }
            .buttonStyle(.plain)
            .help("Compact context window")

            Button(action: { withAnimation { state.settingsPanelVisible.toggle() } }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15))
                    .foregroundColor(state.settingsPanelVisible ? .blue : Color.white.opacity(0.5))
                    .padding(7)
                    .glassBackground(opacity: state.settingsPanelVisible ? 0.2 : 0.08, cornerRadius: 8, borderOpacity: 0.15)
            }
            .buttonStyle(.plain).padding(.leading, 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Message Bubbles

struct AnimatedGradientBubble: View {
    let isUser: Bool
    let index: Int
    var isThinking: Bool = false
    var isLatest: Bool = false
    var shouldAnimate: Bool = true
    @State private var shift: CGFloat = 0

    var body: some View {
        let dir: (UnitPoint, UnitPoint) = (index % 2 == 0)
            ? (UnitPoint(x: 0, y: 0.5), UnitPoint(x: 1, y: 0.5))
            : (UnitPoint(x: 1, y: 0.5), UnitPoint(x: 0, y: 0.5))
        ZStack {
            if isUser {
                BubbleShape(isUser: true)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(0.90), location: max(0, min(1, -0.125 + shift))),
                            .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55).opacity(0.90), location: max(0, min(1,  0.125 + shift))),
                            .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.90), location: max(0, min(1,  0.375 + shift))),
                            .init(color: Color(red: 0.30, green: 0.55, blue: 1.00).opacity(0.90), location: max(0, min(1,  0.625 + shift))),
                            .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.88), location: max(0, min(1,  0.875 + shift))),
                        ],
                        startPoint: dir.0, endPoint: dir.1
                    ))
                BubbleShape(isUser: true).fill(.ultraThinMaterial.opacity(0.08))
                BubbleShape(isUser: true).stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.15)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.7)
            } else {
                BubbleShape(isUser: false)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(0.16), location: max(0, min(1, -0.125 + shift))),
                            .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55).opacity(0.16), location: max(0, min(1,  0.125 + shift))),
                            .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.14), location: max(0, min(1,  0.375 + shift))),
                            .init(color: Color(red: 0.30, green: 0.55, blue: 1.00).opacity(0.16), location: max(0, min(1,  0.625 + shift))),
                            .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.16), location: max(0, min(1,  0.875 + shift))),
                        ],
                        startPoint: dir.0, endPoint: dir.1
                    ))
                BubbleShape(isUser: false).fill(.ultraThinMaterial.opacity(0.55))
                BubbleShape(isUser: false).stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(0.40), location: max(0, min(1, -0.125 + shift))),
                            .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.35), location: max(0, min(1,  0.375 + shift))),
                            .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.35), location: max(0, min(1,  0.875 + shift))),
                        ],
                        startPoint: dir.0, endPoint: dir.1
                    ), lineWidth: 0.6)
                if isThinking || isLatest {
                    let gleamOpacity: Double = isThinking ? 0.92 : 0.45
                    let gleamWidth: CGFloat  = isThinking ? 1.5  : 0.9
                    let glowOpacity: Double  = isThinking ? 0.5  : 0.2
                    BubbleShape(isUser: false).stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(gleamOpacity), location: max(0, min(1, -0.125 + shift))),
                                .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55).opacity(gleamOpacity), location: max(0, min(1,  0.125 + shift))),
                                .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(gleamOpacity), location: max(0, min(1,  0.375 + shift))),
                                .init(color: Color(red: 0.30, green: 0.55, blue: 1.00).opacity(gleamOpacity), location: max(0, min(1,  0.625 + shift))),
                                .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(gleamOpacity), location: max(0, min(1,  0.875 + shift))),
                            ],
                            startPoint: dir.0, endPoint: dir.1
                        ), lineWidth: gleamWidth)
                    .shadow(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(glowOpacity), radius: 4)
                    .shadow(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(glowOpacity * 0.8), radius: 6)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }
            }
        }
        .onAppear {
            guard shouldAnimate, shift == 0 else { return }
            let delay = Double(index % 8) * 0.45
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: isThinking ? 0.6 : 3.0).repeatForever(autoreverses: true)) {
                    shift = 0.25
                }
            }
        }
        .onChange(of: isThinking) { thinking in
            guard shouldAnimate else { return }
            shift = 0
            withAnimation(.easeInOut(duration: thinking ? 0.6 : 3.0).repeatForever(autoreverses: true)) {
                shift = 0.25
            }
        }
    }
}

struct MessageBubbleView: View {
    let message: Message
    let agent: Agent
    let sideIndex: Int
    var isThinking: Bool = false
    var isLatest: Bool = false
    var shouldAnimate: Bool = true

    func markdownText(_ string: String) -> Text {
        if var attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // Style links with app pink color and underline
            for run in attributed.runs {
                if run.link != nil {
                    attributed[run.range].foregroundColor = Color(red: 1.0, green: 0.25, blue: 0.55)
                    attributed[run.range].underlineStyle = .single
                }
            }
            return Text(attributed)
        }
        return Text(string)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    markdownText(message.content)
                        .font(.system(size: 13)).foregroundColor(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(AnimatedGradientBubble(isUser: true, index: sideIndex, shouldAnimate: shouldAnimate))
                    Text(timeString(message.timestamp)).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                }
            } else {
                Circle().fill(agent.avatarColor.opacity(0.15)).frame(width: 28, height: 28)
                    .overlay(Circle().stroke(agent.avatarColor.opacity(0.3), lineWidth: 0.5))
                    .overlay(Text(String(agent.name.prefix(1))).font(.system(size: 11, weight: .bold)).foregroundColor(agent.avatarColor))

                VStack(alignment: .leading, spacing: 3) {
                    markdownText(message.content.isEmpty ? " " : message.content)
                        .font(.system(size: 13)).foregroundColor(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(AnimatedGradientBubble(isUser: false, index: sideIndex, isThinking: isThinking, isLatest: isLatest, shouldAnimate: shouldAnimate))
                    Text(timeString(message.timestamp)).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                }
                Spacer(minLength: 60)
            }
        }
        .padding(.vertical, 2)
    }

    func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }
}

struct BubbleShape: Shape {
    let isUser: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 12; let smallR: CGFloat = 3; var path = Path()
        if isUser {
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - smallR))
            path.addArc(center: CGPoint(x: rect.maxX - smallR, y: rect.maxY - smallR), radius: smallR, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + smallR, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + smallR, y: rect.maxY - smallR), radius: smallR, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath(); return path
    }
}


// MARK: - Input Bar

struct AnimatedSendButton: View {
    @State private var shift: CGFloat = 0

    var body: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(
                    stops: [
                        .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(0.90), location: max(0, 0.00 - shift)),
                        .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55).opacity(0.90), location: max(0, min(1, 0.25 - shift))),
                        .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.90), location: max(0, min(1, 0.50 - shift))),
                        .init(color: Color(red: 0.30, green: 0.55, blue: 1.00).opacity(0.90), location: max(0, min(1, 0.75 - shift))),
                        .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.88), location: min(1, 1.00 - shift)),
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                ))
                .frame(width: 32, height: 26)
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(.white)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                shift = 0.30
            }
        }
    }
}

struct InputBarView: View {
    @Binding var inputText: String
    @Binding var agent: Agent
    @Binding var pendingCompact: Bool
    @EnvironmentObject var state: AppState
    @State private var pastedContent: String? = nil

    var isStreaming: Bool { state.streamingAgents.contains(agent.id) }

    // Returns the name of a different agent that is currently streaming, if any
    var otherStreamingAgentName: String? {
        guard let streaming = state.streamingAgents.first(where: { $0 != agent.id }) else { return nil }
        return state.agents.first(where: { $0.id == streaming })?.name
    }

    var body: some View {
        VStack(spacing: 0) {
            if let otherName = otherStreamingAgentName {
                HStack(spacing: 6) {
                    TypingIndicator()
                    Text("\(otherName) is responding. Please wait…")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.35))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            } else if isStreaming {
                HStack(spacing: 6) {
                    TypingIndicator()
                    Text("\(agent.name) is thinking…")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.35))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }

            if let pasted = pastedContent {
                let lineCount = pasted.components(separatedBy: .newlines).count
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text("Pasted text • \(lineCount) lines")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.7))
                    Spacer()
                    Button(action: { pastedContent = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(opacity: 0.10, cornerRadius: 10, borderOpacity: 0.15)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 0) {
                TextField("Message \(agent.name)...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(1...5)
                    .onSubmit { sendMessage() }
                    .padding(.horizontal, 13)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .onChange(of: inputText) { newValue in
                        let lines = newValue.components(separatedBy: .newlines)
                        if lines.count > 10 {
                            pastedContent = newValue
                            inputText = ""
                        } else if newValue.count > 80000 {
                            inputText = String(newValue.prefix(80000))
                        }
                    }

                Button(action: sendMessage) {
                    AnimatedSendButton()
                        .opacity((inputText.isEmpty && pastedContent == nil || isStreaming || otherStreamingAgentName != nil) ? 0 : 1)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .padding(.top, 4)
                .padding(.bottom, 4)
                .allowsHitTesting((!inputText.isEmpty || pastedContent != nil) && !isStreaming && otherStreamingAgentName == nil)
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            )
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: pastedContent != nil)
        .onChange(of: pendingCompact) { pending in
            if pending { pendingCompact = false; sendMessage() }
        }
    }

    func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPasted = pastedContent != nil

        guard (!trimmed.isEmpty || hasPasted), !isStreaming, otherStreamingAgentName == nil else { return }

        var fullContent = trimmed
        if let pasted = pastedContent {
            let pastedBlock = "[Pasted content]\n\(pasted)"
            fullContent = trimmed.isEmpty ? pastedBlock : "\(trimmed)\n\n\(pastedBlock)"
        }

        let displayContent: String = {
            if let pasted = pastedContent {
                let lineCount = pasted.components(separatedBy: .newlines).count
                let preview = trimmed.isEmpty ? "📄 Pasted text • \(lineCount) lines" : "\(trimmed)\n📄 Pasted text • \(lineCount) lines"
                return preview
            }
            return trimmed
        }()

        let userMsg = Message(content: displayContent, isUser: true, timestamp: Date(), agentName: nil)
        if state.messages[agent.id] == nil { state.messages[agent.id] = [] }
        state.messages[agent.id]?.append(userMsg)
        state.updateSidebarPreview(for: agent.id)

        inputText     = ""
        pastedContent = nil
        state.streamingAgents.insert(agent.id)

        DispatchQueue.main.async {
            if let idx = self.state.agents.firstIndex(where: { $0.id == agent.id }) {
                self.state.agents[idx].status = .thinking
            }
        }

        let agentId       = agent.id
        let agentName     = agent.name
        let messageToSend = fullContent

        Task {
            await streamResponse(agentId: agentId, agentName: agentName, message: messageToSend)
        }
    }

    func streamResponse(agentId: String, agentName: String, message: String) async {
        let replyId     = UUID()
        let placeholder = Message(id: replyId, content: "", isUser: false, timestamp: Date(), agentName: agentName)
        state.messages[agentId]?.append(placeholder)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed     = false
            var buffer      = ""
            var displayLink: Timer?
            var idleTimer:   Timer?

            func updateUIForCompletion() {
                if let idx = self.state.agents.firstIndex(where: { $0.id == agentId }) {
                    self.state.agents[idx].status = .idle
                }
                self.state.updateSidebarPreview(for: agentId)
            }

            func resetIdleTimer() {
                idleTimer?.invalidate()
                idleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                    DispatchQueue.main.async {
                        if let idx = self.state.agents.firstIndex(where: { $0.id == agentId }),
                           self.state.agents[idx].status == .responding {
                            self.state.agents[idx].status = .idle
                        }
                        self.state.updateSidebarPreview(for: agentId)
                    }
                }
            }

            func flush() {
                guard !buffer.isEmpty else { return }
                let charsPerTick = buffer.count > 20 ? 8 : 3
                let chunk = String(buffer.prefix(charsPerTick))
                buffer = String(buffer.dropFirst(chunk.count))
                guard let idx = self.state.messages[agentId]?.firstIndex(where: { $0.id == replyId }) else { return }
                self.state.messages[agentId]?[idx].content += chunk
            }

            func finish() {
                guard !resumed else { return }
                resumed = true
                idleTimer?.invalidate()
                idleTimer = nil
                displayLink?.invalidate()
                displayLink = nil
                if !buffer.isEmpty {
                    let remaining = buffer
                    buffer = ""
                    if let idx = self.state.messages[agentId]?.firstIndex(where: { $0.id == replyId }) {
                        self.state.messages[agentId]?[idx].content += remaining
                    }
                }
                DispatchQueue.main.async {
                    self.state.streamingAgents.remove(agentId)
                    updateUIForCompletion()
                    if let agent = self.state.agents.first(where: { $0.id == agentId }) {
                        self.state.saveChat(for: agent)
                    }
                    continuation.resume()
                }
            }

            let dl = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in flush() }
            displayLink = dl

            state.wsManager.send(
                message: message,
                agentID: agentId,

                onToken: { token in
                    if token.isEmpty {
                        DispatchQueue.main.async {
                            updateUIForCompletion()
                            finish()
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        buffer += token
                        if let idx = self.state.agents.firstIndex(where: { $0.id == agentId }),
                           self.state.agents[idx].status == .thinking {
                            self.state.agents[idx].status = .responding
                        }
                        if let idx = self.state.agents.firstIndex(where: { $0.id == agentId }),
                           self.state.agents[idx].status == .responding {
                            resetIdleTimer()
                        }
                    }
                },

                onError: { errorMessage in
                    DispatchQueue.main.async {
                        guard let idx = self.state.messages[agentId]?.firstIndex(where: { $0.id == replyId }) else { return }
                        self.state.messages[agentId]?[idx].content = "⚠️ \(errorMessage)"
                        finish()
                    }
                }
            )
        }
    }
}

struct TypingIndicator: View {
    @State private var phase = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.white.opacity(phase == i ? 0.8 : 0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 }
        }
    }
}

// MARK: - Personality Matrix

// Reusable markdown file editor sheet
struct MarkdownEditorSheet: View {
    let title: String
    let filePath: String
    @Binding var content: String
    let onSave: () -> Bool
    let onDismiss: () -> Void

    @State private var editBuffer   = ""
    @State private var backup       = ""
    @State private var showRestored = false
    @State private var saveError    = false

    var hasChanges: Bool { editBuffer != backup }

    func saveChanges() {
        content = editBuffer
        let success = onSave()
        if success {
            backup = editBuffer
            saveError = false
            onDismiss()
        } else {
            content = backup
            saveError = true
        }
    }

    func undoChanges() {
        editBuffer = backup
        showRestored = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showRestored = false }
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.12).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(title, systemImage: "cpu")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    if hasChanges {
                        Button(action: undoChanges) {
                            Label("Undo", systemImage: "arrow.uturn.backward").font(.system(size: 12)).foregroundColor(.orange)
                        }.buttonStyle(.plain).padding(.trailing, 8)
                    }
                    Button("Cancel") { onDismiss() }.font(.system(size: 13)).foregroundColor(Color.white.opacity(0.5)).buttonStyle(.plain)
                    Button("Save") { saveChanges() }
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(hasChanges ? Color.blue.opacity(0.8) : Color.white.opacity(0.1))
                        .cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        .buttonStyle(.plain).disabled(!hasChanges)
                }
                HStack(spacing: 6) {
                    Circle().fill(saveError ? Color.red : (showRestored ? Color.orange : (hasChanges ? Color.yellow : Color.green))).frame(width: 7, height: 7)
                    Text(saveError ? "Failed to save — check file permissions" : (showRestored ? "Restored to original" : (hasChanges ? "Unsaved changes" : "No changes")))
                        .font(.system(size: 12)).foregroundColor(saveError ? .red : Color.white.opacity(0.4))
                }
                Text("Editing: \(filePath)").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.25))
                TextEditor(text: $editBuffer)
                    .font(.system(size: 14)).foregroundColor(.white).scrollContentBackground(.hidden)
                    .padding(12)
                    .glassBackground(opacity: hasChanges ? 0.10 : 0.07, cornerRadius: 10, borderOpacity: hasChanges ? 0.25 : 0.12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 460).preferredColorScheme(.dark)
        .onAppear {
            editBuffer = content
            backup = content
        }
    }
}

struct PersonalityMatrixView: View {
    @Binding var agent: Agent
    @EnvironmentObject var state: AppState
    @State private var showSoulEditor     = false
    @State private var showIdentityEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Personality Matrix", systemImage: "cpu")
                .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))

            VStack(alignment: .leading, spacing: 6) {
                // Identity row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent Identity")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        Text(agent.identityMDFound ? "Configured" : "Not configured")
                            .font(.system(size: 11))
                            .foregroundColor(agent.identityMDFound ? Color.white.opacity(0.4) : .orange)
                    }
                    Spacer()
                    Button(action: { showIdentityEditor = true }) {
                        Label(agent.identityMDFound ? "Edit" : "Create", systemImage: agent.identityMDFound ? "pencil" : "plus")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(.blue)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)

                // Soul row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent Soul")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        Text(agent.soulMDFound ? "Configured" : "Not configured")
                            .font(.system(size: 11))
                            .foregroundColor(agent.soulMDFound ? Color.white.opacity(0.4) : .orange)
                    }
                    Spacer()
                    Button(action: { showSoulEditor = true }) {
                        Label(agent.soulMDFound ? "Edit" : "Create", systemImage: agent.soulMDFound ? "pencil" : "plus")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(.blue)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
            }
        }
        .sheet(isPresented: $showSoulEditor) {
            MarkdownEditorSheet(
                title: "Soul",
                filePath: "\(agent.workspacePath)/SOUL.md",
                content: $agent.systemPrompt,
                onSave: {
                    let success = state.saveSoulMD(for: agent)
                    if success { agent.soulMDFound = true }
                    return success
                },
                onDismiss: { showSoulEditor = false }
            )
        }
        .sheet(isPresented: $showIdentityEditor) {
            MarkdownEditorSheet(
                title: "Identity",
                filePath: "\(agent.workspacePath)/IDENTITY.md",
                content: $agent.identityContent,
                onSave: {
                    let success = state.saveIdentityMD(for: agent)
                    if success { agent.identityMDFound = true }
                    return success
                },
                onDismiss: { showIdentityEditor = false }
            )
        }
    }
}

// MARK: - Heartbeat Editor

struct HeartbeatEditorView: View {
    @Binding var agent: Agent
    @EnvironmentObject var state: AppState
    @State private var selectedInterval: String = ""
    @State private var customInterval: String   = ""
    @State private var showCustomField = false
    @State private var intervalSaved   = false

    let presets = ["30m", "1h", "2h", "4h", "6h", "12h", "24h", "Custom"]

    func saveInterval() {
        let interval: String
        if showCustomField {
            interval = customInterval.trimmingCharacters(in: .whitespaces)
            guard !interval.isEmpty else { return }
        } else if selectedInterval.isEmpty {
            interval = "off"
        } else {
            interval = selectedInterval
        }
        agent.heartbeatInterval = interval
        let success = state.saveHeartbeatInterval(for: agent)
        if success {
            intervalSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { intervalSaved = false }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Heartbeat", systemImage: "heart.fill")
                .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))

            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(presets, id: \.self) { preset in
                        Button(action: {
                            selectedInterval = preset
                            showCustomField  = preset == "Custom"
                        }) {
                            Text(preset)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(selectedInterval == preset ? .white : Color.white.opacity(0.5))
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(selectedInterval == preset ? Color.blue.opacity(0.6) : Color.white.opacity(0.06))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                                    selectedInterval == preset ? Color.blue.opacity(0.8) : Color.white.opacity(0.1),
                                    lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if showCustomField {
                    TextField("e.g. 2h, 45m", text: $customInterval)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassBackground(opacity: 0.08, cornerRadius: 6, borderOpacity: 0.15)
                }

                HStack {
                    if intervalSaved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 11))
                            Text("Saved").font(.system(size: 11)).foregroundColor(.green)
                        }
                    } else {
                        Text("Currently: \(agent.heartbeatInterval == "off" ? "Off" : agent.heartbeatInterval)")
                            .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.25))
                    }
                    Spacer()
                    Button(action: saveInterval) {
                        Text("Apply")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Color.blue.opacity(0.6)).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10).frame(maxWidth: .infinity)
            .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
        }
        .onAppear { syncToAgent() }
        .onChange(of: agent.id) { _ in syncToAgent() }
        .onChange(of: agent.heartbeatInterval) { _ in syncToAgent() }
    }

    func syncToAgent() {
        intervalSaved = false
        let current   = agent.heartbeatInterval
        if current == "off" || current.isEmpty {
            selectedInterval = ""; customInterval = ""; showCustomField = false
        } else if presets.contains(current) {
            selectedInterval = current; customInterval = ""; showCustomField = false
        } else {
            selectedInterval = "Custom"; customInterval = current; showCustomField = true
        }
    }
}

// MARK: - Agent Settings Panel

struct AgentSettingsPanel: View {
    @Binding var agent: Agent
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.12).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Agent Settings")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white).padding(.top, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Model", systemImage: "cpu")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                        Text(agent.role).font(.system(size: 13)).foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Workspace", systemImage: "folder")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                        Text(agent.workspacePath).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                    }

                    PersonalityMatrixView(agent: $agent).environmentObject(state)
                    HeartbeatEditorView(agent: $agent).environmentObject(state)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Activity", systemImage: "chart.bar.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                        VStack(alignment: .leading, spacing: 6) {
                            ActivityLogRow(icon: "circle.fill", color: agent.status.color, text: agent.status.label)
                            ActivityLogRow(icon: "folder",      color: Color.white.opacity(0.3), text: agent.soulMDFound ? "Personality Matrix loaded" : "Personality Matrix missing")
                            ActivityLogRow(icon: "heart",       color: .pink, text: agent.heartbeatMDFound ? "Heartbeat loaded" : "Heartbeat not configured")
                            ActivityLogRow(icon: "message",     color: .blue, text: "\(state.messages[agent.id]?.count ?? 0) messages this session")
                        }
                        .padding(10)
                        .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                    }

                    Spacer()
                }
                .padding(16)
            }
        }
    }
}

struct ActivityLogRow: View {
    let icon: String; let color: Color; let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(color).frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.06, blue: 0.12), Color(red: 0.04, green: 0.04, blue: 0.09)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48)).foregroundColor(Color.white.opacity(0.15))
                Text("Select an agent to start chatting")
                    .font(.system(size: 15)).foregroundColor(Color.white.opacity(0.3))
                if let error = state.loadError {
                    Text(error).font(.system(size: 12)).foregroundColor(.orange).padding(.top, 4)
                    Text("Make sure openclaw.json is configured correctly")
                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.3))
                }
            }
        }
    }
}


// MARK: - API Key Manager

struct APIKeyManagerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var gatewayToken: String = ""
    @State private var saveStatus: String? = nil
    @State private var isError: Bool = false
    @State private var anthropicRevealed: Bool = false
    @State private var openAIRevealed: Bool = false
    @State private var gatewayRevealed: Bool = false

    // Check for env variable conflicts
    var anthropicEnvConflict: Bool { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil }
    var openAIEnvConflict: Bool { ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil }
    var gatewayEnvConflict: Bool { ProcessInfo.processInfo.environment["OPENCLAW_GATEWAY_TOKEN"] != nil }

    func authenticate(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Reveal API key") { success, _ in
                DispatchQueue.main.async { completion(success) }
            }
        } else {
            // No biometrics available — fall back to allowing reveal
            completion(true)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.12).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("API Keys")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.5))
                        .buttonStyle(.plain)
                }

                Text("API keys are saved to each agent's auth-profiles.json. The gateway token is saved to openclaw.json. Changes take effect the next time the gateway loads credentials.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)

                // Env variable conflict warning
                if anthropicEnvConflict || openAIEnvConflict || gatewayEnvConflict {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Environment variable conflict detected")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.orange)
                            let conflicts = [
                                anthropicEnvConflict ? "ANTHROPIC_API_KEY" : nil,
                                openAIEnvConflict ? "OPENAI_API_KEY" : nil,
                                gatewayEnvConflict ? "OPENCLAW_GATEWAY_TOKEN" : nil
                            ].compactMap { $0 }
                            Text("\(conflicts.joined(separator: " and ")) \(conflicts.count == 1 ? "is" : "are") set in your shell environment and may override the values saved here. Remove \(conflicts.count == 1 ? "it" : "them") from ~/.zshrc to avoid conflicts.")
                                .font(.system(size: 11))
                                .foregroundColor(Color.orange.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .glassBackground(opacity: 0.06, cornerRadius: 8, borderOpacity: 0.25)
                }

                // Anthropic
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Anthropic", systemImage: "brain")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.5))
                        if anthropicEnvConflict {
                            Text("ENV OVERRIDE ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                    HStack(spacing: 8) {
                        Group {
                            if anthropicRevealed {
                                TextField("sk-ant-...", text: $anthropicKey)
                            } else {
                                SecureField("sk-ant-...", text: $anthropicKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: anthropicEnvConflict ? 0.4 : 0.15)

                        Button(action: {
                            if anthropicRevealed {
                                anthropicRevealed = false
                            } else {
                                authenticate { success in
                                    if success { anthropicRevealed = true }
                                }
                            }
                        }) {
                            Image(systemName: anthropicRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundColor(Color.white.opacity(0.4))
                                .frame(width: 32, height: 32)
                                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                        }
                        .buttonStyle(.plain)
                        .help(anthropicRevealed ? "Hide key" : "Reveal key with Touch ID")
                    }
                }

                // OpenAI
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("OpenAI", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.5))
                        if openAIEnvConflict {
                            Text("ENV OVERRIDE ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                    HStack(spacing: 8) {
                        Group {
                            if openAIRevealed {
                                TextField("sk-proj-...", text: $openAIKey)
                            } else {
                                SecureField("sk-proj-...", text: $openAIKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: openAIEnvConflict ? 0.4 : 0.15)

                        Button(action: {
                            if openAIRevealed {
                                openAIRevealed = false
                            } else {
                                authenticate { success in
                                    if success { openAIRevealed = true }
                                }
                            }
                        }) {
                            Image(systemName: openAIRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundColor(Color.white.opacity(0.4))
                                .frame(width: 32, height: 32)
                                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                        }
                        .buttonStyle(.plain)
                        .help(openAIRevealed ? "Hide key" : "Reveal key with Touch ID")
                    }
                }

                // Gateway Token
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Gateway Token", systemImage: "lock.shield")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.5))
                        if gatewayEnvConflict {
                            Text("ENV OVERRIDE ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                    HStack(spacing: 8) {
                        Group {
                            if gatewayRevealed {
                                TextField("Gateway auth token...", text: $gatewayToken)
                            } else {
                                SecureField("Gateway auth token...", text: $gatewayToken)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: gatewayEnvConflict ? 0.4 : 0.15)

                        Button(action: {
                            if gatewayRevealed {
                                gatewayRevealed = false
                            } else {
                                authenticate { success in
                                    if success { gatewayRevealed = true }
                                }
                            }
                        }) {
                            Image(systemName: gatewayRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundColor(Color.white.opacity(0.4))
                                .frame(width: 32, height: 32)
                                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                        }
                        .buttonStyle(.plain)
                        .help(gatewayRevealed ? "Hide token" : "Reveal token with Touch ID")
                    }
                }

                if let status = saveStatus {
                    HStack(spacing: 6) {
                        Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(isError ? .red : .green)
                            .font(.system(size: 12))
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundColor(isError ? .red : .green)
                    }
                }

                HStack {
                    Spacer()
                    Button(action: saveKeys) {
                        Text("Save Keys")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.7))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(anthropicKey.isEmpty && openAIKey.isEmpty && gatewayToken.isEmpty)
                }

                Spacer()
            }
            .padding(28)
        }
        .frame(width: 420, height: 460)
        .preferredColorScheme(.dark)
        .onAppear { loadCurrentKeys() }
        .onDisappear {
            anthropicRevealed = false
            openAIRevealed = false
            gatewayRevealed = false
        }
    }

    func loadCurrentKeys() {
        // Load gateway token from openclaw.json
        if gatewayToken.isEmpty, let token = OpenClawLoader.shared.readGatewayToken(configPath: state.configPath) {
            gatewayToken = token
        }

        // Load existing API keys from the first agent that has them
        for agent in state.agents {
            guard let agentConfig = agent.agentConfig else { continue }
            let agentDir = agentConfig.agentDir ?? ""
            let path = (agentDir as NSString).appendingPathComponent("auth-profiles.json")
            let expandedPath = (path as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: expandedPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profiles = json["profiles"] as? [String: Any] else { continue }
            if anthropicKey.isEmpty, let p = profiles["anthropic:default"] as? [String: Any], let key = p["key"] as? String {
                anthropicKey = key
            }
            if openAIKey.isEmpty, let p = profiles["openai:default"] as? [String: Any], let key = p["key"] as? String {
                openAIKey = key
            }
            if !anthropicKey.isEmpty && !openAIKey.isEmpty { break }
        }
    }

    func saveKeys() {
        var successCount = 0
        var failCount = 0

        // Save gateway token to openclaw.json
        if !gatewayToken.isEmpty {
            if OpenClawLoader.shared.writeGatewayToken(gatewayToken, configPath: state.configPath) {
                successCount += 1
            } else {
                failCount += 1
            }
        }

        // Save API keys to each agent's auth-profiles.json
        for agent in state.agents {
            guard let agentConfig = agent.agentConfig else { continue }
            let agentDir = agentConfig.agentDir ?? ""
            let path = ((agentDir as NSString).appendingPathComponent("auth-profiles.json") as NSString).expandingTildeInPath

            var json: [String: Any] = [:]
            if let data = FileManager.default.contents(atPath: path),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = existing
            }

            var profiles = json["profiles"] as? [String: Any] ?? [:]

            if !anthropicKey.isEmpty {
                profiles["anthropic:default"] = [
                    "type": "api_key",
                    "provider": "anthropic",
                    "key": anthropicKey
                ]
            }
            if !openAIKey.isEmpty {
                profiles["openai:default"] = [
                    "type": "api_key",
                    "provider": "openai",
                    "key": openAIKey
                ]
            }

            json["profiles"] = profiles

            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
               (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
                successCount += 1
            } else {
                failCount += 1
            }
        }

        if failCount == 0 {
            saveStatus = "Saved to \(successCount) agent(s) successfully"
            isError = false
        } else {
            saveStatus = "Saved \(successCount), failed \(failCount)"
            isError = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { saveStatus = nil }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().frame(width: 1000, height: 680)
    }
}

