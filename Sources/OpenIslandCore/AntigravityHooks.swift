import Foundation

public enum AntigravityHookEventName: String, Codable, Sendable, CaseIterable {
    case preInvocation = "PreInvocation"
    case postInvocation = "PostInvocation"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
}

/// A tool call reported by `PreToolUse` / `PostToolUse`. Argument shapes are
/// tool-specific (`CommandLine` for `run_command`, etc.), so args stay raw.
public struct AntigravityHookToolCall: Equatable, Codable, Sendable {
    public var name: String?
    public var args: CodexHookJSONValue?

    public init(name: String? = nil, args: CodexHookJSONValue? = nil) {
        self.name = name
        self.args = args
    }

    var toolSummary: String? {
        guard case let .object(object)? = args else {
            return nil
        }

        for key in ["toolSummary", "toolAction"] {
            if case let .string(value)? = object[key], !value.isEmpty {
                return value
            }
        }

        return nil
    }

    var commandLine: String? {
        guard case let .object(object)? = args else {
            return nil
        }

        if case let .string(value)? = object["CommandLine"], !value.isEmpty {
            return value
        }

        return nil
    }
}

/// Hook payload for the Antigravity CLI (`agy`).
///
/// agy sends a camelCase protojson object on stdin. Unlike Claude Code and
/// Gemini CLI, the payload does not identify its own event — each event is a
/// separate command entry in `hooks.json`, so the runtime passes the event
/// through the `--event` CLI argument instead. It also omits a `cwd` field;
/// the workspace is recovered from the spawning `agy` process (the hook
/// command is a direct descendant) or `workspacePaths` when populated.
public struct AntigravityHookPayload: Equatable, Codable, Sendable {
    public var conversationId: String
    public var hookEventName: AntigravityHookEventName?
    public var workspacePaths: [String]?
    public var transcriptPath: String?
    public var artifactDirectoryPath: String?
    public var modelName: String?
    public var toolCall: AntigravityHookToolCall?
    public var stepIdx: Int?
    public var invocationNum: Int?
    public var initialNumSteps: Int?
    public var executionNum: Int?
    public var terminationReason: String?
    public var fullyIdle: Bool?
    public var error: String?

    // Runtime context appended by the hooks CLI (not part of agy's stdin).
    public var workingDirectory: String?
    public var terminalApp: String?
    public var terminalSessionID: String?
    public var terminalTTY: String?
    public var terminalTitle: String?

    public init(
        conversationId: String,
        hookEventName: AntigravityHookEventName? = nil,
        workspacePaths: [String]? = nil,
        transcriptPath: String? = nil,
        artifactDirectoryPath: String? = nil,
        modelName: String? = nil,
        toolCall: AntigravityHookToolCall? = nil,
        stepIdx: Int? = nil,
        invocationNum: Int? = nil,
        initialNumSteps: Int? = nil,
        executionNum: Int? = nil,
        terminationReason: String? = nil,
        fullyIdle: Bool? = nil,
        error: String? = nil,
        workingDirectory: String? = nil,
        terminalApp: String? = nil,
        terminalSessionID: String? = nil,
        terminalTTY: String? = nil,
        terminalTitle: String? = nil
    ) {
        self.conversationId = conversationId
        self.hookEventName = hookEventName
        self.workspacePaths = workspacePaths
        self.transcriptPath = transcriptPath
        self.artifactDirectoryPath = artifactDirectoryPath
        self.modelName = modelName
        self.toolCall = toolCall
        self.stepIdx = stepIdx
        self.invocationNum = invocationNum
        self.initialNumSteps = initialNumSteps
        self.executionNum = executionNum
        self.terminationReason = terminationReason
        self.fullyIdle = fullyIdle
        self.error = error
        self.workingDirectory = workingDirectory
        self.terminalApp = terminalApp
        self.terminalSessionID = terminalSessionID
        self.terminalTTY = terminalTTY
        self.terminalTitle = terminalTitle
    }
}

public extension AntigravityHookPayload {
    /// agy reports success as an empty `error` string, not a missing key.
    var toolErrorText: String? {
        guard let error, !error.isEmpty else {
            return nil
        }

        return error
    }

    /// Preferred workspace for the session: agy only populates
    /// `workspacePaths` in some modes, so the cwd recovered from the parent
    /// `agy` process is the reliable signal.
    var resolvedWorkingDirectory: String? {
        let candidates = [workspacePaths?.first, workingDirectory].compactMap { $0 }
        return candidates.first { !$0.isEmpty }
    }

    var workspaceName: String {
        resolvedWorkingDirectory.map { WorkspaceNameResolver.workspaceName(for: $0) } ?? "Antigravity"
    }

    var sessionTitle: String {
        "Antigravity CLI · \(workspaceName)"
    }

    var defaultJumpTarget: JumpTarget {
        JumpTarget(
            terminalApp: terminalApp ?? "Antigravity",
            workspaceName: workspaceName,
            paneTitle: terminalTitle ?? "Antigravity \(conversationId.prefix(8))",
            workingDirectory: resolvedWorkingDirectory,
            terminalSessionID: terminalSessionID,
            terminalTTY: terminalTTY
        )
    }

