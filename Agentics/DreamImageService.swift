// DreamImageService.swift
// Agentics
//
// Generates and caches dream imagery using DALL-E 3.
// Images are saved as dream-YYYY-MM-DD.png inside the agent's workspace
// and matched to diary entries by their real date.
//
// Generation is triggered when the Dream Diary sheet opens — catching up on
// any entries written while the app was closed — and again whenever the
// image toggle is turned on while the sheet is already open.

import Foundation
import AppKit

@MainActor
final class DreamImageService: ObservableObject {

    static let shared = DreamImageService()
    private init() {}

    /// Dates currently being generated — observed by the sheet to show loading state.
    @Published var generatingFor: Set<String> = []

    // MARK: - File management

    /// Returns the local path to a cached image for the given entry, or nil if none exists.
    func imagePath(for entry: DreamEntry, workspace: String) -> String? {
        let expanded = (workspace as NSString).expandingTildeInPath
        let path = (expanded as NSString).appendingPathComponent("dream-\(entry.realDate).png")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Generation

    /// Generates images for any entries that don't have one yet.
    /// Checks Task.isCancelled between entries so it stops promptly when the sheet is closed.
    func generateMissing(entries: [DreamEntry], workspace: String, agentId: String) async {
        for entry in entries {
            guard !Task.isCancelled else { break }
            guard imagePath(for: entry, workspace: workspace) == nil else { continue }
            await generate(for: entry, workspace: workspace, agentId: agentId)
        }
    }

    /// Generates a single dream image and saves it to the agent's workspace.
    func generate(for entry: DreamEntry, workspace: String, agentId: String) async {
        guard !generatingFor.contains(entry.realDate) else { return }
        generatingFor.insert(entry.realDate)
        defer { generatingFor.remove(entry.realDate) }

        guard let apiKey = OpenClawLoader.shared.readOpenAIKey(), !apiKey.isEmpty else {
            print("[DreamImageService] No OpenAI key found — skipping generation")
            return
        }

        let prompt = """
            A dreamlike, atmospheric artwork inspired by this dream: \
            \(entry.content.prefix(700)). \
            Style: ethereal, cinematic lighting, painterly, surreal, impressionistic. \
            No text or words in the image.
            """

        guard let imageData = await callDALLE(prompt: prompt, apiKey: apiKey) else { return }

        let expanded = (workspace as NSString).expandingTildeInPath
        let path = (expanded as NSString).appendingPathComponent("dream-\(entry.realDate).png")
        try? imageData.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - DALL-E 3 API
    // Pattern mirrors AgentAvatarService.callDALLE — landscape format suits dream banners.

    private func callDALLE(prompt: String, apiKey: String) async -> Data? {
        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else { return nil }

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model":           "dall-e-3",
            "prompt":          prompt,
            "n":               1,
            "size":            "1792x1024",
            "quality":         "standard",
            "response_format": "url"
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("[DreamImageService] DALL-E HTTP error")
                return nil
            }

            guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first   = dataArr.first,
                  let urlStr  = first["url"] as? String,
                  let imgURL  = URL(string: urlStr)
            else {
                print("[DreamImageService] Could not parse image URL from response")
                return nil
            }

            let (imgData, _) = try await URLSession.shared.data(from: imgURL)

            guard let nsImage  = NSImage(data: imgData),
                  let tiffData = nsImage.tiffRepresentation,
                  let bitmap   = NSBitmapImageRep(data: tiffData),
                  let pngData  = bitmap.representation(using: .png, properties: [:])
            else {
                print("[DreamImageService] Failed to convert image to PNG")
                return nil
            }

            return pngData

        } catch {
            print("[DreamImageService] Network error: \(error)")
            return nil
        }
    }
}
