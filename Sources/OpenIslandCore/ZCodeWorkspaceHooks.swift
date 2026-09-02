import Foundation

// ZCode workspace hooks: managed writes of a project-level `zcode.json` so
// ZCode.app sessions (which never load user-config hooks) can report to the
// island through ZCode's own workspace mechanism — a one-time in-app trust
// per workspace. The design contract lives in `docs/adr/0001`:
//
// - The managed file sits at the workspace root (first `.git` ancestor of
//   the session's working directory, mirroring ZCode's config discovery),
//   named `zcode.json` — deliberately not `.zcode/config.json`, which is
//   ZCode.app's own editable target.
// - Once trusted, the file must not be rewritten: ZCode keys trust on a
//   digest covering command text, args, timeouts, and position indexes, so
//   any byte change invalidates the grant. We rewrite only when the managed
//   command drifted (binary moved), and the coordinator then re-surfaces the
//   trust guide.
// - The file is git-excluded via `.git/info/exclude` (local, never shared)
//   because the hook command embeds a machine-specific absolute path.

// MARK: - Workspace root

/// Resolves the directory a managed workspace config belongs to, using the
/// same traversal rule as ZCode's config discovery: walk from the session's
/// working directory up to the first ancestor containing `.git` (directory
/// or file, so worktrees resolve like repos), falling back to the working
/// directory itself.
public enum ZCodeWorkspaceRootResolver {
    public static func workspaceRoot(forCWD cwd: URL) -> URL {
        let standardized = cwd.standardizedFileURL
        var current = standardized
        while true {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return standardized
            }
            current = parent
        }
    }
}

// MARK: - Git exclude management

enum ZCodeWorkspaceGitExclude {
    static let managedMarker = "# open-island-zcode"

    /// Resolves the `.git/info/exclude` URL for a workspace root, following
    /// a `.git` *file* (worktree) to its `gitdir:` target. Returns `nil` for
    /// non-git directories — a plain directory write needs no exclude.
    static func excludeURL(forWorkspaceRoot root: URL, fileManager: FileManager = .default) -> URL? {
        let gitPath = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitPath.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return gitPath.appendingPathComponent("info/exclude")
        }