    var implicitSummary: String {
        switch hookEventName {
        case .preInvocation, .postInvocation:
            "Antigravity CLI started a new turn in \(workspaceName)."
        case .preToolUse:
            "Antigravity \(toolCall?.name ?? "tool"): \(toolCall?.toolSummary ?? toolCall?.commandLine ?? "running")."
        case .postToolUse:
            toolErrorText.map { error in
                "Antigravity \(toolCall?.name ?? "tool") failed: \(error)."
            } ?? "Antigravity \(toolCall?.name ?? "tool"): \(toolCall?.toolSummary ?? toolCall?.commandLine ?? "completed")."
        case .stop:
            "Antigravity CLI completed a turn in \(workspaceName)."
        case nil:
            "Antigravity CLI session in \(workspaceName)."
        }
    }

    func withRuntimeContext(environment: [String: String]) -> AntigravityHookPayload {
        withRuntimeContext(
            environment: environment,
            currentTTYProvider: { currentTTY() },
            terminalLocatorProvider: { terminalLocator(for: $0) },
            parentWorkingDirectoryProvider: { Self.parentAntigravityWorkingDirectory() }
        )
    }

    func withRuntimeContext(
        environment: [String: String],
        currentTTYProvider: () -> String?,
        terminalLocatorProvider: (String) -> (sessionID: String?, tty: String?, title: String?),
        parentWorkingDirectoryProvider: () -> String?
    ) -> AntigravityHookPayload {
        var payload = self

        if payload.terminalApp == nil {
            payload.terminalApp = inferTerminalApp(from: environment)
        }

        if payload.terminalTTY == nil {
            payload.terminalTTY = currentTTYProvider()
        }

        if payload.workingDirectory == nil {
            payload.workingDirectory = parentWorkingDirectoryProvider()
        }

        let useLocator: Bool
        if isCmuxTerminalApp(payload.terminalApp) || isZellijTerminalApp(payload.terminalApp) {
            useLocator = false
        } else if let terminalApp = payload.terminalApp, isGhosttyTerminalApp(terminalApp) {
            switch payload.hookEventName {
            case .preInvocation, .postInvocation, nil:
                useLocator = true
            case .stop:
                payload.terminalSessionID = nil
                payload.terminalTitle = nil
                useLocator = false
            case .preToolUse, .postToolUse:
                // Per-tool events fire in tight succession; locator calls
                // (AppleScript) would hammer the terminal for no value.
                useLocator = false
            }
        } else {
            useLocator = shouldUseFocusedTerminalLocator(for: payload.terminalApp ?? "")
        }

        if useLocator, let terminalApp = payload.terminalApp {
            let locator = terminalLocatorProvider(terminalApp)
            if payload.terminalSessionID == nil {
                payload.terminalSessionID = locator.sessionID
            }
            if payload.terminalTTY == nil {
                payload.terminalTTY = locator.tty
            }
            if payload.terminalTitle == nil {
                payload.terminalTitle = locator.title
            }
        }

        return payload
    }

    /// Walks the parent process chain looking for the `agy` process that
    /// spawned this hook (agy runs hook commands via `sh -c`, so the CLI is
    /// at most a couple of hops away) and returns its working directory.
    /// This is the only reliable workspace signal: agy's payloads omit
    /// `cwd` and often leave `workspacePaths` empty.
    static func parentAntigravityWorkingDirectory() -> String? {
        var pid: Int? = Int(getppid())

        for _ in 0..<6 {
            guard let currentPID = pid else {
                return nil
            }

            guard
                let raw = Self.commandOutput(
                    executablePath: "/bin/ps",
                    arguments: ["-p", "\(currentPID)", "-o", "ppid=,comm="]
                )
            else {
                return nil
            }

            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstSpace = line.firstIndex(of: " ") else {
                return nil
            }

            let parentID = Int(line[..<firstSpace].trimmingCharacters(in: .whitespaces))
            let command = String(line[line.index(after: firstSpace)...]).trimmingCharacters(in: .whitespaces)
            let binaryName = URL(fileURLWithPath: command).lastPathComponent

            if binaryName == "agy" || binaryName.hasPrefix("agy-") {
                return workingDirectory(ofProcessID: currentPID)
            }

            pid = parentID
        }

        return nil
    }

    private static func workingDirectory(ofProcessID pid: Int) -> String? {
        guard
            let raw = Self.commandOutput(
                executablePath: "/usr/sbin/lsof",
                arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
            )
        else {
            return nil
        }

        for line in raw.components(separatedBy: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            return path.isEmpty ? nil : path
        }

        return nil
    }

    private static let noLocatorTerminalApps: Set<String> = [
        "cmux", "kaku", "wezterm", "zellij",
        "vs code", "vs code insiders", "cursor", "windsurf", "trae",
        "intellij idea", "webstorm", "pycharm", "goland", "clion",
        "rubymine", "phpstorm", "rider", "rustrover"
    ]

