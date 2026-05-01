// AgentSettingsPanel.swift
// Agentics
//
// The settings panel shown on the right side of the app when you tap the
// settings icon in the chat header. Includes model picker, workspace path,
// avatar toggle, personality matrix, dream diary, heartbeat editor,
// activity log, and the danger-zone delete button.
//
// Also contains ActivityLogRow — a small helper view used only by this panel.

import SwiftUI

// MARK: - AgentSettingsPanel

struct AgentSettingsPanel: View {
    @Binding var agent: Agent
    @EnvironmentObject var state: AppState
    @EnvironmentObject var avatarService: AgentAvatarService
    @State private var showModelPicker    = false
    @State private var modelChanged       = false
    @State private var isRestartingModel  = false
    @State private var modelRestartFailed = false
    @State private var previousModel      = ""   // captured before updateAgentModel() runs

    func restartGateway() {
        let messages      = state.messages[agent.id] ?? []
        let agentName     = agent.name
        let agentCopy     = agent
        let toModel       = agent.role
        let fromModel     = previousModel
        let toModelName   = ModelCostTier.availableModels.first(where: { $0.id == toModel })?.displayName ?? toModel
        let fromModelName = ModelCostTier.availableModels.first(where: { $0.id == fromModel })?.displayName ?? fromModel

        for i in state.agents.indices { state.agents[i].status = .restarting }
        isRestartingModel  = true
        modelRestartFailed = false

        let performRestart = { (summarySent: Bool) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/openclaw")
                process.arguments = ["gateway", "restart"]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["HOME"] = NSHomeDirectory()
                process.environment = env
                process.standardOutput = Pipe()
                process.standardError  = Pipe()
                var success = false
                do { try process.run(); process.waitUntilExit(); success = process.terminationStatus == 0 }
                catch { success = false }
                DispatchQueue.main.async { self.state.clearBootstrapMD(for: agentCopy) }
                DispatchQueue.main.async {
                    self.isRestartingModel = false
                    if success {
                        self.modelChanged = false
                        for i in self.state.agents.indices { self.state.agents[i].status = .idle }
                        let noticeText = summarySent
                            ? "Switched to \(toModelName)\nContext summary transferred ✓"
                            : "Switched to \(toModelName)\nNo prior context to transfer"
                        let notice = Message(
                            content: noticeText,
                            isUser: false,
                            timestamp: Date(),
                            agentName: nil,
                            isSystemNotice: true
                        )
                        self.state.messages[agentCopy.id, default: []].append(notice)
                        self.state.saveChat(for: agentCopy)
                    } else {
                        self.modelRestartFailed = true
                        for i in self.state.agents.indices { self.state.agents[i].status = .error }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.modelRestartFailed = false }
                    }
                }
            }
        }

        guard !messages.isEmpty else { performRestart(false); return }

        state.clearBootstrapMD(for: agentCopy)

        SummaryService.shared.summarizeChat(messages: messages, agentName: agentName) { [self] summary in
            var summarySent = false
            if let summary {
                let bootstrapContent = """
                # Recent Conversation Context

                The following is a summary of the conversation before the model was switched. \
                Use this as context for the new session:

                \(summary)
                """
                DispatchQueue.main.async { self.state.writeBootstrapMD(content: bootstrapContent, for: agentCopy) }
                DispatchQueue.main.async {
                    self.state.appendToHandoffLog(
                        summary: summary,
                        fromModel: fromModelName,
                        toModel: toModelName,
                        for: agentCopy
                    )
                }
                summarySent = true
            }
            performRestart(summarySent)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.14, green: 0.14, blue: 0.14).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Agent Settings")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white).padding(.top, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Model", systemImage: "cpu")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                        Button(action: { showModelPicker.toggle() }) {
                            HStack(spacing: 6) {
                                Text(ModelCostTier.availableModels.first(where: { $0.id == agent.role })?.displayName ?? agent.role)
                                    .font(.system(size: 13)).foregroundColor(.white)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(Color.white.opacity(0.2)))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(ModelCostTier.availableModels, id: \.id) { model in
                                    Button(action: {
                                        previousModel = agent.role
                                        state.updateAgentModel(agentId: agent.id, newModel: model.id)
                                        showModelPicker = false
                                        modelChanged = true
                                    }) {
                                        HStack {
                                            Text(model.displayName)
                                                .font(.system(size: 13)).foregroundColor(.white)
                                            Spacer()
                                            if agent.role == model.id {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
                                            }
                                        }
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(width: 220)
                            .padding(.vertical, 4)
                        }
                        if modelChanged {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                Text("Restart required to apply")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                Spacer()
                                Button(action: restartGateway) {
                                    Text(isRestartingModel ? "Restarting…" : modelRestartFailed ? "Failed" : "Restart")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(isRestartingModel ? Color.gray.opacity(0.4) : Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.7))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                                .disabled(isRestartingModel)
                            }
                            .padding(.top, 4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Workspace", systemImage: "folder")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                        Text(agent.workspacePath).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Avatar Generation", systemImage: "wand.and.stars")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                        HStack {
                            Text("Avatar generation")
                                .font(.system(size: 12)).foregroundColor(.white)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { avatarService.isGenerationEnabled(for: agent.id) },
                                set: { avatarService.setGeneration(enabled: $0, for: agent.id) }
                            ))
                            .toggleStyle(.switch)
                            .tint(Color(red: 1.0, green: 0.25, blue: 0.55))
                            .scaleEffect(0.75)
                            .frame(width: 40)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
                    }

                    PersonalityMatrixView(agent: $agent).environmentObject(state)
                    DreamDiaryView(agent: $agent)
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

                    DeleteAgentButton(agent: agent).environmentObject(state)

                    Spacer()
                }
                .padding(16)
            }
        }
    }
}

// MARK: - ActivityLogRow

struct ActivityLogRow: View {
    let icon: String; let color: Color; let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(color).frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
        }
    }
}
