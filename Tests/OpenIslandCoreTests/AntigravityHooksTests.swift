import Foundation
import Testing
@testable import OpenIslandCore

struct AntigravityHooksTests {
    private let binaryPath = "/opt/open-island/OpenIslandHooks"

    // Captured verbatim from a live agy 1.1.26 print-mode session (2026-09-04).
    // Keys are camelCase protojson; payloads carry no event name and no cwd.

    private let preInvocationJSON = """
    {
      "artifactDirectoryPath": "/Users/dev/.gemini/antigravity-cli/brain/05bfab3a-1885-4031-abc8-0e9282425087",
      "conversationId": "05bfab3a-1885-4031-abc8-0e9282425087",
      "initialNumSteps": 1,
      "invocationNum": 0,
      "modelName": "gemini-pro-agent",
      "transcriptPath": "/Users/dev/.gemini/antigravity-cli/brain/05bfab3a-1885-4031-abc8-0e9282425087/.system_generated/logs/transcript_full.jsonl",
      "workspacePaths": []
    }
    """

    private let postToolUseJSON = """
    {
      "artifactDirectoryPath": "/Users/dev/.gemini/antigravity-cli/brain/394fd1a6-7a91-4cae-8c58-0405fc1470bb",
      "conversationId": "394fd1a6-7a91-4cae-8c58-0405fc1470bb",
      "error": "",
      "modelName": "gemini-pro-agent",
      "stepIdx": 2,
      "toolCall": {
        "args": {
          "CommandLine": "echo probe3-ok",
          "Cwd": "/Users/dev/.gemini/antigravity-cli/brain/394fd1a6-7a91-4cae-8c58-0405fc1470bb/scratch",
          "WaitMsBeforeAsync": 10000,
          "toolAction": "Running echo command",
          "toolSummary": "Echo probe3-ok"
        },
        "name": "run_command"
      },
      "transcriptPath": "/Users/dev/.gemini/antigravity-cli/brain/394fd1a6-7a91-4cae-8c58-0405fc1470bb/.system_generated/logs/transcript_full.jsonl",
      "workspacePaths": []
    }
    """

    private let stopJSON = """
    {
      "artifactDirectoryPath": "/Users/dev/.gemini/antigravity-cli/brain/394fd1a6-7a91-4cae-8c58-0405fc1470bb",
      "conversationId": "394fd1a6-7a91-4cae-8c58-0405fc1470bb",
      "error": "",
      "executionNum": 0,
      "fullyIdle": true,
      "modelName": "gemini-pro-agent",
      "terminationReason": "NO_TOOL_CALL",
      "transcriptPath": "/Users/dev/.gemini/antigravity-cli/brain/394fd1a6-7a91-4cae-8c58-0405fc1470bb/.system_generated/logs/transcript_full.jsonl",
      "workspacePaths": []
    }
    """

    // MARK: - Payload decoding

    @Test
    func preInvocationPayloadFromCapturedAgyStdinDecodes() throws {
        let payload = try JSONDecoder().decode(AntigravityHookPayload.self, from: Data(preInvocationJSON.utf8))

        #expect(payload.conversationId == "05bfab3a-1885-4031-abc8-0e9282425087")
        #expect(payload.invocationNum == 0)
        #expect(payload.initialNumSteps == 1)
        #expect(payload.modelName == "gemini-pro-agent")
        #expect(payload.workspacePaths == [])
        // The event travels via the CLI's --event argument, not the payload.
        #expect(payload.hookEventName == nil)
        #expect(payload.toolErrorText == nil)
    }

    @Test
    func postToolUsePayloadDecodesToolCallAndTreatsEmptyErrorAsSuccess() throws {
        let payload = try JSONDecoder().decode(AntigravityHookPayload.self, from: Data(postToolUseJSON.utf8))

        #expect(payload.stepIdx == 2)
        #expect(payload.toolCall?.name == "run_command")
        #expect(payload.toolCall?.toolSummary == "Echo probe3-ok")
        #expect(payload.toolCall?.commandLine == "echo probe3-ok")
        // agy reports success as an empty error string.
        #expect(payload.toolErrorText == nil)
    }

