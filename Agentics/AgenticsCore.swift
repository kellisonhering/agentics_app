import SwiftUI
import CryptoKit
import Security
import LocalAuthentication
import UniformTypeIdentifiers

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
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var gateway = json["gateway"] as? [String: Any],
              var auth = gateway["auth"] as? [String: Any] else { return false }
        auth["token"] = token
        gateway["auth"] = auth
        json["gateway"] = gateway
        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do { try newData.write(to: URL(fileURLWithPath: expandedPath), options: .atomic); return true }
        catch { print("[KeyStore] Failed to write gateway token: \(error)"); return false }
    }

    func writeAgentModel(_ model: String, agentId: String, configPath: String) -> Bool {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath),
              var json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var agents = json["agents"] as? [String: Any],
              var list   = agents["list"] as? [[String: Any]] else { return false }
        guard let idx = list.firstIndex(where: { $0["id"] as? String == agentId }) else { return false }
        list[idx]["model"] = ["primary": model]
        agents["list"] = list
        json["agents"]  = agents
        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do { try newData.write(to: URL(fileURLWithPath: expandedPath), options: .atomic); return true }
        catch { print("[OpenClawLoader] Failed to write agent model: \(error)"); return false }
    }

    /// Appends a new agent entry to openclaw.json and returns the workspace path on success.
    func addAgent(id: String, name: String, model: String, configPath: String) -> (success: Bool, workspacePath: String?) {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        guard let data    = FileManager.default.contents(atPath: expandedPath),
              var json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var agents  = json["agents"] as? [String: Any],
              var list    = agents["list"] as? [[String: Any]],
              let defaults        = agents["defaults"] as? [String: Any],
              let defaultWorkspace = defaults["workspace"] as? String
        else { return (false, nil) }

        // Reject duplicate IDs
        if list.contains(where: { $0["id"] as? String == id }) { return (false, nil) }

        let agentWorkspace = (defaultWorkspace as NSString).appendingPathComponent(id)

        let newAgent: [String: Any] = [
            "id":        id,
            "name":      name,
            "workspace": agentWorkspace,
            "model":     ["primary": model]
        ]

        list.append(newAgent)
        agents["list"] = list
        json["agents"] = agents

        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return (false, nil) }
        do {
            try newData.write(to: URL(fileURLWithPath: expandedPath), options: .atomic)
            return (true, agentWorkspace)
        } catch {
            print("[OpenClawLoader] Failed to add agent: \(error)")
            return (false, nil)
        }
    }

    /// Removes an agent entry from openclaw.json by ID. Returns true on success.
    /// Does not touch the agent's workspace files on disk — caller decides what to do with those.
    func removeAgent(id: String, configPath: String) -> Bool {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        guard let data   = FileManager.default.contents(atPath: expandedPath),
              var json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var agents = json["agents"] as? [String: Any],
              var list   = agents["list"] as? [[String: Any]]
        else { return false }

        let countBefore = list.count
        list.removeAll { $0["id"] as? String == id }

        // If nothing was removed the ID didn't exist — treat as failure
        guard list.count < countBefore else { return false }

        agents["list"] = list
        json["agents"] = agents

        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try newData.write(to: URL(fileURLWithPath: expandedPath), options: .atomic)
            print("[OpenClawLoader] Removed agent '\(id)' from config")
            return true
        } catch {
            print("[OpenClawLoader] Failed to remove agent '\(id)': \(error)")
            return false
        }
    }

    // MARK: - .env File (global API keys for all agents)

    var dotEnvPath: String = ("~/.openclaw/.env" as NSString).expandingTildeInPath

    private func readDotEnv() -> [String: String] {
        guard let contents = try? String(contentsOfFile: dotEnvPath, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            result[key] = value
        }
        return result
    }

    private func writeDotEnv(_ values: [String: String]) -> Bool {
        var existing = readDotEnv()
        for (k, v) in values { existing[k] = v }
        let contents = existing.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") + "\n"
        do { try contents.write(toFile: dotEnvPath, atomically: true, encoding: .utf8); return true }
        catch { print("[KeyStore] Failed to write .env: \(error)"); return false }
    }

    func readEnvKey(_ name: String) -> String? {
        let value = readDotEnv()[name]
        return value?.isEmpty == false ? value : nil
    }

    func writeEnvKeys(_ keys: [String: String]) -> Bool {
        writeDotEnv(keys)
    }

    func readGeminiKey() -> String? { readEnvKey("GOOGLE_API_KEY") }
    func readAnthropicKey() -> String? { readEnvKey("ANTHROPIC_API_KEY") }
    func readOpenAIKey() -> String? { readEnvKey("OPENAI_API_KEY") }
    func readIBMQuantumKey() -> String? { readEnvKey("IBM_QUANTUM_TOKEN") }

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
    case idle, thinking, responding, error, restarting

    var label: String {
        switch self {
        case .idle:       return "Idle"
        case .thinking:   return "Thinking..."
        case .responding: return "Responding..."
        case .error:      return "Error"
        case .restarting: return "Restarting..."
        }
    }

    var color: Color {
        switch self {
        case .idle:       return .green
        case .thinking:   return .yellow
        case .responding: return .blue
        case .error:      return .red
        case .restarting: return .yellow
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
    var isSystemNotice: Bool

    enum CodingKeys: String, CodingKey {
        case id, content, isUser, timestamp, agentName, isSystemNotice
    }

    init(id: UUID = UUID(), content: String, isUser: Bool, timestamp: Date, agentName: String?, isSystemNotice: Bool = false) {
        self.id             = id
        self.content        = content
        self.isUser         = isUser
        self.timestamp      = timestamp
        self.agentName      = agentName
        self.isSystemNotice = isSystemNotice
    }

    // Custom decoder so existing saved chat history (which has no isSystemNotice field)
    // loads correctly instead of throwing a decoding error.
    init(from decoder: Decoder) throws {
        let container   = try decoder.container(keyedBy: CodingKeys.self)
        id              = try container.decode(UUID.self,   forKey: .id)
        content         = try container.decode(String.self, forKey: .content)
        isUser          = try container.decode(Bool.self,   forKey: .isUser)
        timestamp       = try container.decode(Date.self,   forKey: .timestamp)
        agentName       = try container.decodeIfPresent(String.self, forKey: .agentName)
        isSystemNotice  = (try? container.decodeIfPresent(Bool.self, forKey: .isSystemNotice)) ?? false
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
    @Published var settingsPanelVisible: Bool = true
    @Published var streamingAgents: Set<String> = []
    let wsManager = OpenClawWebSocket()

    private let avatarColors: [Color] = [.purple, .cyan, .orange, .green, .blue, .pink, .yellow]
    private var agentDefaults: AgentDefaults? = nil

    init() {
        loadAgents()
        NotificationCenter.default.addObserver(
            forName: .gatewayDidReconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("[AppState] Gateway reconnected — clearing BOOTSTRAP.md for all agents")
            for agent in self.agents { self.clearBootstrapMD(for: agent) }
        }

        NotificationCenter.default.addObserver(
            forName: .gatewayDidInterrupt,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let agentIds = notification.userInfo?["agentIds"] as? [String] else { return }
            print("[AppState] Connection interrupted — cleaning up streams for: \(agentIds)")
            for agentId in agentIds {
                // Remove any empty streaming bubble left behind — it will never receive content
                if let lastIdx = self.messages[agentId]?.lastIndex(where: { !$0.isUser && !$0.isSystemNotice }),
                   self.messages[agentId]?[lastIdx].content.isEmpty == true {
                    self.messages[agentId]?.remove(at: lastIdx)
                }
                // Insert a system notice in place of the lost response
                let notice = Message(
                    content: "Connection interrupted\nResponse may be incomplete",
                    isUser: false,
                    timestamp: Date(),
                    agentName: nil,
                    isSystemNotice: true
                )
                self.messages[agentId, default: []].append(notice)
                // Clean up streaming state so the send button unlocks
                self.streamingAgents.remove(agentId)
                if let idx = self.agents.firstIndex(where: { $0.id == agentId }) {
                    self.agents[idx].status = .idle
                }
                if let agent = self.agents.first(where: { $0.id == agentId }) {
                    self.saveChat(for: agent)
                }
            }
        }
    }

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
        if selectedAgent == nil { selectedAgent = agents.first }
    }

    func saveSoulMD(for agent: Agent) -> Bool {
        guard let agentConfig = agent.agentConfig, let defaults = agentDefaults else { return false }
        return OpenClawLoader.shared.writeSoulMD(content: agent.systemPrompt, for: agentConfig, defaults: defaults)
    }

    func saveIdentityMD(for agent: Agent) -> Bool {
        guard let agentConfig = agent.agentConfig, let defaults = agentDefaults else { return false }
        return OpenClawLoader.shared.writeIdentityMD(content: agent.identityContent, for: agentConfig, defaults: defaults)
    }

    func saveChat(for agent: Agent) {
        guard let agentConfig = agent.agentConfig, let defaults = agentDefaults else { return }
        let msgs = (messages[agent.id] ?? []).suffix(500)
        OpenClawLoader.shared.writeChat(Array(msgs), for: agentConfig, defaults: defaults)
    }

    func writeBootstrapMD(content: String, for agent: Agent) {
        let path = ((agent.workspacePath as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent("BOOTSTRAP.md")
        DispatchQueue.global(qos: .utility).async {
            do { try content.write(toFile: path, atomically: true, encoding: .utf8)
                print("[AppState] Wrote BOOTSTRAP.md for \(agent.id)") }
            catch { print("[AppState] Failed to write BOOTSTRAP.md: \(error)") }
        }
    }

    func clearBootstrapMD(for agent: Agent) {
        let path = ((agent.workspacePath as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent("BOOTSTRAP.md")
        DispatchQueue.global(qos: .utility).async {
            do { try "".write(toFile: path, atomically: true, encoding: .utf8)
                print("[AppState] Cleared BOOTSTRAP.md for \(agent.id)") }
            catch { print("[AppState] Failed to clear BOOTSTRAP.md: \(error)") }
        }
    }

    /// Appends a model-switch summary entry to handoff-log.md in the agent's workspace.
    /// Creates the file with a header the first time it is called for a given agent.
    func appendToHandoffLog(summary: String, fromModel: String, toModel: String, for agent: Agent) {
        let path = ((agent.workspacePath as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent("handoff-log.md")

        let formatter        = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp        = formatter.string(from: Date())

        let entry = """


        ---

        ## \(timestamp)
        From: \(fromModel) → To: \(toModel)

        \(summary)
        """

        DispatchQueue.global(qos: .utility).async {
            if !FileManager.default.fileExists(atPath: path) {
                let header = "# Handoff Log — \(agent.name)\n"
                do {
                    try (header + entry).write(toFile: path, atomically: true, encoding: .utf8)
                    print("[AppState] Created handoff-log.md for \(agent.id)")
                } catch {
                    print("[AppState] Failed to create handoff-log.md: \(error)")
                }
            } else {
                if let fileHandle = FileHandle(forWritingAtPath: path) {
                    fileHandle.seekToEndOfFile()
                    if let data = entry.data(using: .utf8) { fileHandle.write(data) }
                    fileHandle.closeFile()
                    print("[AppState] Appended to handoff-log.md for \(agent.id)")
                } else {
                    print("[AppState] Failed to open handoff-log.md for appending")
                }
            }
        }
    }

    func updateAgentModel(agentId: String, newModel: String) {
        if let idx = agents.firstIndex(where: { $0.id == agentId }) {
            agents[idx].role = newModel
        }
        if selectedAgent?.id == agentId {
            selectedAgent?.role = newModel
        }
        let success = OpenClawLoader.shared.writeAgentModel(newModel, agentId: agentId, configPath: configPath)
        print("[AppState] Model update for \(agentId) → \(newModel): \(success ? "saved" : "failed")")
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
    @StateObject var avatarService = AgentAvatarService()
    @State private var showAPIKeyManager = false

    var body: some View {
        NavigationSplitView {
            SidebarView().environmentObject(state).environmentObject(avatarService)
        } detail: {
            if let agent = state.selectedAgent {
                ChatView(agent: binding(for: agent))
                    .environmentObject(state)
                    .environmentObject(avatarService)
                    .id(agent.id)
            } else {
                EmptyStateView().environmentObject(state)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAPIKeyManager) {
            APIKeyManagerView().environmentObject(state).environmentObject(avatarService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAPIKeyManager)) { _ in
            showAPIKeyManager = true
        }
        .task {
            await avatarService.loadAll(agents: state.agents)
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
    @State private var searchText      = ""
    @State private var showCreateAgent = false

    var filteredAgents: [Agent] {
        if searchText.isEmpty { return state.agents }
        return state.agents.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.role.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.14, green: 0.14, blue: 0.14).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Agentics")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    // + button disabled until create agent flow is redesigned
                    // Button(action: { showCreateAgent = true }) {
                    //     Image(systemName: "plus")
                    //         .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
                    //         .font(.system(size: 16, weight: .medium))
                    // }
                    // .buttonStyle(.plain)
                    // .help("Add new agent")
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
        .sheet(isPresented: $showCreateAgent) {
            CreateAgentSheet().environmentObject(state)
        }
    }
}

struct AgentRowView: View {
    let agent: Agent
    @EnvironmentObject var state: AppState
    @EnvironmentObject var avatarService: AgentAvatarService
    var isSelected: Bool { state.selectedAgent?.id == agent.id }
    var liveStatus: AgentStatus { state.agents.first(where: { $0.id == agent.id })?.status ?? agent.status }

    var body: some View {
        let avatarImage: CGImage? = avatarService.avatarImages[agent.id]
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let cgImage = avatarImage {
                    Image(cgImage, scale: 1.0, label: Text(agent.name))
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(agent.avatarColor.opacity(0.3), lineWidth: 1))
                } else {
                    Circle()
                        .fill(agent.avatarColor.opacity(0.15))
                        .frame(width: 46, height: 46)
                        .overlay(Circle().stroke(agent.avatarColor.opacity(0.3), lineWidth: 1))
                        .overlay(
                            Text(String(agent.name.prefix(1)))
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(agent.avatarColor)
                        )
                }
                AgentStatusDot(status: liveStatus, size: 11)
                    .id(liveStatus)
                    .overlay(Circle().stroke(Color(red: 0.14, green: 0.14, blue: 0.14), lineWidth: 2))
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
                            .background(Color(red: 1.0, green: 0.25, blue: 0.55)).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(isSelected ? Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.12) : Color.clear)
        .overlay(
            isSelected ? Rectangle().fill(Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.6))
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
    @EnvironmentObject var avatarService: AgentAvatarService
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
            Color(red: 0.10, green: 0.10, blue: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {
                ChatHeaderView(agent: $agent, onCompact: compactContext)
                    .environmentObject(state)
                    .environmentObject(avatarService)
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
                                    if message.isSystemNotice {
                                        SystemNoticeView(content: message.content)
                                            .id(message.id)
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                    } else {
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
                            .environmentObject(avatarService)
                    }

                    if state.settingsPanelVisible {
                        Divider().background(Color.white.opacity(0.08))
                        AgentSettingsPanel(agent: $agent).environmentObject(state).environmentObject(avatarService)
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
    @EnvironmentObject var avatarService: AgentAvatarService
    var onCompact: (() -> Void)? = nil

    @State private var showAvatarPopover = false
    @State private var ringShift: CGFloat = 0
    @State private var ringOpacity: Double = 0
    @State private var ringWidth: CGFloat = 2

    var body: some View {
        let avatarImage: CGImage? = avatarService.avatarImages[agent.id]
        let isGenerating: Bool    = avatarService.generatingAgents.contains(agent.id)
        HStack(spacing: 12) {
            Button(action: { showAvatarPopover.toggle() }) {
                ZStack {
                    if let cgImage = avatarImage {
                        Image(cgImage, scale: 1.0, label: Text(agent.name))
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(agent.avatarColor.opacity(0.15))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Text(String(agent.name.prefix(1)))
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundColor(agent.avatarColor)
                            )
                    }
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                stops: [
                                    .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10), location: max(0, min(1, 0.00 + ringShift))),
                                    .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55), location: max(0, min(1, 0.25 + ringShift))),
                                    .init(color: Color(red: 0.95, green: 0.15, blue: 0.65), location: max(0, min(1, 0.50 + ringShift))),
                                    .init(color: Color(red: 0.30, green: 0.55, blue: 1.00), location: max(0, min(1, 0.75 + ringShift))),
                                    .init(color: Color(red: 0.40, green: 0.78, blue: 1.00), location: max(0, min(1, 1.00 + ringShift))),
                                ],
                                center: .center
                            ),
                            lineWidth: ringWidth
                        )
                        .frame(width: 56, height: 56)
                        .opacity(ringOpacity)
                        .shadow(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.5), radius: 4)
                        .shadow(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.4), radius: 6)
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .help("Edit avatar DNA")
            .popover(isPresented: $showAvatarPopover, arrowEdge: .bottom) {
                AvatarPopoverView(agent: $agent)
                    .environmentObject(state)
                    .environmentObject(avatarService)
            }
            .onChange(of: isGenerating) { generating in
                if generating { startPulse() } else { flashOnArrival() }
            }

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
                    .foregroundColor(state.settingsPanelVisible ? Color(red: 1.0, green: 0.25, blue: 0.55) : Color.white.opacity(0.5))
                    .padding(7)
                    .glassBackground(opacity: state.settingsPanelVisible ? 0.2 : 0.08, cornerRadius: 8, borderOpacity: 0.15)
            }
            .buttonStyle(.plain).padding(.leading, 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func startPulse() {
        ringWidth   = 2
        ringOpacity = 0
        withAnimation(.easeIn(duration: 0.3)) { ringOpacity = 0.85 }
        withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) { ringShift = 1.0 }
    }

    private func flashOnArrival() {
        withAnimation(.easeOut(duration: 0.15)) { ringWidth = 3.5; ringOpacity = 1.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.6)) { ringWidth = 2; ringOpacity = 0 }
            ringShift = 0
        }
    }
}

// MARK: - Avatar Popover

struct AvatarPopoverView: View {
    @Binding var agent: Agent
    @EnvironmentObject var state: AppState
    @EnvironmentObject var avatarService: AgentAvatarService

    @State private var dnaText: String = ""
    @State private var didSave = false
    @State private var didStarSave = false

    private let historySize: CGFloat = 44
    var body: some View {
        let avatarImage: CGImage? = avatarService.avatarImages[agent.id]
        let isGenerating: Bool    = avatarService.generatingAgents.contains(agent.id)
        let history: [CGImage]    = avatarService.avatarHistory[agent.id] ?? []
        let selectedIdx: Int      = avatarService.selectedHistoryIndex[agent.id] ?? 0
        let workspacePath: String = (agent.workspacePath as NSString).expandingTildeInPath

        VStack(alignment: .leading, spacing: 14) {

                // Main avatar preview + star button
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        ZStack {
                            if let cgImage = avatarImage {
                                Image(cgImage, scale: 1.0, label: Text(agent.name))
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 120, height: 120)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(agent.avatarColor.opacity(0.4), lineWidth: 1.5))
                            } else {
                                Circle()
                                    .fill(agent.avatarColor.opacity(0.15))
                                    .frame(width: 120, height: 120)
                                    .overlay(Circle().stroke(agent.avatarColor.opacity(0.3), lineWidth: 1.5))
                                    .overlay(
                                        Text(String(agent.name.prefix(1)))
                                            .font(.system(size: 48, weight: .semibold, design: .rounded))
                                            .foregroundColor(agent.avatarColor)
                                    )
                            }
                            if isGenerating {
                                Circle().fill(Color.black.opacity(0.45)).frame(width: 120, height: 120)
                                ProgressView().progressViewStyle(.circular).scaleEffect(0.8)
                            }
                        }

                        // Star button to permanently save
                        if avatarImage != nil {
                            Button(action: {
                                avatarService.savePermanently(agentId: agent.id, workspacePath: workspacePath)
                                didStarSave = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didStarSave = false }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: didStarSave ? "star.fill" : "star")
                                        .font(.system(size: 12))
                                        .foregroundColor(didStarSave ? Color(red: 1.0, green: 0.80, blue: 0.20) : Color.white.opacity(0.4))
                                    Text(didStarSave ? "Saved!" : "Save permanently")
                                        .font(.system(size: 11))
                                        .foregroundColor(didStarSave ? Color(red: 1.0, green: 0.80, blue: 0.20) : Color.white.opacity(0.4))
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        // History strip — last 5 generated images
                        if !history.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(0..<min(history.count, 5), id: \.self) { i in
                                    let isSelected = i == selectedIdx
                                    Button(action: {
                                        avatarService.selectHistory(agentId: agent.id, index: i, workspacePath: workspacePath)
                                    }) {
                                        ZStack {
                                            Image(history[i], scale: 1.0, label: Text("History \(i)"))
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: historySize, height: historySize)
                                                .clipShape(Circle())

                                            if isSelected {
                                                Circle()
                                                    .strokeBorder(
                                                        Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.7),
                                                        lineWidth: 2.5
                                                    )
                                                    .frame(width: historySize, height: historySize)
                                                    .shadow(color: Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.5), radius: 4)
                                            } else {
                                                Circle()
                                                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                                    .frame(width: historySize, height: historySize)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("Avatar generation")
                        .font(.system(size: 12)).foregroundColor(.white)
                    Toggle("", isOn: Binding(
                        get: { avatarService.isGenerationEnabled(for: agent.id) },
                        set: { avatarService.setGeneration(enabled: $0, for: agent.id) }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color(red: 1.0, green: 0.25, blue: 0.55))
                    .scaleEffect(0.75)
                    .frame(width: 40)
                }

                if avatarService.geminiUnavailable {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("Using basic mood detection")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Label("Avatar DNA", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.45))

                    TextEditor(text: $dnaText)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 72)
                        .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.15)

                    if let error = avatarService.lastError[agent.id] {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundColor(.orange)
                            Text(error)
                                .font(.system(size: 10)).foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Describe your agent's look. Example: \"glowing teal robot with kind eyes, friendly cartoon style\"")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.25))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    if didSave {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 11))
                            Text("Generating…").font(.system(size: 11)).foregroundColor(.green)
                        }
                    }
                    Spacer()
                    Button(action: regenerate) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                            Text("Save & Regenerate").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(isGenerating ? Color.gray.opacity(0.4) : Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.7))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)
                }
            }
            .padding(18)
        .frame(width: 320, alignment: .leading)
        .preferredColorScheme(.dark)
        .onAppear { dnaText = avatarService.agentDNA[agent.id] ?? "" }
    }

    private func regenerate() {
        guard !avatarService.generatingAgents.contains(agent.id) else { return }
        didSave = true
        let messages = state.messages[agent.id] ?? []
        avatarService.regenerate(for: agent, messages: messages, dna: dnaText)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { didSave = false }
    }
}

