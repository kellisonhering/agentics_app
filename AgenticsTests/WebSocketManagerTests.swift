// WebSocketManagerTests.swift
// AgenticsTests
//
// Tests for the session-keyed token routing logic in OpenClawWebSocket.
// Proves that each agent's tokens are routed to the correct handler,
// even when multiple agents are active — no token mixing.

import XCTest
@testable import Agentics

final class WebSocketManagerTests: XCTestCase {

    // MARK: - Frame Helpers
    // These helpers build JSON frames that match the real gateway format.
    // Every agent token event includes "sessionKey" and "runId" so the
    // router can dispatch to the correct handler.

    /// A token streaming frame for a specific session.
    private func makeTokenFrame(delta: String, sessionKey: String, runId: String = "run-test-123") -> String {
        return """
        {
            "type": "event",
            "event": "agent",
            "payload": {
                "sessionKey": "\(sessionKey)",
                "runId": "\(runId)",
                "stream": "assistant",
                "data": { "delta": "\(delta)" }
            }
        }
        """
    }

    /// A lifecycle frame signaling the end of a stream (this is how the
    /// gateway tells us a response is fully done).
    private func makeLifecycleEndFrame(sessionKey: String, runId: String = "run-test-123") -> String {
        return """
        {
            "type": "event",
            "event": "agent",
            "payload": {
                "sessionKey": "\(sessionKey)",
                "runId": "\(runId)",
                "stream": "lifecycle",
                "data": { "phase": "end" }
            }
        }
        """
    }

    /// A chat.final frame — still sent by the gateway but only used for
    /// bookkeeping, not for calling completion handlers.
    private func makeChatFinalFrame() -> String {
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

    /// THE CORE TEST: Tokens only go to the agent whose sessionKey matches.
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

        // Frames carry sessionKey "agent:eve:main" — should go to Eve's handler
        ws.handleFrame(makeTokenFrame(delta: "Hello",  sessionKey: "agent:eve:main"))
        ws.handleFrame(makeTokenFrame(delta: " there", sessionKey: "agent:eve:main"))
        ws.handleFrame(makeTokenFrame(delta: "!",      sessionKey: "agent:eve:main"))

        drainMainQueue()

        XCTAssertEqual(eveTokens, ["Hello", " there", "!"],
                       "Eve should receive all tokens from her stream")
        XCTAssertTrue(orionTokens.isEmpty,
                      "Orion should receive zero tokens — he never sent a message")
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

        ws.handleFrame(makeTokenFrame(delta: "Eve reply", sessionKey: "agent:eve:main"))
        ws.handleFrame(makeLifecycleEndFrame(sessionKey: "agent:eve:main"))

        drainMainQueue()

        ws.send(
            message: "Hello from Orion",
            agentID: "orion",
            onToken: { token in orionTokens.append(token) },
            onError: { _ in XCTFail("Orion error") }
        )

        ws.handleFrame(makeTokenFrame(delta: "Orion reply", sessionKey: "agent:orion:main"))

        drainMainQueue()

        XCTAssertTrue(eveTokens.contains("Eve reply"),
                      "Eve should have received her token before the stream ended")
        XCTAssertEqual(orionTokens, ["Orion reply"],
                       "Orion should receive only his own tokens")
    }

    /// If no message has been sent yet, incoming tokens should not crash.
    func testTokensWithNoHandlerDoNotCrash() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        // No call to send() — no handlers registered — should be a silent no-op
        ws.handleFrame(makeTokenFrame(delta: "orphan token", sessionKey: "agent:nobody:main"))
        ws.handleFrame(makeLifecycleEndFrame(sessionKey: "agent:nobody:main"))

        drainMainQueue()
        // If we get here without crashing, the test passes
    }

    /// The pending agent ID should be set immediately after send().
    func testPendingAgentIDSetAfterSend() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        ws.send(
            message: "test",
            agentID: "eve",
            onToken: { _ in },
            onError: { _ in }
        )

        XCTAssertEqual(ws.pendingAgentID, "eve",
                       "pendingAgentID should be 'eve' right after send()")
    }

    /// Two concurrent agents should each get only their own tokens.
    func testTwoAgentsConcurrentStreams() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        var eveTokens:  [String] = []
        var novaTokens: [String] = []

        ws.send(
            message: "Eve message",
            agentID: "eve",
            onToken: { token in eveTokens.append(token) },
            onError: { _ in }
        )

        ws.send(
            message: "Nova message",
            agentID: "nova",
            onToken: { token in novaTokens.append(token) },
            onError: { _ in }
        )

        // Interleaved frames from two different sessions
        ws.handleFrame(makeTokenFrame(delta: "eve-1",  sessionKey: "agent:eve:main",  runId: "run-eve"))
        ws.handleFrame(makeTokenFrame(delta: "nova-1", sessionKey: "agent:nova:main", runId: "run-nova"))
        ws.handleFrame(makeTokenFrame(delta: "eve-2",  sessionKey: "agent:eve:main",  runId: "run-eve"))
        ws.handleFrame(makeTokenFrame(delta: "nova-2", sessionKey: "agent:nova:main", runId: "run-nova"))

        drainMainQueue()

        XCTAssertEqual(eveTokens,  ["eve-1",  "eve-2"],  "Eve should get exactly her two tokens")
        XCTAssertEqual(novaTokens, ["nova-1", "nova-2"], "Nova should get exactly her two tokens")
    }

    /// A lifecycle:end frame should remove the handler so future orphan
    /// tokens for that session produce no output.
    func testLifecycleEndClearsHandler() {
        let ws = OpenClawWebSocket(authToken: "test-token-not-real")

        var tokens: [String] = []

        ws.send(
            message: "test",
            agentID: "eve",
            onToken: { token in tokens.append(token) },
            onError: { _ in }
        )

        ws.handleFrame(makeTokenFrame(delta: "before end", sessionKey: "agent:eve:main"))
        ws.handleFrame(makeLifecycleEndFrame(sessionKey: "agent:eve:main"))

        drainMainQueue()

        // After lifecycle:end the handler is gone — stale tokens must be ignored
        ws.handleFrame(makeTokenFrame(delta: "after end", sessionKey: "agent:eve:main"))

        drainMainQueue()

        XCTAssertEqual(tokens, ["before end"],
                       "Tokens arriving after lifecycle:end should be silently dropped")
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
                      "Unparseable frames should not produce any tokens")
    }
}