    @Test
    func stopPayloadDecodesTerminationMetadata() throws {
        let payload = try JSONDecoder().decode(AntigravityHookPayload.self, from: Data(stopJSON.utf8))

        #expect(payload.executionNum == 0)
        #expect(payload.fullyIdle == true)
        #expect(payload.terminationReason == "NO_TOOL_CALL")
    }

    @Test
    func implicitSummariesFollowEventKind() throws {
        var payload = try JSONDecoder().decode(AntigravityHookPayload.self, from: Data(preInvocationJSON.utf8))
        payload.workingDirectory = "/Users/dev/Projects/api-server"

        payload.hookEventName = .preInvocation
        #expect(payload.implicitSummary == "Antigravity CLI started a new turn in api-server.")

        payload.hookEventName = .stop
        #expect(payload.implicitSummary == "Antigravity CLI completed a turn in api-server.")

        let toolPayload = try JSONDecoder().decode(AntigravityHookPayload.self, from: Data(postToolUseJSON.utf8))
        var running = toolPayload
        running.hookEventName = .preToolUse
        #expect(running.implicitSummary == "Antigravity run_command: Echo probe3-ok.")

        var failed = toolPayload
        failed.hookEventName = .postToolUse
        failed.error = "exit status 1"
        #expect(failed.implicitSummary == "Antigravity run_command failed: exit status 1.")
    }

    @Test
    func workspaceResolutionPrefersWorkspacePathsThenParentCWD() throws {
        var payload = try JSONDecoder().decode(AntigravityHookPayload.self, from: Data(preInvocationJSON.utf8))

        payload.workingDirectory = "/from-parent-cwd"
        #expect(payload.resolvedWorkingDirectory == "/from-parent-cwd")
        #expect(payload.workspaceName == "from-parent-cwd")

        payload.workspacePaths = ["/Users/dev/Projects/api-server"]
        #expect(payload.resolvedWorkingDirectory == "/Users/dev/Projects/api-server")
        #expect(payload.workspaceName == "api-server")

        payload.workspacePaths = []
        payload.workingDirectory = nil
        #expect(payload.resolvedWorkingDirectory == nil)
        #expect(payload.workspaceName == "Antigravity")
    }

    @Test
    func runtimeContextInfersTerminalAndParentWorkspace() throws {
        var payload = try JSONDecoder().decode(AntigravityHookPayload.self, from: Data(preInvocationJSON.utf8))
        payload.hookEventName = .preInvocation

        payload = payload.withRuntimeContext(
            environment: ["WARP_IS_LOCAL_SHELL_SESSION": "1"],
            currentTTYProvider: { "/dev/ttys001" },
            terminalLocatorProvider: { _ in (nil, nil, nil) },
            parentWorkingDirectoryProvider: { "/Users/dev/Projects/api-server" }
        )

        #expect(payload.terminalApp == "Warp")
        #expect(payload.terminalTTY == "/dev/ttys001")
        #expect(payload.workingDirectory == "/Users/dev/Projects/api-server")

        let jumpTarget = payload.defaultJumpTarget
        #expect(jumpTarget.terminalApp == "Warp")
        #expect(jumpTarget.workingDirectory == "/Users/dev/Projects/api-server")
        #expect(jumpTarget.workspaceName == "api-server")
    }

    // MARK: - Installer

