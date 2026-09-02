import Foundation
import Observation
import OpenIslandCore

/// Drives ZCode workspace hooks (see `docs/adr/0001`): watch ZCode session
/// processes, offer a one-time confirmation per workspace, write the managed
/// `zcode.json` + git exclude at the workspace root, and guide the user
/// through ZCode's in-app trust review. All filesystem work runs off the
/// main actor; decisions persist in the managed writes registry so disable
/// and uninstall can remove every managed write wholesale.
@MainActor
@Observable
final class ZCodeWorkspaceHooksCoordinator {
    struct WorkspacePrompt: Equatable, Identifiable {
        let workspaceRoot: URL

        var id: String { workspaceRoot.path }
        var workspaceName: String { workspaceRoot.lastPathComponent }
    }

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    /// Fires after a workspace config is written or repaired. ZCode requires
    /// a one-time in-app trust per workspace, and the review prompt does not
    /// reliably reappear on its own — the guide must always point at
    /// Settings → Hooks → Workspace.
    @ObservationIgnored
    var onTrustGuideNeeded: ((_ workspaceRoot: URL) -> Void)?

    /// Fires once per workspace when a first-time confirmation prompt
    /// becomes available. The app layer renders it; the answer comes back
    /// via ``answerPrompt(_:)``.
    @ObservationIgnored
    var onPromptAvailable: ((_ prompt: WorkspacePrompt) -> Void)?

    /// Presented to the user (one workspace at a time). Cleared by
    /// ``answerPrompt(_:)``.
    var pendingPrompt: WorkspacePrompt?

    /// Managed-command (`processCommand(for:)`) from the latest observation
    /// pass; kept so ``answerPrompt(_:)`` can install immediately.
    @ObservationIgnored
    private var lastHookCommand: String?

    @ObservationIgnored
    private let store: ZCodeWorkspaceManagedWritesStore
    @ObservationIgnored
    private let controller: ZCodeWorkspaceHooksController
    /// Roots already surfaced this run — suppression for "Not Now".
    @ObservationIgnored
    private var surfacedPromptRoots: Set<String> = []

    init(store: ZCodeWorkspaceManagedWritesStore = ZCodeWorkspaceManagedWritesStore(storeURL: ZCodeWorkspaceManagedWritesStore.defaultURL())) {
        self.store = store
        self.controller = ZCodeWorkspaceHooksController(store: store)
    }

    /// The trust guidance shown after every write or repair. Centralized so
    /// the confirmation dialog and the status line cannot drift apart.
    static func trustGuideText(workspaceName: String) -> String {
        "Approve it once in ZCode under Settings → Hooks → Workspace (\(workspaceName))."
    }

    /// Called from process monitoring with the working directory of every
    /// running ZCode session process.
    func observeZcodeProcessWorkingDirectories(_ workingDirectories: Set<String>, hooksBinaryURL: URL?) {
        guard let hooksBinaryURL, !workingDirectories.isEmpty else {
            return
        }
        let hookCommand = ZCodeHookInstaller.processCommand(for: hooksBinaryURL.path)
        lastHookCommand = hookCommand
        let store = self.store
        let controller = self.controller

        Task { [weak self] in
            guard let self else { return }

            var plan = await Task.detached(priority: .utility) {
                controller.reconcile(observedWorkspaceCWDs: workingDirectories, hookCommand: hookCommand)
            }.value

            // Managed roots are assessed against disk every pass, but only
            // a drifted managed command (binary moved) or a missing file
            // rewrites — any rewrite invalidates ZCode's trust digest, so
            // user-edited configs are left untouched (ADR 0001).
            for root in plan.managedRoots where store.decision(forRoot: root.path) == .enabled {
                let assessment = await Task.detached(priority: .utility) {
                    ZCodeWorkspaceConfigWriter.assess(workspaceRoot: root, hookCommand: hookCommand)
                }.value
                switch assessment {
                case .absent, .needsRewrite:
                    controller.markNeedsRepair(workspaceRoot: root)
                    plan.installRoots.append(root)
                case .current, .userModified:
                    continue
                }
            }

            for root in plan.pendingConfirmationRoots where self.pendingPrompt == nil {
                let key = root.path
                guard !self.surfacedPromptRoots.contains(key) else {
                    continue
                }
                self.surfacedPromptRoots.insert(key)
                let prompt = WorkspacePrompt(workspaceRoot: root)
                self.pendingPrompt = prompt
                self.onPromptAvailable?(prompt)
            }

            await self.performInstalls(roots: plan.installRoots, hookCommand: hookCommand)
        }
    }

    /// Answers the active first-time confirmation prompt. Confirming writes
    /// the managed config immediately and fires the trust guide.
    func answerPrompt(_ confirmed: Bool) {
        guard let prompt = pendingPrompt else {
            return
        }
        pendingPrompt = nil

        if confirmed {
            controller.confirm(workspaceRoot: prompt.workspaceRoot)
            guard let hookCommand = lastHookCommand else {
                return
            }
            Task { [weak self] in
                await self?.performInstalls(roots: [prompt.workspaceRoot], hookCommand: hookCommand)
            }
        } else {
            controller.decline(workspaceRoot: prompt.workspaceRoot)
            surfacedPromptRoots.insert(prompt.workspaceRoot.path)
            onStatusMessage?("Skipped ZCode workspace monitoring for \(prompt.workspaceName). It will be offered again next launch.")
        }
    }

    /// Removes every managed workspace config and exclude line recorded in
    /// the registry. Invoked when the user disables ZCode support; leftover
    /// trust grants inside ZCode are inert without the config file.
    func uninstallAllManagedWrites() {
        let entries = store.entries
        guard !entries.isEmpty else {
            return
        }

        Task { [weak self] in
            for entry in entries {
                let root = URL(fileURLWithPath: entry.rootPath)
                _ = await Task.detached(priority: .utility) {
                    try? ZCodeWorkspaceConfigWriter.uninstall(workspaceRoot: root)
                }.value
                self?.store.removeEntry(forRoot: entry.rootPath)
            }
            self?.onStatusMessage?("Removed Open Island workspace configs from \(entries.count) workspace(s).")
        }
    }

    // MARK: - Private

    private func performInstalls(roots: [URL], hookCommand: String) async {
        guard !roots.isEmpty else {
            return
        }

        for root in roots {
            // `nil` means the install threw (permissions, invalid JSON in a
            // user-owned file): leave the root unrecorded so the next pass
            // retries instead of silently claiming success.
            let installOutcome = await Task.detached(priority: .utility) {
                try? ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: hookCommand)
            }.value
            guard let outcome = installOutcome else {
                onStatusMessage?("Could not write the ZCode workspace config for \(root.lastPathComponent).")
                continue
            }

            let hasGitDirectory = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".git").path
            )
            store.record(entry: ZCodeWorkspaceManagedWriteEntry(
                rootPath: root.path,
                hookCommand: hookCommand,
                excludeAdded: hasGitDirectory
            ))
            controller.markInstalled(workspaceRoot: root)
            onTrustGuideNeeded?(root)
            let verb = outcome == .installed ? "Enabled" : "Verified"
            onStatusMessage?("\(verb) ZCode workspace monitoring for \(root.lastPathComponent).")
        }
    }
}
