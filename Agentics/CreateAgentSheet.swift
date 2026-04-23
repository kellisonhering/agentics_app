// CreateAgentSheet.swift
// Agentics
//
// Two-phase sheet for hatching a new agent.
//
// Phase 1 — Model: user picks a model, taps "Begin".
// Phase 2 — Interview: four questions answered one at a time inside the sheet.
//   Q1: What should I be called?
//   Q2: What personality should I have?
//   Q3: What is my purpose?
//   Q4: Who is the user?
// Phase 3 — Hatching: image + animated step list while the agent is created.
//
// On finish the agent is written to openclaw.json, SOUL.md is built from
// the interview answers, the sidebar reloads, and the new agent is selected.

import SwiftUI

// MARK: - Phase

private enum HatchPhase: Equatable {
    case model
    case interview(step: Int)
    case creating
}

// MARK: - Sheet

struct CreateAgentSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    @State private var selectedModel  = "anthropic/claude-sonnet-4-6"
    @State private var phase: HatchPhase = .model
    @State private var answers        = ["", "", "", ""]
    @State private var errorMessage: String? = nil
    @State private var isHatching     = false  // true while openclaw agents add is running

    // Hatching animation state
    @State private var completedSteps = 0
    @State private var pendingAgentId = ""

    private let questions: [(question: String, hint: String)] = [
        (
            "What would you like to call me?",
            "Give me a name."
        ),
        (
            "What kind of personality should I have?",
            "e.g. calm and precise, warm and playful, direct and witty…"
        ),
        (
            "What should my purpose be?",
            "What kinds of things do you want me to help with?"
        ),
        (
            "Tell me a little about yourself.",
            "Your name, what you're into, what your world looks like."
        )
    ]

    // Fun fake steps shown during hatching. Mix technical-sounding with silly.
    private let hatchSteps: [String] = [
        "Booting up the imagination engine",
        "Installing personality module",
        "Tightening all the screws",
        "Calibrating curiosity levels",
        "Teaching it to say please and thank you",
        "Hiding emergency snack reserves",
        "Checking expiration date",
        "Syncing with the moon",
        "Running final vibe check",
        "Agent is awake"
    ]

    private var currentStep: Int {
        if case .interview(let s) = phase { return s } else { return 0 }
    }

    private var currentAnswerEmpty: Bool {
        answers[currentStep].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(red: 0.12, green: 0.12, blue: 0.14).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .model:
                        modelPhase
                    case .interview(let step):
                        interviewPhase(step: step)
                    case .creating:
                        creatingPhase
                    }
                }
                .padding(phase == .creating ? 0 : 20)
            }
        }
        .frame(width: 380, height: frameHeight)
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    // MARK: - Frame height

    private var frameHeight: CGFloat {
        switch phase {
        case .model:      return 340
        case .interview:  return 420
        case .creating:   return 520
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                switch phase {
                case .model:
                    Text("New Agent")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Choose a model to get started.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.4))

                case .interview(let step):
                    Text("Hatching")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    HStack(spacing: 5) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle()
                                .fill(i <= step
                                      ? Color(red: 1.0, green: 0.25, blue: 0.55)
                                      : Color.white.opacity(0.15))
                                .frame(width: 5, height: 5)
                        }
                    }

                case .creating:
                    Text("Hatching")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    HStack(spacing: 5) {
                        ForEach(0..<4, id: \.self) { _ in
                            Circle()
                                .fill(Color(red: 1.0, green: 0.25, blue: 0.55))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
            Spacer()
            if phase != .creating {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Model phase

    private var modelPhase: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Model", systemImage: "cpu")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.5))
                VStack(spacing: 0) {
                    ForEach(ModelCostTier.availableModels, id: \.id) { model in
                        Button { selectedModel = model.id } label: {
                            HStack {
                                Text(model.displayName)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                                Spacer()
                                if selectedModel == model.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if model.id != ModelCostTier.availableModels.last?.id {
                            Divider().background(Color.white.opacity(0.06))
                        }
                    }
                }
                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)
            }

            actionButton(label: "Begin", icon: "moon.stars.fill") {
                phase = .interview(step: 0)
            }
        }
    }

    // MARK: - Interview phase

    private func interviewPhase(step: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {

            // Agent "speech" card
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.7))
                    .padding(.top, 1)
                Text(questions[step].question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassBackground(opacity: 0.1, cornerRadius: 10, borderOpacity: 0.14)

            // Answer field
            TextField(questions[step].hint, text: $answers[step], axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(3...5)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassBackground(opacity: 0.08, cornerRadius: 8, borderOpacity: 0.12)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            let isLast = step == questions.count - 1
            actionButton(
                label:    isLast ? (isHatching ? "Creating…" : "Finish") : "Next",
                icon:     isLast ? (isHatching ? "hourglass" : "checkmark") : "arrow.right",
                disabled: currentAnswerEmpty || isHatching
            ) {
                if isLast { startHatching() }
                else       { phase = .interview(step: step + 1) }
            }
        }
    }

    // MARK: - Creating / hatching phase

    private var creatingPhase: some View {
        VStack(spacing: 0) {

            // Hero image — add an image named "HatchImage" to Assets.xcassets
            Group {
                if let nsImg = NSImage(named: "HatchImage") {
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipped()
                } else {
                    // Fallback if image hasn't been added yet
                    ZStack {
                        Color.white.opacity(0.04)
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55).opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                }
            }

            // Step list
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hatchSteps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 10) {
                        // Status indicator
                        Group {
                            if index < completedSteps {
                                // Done — pink checkmark
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
                                    .font(.system(size: 12))
                            } else if index == completedSteps {
                                // Current — spinner
                                ProgressView()
                                    .scaleEffect(0.55)
                                    .tint(Color.white.opacity(0.5))
                                    .frame(width: 12, height: 12)
                            } else {
                                // Pending — dim circle
                                Circle()
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    .frame(width: 12, height: 12)
                            }
                        }
                        .frame(width: 16)

                        Text(step)
                            .font(.system(size: 12))
                            .foregroundColor(
                                index < completedSteps
                                    ? Color.white.opacity(0.55)
                                    : index == completedSteps
                                        ? .white
                                        : Color.white.opacity(0.2)
                            )
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)

                    if index < hatchSteps.count - 1 {
                        Divider()
                            .background(Color.white.opacity(0.05))
                            .padding(.leading, 46)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        // Drive the step animation
        .task {
            for i in 0..<hatchSteps.count {
                try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s per step
                completedSteps = i + 1
            }
            // All steps done — select agent and close
            if let agent = state.agents.first(where: { $0.id == pendingAgentId }) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    state.selectedAgent = agent
                }
            }
            dismiss()
        }
    }

    // MARK: - Shared button

    private func actionButton(
        label: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 10)
            .background(
                disabled
                    ? Color.white.opacity(0.1)
                    : Color(red: 1.0, green: 0.25, blue: 0.55)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Hatching logic

    // Runs `openclaw agents add` on a background thread — this is the correct
    // way to create an agent. It sets up the workspace with all default files
    // (SOUL.md, IDENTITY.md, USER.md, TOOLS.md, etc.) the way OpenClaw expects.
    // Once the command succeeds, we append the interview answers to SOUL.md and
    // USER.md, reload the sidebar, then enter the animation phase.
    private func startHatching() {
        guard !isHatching else { return }
        isHatching   = true
        errorMessage = nil

        let name        = answers[0].trimmingCharacters(in: .whitespaces)
        let personality = answers[1].trimmingCharacters(in: .whitespaces)
        let purpose     = answers[2].trimmingCharacters(in: .whitespaces)
        let userInfo    = answers[3].trimmingCharacters(in: .whitespaces)
        let model       = selectedModel

        DispatchQueue.global(qos: .userInitiated).async {
            // 1. Run openclaw agents add — returns the normalized agent ID on success
            guard let agentId = Self.runOpenClawAdd(name: name, model: model) else {
                DispatchQueue.main.async {
                    self.errorMessage = "Could not create agent. The name may already be taken."
                    self.isHatching = false
                }
                return
            }

            // 2. Append interview answers to the files OpenClaw just created
            let workspacePath = "\(NSHomeDirectory())/.openclaw/workspace-\(agentId)"
            Self.appendToSoul(at: workspacePath, personality: personality, purpose: purpose)
            Self.appendToUser(at: workspacePath, userInfo: userInfo)

            // 3. Back on main thread: reload sidebar and start the animation
            DispatchQueue.main.async {
                self.state.loadAgents()
                self.pendingAgentId = agentId
                self.completedSteps = 0
                self.isHatching     = false
                self.phase          = .creating
            }
        }
    }

    // Calls `/usr/local/bin/openclaw agents add` with --non-interactive and --json.
    // Returns the normalized agentId string on success, nil on failure.
    // Static so it can be called from a background thread without capturing self.
    private static func runOpenClawAdd(name: String, model: String) -> String? {
        // Workspace path: openclaw uses workspace-[normalizedId] convention.
        // We derive it from the name; openclaw will confirm/correct via JSON output.
        let slug = name.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let workspacePath = "\(NSHomeDirectory())/.openclaw/workspace-\(slug)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/openclaw")
        process.arguments = [
            "agents", "add",
            "--non-interactive",
            "--json",
            "--model", model,
            "--workspace", workspacePath,
            name
        ]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        do { try process.run() } catch {
            print("[Hatch] Failed to launch openclaw: \(error)")
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[Hatch] openclaw agents add failed: \(err)")
            return nil
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let json    = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let agentId = json["agentId"] as? String else {
            print("[Hatch] Could not parse agentId from openclaw output")
            return nil
        }

        print("[Hatch] Created agent '\(agentId)' at \(workspacePath)")
        return agentId
    }

    // Appends personality + purpose to the SOUL.md OpenClaw already wrote,
    // preserving all of OpenClaw's default content.
    private static func appendToSoul(at workspacePath: String, personality: String, purpose: String) {
        let path = "\(workspacePath)/SOUL.md"
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let addition = """

        ---

        ## My Personality
        \(personality)

        ## My Purpose
        \(purpose)
        """
        try? (existing + addition).write(toFile: path, atomically: true, encoding: .utf8)
    }

    // Appends the user's info to the USER.md OpenClaw already wrote.
    private static func appendToUser(at workspacePath: String, userInfo: String) {
        let path = "\(workspacePath)/USER.md"
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let addition = """

        ---

        ## From Setup
        \(userInfo)
        """
        try? (existing + addition).write(toFile: path, atomically: true, encoding: .utf8)
    }

}
