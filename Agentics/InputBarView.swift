// InputBarView.swift
// Agentics
//
// Everything at the bottom of the chat window:
//   - AnimatedSendButton — the gradient capsule send button
//   - TypingIndicator    — the three animated dots shown while the agent is thinking
//   - InputBarView       — the full input bar: plus button, text field, send button,
//                          attachment pill, image suggestion chip, pasted text pill

import SwiftUI
import UniformTypeIdentifiers

// MARK: - AnimatedSendButton

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

// MARK: - TypingIndicator

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

// MARK: - InputBarView

struct InputBarView: View {
    @Binding var inputText: String
    @Binding var agent: Agent
    @Binding var pendingCompact: Bool
    @EnvironmentObject var state: AppState
    @EnvironmentObject var avatarService: AgentAvatarService
    @State private var pastedContent:       String? = nil
    @State private var attachedImage:       (name: String, data: Data, mimeType: String)? = nil
    @State private var showImageSuggestion: Bool = false
    @State private var plusShift:           CGFloat = 0

    var isStreaming: Bool { state.streamingAgents.contains(agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            if isStreaming {
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

            // Image agent suggestion chip
            if attachedImage != nil && showImageSuggestion {
                let visionAgents = state.agents.filter {
                    let model = ($0.agentConfig?.model?.primary ?? "").lowercased()
                    return model.contains("anthropic") || model.contains("claude")
                }
                let ranked = ModelCostTier.rankedAgents(from: visionAgents)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
                        Text("Send image to:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.7))
                        Spacer()
                        Button(action: { showImageSuggestion = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 6)

                    ForEach(ranked, id: \.agent.id) { item in
                        Button(action: {
                            state.selectedAgent = item.agent
                            showImageSuggestion = false
                        }) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(item.agent.avatarColor.opacity(0.25))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Text(String(item.agent.name.prefix(1)).uppercased())
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(item.agent.avatarColor)
                                    )
                                Text("\(item.label): \(item.agent.name.capitalized)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                Spacer()
                                if item.agent.id == agent.id {
                                    Text("current")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color.white.opacity(0.35))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .glassBackground(opacity: 0.10, cornerRadius: 10, borderOpacity: 0.15)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let pasted = pastedContent {
                let lineCount = pasted.components(separatedBy: .newlines).count
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
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

            // Attached image pill
            if let image = attachedImage {
                HStack(spacing: 8) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1.0, green: 0.25, blue: 0.55))
                    Text(image.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: { attachedImage = nil; showImageSuggestion = false }) {
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

            HStack(alignment: .center, spacing: 8) {
                // Plus button — sits outside the input bar, to its left
                Button(action: pickImage) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                stops: [
                                    .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(0.90), location: max(0, 0.00 - plusShift)),
                                    .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55).opacity(0.90), location: max(0, min(1, 0.25 - plusShift))),
                                    .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.90), location: max(0, min(1, 0.50 - plusShift))),
                                    .init(color: Color(red: 0.30, green: 0.55, blue: 1.00).opacity(0.90), location: max(0, min(1, 0.75 - plusShift))),
                                    .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.88), location: min(1, 1.00 - plusShift)),
                                ],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            ))
                            .frame(width: 32, height: 32)
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .onAppear {
                    withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                        plusShift = 0.30
                    }
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
                            .opacity((inputText.isEmpty && pastedContent == nil && attachedImage == nil || isStreaming) ? 0 : 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    .allowsHitTesting((!inputText.isEmpty || pastedContent != nil || attachedImage != nil) && !isStreaming)
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: pastedContent != nil)
        .animation(.easeInOut(duration: 0.2), value: attachedImage != nil)
        .animation(.easeInOut(duration: 0.2), value: showImageSuggestion)
        .onChange(of: pendingCompact) { pending in
            if pending { pendingCompact = false; sendMessage() }
        }
    }

    /// Converts a HEIC file to JPEG data at 90% quality.
    /// Forces sRGB colour space so Claude's API can decode it —
    /// HEIC images often carry Display P3 / HDR profiles that confuse the API.
    /// Returns nil if the file can't be read or any conversion step fails.
    func convertHEIC(at url: URL) -> Data? {
        guard let image   = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width  = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let sRGBImage = context.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: sRGBImage)
        rep.size = image.size
        return rep.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: 0.9)])
    }

    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.message = "Choose an image to send"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext    = url.pathExtension.lowercased()
        let isHEIC = ext == "heic"

        let imageData:   Data
        let displayName: String
        let mimeType:    String

        if isHEIC {
            guard let converted = convertHEIC(at: url) else {
                let errMsg = Message(content: "⚠️ Could not convert HEIC file. Try saving it as JPEG first.", isUser: false, timestamp: Date(), agentName: agent.name)
                if state.messages[agent.id] == nil { state.messages[agent.id] = [] }
                state.messages[agent.id]?.append(errMsg)
                return
            }
            imageData   = converted
            displayName = url.deletingPathExtension().lastPathComponent + ".heic → JPEG"
            mimeType    = "image/jpeg"
        } else {
            guard let data = try? Data(contentsOf: url) else { return }
            imageData   = data
            displayName = url.lastPathComponent
            mimeType    = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/jpeg"
        }

        guard imageData.count <= 5 * 1024 * 1024 else {
            let sizeNote = isHEIC ? " (after HEIC conversion)" : ""
            let errMsg = Message(content: "⚠️ Image too large\(sizeNote). Maximum size is 5MB.", isUser: false, timestamp: Date(), agentName: agent.name)
            if state.messages[agent.id] == nil { state.messages[agent.id] = [] }
            state.messages[agent.id]?.append(errMsg)
            return
        }

        attachedImage       = (name: displayName, data: imageData, mimeType: mimeType)
        showImageSuggestion = true
    }

    func sendMessage() {
        let trimmed   = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPasted = pastedContent != nil
        let hasImage  = attachedImage != nil

        guard (!trimmed.isEmpty || hasPasted || hasImage), !isStreaming else { return }

        var fullContent = trimmed
        if let pasted = pastedContent {
            let pastedBlock = "[Pasted content]\n\(pasted)"
            fullContent = trimmed.isEmpty ? pastedBlock : "\(trimmed)\n\n\(pastedBlock)"
        }

        var displayContent: String = {
            if let pasted = pastedContent {
                let lineCount = pasted.components(separatedBy: .newlines).count
                let preview = trimmed.isEmpty ? "📄 Pasted text • \(lineCount) lines" : "\(trimmed)\n📄 Pasted text • \(lineCount) lines"
                return preview
            }
            return trimmed
        }()

        if let image = attachedImage {
            displayContent = displayContent.isEmpty ? "📎 \(image.name)" : "\(displayContent)\n📎 \(image.name)"
            // Gateway requires non-empty message text even when an attachment is present
            if fullContent.isEmpty { fullContent = "Please analyze this image." }
        }

        // Build attachment payload for gateway if image is attached
        var attachments: [[String: Any]]? = nil
        if let image = attachedImage {
            let base64  = image.data.base64EncodedString()
            attachments = [["type": "image", "mimeType": image.mimeType, "content": base64]]
        }

        let userMsg = Message(content: displayContent, isUser: true, timestamp: Date(), agentName: nil)
        if state.messages[agent.id] == nil { state.messages[agent.id] = [] }
        state.messages[agent.id]?.append(userMsg)
        state.updateSidebarPreview(for: agent.id)

        inputText           = ""
        pastedContent       = nil
        attachedImage       = nil
        showImageSuggestion = false
        state.streamingAgents.insert(agent.id)

        DispatchQueue.main.async {
            if let idx = self.state.agents.firstIndex(where: { $0.id == agent.id }) {
                self.state.agents[idx].status = .thinking
            }
        }

        let agentId          = agent.id
        let agentName        = agent.name
        let messageToSend    = fullContent
        let imageAttachments = attachments

        Task {
            await streamResponse(agentId: agentId, agentName: agentName, message: messageToSend, attachments: imageAttachments)
        }
    }

    func streamResponse(agentId: String, agentName: String, message: String, attachments: [[String: Any]]? = nil) async {
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
                        let allMessages = self.state.messages[agentId] ?? []
                        self.avatarService.didReceiveMessage(for: agent, messages: allMessages)
                    }
                    continuation.resume()
                }
            }

            let dl = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in flush() }
            displayLink = dl

            state.wsManager.send(
                message:     message,
                agentID:     agentId,
                attachments: attachments,

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
