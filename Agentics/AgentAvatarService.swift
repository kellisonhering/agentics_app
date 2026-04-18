import SwiftUI
import ImageIO

// MARK: - Agent Avatar Service

/// Handles avatar generation for each agent using DALL-E 3 + Gemini Flash.
/// Gemini reads the last 10 messages and produces a rich mood/atmosphere description.
/// That description is combined with the agent's fixed DNA string to form the DALL-E prompt.
/// DNA anchors the character appearance; Gemini only describes mood, lighting, and environment.
/// Triggered automatically every 3 new messages, or manually via the avatar popover.
/// Saves result as avatar.png and avatar-dna.txt in the agent's workspace folder.
@MainActor
class AgentAvatarService: ObservableObject {

    @Published var avatarImages:         [String: CGImage]   = [:]
    @Published var agentDNA:             [String: String]    = [:]
    @Published var generatingAgents:     Set<String>         = []
    @Published var lastError:            [String: String]    = [:]
    @Published var avatarHistory:        [String: [CGImage]] = [:]
    @Published var selectedHistoryIndex: [String: Int]       = [:]
    @Published var generationDisabled:   Set<String>         = []
    @Published var geminiUnavailable:    Bool                = false

    private var messageCounters: [String: Int] = [:]

    static let triggerInterval  = 3
    static let historyMaxCount  = 5

    // MARK: - Generation Toggle

    func isGenerationEnabled(for agentId: String) -> Bool {
        !generationDisabled.contains(agentId)
    }

    func setGeneration(enabled: Bool, for agentId: String) {
        if enabled {
            generationDisabled.remove(agentId)
        } else {
            generationDisabled.insert(agentId)
        }
        UserDefaults.standard.set(!enabled, forKey: "avatarGenDisabled_\(agentId)")
    }

    // MARK: - Lifecycle

    func loadAll(agents: [Agent]) async {
        for agent in agents {
            let expanded = (agent.workspacePath as NSString).expandingTildeInPath
            loadAvatar(agentId: agent.id, workspacePath: expanded)
            loadDNA(agentId: agent.id, workspacePath: expanded)
            loadHistory(agentId: agent.id, workspacePath: expanded)
            if UserDefaults.standard.bool(forKey: "avatarGenDisabled_\(agent.id)") {
                generationDisabled.insert(agent.id)
            }
        }
    }

    // MARK: - Message Counter

    func didReceiveMessage(for agent: Agent, messages: [Message]) {
        guard isGenerationEnabled(for: agent.id) else { return }
        let count = (messageCounters[agent.id] ?? 0) + 1
        messageCounters[agent.id] = count

        if count >= Self.triggerInterval {
            messageCounters[agent.id] = 0
            let expanded = (agent.workspacePath as NSString).expandingTildeInPath
            let dna      = agentDNA[agent.id] ?? ""
            Task {
                await generate(agentId: agent.id, agentName: agent.name, messages: messages, workspacePath: expanded, dna: dna, agentConfig: agent.agentConfig)
            }
        }
    }

    // MARK: - Generation

