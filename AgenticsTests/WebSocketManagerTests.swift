// WebSocketManagerTests.swift
// AgenticsTests
//
// Tests for the token stream routing logic in OpenClawWebSocket.
// Proves that the single-handler design prevents token mixing between agents.

import XCTest
@testable import Agentics

final class WebSocketManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a fake "agent" event frame (token streaming) as a JSON string.
    /// This is exactly what the OpenClaw gateway sends when an agent produces a token.
    private func makeTokenFrame(delta: String) -> String {
        return """
        {
            "type": "event",
            "event": "agent",
            "payload": {
                "stream": "assistant",
                "data": { "delta": "\(delta)" }
            }
        }
        """
    }

    /// Builds a fake "chat" event frame with state: "final" (stream complete).
    /// The gateway sends this when the agent finishes its response.
    private func makeFinalFrame() -> String {
        return """
        {
            "type": "event",
            "event": "chat",
            "payload": { "state": "final" }
        }
        """
    }

    // MARK: - Tests

    /// THE CORE TEST: Tokens only go to the agent that sent the last message.
    ///
    /// Scenario:
    /// 1. Eve sends a message → her handler is registered
    /// 2. Tokens arrive → they should ALL go to Eve's handler
    /// 3. Orion's handler should receive NOTHING
    ///
    /// This is the exact bug that existed before the single-manager fix:
    /// with per-agent WebSocket connections, tokens could route to the wrong agent.
    func testTokensRouteToCorrectAgent() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        // These arrays collect tokens as they arrive
        var eveTokens:   [String] = []
        var orionTokens: [String] = []

        // Eve sends a message — her handler gets registered
        ws.send(
            message: "Hello from Eve",
            agentID: "eve",
            onToken: { token in eveTokens.append(token) },
            onError: { _ in XCTFail("Eve should not get an error") }
        )

        // Simulate tokens arriving from the gateway
        // Because Eve sent the last message, her handler should catch all of these
        ws.handleFrame(makeTokenFrame(delta: "Hello"))
        ws.handleFrame(makeTokenFrame(delta: " there"))
        ws.handleFrame(makeTokenFrame(delta: "!"))

        // Verify: Eve got all 3 tokens
        XCTAssertEqual(eveTokens, ["Hello", " there", "!"],
                        "Eve should receive all tokens from her stream")

        // Verify: Orion got nothing (he never sent a message)
        XCTAssertTrue(orionTokens.isEmpty,
                      "Orion should receive zero tokens — he didn't send anything")
    }

    /// After Eve's stream completes, sending as Orion should route
    /// all NEW tokens to Orion — not Eve.
    func testHandlerSwitchesAfterStreamCompletes() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        var eveTokens:   [String] = []
        var orionTokens: [String] = []

        // Eve sends and receives a full response
        ws.send(
            message: "Eve's question",
            agentID: "eve",
            onToken: { token in eveTokens.append(token) },
            onError: { _ in }
        )
        ws.handleFrame(makeTokenFrame(delta: "Eve's"))
        ws.handleFrame(makeTokenFrame(delta: " answer"))
        ws.handleFrame(makeFinalFrame())  // Eve's stream ends

        // Now Orion sends a message — his handler should take over
        ws.send(
            message: "Orion's question",
            agentID: "orion",
            onToken: { token in orionTokens.append(token) },
            onError: { _ in }
        )
        ws.handleFrame(makeTokenFrame(delta: "Orion's"))
        ws.handleFrame(makeTokenFrame(delta: " answer"))

        // Eve should have her original tokens plus the empty string from "final"
        XCTAssertEqual(eveTokens, ["Eve's", " answer", ""],
                        "Eve should have her tokens plus empty string from stream end")

        // Orion should have ONLY his own tokens
        XCTAssertEqual(orionTokens, ["Orion's", " answer"],
                        "Orion should only receive tokens from his own stream")
    }

    /// If Orion sends a message WHILE Eve is still streaming,
    /// the handler switches to Orion. Eve's remaining tokens go to Orion.
    /// This is the expected behavior of the single-handler design —
    /// you can't have two streams at once, so the last sender wins.
    func testLastSenderWinsWhenStreamInterrupted() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        var eveTokens:   [String] = []
        var orionTokens: [String] = []

        // Eve sends a message
        ws.send(
            message: "Eve's question",
            agentID: "eve",
            onToken: { token in eveTokens.append(token) },
            onError: { _ in }
        )
        ws.handleFrame(makeTokenFrame(delta: "Start of Eve's"))

        // BEFORE Eve's stream finishes, Orion sends a message
        // This replaces the handler — Orion now owns the inbox
        ws.send(
            message: "Orion's question",
            agentID: "orion",
            onToken: { token in orionTokens.append(token) },
            onError: { _ in }
        )

        // More tokens arrive — they go to Orion (the current handler owner)
        ws.handleFrame(makeTokenFrame(delta: "This goes to Orion"))

        // Eve should only have the token she received before Orion took over
        XCTAssertEqual(eveTokens, ["Start of Eve's"],
                        "Eve should only have tokens from before the handler switch")

        // Orion should have the token that arrived after he took ownership
        XCTAssertEqual(orionTokens, ["This goes to Orion"],
                        "Orion should receive tokens after he became the handler owner")
    }

    /// Empty deltas from the gateway should be ignored (not delivered to handler).
    func testEmptyDeltaIsIgnored() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")
        var tokens: [String] = []

        ws.send(
            message: "test",
            agentID: "eve",
            onToken: { token in tokens.append(token) },
            onError: { _ in }
        )

        // Gateway sometimes sends empty deltas — they should be filtered out
        ws.handleFrame(makeTokenFrame(delta: ""))
        ws.handleFrame(makeTokenFrame(delta: "real token"))

        XCTAssertEqual(tokens, ["real token"],
                        "Empty deltas should be filtered out")
    }

    /// The "final" frame should deliver an empty string to signal stream completion,
    /// then clear the handler so no more tokens are delivered.
    func testFinalFrameClearsHandler() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")
        var tokens: [String] = []

        ws.send(
            message: "test",
            agentID: "eve",
            onToken: { token in tokens.append(token) },
            onError: { _ in }
        )

        ws.handleFrame(makeTokenFrame(delta: "hello"))
        ws.handleFrame(makeFinalFrame())

        // After final, stray tokens should go nowhere (no crash, no delivery)
        ws.handleFrame(makeTokenFrame(delta: "stray token"))

        // Should have: "hello" from the stream, "" from the final signal
        // Should NOT have: "stray token"
        XCTAssertEqual(tokens, ["hello", ""],
                        "After final frame, no more tokens should be delivered")
    }

    /// Verify that pendingAgentID tracks which agent currently owns the handler.
    func testPendingAgentIDTracksCurrentOwner() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        ws.send(message: "hi", agentID: "eve",
                onToken: { _ in }, onError: { _ in })
        XCTAssertEqual(ws.pendingAgentID, "eve",
                        "pendingAgentID should be eve after she sends")

        ws.send(message: "hi", agentID: "orion",
                onToken: { _ in }, onError: { _ in })
        XCTAssertEqual(ws.pendingAgentID, "orion",
                        "pendingAgentID should switch to orion after he sends")
    }
}
