// ModelCostTier.swift
// Agentics
//
// Maps model name strings to relative cost tiers at runtime.
// Used to rank agents in the image upload suggestion chip.
//
// Pricing reference (per million tokens, as of April 2026):
//   GPT-4o-mini:        $0.15 input / $0.60 output
//   Claude Haiku 4.5:   $1.00 input / $5.00 output
//   Claude Sonnet 4.6:  $3.00 input / $15.00 output
//   Claude Opus:        $5.00 input / $25.00 output
//
// To support a new model: add its pattern to score() below.
// The suggestion chip ranking updates automatically at runtime.

import Foundation

enum ModelCostTier {

    /// Returns a relative cost score for the given model string.
    /// Lower score = cheaper. Reads the model name at runtime so
    /// swapping models via a model picker automatically re-sorts the chip.
    static func score(for modelString: String) -> Int {
        let m = modelString.lowercased()
        if m.contains("gpt-4.1-nano")                   { return 1 }
        if m.contains("gpt-4o-mini")                   { return 2 }
        if m.contains("haiku")                          { return 3 }
        if m.contains("gpt-4o") && !m.contains("mini") { return 4 }
        if m.contains("sonnet")                         { return 5 }
        if m.contains("gpt-5")                          { return 6 }
        if m.contains("opus")                           { return 7 }
        return 3 // unknown model → treat as mid-tier
    }

    /// Returns a human-readable cost label for a given score.
    static func label(for score: Int) -> String {
        switch score {
        case 1, 2: return "Low Cost"
        case 3:    return "Mid Cost"
        default:   return "High Cost"
        }
    }

    /// Curated list of models available in the model picker.
    /// Add new models here — cost scoring and suggestion chip update automatically.
    static let availableModels: [(id: String, displayName: String)] = [
        ("openai/gpt-4.1-nano",         "GPT-4.1 Nano"),
        ("openai/gpt-4o-mini",          "GPT-4o mini"),
        ("anthropic/claude-haiku-4-5",  "Claude Haiku 4.5"),
        ("openai/gpt-4o",               "GPT-4o"),
        ("anthropic/claude-sonnet-4-6", "Claude Sonnet 4.6"),
    ]

    /// Returns all agents sorted cheapest-first, each paired with a cost label.
    /// Reads agentConfig.model at runtime — adapts automatically when models are swapped.
    static func rankedAgents(from agents: [Agent]) -> [(agent: Agent, label: String)] {
        agents
            .compactMap { a -> (agent: Agent, score: Int)? in
                guard let model = a.agentConfig?.model?.primary else { return nil }
                return (a, score(for: model))
            }
            .sorted { $0.score < $1.score }
            .map { (agent: $0.agent, label: label(for: $0.score)) }
    }
}
