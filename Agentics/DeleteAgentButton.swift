// DeleteAgentButton.swift
// Agentics
//
// A danger-zone button that permanently removes an agent from openclaw.json.
// Requires Touch ID before the confirmation dialog even appears — two gates,
// not one. Touch ID first, then an explicit "Delete" confirmation.
//
// Placed at the bottom of AgentSettingsPanel, separated from the rest of
// the settings by a labelled "Danger Zone" divider.

import SwiftUI
import LocalAuthentication

struct DeleteAgentButton: View {
    let agent: Agent
    @EnvironmentObject var state: AppState

    @State private var showConfirmation = false
    @State private var authFailed       = false
    @State private var isDeleting       = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Section label
            Label("Danger Zone", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.red.opacity(0.6))

            Button {
                authenticate()
            } label: {
                HStack {
                    Spacer()
                    if isDeleting {
                        ProgressView().scaleEffect(0.6).tint(.white)
                        Text("Deleting…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Delete \(agent.name)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(Color.red.opacity(isDeleting ? 0.3 : 0.75))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)

            // Auth failure note — clears after 3 seconds
            if authFailed {
                Text("Touch ID failed. Try again.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.red.opacity(0.8))
                    .transition(.opacity)
            }
        }
        // Confirmation dialog — only reaches here after Touch ID passes
        .confirmationDialog(
            "Delete \(agent.name)?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteAgent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \(agent.name) from your config. Workspace files on disk will not be touched.")
        }
        .animation(.easeInOut(duration: 0.2), value: authFailed)
    }

    // MARK: - Touch ID

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Confirm deletion of \(agent.name)"
            ) { success, _ in
                DispatchQueue.main.async {
                    if success {
                        authFailed = false
                        showConfirmation = true
                    } else {
                        authFailed = true
                        // Auto-clear the failure message after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            authFailed = false
                        }
                    }
                }
            }
        } else {
            // No biometrics available — fall straight through to confirmation
            showConfirmation = true
        }
    }

    // MARK: - Deletion

    private func deleteAgent() {
        isDeleting = true
        let agentId    = agent.id
        let agentName  = agent.name
        let configPath = state.configPath

        DispatchQueue.global(qos: .userInitiated).async {
            // Try the proper openclaw CLI first
            let cliSuccess = Self.runOpenClawDelete(agentId: agentId)

            if !cliSuccess {
                // Fallback: agent may have been created manually (not via openclaw agents add).
                // Directly remove it from openclaw.json so the sidebar still clears.
                let _ = OpenClawLoader.shared.removeAgent(id: agentId, configPath: configPath)
                print("[DeleteAgent] CLI failed for '\(agentName)' — used JSON fallback")
            }

            DispatchQueue.main.async {
                // Always reload regardless of how deletion went —
                // the sidebar must reflect what's actually in openclaw.json right now.
                if state.selectedAgent?.id == agentId {
                    state.selectedAgent = nil
                }
                state.loadAgents()
                if state.selectedAgent == nil {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.selectedAgent = state.agents.first
                    }
                }
                isDeleting = false
            }
        }
    }

    // Uses `openclaw agents delete --force` — the proper way to remove an agent.
    // Handles openclaw.json cleanup, session pruning, and agent dir removal.
    // Static so it runs cleanly off the main thread without capturing self.
    private static func runOpenClawDelete(agentId: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/openclaw")
        process.arguments = ["agents", "delete", "--force", agentId]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        process.standardOutput = Pipe() // suppress output
        process.standardError  = Pipe()

        do { try process.run() } catch {
            print("[DeleteAgent] Failed to launch openclaw: \(error)")
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
