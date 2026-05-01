// SummaryService.swift
// Agentics
//
// Handles AI-powered text summarization using GPT-4.1 Nano.
// Currently used to summarize chat history before a gateway restart,
// so the new model receives context via BOOTSTRAP.md.
//
// Can be extended for other summarization needs — Council Mode,
// avatar mood detection fallback, sidebar previews, session export, etc.

import Foundation

class SummaryService {
    static let shared = SummaryService()

    private let loader: OpenClawLoader

    /// Production init — uses the shared OpenClawLoader.
    private init() {
        self.loader = OpenClawLoader.shared
    }

    /// Test init — accepts a custom loader so unit tests can run
    /// without touching the real ~/.openclaw/.env file on disk.
    init(loader: OpenClawLoader) {
        self.loader = loader
    }

    /// Summarizes a conversation using GPT-4.1 Nano.
    /// Reads the OpenAI key from ~/.openclaw/.env automatically.
    /// Completion is called with nil if no key is available or the API call fails —
    /// the caller should proceed normally in that case rather than blocking.
    func summarizeChat(messages: [Message], agentName: String, completion: @escaping (String?) -> Void) {
        guard let openAIKey = loader.readOpenAIKey(), !openAIKey.isEmpty else {
            print("[SummaryService] No OpenAI key found — skipping summarization")
            completion(nil)
            return
        }

        let conversation = messages
            .map { "\($0.isUser ? "User" : agentName): \($0.content)" }
            .joined(separator: "\n")

        let prompt = """
        Summarize this conversation as a detailed handoff note for another AI model \
        that will be continuing this conversation. Include the main topics discussed, \
        any decisions or conclusions reached, important context, and anything that was \
        left unresolved. Be thorough and detailed — do not leave out any important \
        details. The new model will have no other context beyond this summary.

        \(conversation)
        """

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod  = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",    forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model":      "gpt-4.1-nano",
            "messages":   [["role": "user", "content": prompt]],
            "max_tokens": 2500
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil)
            return
        }
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data,
                  let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                print("[SummaryService] API call failed: \(error?.localizedDescription ?? "unknown error")")
                completion(nil)
                return
            }
            completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
        }.resume()
    }
}
