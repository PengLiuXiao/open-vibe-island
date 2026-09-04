import Foundation

public struct AntigravityHookInstallationStatus: Equatable, Sendable {
    public var configDirectory: URL
    public var configURL: URL
    public var manifestURL: URL
    public var hooksBinaryURL: URL?
    public var managedHooksPresent: Bool
    /// Managed entries exist for every lifecycle event in the expected
    /// shape. `false` with `managedHooksPresent == true` means a partial or
    /// stale install the manager should re-install.
    public var completeManagedHooksPresent: Bool
    public var manifest: AntigravityHookInstallerManifest?

    public init(
        configDirectory: URL,
        configURL: URL,
        manifestURL: URL,
        hooksBinaryURL: URL?,
        managedHooksPresent: Bool,
        completeManagedHooksPresent: Bool = false,
        manifest: AntigravityHookInstallerManifest?
    ) {
        self.configDirectory = configDirectory
        self.configURL = configURL
        self.manifestURL = manifestURL
        self.hooksBinaryURL = hooksBinaryURL
        self.managedHooksPresent = managedHooksPresent
        self.completeManagedHooksPresent = completeManagedHooksPresent
        self.manifest = manifest
    }
}

/// Installs Open Island's managed hooks into the Antigravity CLI's shared
/// customization config, `~/.gemini/config/hooks.json`.
///
/// agy reads `hooks.json` when a process starts, so installs and uninstalls
/// only affect agy sessions launched afterwards. The manifest records the
/// managed command (and prior `enabled` state) so uninstall removes exactly
/// what Open Island wrote.
public final class AntigravityHookInstallationManager: @unchecked Sendable {
    public let configDirectory: URL
    public let managedHooksBinaryURL: URL
    private let fileManager: FileManager

    public init(
        configDirectory: URL = AntigravityHookInstallationManager.defaultDirectory(),
        managedHooksBinaryURL: URL = ManagedHooksBinary.defaultURL(),
        fileManager: FileManager = .default
    ) {
        self.configDirectory = configDirectory
        self.managedHooksBinaryURL = managedHooksBinaryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func defaultDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/config")
    }

    public static var defaultConfigURL: URL {
        defaultDirectory().appendingPathComponent("hooks.json")
    }

    public func status(hooksBinaryURL: URL? = nil) throws -> AntigravityHookInstallationStatus {
        let configURL = Self.defaultConfigURL(in: configDirectory)
        let manifestURL = configDirectory.appendingPathComponent(AntigravityHookInstallerManifest.fileName)
        let resolvedHooksBinaryURL = resolvedHooksBinaryURL(explicitURL: hooksBinaryURL)

        let configData = try? Data(contentsOf: configURL)
        let manifest = try loadManifest(at: manifestURL)
        let uninstallMutation = try AntigravityHookInstaller.uninstallConfigJSON(
            existingData: configData,
            managedBinaryPath: manifest?.binaryPath
        )
        // Completeness runs against the binary this machine would install,
        // not the manifest's recorded command: a manifest from another
        // machine (or a moved binary) must not mask a pending re-install.
        let currentBinaryPath = resolvedHooksBinaryURL?.path

        return AntigravityHookInstallationStatus(
            configDirectory: configDirectory,
            configURL: configURL,
            manifestURL: manifestURL,
            hooksBinaryURL: resolvedHooksBinaryURL,
            managedHooksPresent: uninstallMutation.managedHooksPresent,
            completeManagedHooksPresent: currentBinaryPath.map {
                AntigravityHookInstaller.containsCompleteManagedHooks(existingData: configData, binaryPath: $0)
            } ?? false,
            manifest: manifest
        )
    }

    @discardableResult
    public func install(hooksBinaryURL: URL) throws -> AntigravityHookInstallationStatus {
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let configURL = Self.defaultConfigURL(in: configDirectory)
        let manifestURL = configDirectory.appendingPathComponent(AntigravityHookInstallerManifest.fileName)
        let existingConfig = try? Data(contentsOf: configURL)
        let installedHooksBinaryURL = try ManagedHooksBinary.install(
            from: hooksBinaryURL,
            to: managedHooksBinaryURL,
            fileManager: fileManager
        )
        let mutation = try AntigravityHookInstaller.installConfigJSON(
            existingData: existingConfig,
            binaryPath: installedHooksBinaryURL.path
        )

        if mutation.changed, fileManager.fileExists(atPath: configURL.path) {
            try backupFile(at: configURL)
        }

        if let contents = mutation.contents {
            try contents.write(to: configURL, options: .atomic)
        }

        let manifest = AntigravityHookInstallerManifest(
            binaryPath: installedHooksBinaryURL.path,
            enabledBeforeInstall: mutation.enabledBefore
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return try status(hooksBinaryURL: installedHooksBinaryURL)
    }

    @discardableResult
    public func uninstall() throws -> AntigravityHookInstallationStatus {
        let configURL = Self.defaultConfigURL(in: configDirectory)
        let manifestURL = configDirectory.appendingPathComponent(AntigravityHookInstallerManifest.fileName)
        let manifest = try loadManifest(at: manifestURL)
        let existingConfig = try? Data(contentsOf: configURL)
        let mutation = try AntigravityHookInstaller.uninstallConfigJSON(
            existingData: existingConfig,
            managedBinaryPath: manifest?.binaryPath
        )

        if mutation.changed, fileManager.fileExists(atPath: configURL.path) {
            try backupFile(at: configURL)
        }

        if let contents = mutation.contents {
            try contents.write(to: configURL, options: .atomic)
        } else if fileManager.fileExists(atPath: configURL.path) {
            // contents == nil means the config ended up empty — the whole
            // file only held Open Island's hooks, so remove it entirely.
            try fileManager.removeItem(at: configURL)
        }

        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }

        return try status()
    }

    private static func defaultConfigURL(in directory: URL) -> URL {
        directory.appendingPathComponent("hooks.json")
    }

    private func loadManifest(at url: URL) throws -> AntigravityHookInstallerManifest? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AntigravityHookInstallerManifest.self, from: data)
    }

    private func resolvedHooksBinaryURL(explicitURL: URL?) -> URL? {
        if let explicitURL {
            return explicitURL.standardizedFileURL
        }

        guard fileManager.isExecutableFile(atPath: managedHooksBinaryURL.path) else {
            return nil
        }

        return managedHooksBinaryURL
    }

    private func backupFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("backup.\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }
}