    private func shouldUseFocusedTerminalLocator(for terminalApp: String) -> Bool {
        let lower = terminalApp.lowercased()
        if lower.contains("ghostty") || lower.contains("jetbrains") {
            return false
        }
        return !Self.noLocatorTerminalApps.contains(lower)
    }

    private func isGhosttyTerminalApp(_ terminalApp: String?) -> Bool {
        guard let app = terminalApp?.lowercased() else { return false }
        return app.contains("ghostty")
    }

    private func isCmuxTerminalApp(_ terminalApp: String?) -> Bool {
        terminalApp?.lowercased() == "cmux"
    }

    private func isZellijTerminalApp(_ terminalApp: String?) -> Bool {
        terminalApp?.lowercased() == "zellij"
    }

    private func inferTerminalApp(from environment: [String: String]) -> String? {
        if environment["ITERM_SESSION_ID"] != nil || environment["LC_TERMINAL"] == "iTerm2" {
            return "iTerm"
        }

        if environment["CMUX_WORKSPACE_ID"] != nil || environment["CMUX_SOCKET_PATH"] != nil {
            return "cmux"
        }

        if environment["ZELLIJ"] != nil {
            return "Zellij"
        }

        if environment["GHOSTTY_RESOURCES_DIR"] != nil {
            return "Ghostty"
        }

        if environment["WARP_IS_LOCAL_SHELL_SESSION"] != nil {
            return "Warp"
        }

        let termProgram = environment["TERM_PROGRAM"]?.lowercased()
        switch termProgram {
        case .some("apple_terminal"):
            return "Terminal"
        case .some("iterm.app"), .some("iterm2"):
            return "iTerm"
        case let value? where value.contains("ghostty"):
            return "Ghostty"
        case let value? where value.contains("warp"):
            return "Warp"
        case let value? where value.contains("wezterm"):
            return "WezTerm"
        case .some("kaku"):
            return "Kaku"
        case .some("vscode"):
            return "VS Code"
        case .some("vscode-insiders"):
            return "VS Code Insiders"
        case .some("windsurf"):
            return "Windsurf"
        case .some("trae"):
            return "Trae"
        case .some("zed"):
            return "Zed"
        default:
            break
        }

        if let terminalEmulator = environment["TERMINAL_EMULATOR"]?.lowercased(),
           terminalEmulator.contains("jetbrains") {
            if let bundleID = environment["__CFBundleIdentifier"]?.lowercased() {
                if bundleID.contains("webstorm") { return "WebStorm" }
                if bundleID.contains("pycharm") { return "PyCharm" }
                if bundleID.contains("goland") { return "GoLand" }
                if bundleID.contains("clion") { return "CLion" }
                if bundleID.contains("rubymine") { return "RubyMine" }
                if bundleID.contains("phpstorm") { return "PhpStorm" }
                if bundleID.contains("rider") { return "Rider" }
                if bundleID.contains("rustrover") { return "RustRover" }
            }
            return "JetBrains"
        }

        return nil
    }

    private func currentTTY() -> String? {
        if let tty = Self.commandOutput(executablePath: "/usr/bin/tty", arguments: []),
           !tty.contains("not a tty") {
            return tty
        }

        return parentProcessTTY()
    }

    private func parentProcessTTY() -> String? {
        let ppid = getppid()
        guard let raw = Self.commandOutput(executablePath: "/bin/ps", arguments: ["-p", "\(ppid)", "-o", "tty="]) else {
            return nil
        }

        let tty = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "??", tty != "-" else {
            return nil
        }

        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    private func terminalLocator(for terminalApp: String) -> (sessionID: String?, tty: String?, title: String?) {
        let normalized = terminalApp.lowercased()

        if normalized.contains("iterm") {
            let values = osascriptValues(script: GeminiHookPayload.terminalLocatorAppleScript(for: "iTerm"))
            return (
                sessionID: values[safe: 0],
                tty: values[safe: 1],
                title: values[safe: 2]
            )
        }

        if normalized.contains("ghostty") {
            let values = osascriptValues(script: GeminiHookPayload.terminalLocatorAppleScript(for: "Ghostty"))
            return (
                sessionID: values[safe: 0],
                tty: nil,
                title: values[safe: 2]
            )
        }

        if normalized.contains("terminal") {
            let values = osascriptValues(script: GeminiHookPayload.terminalLocatorAppleScript(for: "Terminal"))
            return (
                sessionID: nil,
                tty: values[safe: 0],
                title: values[safe: 1]
            )
        }

        return (nil, nil, nil)
    }

    private func osascriptValues(script: String) -> [String] {
        guard let raw = Self.commandOutput(executablePath: "/usr/bin/osascript", arguments: ["-e", script]) else {
            return []
        }

        let separator = String(UnicodeScalar(31)!)
        return raw
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func commandOutput(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return nil
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
