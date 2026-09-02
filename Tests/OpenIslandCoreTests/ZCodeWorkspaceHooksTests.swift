import Foundation
import Testing
@testable import OpenIslandCore

struct ZCodeWorkspaceHooksTests {
    // MARK: - Workspace root resolution

    @Test
    func workspaceRootResolvesToGitAncestor() throws {
        let root = try temporaryDirectory()
        let nested = root.appendingPathComponent("packages/app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)

        let resolved = ZCodeWorkspaceRootResolver.workspaceRoot(forCWD: nested)
        #expect(resolved.standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test
    func workspaceRootAcceptsGitFileForWorktrees() throws {
        let root = try temporaryDirectory()
        let nested = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "gitdir: /elsewhere/main/.git/worktrees/topic".write(
            toFile: root.appendingPathComponent(".git").path,
            atomically: true,
            encoding: .utf8
        )

        let resolved = ZCodeWorkspaceRootResolver.workspaceRoot(forCWD: nested)
        #expect(resolved.standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test
    func workspaceRootFallsBackToCWDWithoutGit() throws {
        let dir = try temporaryDirectory()

        let resolved = ZCodeWorkspaceRootResolver.workspaceRoot(forCWD: dir)
        #expect(resolved.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    // MARK: - Config writer

    @Test
    func installWritesConfigAndGitExclude() throws {
        let root = try workspaceWithGit()
        let hookCommand = "/opt/hooks/OpenIslandHooks"

        let outcome = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: hookCommand)

        #expect(outcome == .installed)
        let configData = try Data(contentsOf: root.appendingPathComponent("zcode.json"))
        #expect(try ZCodeHookInstaller.containsCurrentFormatHooks(existingData: configData, hookCommand: hookCommand))
        let exclude = try String(contentsOf: gitInfoExclude(root: root), encoding: .utf8)
        #expect(exclude.contains("zcode.json"))
    }

    @Test
    func reinstallWithCurrentFormatLeavesFileUntouched() throws {
        let root = try workspaceWithGit()
        let hookCommand = "/opt/hooks/OpenIslandHooks"
        _ = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: hookCommand)
        let before = try Data(contentsOf: root.appendingPathComponent("zcode.json"))

        let outcome = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: hookCommand)

        // Trust digests key on the file contents; an unchanged install must
        // not rewrite (and thereby invalidate) the trusted declaration.
        #expect(outcome == .alreadyCurrent)
        let after = try Data(contentsOf: root.appendingPathComponent("zcode.json"))
        #expect(before == after)
    }

    @Test
    func installWithoutGitDirectorySkipsExclude() throws {
        let root = try temporaryDirectory()

        _ = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: "/opt/hooks/OpenIslandHooks")

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("zcode.json").path))
    }

    @Test
    func statusDetectsTamperedConfigAsStale() throws {
        let root = try workspaceWithGit()
        let hookCommand = "/opt/hooks/OpenIslandHooks"
        _ = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: hookCommand)

        // A different (user-modified or stale) command makes the managed
        // entries no longer current-format for this binary.
        let otherCommand = ZCodeHookInstaller.processCommand(for: "/opt/hooks/OpenIslandHooks-old")
        let tampered = try ZCodeHookInstaller.installConfigJSON(
            existingData: try Data(contentsOf: root.appendingPathComponent("zcode.json")),
            hookCommand: otherCommand
        )
        try FileManager.default.removeItem(at: root.appendingPathComponent("zcode.json"))
        try tampered.contents!.write(to: root.appendingPathComponent("zcode.json"))

        #expect(ZCodeWorkspaceConfigWriter.status(workspaceRoot: root, hookCommand: hookCommand) == .stale)
    }

    @Test
    func uninstallRemovesHooksAndManagedExcludeLines() throws {
        let root = try workspaceWithGit()
        let hookCommand = "/opt/hooks/OpenIslandHooks"
        try "user-ignored-file\n".write(toFile: gitInfoExclude(root: root).path, atomically: true, encoding: .utf8)
        _ = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: hookCommand)

        let outcome = try ZCodeWorkspaceConfigWriter.uninstall(workspaceRoot: root)

        #expect(outcome == .uninstalled)
        // The workspace config held only managed hooks → the file is removed.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("zcode.json").path))
        let exclude = try String(contentsOf: gitInfoExclude(root: root), encoding: .utf8)
        #expect(!exclude.contains("zcode.json"))
        #expect(exclude.contains("user-ignored-file"))
    }

    @Test
    func uninstallKeepsForeignWorkspaceConfig() throws {
        let root = try workspaceWithGit()
        let foreign = """
        { "hooks": { "enabled": true, "events": { "SessionStart": [ { "hooks": [ { "type": "process", "command": "/usr/local/bin/notify-me" } ] } ] } } }
        """
        try foreign.data(using: .utf8)!.write(to: root.appendingPathComponent("zcode.json"))

        _ = try ZCodeWorkspaceConfigWriter.uninstall(workspaceRoot: root)

        let remaining = try String(contentsOf: root.appendingPathComponent("zcode.json"), encoding: .utf8)
        #expect(remaining.contains("notify-me"))
    }

    // MARK: - Managed writes store

    @Test
    func storeRoundTripsDecisionsAndEntries() throws {
        let url = try temporaryDirectory().appendingPathComponent("store.json")
        let store = ZCodeWorkspaceManagedWritesStore(storeURL: url)
        let root = "/tmp/demo-workspace"

        store.setDecision(.enabled, forRoot: root)
        store.record(entry: ZCodeWorkspaceManagedWriteEntry(
            rootPath: root,
            hookCommand: "/opt/hooks/OpenIslandHooks",
            excludeAdded: true
        ))

        let reloaded = ZCodeWorkspaceManagedWritesStore(storeURL: url)
        #expect(reloaded.decision(forRoot: root) == .enabled)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.excludeAdded == true)
    }

    // MARK: - Controller state machine

    @Test
    func controllerPromptsForUnknownRootOnceAndInstallsAfterConfirmation() throws {
        let controller = ZCodeWorkspaceHooksController(store: inMemoryStore())
        let cwd = try workspaceWithGit()
        let hookCommand = "/opt/hooks/OpenIslandHooks"

        let first = controller.reconcile(observedWorkspaceCWDs: [cwd.path], hookCommand: hookCommand)
        #expect(first.pendingConfirmationRoots.map(\.lastPathComponent) == [cwd.lastPathComponent])
        #expect(first.installRoots.isEmpty)

        controller.confirm(workspaceRoot: cwd)
        let second = controller.reconcile(observedWorkspaceCWDs: [cwd.path], hookCommand: hookCommand)
        #expect(second.pendingConfirmationRoots.isEmpty)
        #expect(second.installRoots.count == 1)
        // Once the app reports the install done, the root is managed and
        // later reconciles neither prompt nor re-install.
        controller.markInstalled(workspaceRoot: cwd)
        let third = controller.reconcile(observedWorkspaceCWDs: [cwd.path], hookCommand: hookCommand)
        #expect(third.pendingConfirmationRoots.isEmpty)
        #expect(third.installRoots.isEmpty)
        #expect(third.managedRoots.count == 1)
    }

    @Test
    func controllerOffersDeclinedRootAgainForNextLaunch() throws {
        // "Not Now" only suppresses for the current run (coordinator-side
        // surfaced set); the controller clears the decision so the workspace
        // is re-offered after a restart.
        let store = inMemoryStore()
        let controller = ZCodeWorkspaceHooksController(store: store)
        let cwd = try workspaceWithGit()
        let hookCommand = "/opt/hooks/OpenIslandHooks"

        let first = controller.reconcile(observedWorkspaceCWDs: [cwd.path], hookCommand: hookCommand)
        #expect(first.pendingConfirmationRoots.count == 1)
        controller.decline(workspaceRoot: cwd)
        #expect(store.decision(forRoot: cwd.standardizedFileURL.path) == nil)

        // A fresh run (new controller, same persisted store) re-offers.
        let relaunched = ZCodeWorkspaceHooksController(store: store)
        let second = relaunched.reconcile(observedWorkspaceCWDs: [cwd.path], hookCommand: hookCommand)
        #expect(second.pendingConfirmationRoots.count == 1)
    }

    @Test
    func controllerCollapsesNestedSessionsIntoOneRoot() throws {
        let controller = ZCodeWorkspaceHooksController(store: inMemoryStore())
        let root = try workspaceWithGit()
        let nested = root.appendingPathComponent("packages/app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        controller.confirm(workspaceRoot: root)

        let plan = controller.reconcile(
            observedWorkspaceCWDs: [root.path, nested.path],
            hookCommand: "/opt/hooks/OpenIslandHooks"
        )

        #expect(plan.installRoots.count == 1)
    }

    @Test
    func controllerFlagsManagedRootAsStaleForReinstall() throws {
        let controller = ZCodeWorkspaceHooksController(store: inMemoryStore())
        let cwd = try workspaceWithGit()
        let hookCommand = "/opt/hooks/OpenIslandHooks"
        controller.confirm(workspaceRoot: cwd)
        controller.markInstalled(workspaceRoot: cwd)

        // Staleness is detected from disk by the coordinator; the controller
        // only re-offers a managed root once told it needs repair.
        controller.markNeedsRepair(workspaceRoot: cwd)
        let plan = controller.reconcile(observedWorkspaceCWDs: [cwd.path], hookCommand: hookCommand)
        #expect(plan.installRoots.count == 1)
    }

    @Test
    func assessDistinguishesBinaryDriftFromUserEdits() throws {
        let root = try workspaceWithGit()
        let hookCommand = "/opt/hooks/OpenIslandHooks"
        _ = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: hookCommand)

        // Missing file → rewrite is safe (nothing trusted is lost).
        try FileManager.default.removeItem(at: root.appendingPathComponent("zcode.json"))
        #expect(ZCodeWorkspaceConfigWriter.assess(workspaceRoot: root, hookCommand: hookCommand) == .absent)

        // Drifted managed command (binary moved) → rewrite migrates + re-trust.
        _ = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: "/opt/hooks/OpenIslandHooks-moved")
        #expect(ZCodeWorkspaceConfigWriter.assess(workspaceRoot: root, hookCommand: hookCommand) == .needsRewrite)

        // User-owned config with no managed entries → hands off.
        let foreign = try workspaceWithGit()
        let foreignJSON = """
        { "hooks": { "enabled": true, "events": { "SessionStart": [ { "hooks": [ { "type": "process", "command": "/usr/local/bin/notify-me" } ] } ] } } }
        """
        try foreignJSON.data(using: .utf8)!.write(to: foreign.appendingPathComponent("zcode.json"))
        #expect(ZCodeWorkspaceConfigWriter.assess(workspaceRoot: foreign, hookCommand: hookCommand) == .userModified)

        // Current install → untouched.
        _ = try ZCodeWorkspaceConfigWriter.install(workspaceRoot: foreign, hookCommand: hookCommand)
        #expect(ZCodeWorkspaceConfigWriter.assess(workspaceRoot: foreign, hookCommand: hookCommand) == .current)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func workspaceWithGit() throws -> URL {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/info", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: gitInfoExclude(root: root).path, contents: nil)
        return root
    }

    private func gitInfoExclude(root: URL) -> URL {
        root.appendingPathComponent(".git/info/exclude")
    }

    private func inMemoryStore() -> ZCodeWorkspaceManagedWritesStore {
        ZCodeWorkspaceManagedWritesStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-ws-\(UUID().uuidString).json"))
    }
}