    private func decodedRoot(_ data: Data?) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try #require(data))
        return try #require(object as? [String: Any])
    }

    private func managedGroup(in root: [String: Any]) throws -> [String: Any] {
        try #require(root[AntigravityHookInstaller.managedGroupName] as? [String: Any])
    }

    private func flatHandlers(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private func groupedHandlers(_ value: Any?) -> [[String: Any]] {
        let groups = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    @Test
    func installIntoEmptyConfigWritesManagedGroupWithLifecycleEvents() throws {
        let mutation = try AntigravityHookInstaller.installConfigJSON(existingData: nil, binaryPath: binaryPath)

        #expect(mutation.changed)
        #expect(mutation.managedHooksPresent)
        #expect(mutation.enabledBefore == nil)

        let group = try managedGroup(in: try decodedRoot(mutation.contents))
        #expect(group["enabled"] as? Bool == true)

        let preInvocation = flatHandlers(group["PreInvocation"])
        #expect(preInvocation.count == 1)
        #expect(preInvocation[0]["type"] as? String == "command")
        #expect(preInvocation[0]["timeout"] as? Int == AntigravityHookInstaller.managedTimeoutSeconds)
        #expect(preInvocation[0]["command"] as? String == "'\(binaryPath)' --source antigravity --event PreInvocation")

        // Tool events are grouped behind a matcher; lifecycle events are flat.
        let preToolUseGroups = (group["PreToolUse"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        #expect(preToolUseGroups.first?["matcher"] as? String == "*")
        #expect(groupedHandlers(group["PreToolUse"]).count == 1)
        #expect(groupedHandlers(group["PostToolUse"]).count == 1)
        #expect(flatHandlers(group["Stop"]).count == 1)

        // Low-noise footprint: PostInvocation is not installed.
        #expect(group["PostInvocation"] == nil)
    }

    @Test
    func installPreservesUnrelatedGroupsAndUserHandlers() throws {
        let existing = Data("""
        {
          "my-linter": {
            "PostToolUse": [
              { "matcher": "run_command", "hooks": [ { "type": "command", "command": "./lint.sh" } ] }
            ]
          },
          "open-island": {
            "PostInvocation": [
              { "type": "command", "command": "/usr/bin/notify.sh" }
            ],
            "Stop": [
              { "type": "command", "command": "/opt/old/OpenIslandHooks --source antigravity --event Stop" }
            ]
          }
        }
        """.utf8)

        let mutation = try AntigravityHookInstaller.installConfigJSON(existingData: existing, binaryPath: binaryPath)
        let root = try decodedRoot(mutation.contents)

        // Unrelated group survives untouched.
        let linter = try #require(root["my-linter"] as? [String: Any])
        #expect(groupedHandlers(linter["PostToolUse"]).first?["command"] as? String == "./lint.sh")

        let group = try managedGroup(in: root)

        // A user's own handler under a non-managed event key survives.
        #expect(flatHandlers(group["PostInvocation"]).first?["command"] as? String == "/usr/bin/notify.sh")

        // A stale managed entry (older binary path) is replaced, not duplicated.
        #expect(flatHandlers(group["Stop"]).count == 1)
        #expect(flatHandlers(group["Stop"]).first?["command"] as? String == "'\(binaryPath)' --source antigravity --event Stop")

        #expect(AntigravityHookInstaller.containsCompleteManagedHooks(existingData: mutation.contents, binaryPath: binaryPath))
    }

    @Test
    func uninstallRemovesManagedEntriesAndDropsEmptyGroup() throws {
        let installed = try AntigravityHookInstaller.installConfigJSON(existingData: nil, binaryPath: binaryPath)

        let cleaned = try AntigravityHookInstaller.uninstallConfigJSON(
            existingData: installed.contents,
            managedBinaryPath: binaryPath
        )

        // `managedHooksPresent` on an uninstall mutation reports that managed
        // entries were found in the input (and removed), matching ZCode.
        #expect(cleaned.managedHooksPresent)
        #expect(cleaned.contents == nil)
    }

    @Test
    func uninstallKeepsUnrelatedContentAndUserHandlersInManagedEvents() throws {
        let existing = Data("""
        {
          "my-linter": {
            "PreToolUse": [
              { "matcher": "write_to_file", "hooks": [ { "type": "command", "command": "./guard.sh" } ] }
            ]
          },
          "open-island": {
            "PreToolUse": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "'/opt/open-island/OpenIslandHooks' --source antigravity --event PreToolUse" } ] },
              { "matcher": "run_command", "hooks": [ { "type": "command", "command": "./mine.sh" } ] }
            ],
            "Stop": [
              { "type": "command", "command": "'/opt/open-island/OpenIslandHooks' --source antigravity --event Stop" }
            ]
          }
        }
        """.utf8)

        let mutation = try AntigravityHookInstaller.uninstallConfigJSON(
            existingData: existing,
            managedBinaryPath: binaryPath
        )

        #expect(mutation.managedHooksPresent)
        let root = try decodedRoot(mutation.contents)

        let linter = try #require(root["my-linter"] as? [String: Any])
        #expect(groupedHandlers(linter["PreToolUse"]).first?["command"] as? String == "./guard.sh")

        // The group keeps the user's mixed-in handler and loses only ours.
        let group = try managedGroup(in: root)
        let preToolUseGroups = (group["PreToolUse"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        #expect(groupedHandlers(group["PreToolUse"]).map { $0["command"] as? String } == ["./mine.sh"])
        #expect(preToolUseGroups.first?["matcher"] as? String == "run_command")
        #expect(group["Stop"] == nil)
    }

    @Test
    func completenessDetectionFlagsPartialInstalls() throws {
        let installed = try AntigravityHookInstaller.installConfigJSON(existingData: nil, binaryPath: binaryPath)
        #expect(AntigravityHookInstaller.containsCompleteManagedHooks(existingData: installed.contents, binaryPath: binaryPath))

        var root = try decodedRoot(installed.contents)
        var group = try managedGroup(in: root)
        group.removeValue(forKey: "Stop")
        root[AntigravityHookInstaller.managedGroupName] = group
        let partial = try JSONSerialization.data(withJSONObject: root)

        #expect(!AntigravityHookInstaller.containsCompleteManagedHooks(existingData: partial, binaryPath: binaryPath))
    }

    // MARK: - Manager roundtrip

    @Test
    func managerInstallStatusUninstallRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-hooks-\(UUID().uuidString)", isDirectory: true)
        let binarySource = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-binary-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: binarySource)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binarySource.path)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: binarySource)
        }

        let manager = AntigravityHookInstallationManager(
            configDirectory: directory,
            managedHooksBinaryURL: directory.appendingPathComponent("OpenIslandHooks")
        )

        let before = try manager.status(hooksBinaryURL: binarySource)
        #expect(!before.managedHooksPresent)

        let installed = try manager.install(hooksBinaryURL: binarySource)
        #expect(installed.completeManagedHooksPresent)
        #expect(FileManager.default.fileExists(atPath: installed.manifestURL.path))

        // The config file materialized at ~/.gemini/config/hooks.json's local twin.
        let configData = try Data(contentsOf: installed.configURL)
        #expect(try JSONSerialization.jsonObject(with: configData) is [String: Any])

        let afterUninstall = try manager.uninstall()
        #expect(!afterUninstall.managedHooksPresent)
        // Only Open Island content ever lived here, so the file is removed.
        #expect(!FileManager.default.fileExists(atPath: installed.configURL.path))
        #expect(!FileManager.default.fileExists(atPath: installed.manifestURL.path))
    }

    // MARK: - Bridge wire format

    @Test
    func bridgeCommandRoundTripsAntigravityHookPayload() throws {
        var payload = try JSONDecoder().decode(AntigravityHookPayload.self, from: Data(postToolUseJSON.utf8))
        payload.hookEventName = .preToolUse
        payload.terminalApp = "Warp"
        payload.workingDirectory = "/Users/dev/Projects/api-server"

        let command = BridgeCommand.processAntigravityHook(payload)
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(BridgeCommand.self, from: encoded)

        #expect(decoded == command)

        guard case let .processAntigravityHook(decodedPayload) = decoded else {
            Issue.record("expected processAntigravityHook")
            return
        }
        #expect(decodedPayload.hookEventName == .preToolUse)
        #expect(decodedPayload.workingDirectory == "/Users/dev/Projects/api-server")
    }
}
