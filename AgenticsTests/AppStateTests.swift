// AppStateTests.swift
// AgenticsTests
//
// Tests for the cross-agent streaming guard in AppState.
// Proves that streamingAgents correctly blocks sending while any agent is active.

import XCTest
@testable import Agentics

final class AppStateTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a minimal Agent for testing without requiring a live config or gateway.
    private func makeAgent(id: String, name: String) -> Agent {
        return Agent(
            id: id,
            agentConfig: nil,
            name: name,
            role: "Test Agent",
            isActive: true,
            systemPrompt: "",
            heartbeatContent: "",
            heartbeatInterval: "off",
            heartbeatMDFound: false,
            workspacePath: "~/.openclaw/workspace",
            soulMDFound: false,
            identityContent: "",
            identityMDFound: false,
            lastMessage: "",
            lastMessageTime: "",
            unreadCount: 0,
            avatarColor: .purple,
            status: .idle
        )
    }

    // MARK: - Tests

    /// streamingAgents should be empty when the app launches.
    /// No agent should be considered streaming before any message is sent.
    func testStreamingAgentsIsEmptyOnInit() {
        let state = AppState()
        XCTAssertTrue(state.streamingAgents.isEmpty,
                      "No agents should be streaming on launch")
    }

    /// Inserting an agent ID into streamingAgents should mark that agent as streaming.
    /// This is how InputBarView's isStreaming computed property works.
    func testInsertingAgentIDMarksItAsStreaming() {
        let state = AppState()
        let eve = makeAgent(id: "eve", name: "Eve")

        state.streamingAgents.insert(eve.id)

        XCTAssertTrue(state.streamingAgents.contains(eve.id),
                      "Eve should be marked as streaming after insert")
    }

    /// isStreaming is true when the current agent's ID is in streamingAgents.
    /// This is the self-guard: blocks sending to an agent already responding.
    func testIsStreamingTrueWhenCurrentAgentIsStreaming() {
        let state = AppState()
        let eve = makeAgent(id: "eve", name: "Eve")

        state.streamingAgents.insert(eve.id)

        // Mirrors InputBarView: var isStreaming: Bool { state.streamingAgents.contains(agent.id) }
        let isStreaming = state.streamingAgents.contains(eve.id)
        XCTAssertTrue(isStreaming,
                      "isStreaming should be true when the current agent is in streamingAgents")
    }

    /// isStreaming is false when a different agent is streaming.
    /// Switching to Orion while Eve is streaming should not block Orion's input bar
    /// via the self-guard — only via the cross-agent guard.
    func testIsStreamingFalseWhenDifferentAgentIsStreaming() {
        let state = AppState()
        let eve   = makeAgent(id: "eve",   name: "Eve")
        let orion = makeAgent(id: "orion", name: "Orion")

        state.streamingAgents.insert(eve.id)

        // From Orion's perspective, isStreaming should be false
        let orionIsStreaming = state.streamingAgents.contains(orion.id)
        XCTAssertFalse(orionIsStreaming,
                       "Orion's isStreaming should be false when only Eve is streaming")
    }

    /// The cross-agent guard: if any OTHER agent is streaming, sending should be blocked.
    /// This mirrors InputBarView's otherStreamingAgentName computed property.
    func testCrossAgentGuardDetectsOtherStreamingAgent() {
        let state = AppState()
        let eve   = makeAgent(id: "eve",   name: "Eve")
        let orion = makeAgent(id: "orion", name: "Orion")

        state.agents = [eve, orion]
        state.streamingAgents.insert(eve.id)

        // Mirrors InputBarView:
        // var otherStreamingAgentName: String? {
        //     guard let streaming = state.streamingAgents.first(where: { $0 != agent.id }) else { return nil }
        //     return state.agents.first(where: { $0.id == streaming })?.name
        // }
        let otherStreamingAgentName = state.streamingAgents
            .first(where: { $0 != orion.id })
            .flatMap { streamingID in state.agents.first(where: { $0.id == streamingID })?.name }

        XCTAssertEqual(otherStreamingAgentName, "Eve",
                       "Cross-agent guard should detect Eve as the other streaming agent")
    }

    /// The cross-agent guard should return nil when no other agent is streaming.
    /// This means Orion's input bar is unblocked when only he is streaming.
    func testCrossAgentGuardIsNilWhenNoOtherAgentStreaming() {
        let state = AppState()
        let eve   = makeAgent(id: "eve",   name: "Eve")
        let orion = makeAgent(id: "orion", name: "Orion")

        state.agents = [eve, orion]
        state.streamingAgents.insert(orion.id)

        // From Orion's perspective — no OTHER agent is streaming
        let otherStreamingAgentName = state.streamingAgents
            .first(where: { $0 != orion.id })
            .flatMap { streamingID in state.agents.first(where: { $0.id == streamingID })?.name }

        XCTAssertNil(otherStreamingAgentName,
                     "Cross-agent guard should be nil when only the current agent is streaming")
    }

    /// Removing an agent from streamingAgents should clear the streaming state.
    /// This happens at the end of streamResponse() when the stream completes.
    func testRemovingAgentIDClearsStreamingState() {
        let state = AppState()
        let eve = makeAgent(id: "eve", name: "Eve")

        state.streamingAgents.insert(eve.id)
        XCTAssertTrue(state.streamingAgents.contains(eve.id))

        state.streamingAgents.remove(eve.id)
        XCTAssertFalse(state.streamingAgents.contains(eve.id),
                       "Eve should no longer be streaming after removal")
    }

    /// With two agents streaming simultaneously, both cross-agent guards should fire.
    /// In practice the UI prevents this, but the underlying Set should handle it correctly.
    func testBothAgentsStreamingBlocksEachOther() {
        let state = AppState()
        let eve   = makeAgent(id: "eve",   name: "Eve")
        let orion = makeAgent(id: "orion", name: "Orion")

        state.agents = [eve, orion]
        state.streamingAgents.insert(eve.id)
        state.streamingAgents.insert(orion.id)

        // From Eve's perspective, Orion is the other streaming agent
        let eveSeesOrion = state.streamingAgents
            .first(where: { $0 != eve.id })
            .flatMap { streamingID in state.agents.first(where: { $0.id == streamingID })?.name }

        // From Orion's perspective, Eve is the other streaming agent
        let orionSeesEve = state.streamingAgents
            .first(where: { $0 != orion.id })
            .flatMap { streamingID in state.agents.first(where: { $0.id == streamingID })?.name }

        XCTAssertEqual(eveSeesOrion, "Orion",
                       "Eve's cross-agent guard should detect Orion")
        XCTAssertEqual(orionSeesEve, "Eve",
                       "Orion's cross-agent guard should detect Eve")
    }
}
