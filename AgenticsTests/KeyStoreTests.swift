// KeyStoreTests.swift
// AgenticsTests
//
// Tests for the .env key store in OpenClawLoader.
// Proves that API keys are saved and loaded correctly without touching the real ~/.openclaw/.env file.

import XCTest
@testable import Agentics

final class KeyStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fresh OpenClawLoader pointed at a temporary file so tests
    /// never touch the real ~/.openclaw/.env on disk.
    private func makeLoader() -> (OpenClawLoader, String) {
        let tempPath = NSTemporaryDirectory() + "agentics-test-\(UUID().uuidString).env"
        let loader = OpenClawLoader()
        loader.dotEnvPath = tempPath
        return (loader, tempPath)
    }

    /// Deletes the temp file after each test so nothing leaks between runs.
    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Tests

    /// Saving a key and reading it back should return the same value.
    func testSaveAndReadSingleKey() {
        let (loader, path) = makeLoader()
        defer { cleanup(path) }

        let saved = loader.writeEnvKeys(["ANTHROPIC_API_KEY": "sk-ant-test-123"])
        XCTAssertTrue(saved, "writeEnvKeys should return true on success")

        let value = loader.readEnvKey("ANTHROPIC_API_KEY")
        XCTAssertEqual(value, "sk-ant-test-123", "Read value should match what was saved")
    }

    /// Saving multiple keys at once should persist all of them.
    func testSaveAndReadMultipleKeys() {
        let (loader, path) = makeLoader()
        defer { cleanup(path) }

        let saved = loader.writeEnvKeys([
            "ANTHROPIC_API_KEY": "sk-ant-test-abc",
            "OPENAI_API_KEY":    "sk-openai-test-xyz",
            "GOOGLE_API_KEY":    "AIza-test-gemini"
        ])
        XCTAssertTrue(saved, "writeEnvKeys should return true when saving multiple keys")

        XCTAssertEqual(loader.readEnvKey("ANTHROPIC_API_KEY"), "sk-ant-test-abc")
        XCTAssertEqual(loader.readEnvKey("OPENAI_API_KEY"),    "sk-openai-test-xyz")
        XCTAssertEqual(loader.readEnvKey("GOOGLE_API_KEY"),    "AIza-test-gemini")
    }

    /// Saving a key twice should update it, not duplicate it.
    func testOverwritingKeyUpdatesValue() {
        let (loader, path) = makeLoader()
        defer { cleanup(path) }

        loader.writeEnvKeys(["OPENAI_API_KEY": "old-value"])
        loader.writeEnvKeys(["OPENAI_API_KEY": "new-value"])

        let value = loader.readEnvKey("OPENAI_API_KEY")
        XCTAssertEqual(value, "new-value", "Second save should overwrite the first value")
    }

    /// Saving one key should not erase other existing keys.
    func testSavingOneKeyPreservesOthers() {
        let (loader, path) = makeLoader()
        defer { cleanup(path) }

        loader.writeEnvKeys(["ANTHROPIC_API_KEY": "sk-ant-keep-me"])
        loader.writeEnvKeys(["OPENAI_API_KEY": "sk-openai-new"])

        XCTAssertEqual(loader.readEnvKey("ANTHROPIC_API_KEY"), "sk-ant-keep-me",
                       "Anthropic key should still be there after saving OpenAI key separately")
        XCTAssertEqual(loader.readEnvKey("OPENAI_API_KEY"), "sk-openai-new")
    }

    /// Reading a key that was never saved should return nil, not crash.
    func testReadMissingKeyReturnsNil() {
        let (loader, path) = makeLoader()
        defer { cleanup(path) }

        let value = loader.readEnvKey("GOOGLE_API_KEY")
        XCTAssertNil(value, "Reading a key that was never saved should return nil")
    }

    /// Reading from a .env file that doesn't exist yet should return nil gracefully.
    func testReadFromMissingFileReturnsNil() {
        let (loader, path) = makeLoader()
        // Deliberately do NOT create the file — just read immediately

        let value = loader.readEnvKey("ANTHROPIC_API_KEY")
        XCTAssertNil(value, "Reading from a non-existent .env file should return nil without crashing")

        cleanup(path)
    }

    /// An empty string value should be treated the same as no key (returns nil).
    func testEmptyValueTreatedAsNil() {
        let (loader, path) = makeLoader()
        defer { cleanup(path) }

        loader.writeEnvKeys(["OPENAI_API_KEY": ""])

        let value = loader.readEnvKey("OPENAI_API_KEY")
        XCTAssertNil(value, "An empty string value should be treated as if the key is not set")
    }

    /// Lines starting with # in the .env file should be ignored as comments.
    func testCommentLinesAreIgnored() {
        let (loader, path) = makeLoader()
        defer { cleanup(path) }

        let contents = "# This is a comment\nANTHROPIC_API_KEY=sk-ant-real-key\n"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)

        let value = loader.readEnvKey("ANTHROPIC_API_KEY")
        XCTAssertEqual(value, "sk-ant-real-key", "Comment lines should be ignored when reading")
    }
}
