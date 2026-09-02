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

    /// Presented to the user (one workspace at a time). Rendered by the app
    /// layer as a confirmation dialog; cleared by ``answerPrompt(_:)``.
    var pendingPrompt: WorkspacePrompt?

    /// The managed hooks binary the workspace configs should point at.
    /// Mirrors `HookInstallationCoordinator.hooksBinaryURL` and is set
    /// during app wiring.
    var hooksBinaryURL: URL?

    @ObservationIgnored
    private let store: ZCodeWorkspaceManagedWritesStore
    @ObservationIgnored
    private let controller: ZCodeWorkspaceHooksController
    @ObservationIgnored
    private var surfacedPromptRoots: Set<String> = []

    init(store: ZCodeWorkspaceManagedWritesStore = ZCodeWorkspaceManagedWritesStore(storeURL: ZCodeWorkspaceManagedWritesStore.defaultURL())) {
        self.store = store
        self.controller = ZCodeWorkspaceHooksController(store: store)
    }

    /// Called from process monitoring with the working directory of every
    /// running ZCode session process.
    func observeZcodeProcessWorkingDirectories(_ workingDirectories: Set<String>, hooksBinaryURL: URL?) {
        guard let hooksBinaryURL, !workingDirectories.isEmpty else {
            return
        }
        let hookCommand = ZCodeHookInstaller.processCommand(for: hooksBinaryURL.path)
        let store = self.store
        let controller = self.controller

        Task { [weak self] in
            guard let self else { return }

            var plan = await Task.detached(priority: .utility) {
                controller.reconcile(observedWorkspaceCWDs: workingDirectories, hookCommand: hookCommand)
            }.value

            // Managed roots are verified against disk every pass: a deleted
            // or user-edited config (or a moved hook binary) drifts from the
            // registry and triggers a rewrite — which also invalidates the
            // ZCode trust digest, so the guide reappears.
            for root in plan.managedRoots where store.decision(forRoot: root.path) == .enabled {
                let status = await Task.detached(priority: .utility) {
                    ZCodeWorkspaceConfigWriter.status(workspaceRoot: root, hookCommand: hookCommand)
                }.value
                if status != .current {
                    controller.markNeedsRepair(workspaceRoot: root)
                    plan.installRoots.append(root)
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
            guard let hooksBinaryURL else {
                return
            }
            let hookCommand = ZCodeHookInstaller.processCommand(for: hooksBinaryURL.path)
            Task { [weak self] in
                await self?.performInstalls(roots: [prompt.workspaceRoot], hookCommand: hookCommand)
            }
        } else {
            controller.decline(workspaceRoot: prompt.workspaceRoot)
            onStatusMessage?("Skipped workspace monitoring for \(prompt.workspaceName). Ask again after restarting Open Island.")
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
            let outcome = await Task.detached(priority: .utility) {
                try? ZCodeWorkspaceConfigWriter.install(workspaceRoot: root, hookCommand: hookCommand)
            }.value

            self.store.record(entry: ZCodeWorkspaceManagedWriteEntry(
                rootPath: root.path,
                hookCommand: hookCommand,
                excludeAdded: true
            ))
            self.controller.markInstalled(workspaceRoot: root)
            self.onTrustGuideNeeded?(root)
            let verb = outcome == .installed ? "Enabled" : "Verified"
            self.onStatusMessage?("\(verb) ZCode workspace monitoring for \(root.lastPathComponent).")
        }
    }
}