// MARK: - Personality Matrix

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
            Color(red: 0.14, green: 0.14, blue: 0.14).ignoresSafeArea()
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
                        .background(hasChanges ? Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.8) : Color.white.opacity(0.1))
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
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)

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
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
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

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.10).ignoresSafeArea()
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
    @EnvironmentObject var avatarService: AgentAvatarService
    @Environment(\.dismiss) var dismiss

    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var geminiKey: String = ""
    @State private var ibmQuantumKey: String = ""
    @State private var gatewayToken: String = ""
    @State private var saveStatus: String? = nil
    @State private var isError: Bool = false
    @State private var anthropicRevealed: Bool = false
    @State private var openAIRevealed: Bool = false
    @State private var geminiRevealed: Bool = false
    @State private var ibmRevealed: Bool = false
    @State private var gatewayRevealed: Bool = false
    @State private var isRestarting: Bool = false

    var anthropicEnvConflict: Bool { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil }
    var openAIEnvConflict: Bool { ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil }
    var geminiEnvConflict: Bool { ProcessInfo.processInfo.environment["GOOGLE_API_KEY"] != nil }
    var ibmEnvConflict: Bool { ProcessInfo.processInfo.environment["IBM_QUANTUM_TOKEN"] != nil }
    var gatewayEnvConflict: Bool { ProcessInfo.processInfo.environment["OPENCLAW_GATEWAY_TOKEN"] != nil }

    func authenticate(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Reveal API key") { success, _ in
                DispatchQueue.main.async { completion(success) }
            }
        } else { completion(true) }
    }

    var body: some View {
        ZStack {
            Color(red: 0.14, green: 0.14, blue: 0.14).ignoresSafeArea()
            ScrollView {
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

                    Text("API keys are saved globally to ~/.openclaw/.env and apply to all agents. The gateway token is saved to openclaw.json. Changes take effect after restart.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)

                    // Env conflict warning
                    let conflicts = [
                        anthropicEnvConflict ? "ANTHROPIC_API_KEY" : nil,
                        openAIEnvConflict    ? "OPENAI_API_KEY"    : nil,
                        geminiEnvConflict    ? "GOOGLE_API_KEY"    : nil,
                        ibmEnvConflict       ? "IBM_QUANTUM_TOKEN" : nil,
                        gatewayEnvConflict   ? "OPENCLAW_GATEWAY_TOKEN" : nil
                    ].compactMap { $0 }

                    if !conflicts.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 12)).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Environment variable conflict detected").font(.system(size: 12, weight: .semibold)).foregroundColor(.orange)
                                Text("\(conflicts.joined(separator: ", ")) \(conflicts.count == 1 ? "is" : "are") set in your shell environment and may override values saved here.")
                                    .font(.system(size: 11)).foregroundColor(Color.orange.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10).glassBackground(opacity: 0.06, cornerRadius: 8, borderOpacity: 0.25)
                    }

                    // Anthropic
                    keyField(label: "Anthropic", icon: "brain", placeholder: "sk-ant-...", key: $anthropicKey, revealed: $anthropicRevealed, hasConflict: anthropicEnvConflict)

                    // OpenAI
                    keyField(label: "OpenAI", icon: "sparkles", placeholder: "sk-proj-...", key: $openAIKey, revealed: $openAIRevealed, hasConflict: openAIEnvConflict)

                    // Gemini
                    keyField(label: "Gemini (Avatar Generation)", icon: "camera.filters", placeholder: "AIza...", key: $geminiKey, revealed: $geminiRevealed, hasConflict: geminiEnvConflict)

                    // IBM Quantum
                    keyField(label: "IBM Quantum", icon: "atom", placeholder: "IBM Quantum API token", key: $ibmQuantumKey, revealed: $ibmRevealed, hasConflict: ibmEnvConflict)

                    if !geminiKey.isEmpty && avatarService.geminiUnavailable {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text("Gemini quota exceeded — using basic mood detection")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                        .padding(.top, -4)
                    }

                    // Gateway Token
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Gateway Token", systemImage: "lock.shield").font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                            if gatewayEnvConflict {
                                Text("ENV OVERRIDE ACTIVE").font(.system(size: 9, weight: .bold)).foregroundColor(.orange)
                                    .padding(.horizontal, 5).padding(.vertical, 2).background(Color.orange.opacity(0.15)).cornerRadius(4)
                            }
                        }
                        HStack(spacing: 8) {
                            Group {
                                if gatewayRevealed { TextField("Gateway auth token...", text: $gatewayToken) }
                                else { SecureField("Gateway auth token...", text: $gatewayToken) }
                            }
                            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: gatewayEnvConflict ? 0.4 : 0.15)

                            Button(action: { if gatewayRevealed { gatewayRevealed = false } else { authenticate { if $0 { gatewayRevealed = true } } } }) {
                                Image(systemName: gatewayRevealed ? "eye.slash" : "eye").font(.system(size: 13)).foregroundColor(Color.white.opacity(0.4))
                                    .frame(width: 32, height: 32).glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                            }.buttonStyle(.plain).help(gatewayRevealed ? "Hide token" : "Reveal token with Touch ID")

                            Button(action: {
                                authenticate { success in
                                    guard success else { return }
                                    var bytes = [UInt8](repeating: 0, count: 24)
                                    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                                    gatewayToken = bytes.map { String(format: "%02x", $0) }.joined()
                                    gatewayRevealed = true
                                }
                            }) {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13)).foregroundColor(Color.white.opacity(0.4))
                                    .frame(width: 32, height: 32).glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                            }.buttonStyle(.plain).help("Generate new token")
                        }
                    }

                    if let status = saveStatus {
                        HStack(spacing: 6) {
                            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundColor(isError ? .red : .green).font(.system(size: 12))
                            Text(status).font(.system(size: 12)).foregroundColor(isError ? .red : .green)
                        }
                    }

                    HStack {
                        Spacer()
                        Button(action: saveKeys) {
                            HStack(spacing: 6) {
                                if isRestarting { ProgressView().scaleEffect(0.6).frame(width: 12, height: 12) }
                                Text(isRestarting ? "Restarting..." : "Save Keys").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.7)).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .disabled((anthropicKey.isEmpty && openAIKey.isEmpty && geminiKey.isEmpty && ibmQuantumKey.isEmpty && gatewayToken.isEmpty) || isRestarting)
                    }
                }
                .padding(28)
            }
        }
        .frame(width: 420, height: 560)
        .preferredColorScheme(.dark)
        .onAppear { loadCurrentKeys() }
        .onDisappear { anthropicRevealed = false; openAIRevealed = false; geminiRevealed = false; ibmRevealed = false; gatewayRevealed = false }
    }

    @ViewBuilder
    func keyField(label: String, icon: String, placeholder: String, key: Binding<String>, revealed: Binding<Bool>, hasConflict: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(label, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                if hasConflict {
                    Text("ENV OVERRIDE ACTIVE").font(.system(size: 9, weight: .bold)).foregroundColor(.orange)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.orange.opacity(0.15)).cornerRadius(4)
                }
            }
            HStack(spacing: 8) {
                Group {
                    if revealed.wrappedValue { TextField(placeholder, text: key) }
                    else { SecureField(placeholder, text: key) }
                }
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: hasConflict ? 0.4 : 0.15)

                Button(action: { if revealed.wrappedValue { revealed.wrappedValue = false } else { authenticate { if $0 { revealed.wrappedValue = true } } } }) {
                    Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye").font(.system(size: 13)).foregroundColor(Color.white.opacity(0.4))
                        .frame(width: 32, height: 32).glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                }.buttonStyle(.plain).help(revealed.wrappedValue ? "Hide key" : "Reveal key with Touch ID")
            }
        }
    }

    func loadCurrentKeys() {
        if let token = OpenClawLoader.shared.readGatewayToken(configPath: state.configPath) { gatewayToken = token }
        if let key = OpenClawLoader.shared.readAnthropicKey() { anthropicKey = key }
        if let key = OpenClawLoader.shared.readOpenAIKey() { openAIKey = key }
        if let key = OpenClawLoader.shared.readGeminiKey() { geminiKey = key }
        if let key = OpenClawLoader.shared.readIBMQuantumKey() { ibmQuantumKey = key }
    }

    func saveKeys() {
        var successCount = 0; var failCount = 0

        if !gatewayToken.isEmpty {
            if OpenClawLoader.shared.writeGatewayToken(gatewayToken, configPath: state.configPath) { successCount += 1 } else { failCount += 1 }
        }

        var envKeys: [String: String] = [:]
        if !anthropicKey.isEmpty  { envKeys["ANTHROPIC_API_KEY"]  = anthropicKey }
        if !openAIKey.isEmpty     { envKeys["OPENAI_API_KEY"]     = openAIKey }
        if !geminiKey.isEmpty     { envKeys["GOOGLE_API_KEY"]     = geminiKey }
        if !ibmQuantumKey.isEmpty { envKeys["IBM_QUANTUM_TOKEN"]  = ibmQuantumKey }
        if !envKeys.isEmpty {
            if OpenClawLoader.shared.writeEnvKeys(envKeys) { successCount += 1 } else { failCount += 1 }
        }

        guard failCount == 0 else {
            saveStatus = "Saved \(successCount), failed \(failCount)"; isError = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { saveStatus = nil }
            return
        }

        saveStatus = "Saved. Restarting gateway..."; isError = false; isRestarting = true
        for i in state.agents.indices { state.agents[i].status = .restarting }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/openclaw")
            process.arguments = ["gateway", "restart"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOME"] = NSHomeDirectory()
            process.environment = env
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            var ok = false
            do { try process.run(); process.waitUntilExit(); ok = process.terminationStatus == 0 } catch { ok = false }
            DispatchQueue.main.async {
                self.isRestarting = false
                if ok {
                    self.saveStatus = "Saved and gateway restarted"; self.isError = false
                    for i in self.state.agents.indices { self.state.agents[i].status = .idle }
                } else {
                    self.saveStatus = "Saved but restart failed — restart manually from Terminal"; self.isError = true
                    for i in self.state.agents.indices { self.state.agents[i].status = .error }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.saveStatus = nil }
            }
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().frame(width: 1000, height: 680)
    }
}

