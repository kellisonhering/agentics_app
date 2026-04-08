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
    private func makeFinalFrame() -> String {
        return """
        {
            "type": "event",
            "event": "chat",
            "payload": { "state": "final" }
        }
        """
    }

    /// Spins the main RunLoop briefly to let DispatchQueue.main.async blocks execute.
    private func drainMainQueue() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    // MARK: - Tests

    /// THE CORE TEST: Tokens only go to the agent that sent the last message.
    func testTokensRouteToCorrectAgent() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        var eveTokens:   [String] = []
        var orionTokens: [String] = []

        ws.send(
            message: "Hello from Eve",
            agentID: "eve",
            onToken: { token in eveTokens.append(token) },
            onError: { _ in XCTFail("Eve should not get an error") }
        )

        ws.handleFrame(makeTokenFrame(delta: "Hello"))
        ws.handleFrame(makeTokenFrame(delta: " there"))
        ws.handleFrame(makeTokenFrame(delta: "!"))

        drainMainQueue()

        XCTAssertEqual(eveTokens, ["Hello", " there", "!"],
                        "Eve should receive all tokens from her stream")

        XCTAssertTrue(orionTokens.isEmpty,
                      "Orion should receive zero tokens — he didn't send anything")
    }

    /// After Eve's stream completes, sending as Orion should route
    /// all NEW tokens to Orion — not Eve.
    func testHandlerSwitchesOnNewMessage() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        var eveTokens:   [String] = []
        var orionTokens: [String] = []

        ws.send(
            message: "Hello from Eve",
            agentID: "eve",
            onToken: { token in eveTokens.append(token) },
            onError: { _ in XCTFail("Eve error") }
        )

        ws.handleFrame(makeTokenFrame(delta: "Eve reply"))
        ws.handleFrame(makeFinalFrame())

        drainMainQueue()

        ws.send(
            message: "Hello from Orion",
            agentID: "orion",
            onToken: { token in orionTokens.append(token) },
            onError: { _ in XCTFail("Orion error") }
        )

        ws.handleFrame(makeTokenFrame(delta: "Orion reply"))

        drainMainQueue()

        XCTAssertTrue(eveTokens.contains("Eve reply"),
                      "Eve should have received her token")
        XCTAssertEqual(orionTokens, ["Orion reply"],
                       "Orion should receive only his own tokens")
    }

    /// If no message has been sent yet, incoming tokens should not crash.
    func testTokensWithNoHandlerDoNotCrash() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        ws.handleFrame(makeTokenFrame(delta: "orphan token"))
        ws.handleFrame(makeFinalFrame())

        drainMainQueue()
    }

    /// The pending agent ID should be set after send().
    func testPendingAgentIDSetAfterSend() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        ws.send(
            message: "test",
            agentID: "eve",
            onToken: { _ in },
            onError: { _ in }
        )

        XCTAssertEqual(ws.pendingAgentID, "eve",
                       "pendingAgentID should be 'eve' after sending as Eve")
    }

    /// Overwriting the handler mid-stream should route new tokens to the new handler.
    func testOverwriteHandlerMidStream() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        var eveTokens:   [String] = []
        var novaTokens:  [String] = []

        ws.send(
            message: "Eve message",
            agentID: "eve",
            onToken: { token in eveTokens.append(token) },
            onError: { _ in }
        )

        ws.handleFrame(makeTokenFrame(delta: "first"))

        drainMainQueue()

        ws.send(
            message: "Nova message",
            agentID: "nova",
            onToken: { token in novaTokens.append(token) },
            onError: { _ in }
        )

        ws.handleFrame(makeTokenFrame(delta: "second"))

        drainMainQueue()

        XCTAssertEqual(eveTokens, ["first"],
                       "Eve should only have the token before handler was overwritten")
        XCTAssertEqual(novaTokens, ["second"],
                       "Nova should get tokens after her send() overwrote the handler")
    }

    /// Unparseable frames should not crash or route to any handler.
    func testUnparseableFrameHandledGracefully() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        var tokens: [String] = []

        ws.send(
            message: "test",
            agentID: "eve",
            onToken: { token in tokens.append(token) },
            onError: { _ in }
        )

        ws.handleFrame("this is not json")
        ws.handleFrame("{malformed")
        ws.handleFrame("")

        drainMainQueue()

        XCTAssertTrue(tokens.isEmpty,
                      "Unparseable frames should not produce tokens")
    }
}

