// HeartbeatService.swift
// Agentics
//
// Everything heartbeat-related in one place:
//   - AgentHeartbeat model
//   - OpenClawLoader helpers for reading/writing HEARTBEAT.md and openclaw.json
//   - AppState save helpers
//   - HeartbeatEditorView (the UI in the settings panel)

import SwiftUI

// MARK: - Model

struct AgentHeartbeat: Codable {
    let every: String
}

// MARK: - OpenClawLoader helpers

extension OpenClawLoader {

    func heartbeatMDPath(for agent: AgentConfig, defaults: AgentDefaults) -> String {
        let workspace = workspacePath(for: agent, defaults: defaults)
        return (workspace as NSString).appendingPathComponent("HEARTBEAT.md")
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

    // Reads and rewrites the agent's JSON block using raw string scanning rather than
    // Codable decode/mutate/re-encode. This approach was chosen because the heartbeat
    // field may not exist yet in the config — the else branch below handles inserting it
    // fresh. A struct-based decode would require the field to already be present or
    // special-cased, which caused reliability issues during development.
    // DO NOT REFACTOR without testing both cases:
    //   1. Agent already has a heartbeat field → should update it
    //   2. Agent has never had a heartbeat → should insert it fresh
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

// MARK: - AppState helpers

extension AppState {

    func saveHeartbeatMD(for agent: Agent) -> Bool {
        guard let agentConfig = agent.agentConfig, let defaults = agentDefaults else { return false }
        return OpenClawLoader.shared.writeHeartbeatMD(content: agent.heartbeatContent, for: agentConfig, defaults: defaults)
    }

    func saveHeartbeatInterval(for agent: Agent) -> Bool {
        let interval = agent.heartbeatInterval == "off" ? nil : agent.heartbeatInterval
        return OpenClawLoader.shared.updateHeartbeat(agentId: agent.id, interval: interval, configPath: configPath)
    }
}

// MARK: - HeartbeatEditorView

struct HeartbeatEditorView: View {
    @Binding var agent: Agent
    @EnvironmentObject var state: AppState
    @State private var selectedInterval: String = ""
    @State private var customInterval: String   = ""
    @State private var showCustomField = false
    @State private var intervalSaved   = false
    @State private var isRestarting    = false
    @State private var restartFailed   = false

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
        guard success else { return }

        for i in state.agents.indices { state.agents[i].status = .restarting }
        isRestarting = true
        restartFailed = false

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/openclaw")
            process.arguments = ["gateway", "restart"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOME"] = NSHomeDirectory()
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var restartSuccess = false
            do { try process.run(); process.waitUntilExit(); restartSuccess = process.terminationStatus == 0 }
            catch { restartSuccess = false }
            DispatchQueue.main.async {
                self.isRestarting = false
                if restartSuccess {
                    self.intervalSaved = true; self.restartFailed = false
                    for i in self.state.agents.indices { self.state.agents[i].status = .idle }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.intervalSaved = false }
                } else {
                    self.restartFailed = true
                    for i in self.state.agents.indices { self.state.agents[i].status = .error }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.restartFailed = false }
                }
            }
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
                                .background(selectedInterval == preset ? Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.6) : Color.white.opacity(0.06))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                                    selectedInterval == preset ? Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.8) : Color.white.opacity(0.1),
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
                    if isRestarting {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                            Text("Restarting gateway...").font(.system(size: 11)).foregroundColor(.yellow)
                        }
                    } else if restartFailed {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.system(size: 11))
                            Text("Restart failed").font(.system(size: 11)).foregroundColor(.red)
                        }
                    } else if intervalSaved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 11))
                            Text("Saved and restarted").font(.system(size: 11)).foregroundColor(.green)
                        }
                    } else {
                        Text("Currently: \(agent.heartbeatInterval == "off" ? "Off" : agent.heartbeatInterval)")
                            .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.25))
                    }
                    Spacer()
                    Button(action: saveInterval) {
                        Text(isRestarting ? "Restarting..." : "Apply")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.6)).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(isRestarting)
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