        guard let contents = try? String(contentsOf: gitPath, encoding: .utf8),
              let gitdirLine = contents
                  .split(whereSeparator: \.isNewline)
                  .first(where: { $0.hasPrefix("gitdir:") }),
              let gitdir = String(gitdirLine.dropFirst("gitdir:".count))
                  .trimmingCharacters(in: .whitespaces) as String?,
              !gitdir.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: gitdir).appendingPathComponent("info/exclude")
    }

    /// Appends the managed exclude block unless an equivalent line already
    /// exists. Returns whether a line was added.
    @discardableResult
    static func addManagedExcludeLine(forWorkspaceRoot root: URL, fileManager: FileManager = .default) -> Bool {
        guard let excludeURL = excludeURL(forWorkspaceRoot: root) else { return false }
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        guard !existing.split(whereSeparator: \.isNewline).contains("zcode.json") else {
            return false
        }

        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += "\(managedMarker)\nzcode.json\n"
        do {
            try FileManager.default.createDirectory(
                at: excludeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try updated.data(using: .utf8)?.write(to: excludeURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes only the managed exclude block; user lines survive.
    @discardableResult
    static func removeManagedExcludeLine(forWorkspaceRoot root: URL, fileManager: FileManager = .default) -> Bool {
        guard let excludeURL = excludeURL(forWorkspaceRoot: root),
              let existing = try? String(contentsOf: excludeURL, encoding: .utf8) else {
            return false
        }

        let listed = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var index = 0
        var removed = false
        while index < listed.count {
            if listed[index] == managedMarker, index + 1 < listed.count, listed[index + 1] == "zcode.json" {
                index += 2
                removed = true
                continue
            }
            if listed[index] == "zcode.json" {
                // Bare managed line without marker (written by earlier builds).
                index += 1
                removed = true
                continue
            }
            result.append(listed[index])
            index += 1
        }

        guard removed else { return false }
        do {
            try result.joined(separator: "\n").data(using: .utf8)?.write(to: excludeURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Config writer

/// Writes, verifies, and removes the managed workspace `zcode.json`.
public enum ZCodeWorkspaceConfigWriter {
    public static let configFileName = "zcode.json"

    public enum InstallOutcome: Equatable, Sendable {
        /// The file was created or rewritten (trust prompt will follow).
        case installed
        /// The file already holds current-format managed entries for this
        /// binary — left byte-identical so an existing trust grant survives.
        case alreadyCurrent
    }

    public enum UninstallOutcome: Equatable, Sendable {
        case uninstalled
        case notPresent
    }

    /// `.current` requires a current-format managed entry whose command
    /// matches the expected binary path *exactly* — the installer's own
    /// detection accepts any `--source zcode` hook pointing at an
    /// OpenIslandHooks binary, which would hide exactly the drift (binary
    /// moved) that must trigger a rewrite + re-trust.
    public enum Status: Equatable, Sendable {
        case current
        case stale
        case absent
    }

    @discardableResult
    public static func install(workspaceRoot: URL, hookCommand: String) throws -> InstallOutcome {
        let configURL = workspaceRoot.appendingPathComponent(configFileName)
        let existingData = try? Data(contentsOf: configURL)

        if status(existingData: existingData, hookCommand: hookCommand) == .current {
            // Trust digests survive only if we never touch the file again.
            ZCodeWorkspaceGitExclude.addManagedExcludeLine(forWorkspaceRoot: workspaceRoot)
            return .alreadyCurrent
        }

        let mutation = try ZCodeHookInstaller.installConfigJSON(existingData: existingData, hookCommand: hookCommand)
        if let contents = mutation.contents {
            try contents.write(to: configURL, options: .atomic)
        }
        ZCodeWorkspaceGitExclude.addManagedExcludeLine(forWorkspaceRoot: workspaceRoot)
        return .installed
    }

    public static func status(workspaceRoot: URL, hookCommand: String) -> Status {
        let configURL = workspaceRoot.appendingPathComponent(configFileName)
        guard let existingData = try? Data(contentsOf: configURL) else {
            return .absent
        }
        return status(existingData: existingData, hookCommand: hookCommand)
    }

    public static func status(existingData: Data?, hookCommand: String) -> Status {
        guard let existingData,
              let rootObject = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              let hooksObject = rootObject["hooks"] as? [String: Any],
              let eventsObject = hooksObject["events"] as? [String: Any] else {
            return .absent
        }

        let eventNames = ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest"]
        let allCurrent = eventNames.allSatisfy { eventName in
            let groups = eventsObject[eventName] as? [[String: Any]] ?? []
            return groups.contains { group in
                let hooks = group["hooks"] as? [[String: Any]] ?? []
                return hooks.contains { hook in
                    hook["type"] as? String == "process"
                        && hook["command"] as? String == hookCommand
                        && (hook["args"] as? [String]) == ZCodeHookInstaller.managedHookArguments
                }
            }
        }
        return allCurrent ? .current : .stale
    }

    @discardableResult
    public static func uninstall(workspaceRoot: URL) throws -> UninstallOutcome {
        let configURL = workspaceRoot.appendingPathComponent(configFileName)
        guard let existingData = try? Data(contentsOf: configURL) else {
            ZCodeWorkspaceGitExclude.removeManagedExcludeLine(forWorkspaceRoot: workspaceRoot)
            return .notPresent
        }

        let mutation = try ZCodeHookInstaller.uninstallConfigJSON(existingData: existingData, managedCommand: nil, hooksEnabledBeforeInstall: nil)
        if let contents = mutation.contents {
            try contents.write(to: configURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: configURL)
        }
        ZCodeWorkspaceGitExclude.removeManagedExcludeLine(forWorkspaceRoot: workspaceRoot)
        return .uninstalled
    }
}

// MARK: - Managed writes store

public enum ZCodeWorkspaceDecision: String, Codable, Sendable, Equatable {
    /// Observed but never surfaced to the user yet.
    case pending
    /// User confirmed (or a prior install exists): manage writes silently.
    case enabled
    /// User declined: never prompt again for this workspace.
    case disabled
}

public struct ZCodeWorkspaceManagedWriteEntry: Codable, Equatable, Sendable {
    public var rootPath: String
    public var hookCommand: String
    public var excludeAdded: Bool
    public var installedAt: Date

    public init(rootPath: String, hookCommand: String, excludeAdded: Bool, installedAt: Date = .now) {
        self.rootPath = rootPath
        self.hookCommand = hookCommand
        self.excludeAdded = excludeAdded
        self.installedAt = installedAt
    }
}

/// The managed writes registry (see `CONTEXT.md`): every workspace file and
/// exclude line Open Island wrote, plus the per-workspace confirmation
/// decisions — consumed wholesale by uninstall cleanup.
public final class ZCodeWorkspaceManagedWritesStore: @unchecked Sendable {
    private struct Document: Codable {
        var entries: [ZCodeWorkspaceManagedWriteEntry] = []
        var decisions: [String: ZCodeWorkspaceDecision] = [:]
    }

    private let lock = NSLock()
    private let storeURL: URL
    private var document: Document

    public init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode(Document.self, from: data) {
            document = decoded
        } else {
            document = Document()
        }
    }

    public static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("OpenIsland/zcode-workspace-writes.json")
    }

    public var entries: [ZCodeWorkspaceManagedWriteEntry] {
        lock.lock()
        defer { lock.unlock() }
        return document.entries
    }

    public func decision(forRoot rootPath: String) -> ZCodeWorkspaceDecision? {
        lock.lock()
        defer { lock.unlock() }
        return document.decisions[rootPath]
    }

    public func setDecision(_ decision: ZCodeWorkspaceDecision, forRoot rootPath: String) {
        lock.lock()
        document.decisions[rootPath] = decision
        let snapshot = document
        lock.unlock()
        persist(snapshot)
    }

    public func record(entry: ZCodeWorkspaceManagedWriteEntry) {
        lock.lock()
        document.entries.removeAll { $0.rootPath == entry.rootPath }
        document.entries.append(entry)
        let snapshot = document
        lock.unlock()
        persist(snapshot)
    }

    public func removeEntry(forRoot rootPath: String) {
        lock.lock()
        document.entries.removeAll { $0.rootPath == rootPath }
        document.decisions[rootPath] = nil
        let snapshot = document
        lock.unlock()
        persist(snapshot)
    }

    public func entry(forRoot rootPath: String) -> ZCodeWorkspaceManagedWriteEntry? {
        lock.lock()
        defer { lock.unlock() }
        return document.entries.first { $0.rootPath == rootPath }
    }

    private func persist(_ snapshot: Document) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - Controller

/// Pure decision layer over the store: given the ZCode session working
/// directories observed this tick, decide which workspace roots need a
/// first-time confirmation prompt and which need an install (or repair).
/// Filesystem verification is the caller's job — the coordinator runs
/// installs, then reports back via ``markInstalled(workspaceRoot:)``.
public final class ZCodeWorkspaceHooksController: @unchecked Sendable {
    public struct Plan: Equatable, Sendable {
        public var pendingConfirmationRoots: [URL]
        public var installRoots: [URL]
        public var managedRoots: [URL]

        public init(
            pendingConfirmationRoots: [URL] = [],
            installRoots: [URL] = [],
            managedRoots: [URL] = []
        ) {
            self.pendingConfirmationRoots = pendingConfirmationRoots
            self.installRoots = installRoots
            self.managedRoots = managedRoots
        }
    }

    private let lock = NSLock()
    private let store: ZCodeWorkspaceManagedWritesStore
    /// Roots known to hold a current managed config (reported by the
    /// coordinator after an install or a disk verification pass).
    private var installedRoots: Set<String> = []
    /// Managed roots whose on-disk config failed verification and must be
    /// rewritten (and re-trusted) on the next reconcile.
    private var repairRoots: Set<String> = []

    public init(store: ZCodeWorkspaceManagedWritesStore) {
        self.store = store
        // Existing registry entries are managed by definition — they were
        // written by a previous run and confirmed then.
        for entry in store.entries {
            installedRoots.insert(entry.rootPath)
        }
    }

    public func reconcile(observedWorkspaceCWDs: Set<String>, hookCommand: String) -> Plan {
        let roots = observedWorkspaceCWDs
            .map { ZCodeWorkspaceRootResolver.workspaceRoot(forCWD: URL(fileURLWithPath: $0)) }
            .reduce(into: Set<URL>()) { $0.insert($1.standardizedFileURL) }
            .sorted { $0.path < $1.path }

        var pending: [URL] = []
        var installs: [URL] = []
        var managed: [URL] = []

        lock.lock()
        let currentRepairRoots = repairRoots
        lock.unlock()

        for root in roots {
            let key = root.path
            switch store.decision(forRoot: key) {
            case .disabled:
                continue
            case .enabled:
                lock.lock()
                let isInstalled = installedRoots.contains(key)
                let needsRepair = currentRepairRoots.contains(key)
                if needsRepair {
                    repairRoots.remove(key)
                }
                lock.unlock()

                if needsRepair || !isInstalled {
                    installs.append(root)
                } else {
                    managed.append(root)
                }
            case .pending, .none:
                lock.lock()
                let alreadyInstalled = installedRoots.contains(key)
                lock.unlock()
                if alreadyInstalled {
                    managed.append(root)
                    continue
                }
                pending.append(root)
                store.setDecision(.pending, forRoot: key)
            }
        }

        return Plan(pendingConfirmationRoots: pending, installRoots: installs, managedRoots: managed)
    }

    public func confirm(workspaceRoot: URL) {
        store.setDecision(.enabled, forRoot: workspaceRoot.standardizedFileURL.path)
    }

    public func decline(workspaceRoot: URL) {
        store.setDecision(.disabled, forRoot: workspaceRoot.standardizedFileURL.path)
    }

    public func markInstalled(workspaceRoot: URL) {
        let key = workspaceRoot.standardizedFileURL.path
        lock.lock()
        installedRoots.insert(key)
        repairRoots.remove(key)
        lock.unlock()
    }

    public func markNeedsRepair(workspaceRoot: URL) {
        lock.lock()
        repairRoots.insert(workspaceRoot.standardizedFileURL.path)
        lock.unlock()
    }
}
