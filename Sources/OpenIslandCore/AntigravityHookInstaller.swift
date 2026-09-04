import Foundation

public struct AntigravityHookInstallerManifest: Equatable, Codable, Sendable {
    public static let fileName = "open-island-antigravity-install.json"

    /// Absolute path of the managed hooks binary the install copied.
    /// Managed entries for every event are matched against this path.
    public var binaryPath: String
    /// Value of the managed group's `enabled` key before the installer
    /// touched it. `nil` means the key (or the whole group) was absent;
    /// uninstall restores this state when other handlers remain.
    public var enabledBeforeInstall: Bool?
    public var installedAt: Date

    public init(
        binaryPath: String,
        enabledBeforeInstall: Bool?,
        installedAt: Date = .now
    ) {
        self.binaryPath = binaryPath
        self.enabledBeforeInstall = enabledBeforeInstall
        self.installedAt = installedAt
    }
}

public struct AntigravityHookFileMutation: Equatable, Sendable {
    public var contents: Data?
    public var changed: Bool
    public var managedHooksPresent: Bool
    /// Prior `enabled` value observed while installing, so the manager can
    /// persist it in the manifest for a faithful uninstall.
    public var enabledBefore: Bool?

    public init(
        contents: Data?,
        changed: Bool,
        managedHooksPresent: Bool,
        enabledBefore: Bool? = nil
    ) {
        self.contents = contents
        self.changed = changed
        self.managedHooksPresent = managedHooksPresent
        self.enabledBefore = enabledBefore
    }
}

public enum AntigravityHookInstallerError: Error, LocalizedError {
    case invalidConfigJSON

    public var errorDescription: String? {
        switch self {
        case .invalidConfigJSON:
            "The existing Antigravity hooks.json is not valid JSON."
        }
    }
}

/// Installs/uninstalls Open Island's managed hook entries in the Antigravity
/// CLI's shared customization config, `~/.gemini/config/hooks.json`.
///
/// agy's `hooks.json` is an object of named hook groups; each group maps
/// event names to handler lists. `PreToolUse`/`PostToolUse` handlers are
/// grouped behind a `matcher` regex, while `PreInvocation`/`PostInvocation`/
/// `Stop` take flat handler lists. Open Island owns the `"open-island"`
/// group and leaves every other group untouched.
///
/// Handler `command` strings run through `sh -c`, so the binary path is
/// single-quoted (it typically contains spaces under ~/Library/Application
/// Support). agy loads `hooks.json` at process start, so installs only
/// affect sessions launched afterwards.
///
/// The managed set stays low-noise: lifecycle signal only (`PreInvocation`,
/// `PreToolUse`, `PostToolUse`, `Stop`). `PreToolUse` entries must write
/// nothing to stdout — agy treats a JSON object without a `decision` field
/// as a deny, while empty output passes through to the normal permission
/// flow.
public enum AntigravityHookInstaller {
    public static let managedGroupName = "open-island"
    public static let managedTimeoutSeconds = 45

    /// Arguments passed to the hooks binary for every managed entry, minus
    /// the per-event `--event` flag appended by `managedHookCommand`.
    public static let managedHookArguments = ["--source", "antigravity"]

    private struct EventSpec {
        let name: String
        let grouped: Bool
    }

    private static let eventSpecs: [EventSpec] = [
        EventSpec(name: "PreInvocation", grouped: false),
        EventSpec(name: "PreToolUse", grouped: true),
        EventSpec(name: "PostToolUse", grouped: true),
        EventSpec(name: "Stop", grouped: false),
    ]

    /// The lifecycle events a managed install covers, in spec order.
    public static let managedEventNames: [String] = eventSpecs.map(\.name)

    /// The `command` string of a managed entry for one event. Single-quoted
    /// so `sh -c` keeps the binary path intact when it contains spaces.
    public static func managedHookCommand(binaryPath: String, event: String) -> String {
        "'\(shellEscaped(binaryPath))' \(managedHookArguments.joined(separator: " ")) --event \(event)"
    }

    public static func installConfigJSON(
        existingData: Data?,
        binaryPath: String
    ) throws -> AntigravityHookFileMutation {
        var rootObject = try loadRootObject(from: existingData)
        var group = rootObject[managedGroupName] as? [String: Any] ?? [:]
        let enabledBefore = group["enabled"] as? Bool

        for spec in eventSpecs {
            group[spec.name] = sanitizedManagedEvent(
                value: group[spec.name],
                grouped: spec.grouped,
                binaryPath: binaryPath
            ) + [managedEntry(event: spec.name, grouped: spec.grouped, binaryPath: binaryPath)]
        }

        group["enabled"] = true
        rootObject[managedGroupName] = group

        let data = try serialize(rootObject)
        return AntigravityHookFileMutation(
            contents: data,
            changed: data != existingData,
            managedHooksPresent: true,
            enabledBefore: enabledBefore
        )
    }