    func generate(agentId: String, agentName: String, messages: [Message], workspacePath: String, dna: String, agentConfig: AgentConfig?) async {
        guard !generatingAgents.contains(agentId) else { return }
        generatingAgents.insert(agentId)
        defer { generatingAgents.remove(agentId) }
        lastError[agentId] = nil

        // Read OpenAI key for DALL-E
        guard let openAIKey = readOpenAIKey(agentConfig: agentConfig), !openAIKey.isEmpty else {
            lastError[agentId] = "No OpenAI API key found. Add one in Agentics → API Keys."
            print("[AvatarService] No OpenAI key found for \(agentName)")
            return
        }

        // Read Gemini key from openclaw.json
        let geminiKey = readGeminiKey()

        // Build prompt — use Gemini if key is available, fall back to DNA-only
        let recentMessages = Array(messages.suffix(10))
        let prompt: String

        if let geminiKey, !geminiKey.isEmpty {
            // Ask Gemini to describe only mood, lighting, environment — not character appearance
            if let geminiDescription = await callGemini(messages: recentMessages, agentName: agentName, apiKey: geminiKey, agentId: agentId) {
                geminiUnavailable = false
                prompt = buildPrompt(dna: dna, agentName: agentName, geminiDescription: geminiDescription)
            } else {
                // Gemini failed (quota exceeded or error) — use basic mood detection as middle tier
                geminiUnavailable = true
                let basicMood = detectMood(from: Array(messages.suffix(3)))
                prompt = buildPrompt(dna: dna, agentName: agentName, geminiDescription: basicMood)
            }
        } else {
            // No Gemini key configured — use basic mood detection silently
            let basicMood = detectMood(from: Array(messages.suffix(3)))
            prompt = buildPrompt(dna: dna, agentName: agentName, geminiDescription: basicMood)
        }

        print("[AvatarService] Generating avatar for \(agentName): \(prompt)")

        // Call DALL-E 3
        guard let imageData = await callDALLE(prompt: prompt, apiKey: openAIKey, agentId: agentId) else {
            return
        }

        // Decode PNG data → CGImage
        guard let provider = CGDataProvider(data: imageData as CFData),
              let cgImage  = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            lastError[agentId] = "Failed to decode generated image."
            return
        }

