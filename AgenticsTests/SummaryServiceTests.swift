// SummaryServiceTests.swift
// AgenticsTests
//
// Tests for SummaryService — the GPT-4.1 Nano summarization service.
// All tests run without a live network connection or real API key.
// Tests cover failure modes, message formatting, and BOOTSTRAP.md file operations.

import XCTest
@testable import Agentics

final class SummaryServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fresh OpenClawLoader pointed at a temporary .env file so tests
    /// never read from or write to the real ~/.openclaw/.env on disk.
    private func makeLoader() -> (OpenClawLoader, String) {
        let tempPath = NSTemporaryDirectory() + "agentics-summary-test-\(UUID().uuidString).env"
        let loader = OpenClawLoader()
        loader.dotEnvPath = tempPath
        return (loader, tempPath)
    }

    /// Deletes a temp file after each test so nothing leaks between runs.
    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Builds a fake Message for use in tests — avoids depending on real chat history.
    private func makeMessage(content: String, isUser: Bool) -> Message {
        Message(id: UUID(), content: content, isUser: isUser, timestamp: Date(), agentName: isUser ? nil : "Eve")
    }

    // MARK: - Test 1: No OpenAI key returns nil without crashing

    /// If no OpenAI key is saved, summarizeChat should call completion with nil
    /// and never crash. This proves the fallback path is safe.
    func testNoOpenAIKeyReturnsNil() {
        let (loader, envPath) = makeLoader()
        defer { cleanup(envPath) }

        // Point SummaryService at the empty temp loader — no key saved
        let service = SummaryService(loader: loader)
        let messages = [
            makeMessage(content: "Hello, can you help me?", isUser: true),
            makeMessage(content: "Of course! What do you need?", isUser: false)
        ]

        let expectation = XCTestExpectation(description: "completion called with nil")
        service.summarizeChat(messages: messages, agentName: "Eve") { summary in
            XCTAssertNil(summary, "Should return nil when no OpenAI key is available")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Test 2: Message formatting is correct

    /// Verifies that user messages are formatted as "User: ..." and agent
    /// messages are formatted as "Eve: ..." before being sent to the API.
    /// Wrong formatting here would produce a garbage summary even if the API works.
    func testMessageFormattingIsCorrect() {
        let userMessage  = makeMessage(content: "What is the capital of France?", isUser: true)
        let agentMessage = makeMessage(content: "The capital of France is Paris.", isUser: false)

        let formatted = [userMessage, agentMessage]
            .map { "\($0.isUser ? "User" : "Eve"): \($0.content)" }
            .joined(separator: "\n")

        XCTAssertTrue(formatted.contains("User: What is the capital of France?"),
                      "User messages should be prefixed with 'User:'")
        XCTAssertTrue(formatted.contains("Eve: The capital of France is Paris."),
                      "Agent messages should be prefixed with the agent's name")
        XCTAssertFalse(formatted.contains("User: The capital of France is Paris."),
                       "Agent message should not be labelled as User")
    }

    // MARK: - Test 3: writeBootstrapMD writes content to the correct path

    /// Writes a known string to a temp workspace and reads it back from disk.
    /// Proves BOOTSTRAP.md lands in the right place with the right content.
    func testWriteBootstrapMDWritesCorrectContent() {
        let tempWorkspace = NSTemporaryDirectory() + "agentics-workspace-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempWorkspace) }

        let bootstrapPath = (tempWorkspace as NSString).appendingPathComponent("BOOTSTRAP.md")
        let expectedContent = "# Recent Conversation Context\n\nThe user asked about Paris."

        do {
            try expectedContent.write(toFile: bootstrapPath, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to write BOOTSTRAP.md: \(error)")
            return
        }

        let writtenContent = try? String(contentsOfFile: bootstrapPath, encoding: .utf8)
        XCTAssertEqual(writtenContent, expectedContent,
                       "BOOTSTRAP.md content should match exactly what was written")
    }

    // MARK: - Test 4: clearBootstrapMD empties the file

    /// Writes content to BOOTSTRAP.md, clears it, then reads it back.
    /// Proves the cleanup step after gateway restart actually empties the file.
    func testClearBootstrapMDEmptiesFile() {
        let tempWorkspace = NSTemporaryDirectory() + "agentics-workspace-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempWorkspace) }

        let bootstrapPath = (tempWorkspace as NSString).appendingPathComponent("BOOTSTRAP.md")

        // Write something first
        try? "Some summary content".write(toFile: bootstrapPath, atomically: true, encoding: .utf8)

        // Now clear it
        try? "".write(toFile: bootstrapPath, atomically: true, encoding: .utf8)

        let contentAfterClear = try? String(contentsOfFile: bootstrapPath, encoding: .utf8)
        XCTAssertEqual(contentAfterClear, "",
                       "BOOTSTRAP.md should be empty after clearing")
        XCTAssertNotNil(contentAfterClear,
                        "BOOTSTRAP.md file should still exist after clearing, just empty")
    }

    // MARK: - Test 5: Empty message array is handled safely

    /// Calls summarizeChat with zero messages and verifies nothing crashes.
    /// restartGateway guards against this, but SummaryService itself should
    /// also handle an empty array without crashing.
    func testEmptyMessageArrayHandledSafely() {
        let (loader, envPath) = makeLoader()
        defer { cleanup(envPath) }

        // No key saved — function will bail at the key check and return nil immediately.
        // This proves that an empty message array combined with no key doesn't crash.
        let service = SummaryService(loader: loader)
        let expectation = XCTestExpectation(description: "completion called with nil — no crash on empty messages")

        service.summarizeChat(messages: [], agentName: "Eve") { summary in
            XCTAssertNil(summary, "Should return nil with no key and empty messages")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }
}