    public static func uninstallConfigJSON(
        existingData: Data?,
        managedBinaryPath: String?
    ) throws -> AntigravityHookFileMutation {
        guard let existingData else {
            return AntigravityHookFileMutation(contents: nil, changed: false, managedHooksPresent: false)
        }

        var rootObject = try loadRootObject(from: existingData)
        guard var group = rootObject[managedGroupName] as? [String: Any] else {
            return AntigravityHookFileMutation(contents: existingData, changed: false, managedHooksPresent: false)
        }

        var mutated = false

        for spec in eventSpecs {
            guard let value = group[spec.name] else {
                continue
            }

            let cleaned = sanitizedManagedEvent(value: value, grouped: spec.grouped, binaryPath: managedBinaryPath)
            if !arraysEqual(cleaned, value) {
                mutated = true
            }

            if cleaned.isEmpty {
                group.removeValue(forKey: spec.name)
            } else {
                group[spec.name] = cleaned
            }
        }

        if group.keys.allSatisfy({ $0 == "enabled" }) {
            // Only our (now empty) events and possibly `enabled` remain —
            // the group exists solely for Open Island, so drop it entirely.
            rootObject.removeValue(forKey: managedGroupName)
            mutated = true
        } else {
            rootObject[managedGroupName] = group
        }

        let contents = rootObject.isEmpty ? nil : try serialize(rootObject)
        return AntigravityHookFileMutation(
            contents: contents,
            changed: mutated || contents != existingData,
            managedHooksPresent: mutated
        )
    }

    /// `true` when every managed lifecycle event carries at least one
    /// managed entry in the expected (flat vs grouped) shape.
    public static func containsCompleteManagedHooks(existingData: Data?, binaryPath: String) -> Bool {
        let rootObject = (try? loadRootObject(from: existingData)) ?? [:]
        let group = rootObject[managedGroupName] as? [String: Any] ?? [:]

        return eventSpecs.allSatisfy { spec in
            guard let value = group[spec.name] as? [Any] else {
                return false
            }

            if spec.grouped {
                return value.contains { item in
                    guard let groupEntry = item as? [String: Any] else {
                        return false
                    }
                    let hooks = groupEntry["hooks"] as? [Any] ?? []
                    return hooks.contains { hook in
                        (hook as? [String: Any]).map { isManagedHandler($0, binaryPath: binaryPath) } ?? false
                    }
                }
            }

            return value.contains { handler in
                (handler as? [String: Any]).map { isManagedHandler($0, binaryPath: binaryPath) } ?? false
            }
        }
    }

    // MARK: - Entry shaping

    private static func managedEntry(event: String, grouped: Bool, binaryPath: String) -> [String: Any] {
        let handler: [String: Any] = [
            "type": "command",
            "command": managedHookCommand(binaryPath: binaryPath, event: event),
            "timeout": managedTimeoutSeconds,
        ]

        if grouped {
            return [
                "matcher": "*",
                "hooks": [handler],
            ]
        }

        return handler
    }

    /// Removes managed handlers from one event's list. When a binary path is
    /// given, managed entries are recognized by that path; the
    /// `--source antigravity` + binary-name heuristic catches entries from
    /// other machines or older installs either way. Handles both flat
    /// handler lists and matcher groups.
    private static func sanitizedManagedEvent(
        value: Any?,
        grouped: Bool,
        binaryPath: String? = nil
    ) -> [[String: Any]] {
        let items = value as? [Any] ?? []

        if grouped {
            return items.compactMap { item -> [String: Any]? in
                guard var groupEntry = item as? [String: Any] else {
                    return nil
                }

                let hooks = groupEntry["hooks"] as? [Any] ?? []
                let filtered = hooks.compactMap { hook -> [String: Any]? in
                    guard let handler = hook as? [String: Any] else {
                        return nil
                    }
                    return isManagedHandler(handler, binaryPath: binaryPath) ? nil : handler
                }

                // An Open Island matcher group exists only to carry our
                // handlers; drop it once they are gone. Mixed groups (a user
                // merged their own handler into our matcher group) survive
                // with only the managed handlers stripped.
                let groupIsFullyManaged = !hooks.isEmpty && hooks.allSatisfy { hook in
                    (hook as? [String: Any]).map { isManagedHandler($0, binaryPath: binaryPath) } ?? false
                }

                if groupIsFullyManaged {
                    return nil
                }

                guard !filtered.isEmpty else {
                    return nil
                }

                groupEntry["hooks"] = filtered
                return groupEntry
            }
        }

        return items.compactMap { item -> [String: Any]? in
            guard let handler = item as? [String: Any] else {
                return nil
            }
            return isManagedHandler(handler, binaryPath: binaryPath) ? nil : handler
        }
    }

    private static func isManagedHandler(
        _ handler: [String: Any],
        binaryPath: String?
    ) -> Bool {
        let command = handler["command"] as? String ?? ""
        // Commands are stored shell-quoted; strip the quotes before
        // comparing against the raw binary path.
        let unquoted = command.replacingOccurrences(of: "'", with: "")
        let arguments = (handler["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        let normalized = (unquoted + " " + arguments.joined(separator: " ")).lowercased()

        guard normalized.contains("--source antigravity") else {
            return false
        }

        if let binaryPath {
            let lowered = binaryPath.lowercased()
            if normalized == lowered || normalized.hasPrefix(lowered + " ") {
                return true
            }
        }

        return normalized.contains("openislandhooks")
            || normalized.contains("vibeislandhooks")
            || normalized.contains("open-island-bridge")
            || normalized.contains("vibe-island-bridge")
    }

    // MARK: - JSON plumbing

    private static func loadRootObject(from data: Data?) throws -> [String: Any] {
        guard let data else {
            return [:]
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let rootObject = object as? [String: Any] else {
            throw AntigravityHookInstallerError.invalidConfigJSON
        }

        return rootObject
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func arraysEqual(_ lhs: [[String: Any]], _ rhs: Any?) -> Bool {
        guard let rhsItems = rhs as? [Any] else {
            return lhs.isEmpty
        }

        guard lhs.count == rhsItems.count else {
            return false
        }

        let lhsData = (try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys])) ?? Data()
        let rhsData = (try? JSONSerialization.data(withJSONObject: rhsItems, options: [.sortedKeys])) ?? Data()
        return lhsData == rhsData
    }

    private static func shellEscaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}