        pushToHistory(cgImage, agentId: agentId, workspacePath: workspacePath)
        avatarImages[agentId] = cgImage
        selectedHistoryIndex[agentId] = 0
        print("[AvatarService] Avatar saved for \(agentName)")
    }

    // MARK: - On-Demand (Popover Button)

    func regenerate(for agent: Agent, messages: [Message], dna: String) {
        let expanded = (agent.workspacePath as NSString).expandingTildeInPath
        saveDNA(dna, to: expanded)
        agentDNA[agent.id] = dna
        Task {
            await generate(agentId: agent.id, agentName: agent.name, messages: messages, workspacePath: expanded, dna: dna, agentConfig: agent.agentConfig)
        }
    }

    // MARK: - Prompt Builders

    /// Full prompt: DNA anchors character, Gemini describes mood/atmosphere only.
    private func buildPrompt(dna: String, agentName: String, geminiDescription: String) -> String {
        let base = dna.isEmpty ? "\(agentName), an AI assistant character" : dna
        return "\(base), \(geminiDescription), single figure, centered, solid color background, no frame, no border, stylized digital painting, soft cinematic lighting, semi-realistic, high quality"
    }

    /// Fallback when Gemini key is missing or call fails.
    private func buildFallbackPrompt(dna: String, agentName: String) -> String {
        let base = dna.isEmpty ? "\(agentName), an AI assistant character" : dna
        return "\(base), single figure, centered, solid color background, no frame, no border, stylized digital painting, soft warm lighting, semi-realistic, high quality"
    }

    // MARK: - Basic Mood Detection (Gemini fallback)

    /// Analyzes the last 3 messages and returns a simple mood/atmosphere string
    /// to use in the DALL-E prompt when Gemini is unavailable.
    private func detectMood(from messages: [Message]) -> String {
        let text = messages.suffix(3)
            .map { $0.content }
            .joined(separator: " ")
            .lowercased()

        let technical = ["code", "error", "bug", "function", "debug", "api", "build", "deploy", "crash", "fix"]
        let urgent    = ["urgent", "help", "problem", "issue", "broken", "wrong", "fail", "stuck", "confused"]
        let positive  = ["thanks", "great", "awesome", "perfect", "love", "excellent", "amazing", "good job"]
        let creative  = ["design", "create", "idea", "imagine", "concept", "make", "art", "build"]
        let curious   = ["what", "how", "why", "explain", "curious", "wonder", "interesting", "tell me"]

        if technical.contains(where: { text.contains($0) }) {
            return "cool blue tones, focused technical atmosphere, clean precise lighting"
        }
        if urgent.contains(where: { text.contains($0) }) {
            return "sharp dramatic lighting, tense focused atmosphere, high contrast"
        }
        if positive.contains(where: { text.contains($0) }) {
            return "warm golden lighting, friendly relaxed atmosphere, soft tones"
        }
        if creative.contains(where: { text.contains($0) }) {
            return "vibrant creative atmosphere, warm inspiring light, energetic mood"
        }
        if curious.contains(where: { text.contains($0) }) {
            return "soft natural lighting, thoughtful curious atmosphere, gentle tones"
        }
        return "neutral soft lighting, calm professional atmosphere"
    }

    // MARK: - Gemini Flash API Call

    /// Sends the last 10 messages to Gemini 2.0 Flash and asks it to describe
    /// only the mood, lighting, and environment — not the character's appearance.
    /// Returns a short descriptive string to layer on top of the DNA anchor.
    private func callGemini(messages: [Message], agentName: String, apiKey: String, agentId: String) async -> String? {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)") else { return nil }

        // Build conversation summary for Gemini
        let conversationText = messages.suffix(10).map { msg in
            let role = msg.isUser ? "User" : agentName
            return "\(role): \(msg.content.prefix(200))"
        }.joined(separator: "\n")

        let systemInstruction = """
        You are a visual artist describing the atmosphere of a scene for an AI-generated portrait.
        Read this conversation and describe ONLY the mood, lighting, and environment that would surround the character.
        Do NOT describe the character's appearance, face, or body.
        Keep it under 20 words. Use visual, painterly language.
        Examples: "warm golden light, cozy library atmosphere, soft bokeh background"
        or "cool blue neon glow, focused intensity, dark dramatic shadows"
        """

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "\(systemInstruction)\n\nConversation:\n\(conversationText)\n\nAtmosphere description:"]
                    ]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 60,
                "temperature": 0.7
            ]
        ]

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode != 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let msg   = error["message"] as? String {
                    print("[AvatarService] Gemini error: \(msg)")
                    // Don't surface Gemini errors to the user — just fall back silently
                } else {
                    print("[AvatarService] Gemini HTTP \(http.statusCode)")
                }
                return nil
            }

            guard let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first      = candidates.first,
                  let content    = first["content"] as? [String: Any],
                  let parts      = content["parts"] as? [[String: Any]],
                  let text       = parts.first?["text"] as? String
            else {
                print("[AvatarService] Could not parse Gemini response")
                return nil
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[AvatarService] Gemini description: \(trimmed)")
            return trimmed.isEmpty ? nil : trimmed

        } catch {
            print("[AvatarService] Gemini network error: \(error)")
            return nil
        }
    }

    // MARK: - DALL-E 3 API Call

    private func callDALLE(prompt: String, apiKey: String, agentId: String) async -> Data? {
        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else { return nil }

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model":           "dall-e-3",
            "prompt":          prompt,
            "n":               1,
            "size":            "1024x1024",
            "quality":         "standard",
            "response_format": "url"
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode != 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let msg   = error["message"] as? String {
                    print("[AvatarService] DALL-E error: \(msg)")
                    lastError[agentId] = msg
                } else {
                    lastError[agentId] = "Generation failed (HTTP \(http.statusCode))."
                }
                return nil
            }

            guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first   = dataArr.first,
                  let urlStr  = first["url"] as? String,
                  let imgURL  = URL(string: urlStr)
            else {
                lastError[agentId] = "Could not parse image URL from response."
                return nil
            }

            let (imgData, _) = try await URLSession.shared.data(from: imgURL)

            // Convert to PNG via NSImage
            guard let nsImage  = NSImage(data: imgData),
                  let tiffData = nsImage.tiffRepresentation,
                  let bitmap   = NSBitmapImageRep(data: tiffData),
                  let pngData  = bitmap.representation(using: .png, properties: [:])
            else {
                lastError[agentId] = "Failed to convert image to PNG."
                return nil
            }

            return pngData

        } catch {
            print("[AvatarService] DALL-E network error: \(error)")
            lastError[agentId] = "Network error. Check your connection."
            return nil
        }
    }

    // MARK: - Key Readers

    private func readOpenAIKey(agentConfig: AgentConfig?) -> String? {
        OpenClawLoader.shared.readOpenAIKey()
    }

    private func readGeminiKey() -> String? {
        OpenClawLoader.shared.readGeminiKey()
    }

    // MARK: - History Selection

    func selectHistory(agentId: String, index: Int, workspacePath: String) {
        let history = avatarHistory[agentId] ?? []
        guard index < history.count else { return }
        let image = history[index]
        selectedHistoryIndex[agentId] = index
        avatarImages[agentId] = image
        saveAvatar(image, to: workspacePath)
    }

    // MARK: - Permanent Save

    func savePermanently(agentId: String, workspacePath: String) {
        guard let image = avatarImages[agentId] else { return }
        let savedDir = (workspacePath as NSString).appendingPathComponent("saved-avatars")
        try? FileManager.default.createDirectory(atPath: savedDir, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = (savedDir as NSString).appendingPathComponent("saved-\(timestamp).png")
        writePNG(image, to: path)
        print("[AvatarService] Avatar permanently saved to \(path)")
    }

    // MARK: - Disk I/O

    private func avatarPath(in workspacePath: String) -> String {
        (workspacePath as NSString).appendingPathComponent("avatar.png")
    }

    private func dnaPath(in workspacePath: String) -> String {
        (workspacePath as NSString).appendingPathComponent("avatar-dna.txt")
    }

    private func historyPath(index: Int, in workspacePath: String) -> String {
        (workspacePath as NSString).appendingPathComponent("avatar-history-\(index).png")
    }

    func loadAvatar(agentId: String, workspacePath: String) {
        let path = avatarPath(in: workspacePath)
        guard let image = loadPNG(from: path) else { return }
        avatarImages[agentId] = image
    }

    func loadHistory(agentId: String, workspacePath: String) {
        var history: [CGImage] = []
        for i in 0..<Self.historyMaxCount {
            let path = historyPath(index: i, in: workspacePath)
            if let image = loadPNG(from: path) { history.append(image) }
        }
        avatarHistory[agentId] = history
        selectedHistoryIndex[agentId] = 0
    }

    private func pushToHistory(_ image: CGImage, agentId: String, workspacePath: String) {
        // Shift files on disk: 3→4, 2→3, 1→2, 0→1, new→0
        let fm = FileManager.default
        for i in stride(from: Self.historyMaxCount - 2, through: 0, by: -1) {
            let src  = historyPath(index: i,     in: workspacePath)
            let dest = historyPath(index: i + 1, in: workspacePath)
            if fm.fileExists(atPath: src) {
                try? fm.removeItem(atPath: dest)
                try? fm.copyItem(atPath: src, toPath: dest)
            }
        }
        writePNG(image, to: historyPath(index: 0, in: workspacePath))
        saveAvatar(image, to: workspacePath)

        // Update in-memory history
        var history = avatarHistory[agentId] ?? []
        history.insert(image, at: 0)
        if history.count > Self.historyMaxCount { history = Array(history.prefix(Self.historyMaxCount)) }
        avatarHistory[agentId] = history
    }

    func loadDNA(agentId: String, workspacePath: String) {
        let path = dnaPath(in: workspacePath)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        agentDNA[agentId] = content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAvatar(_ image: CGImage, to workspacePath: String) {
        writePNG(image, to: avatarPath(in: workspacePath))
    }

    func saveDNA(_ dna: String, to workspacePath: String) {
        let path = dnaPath(in: workspacePath)
        try? dna.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - PNG Helpers

    private func loadPNG(from path: String) -> CGImage? {
        guard FileManager.default.fileExists(atPath: path),
              let data     = FileManager.default.contents(atPath: path),
              let provider = CGDataProvider(data: data as CFData),
              let image    = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return image
    }

    private func writePNG(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

