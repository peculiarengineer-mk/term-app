import XCTest
@testable import Store

final class AIAgentTests: XCTestCase {
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "termapp.tests.agents.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    // MARK: - Presets & Descriptors

    func testBuiltInAgentsAndDescriptors() {
        XCTAssertEqual(BuiltInAIAgent.allCases, [.claude, .agy, .codex, .aider, .opencode])

        XCTAssertEqual(BuiltInAIAgent.claude.displayName, "Claude Code")
        XCTAssertEqual(BuiltInAIAgent.claude.command, "claude")
        XCTAssertEqual(BuiltInAIAgent.claude.symbolName, "sparkles")
        XCTAssertEqual(BuiltInAIAgent.claude.colorToken, "amber")

        XCTAssertEqual(BuiltInAIAgent.agy.displayName, "Antigravity")
        XCTAssertEqual(BuiltInAIAgent.agy.command, "agy")
        XCTAssertEqual(BuiltInAIAgent.agy.symbolName, "wand.and.stars")
        XCTAssertEqual(BuiltInAIAgent.agy.colorToken, "cyan")

        XCTAssertEqual(BuiltInAIAgent.codex.displayName, "Codex")
        XCTAssertEqual(BuiltInAIAgent.codex.command, "codex")
        XCTAssertEqual(BuiltInAIAgent.codex.symbolName, "cpu")
        XCTAssertEqual(BuiltInAIAgent.codex.colorToken, "green")

        XCTAssertEqual(BuiltInAIAgent.aider.displayName, "Aider")
        XCTAssertEqual(BuiltInAIAgent.aider.command, "aider")
        XCTAssertEqual(BuiltInAIAgent.aider.symbolName, "wrench.and.screwdriver")
        XCTAssertEqual(BuiltInAIAgent.aider.colorToken, "blue")

        XCTAssertEqual(BuiltInAIAgent.opencode.displayName, "OpenCode")
        XCTAssertEqual(BuiltInAIAgent.opencode.command, "opencode")
        XCTAssertEqual(BuiltInAIAgent.opencode.symbolName, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(BuiltInAIAgent.opencode.colorToken, "purple")

        let builtIns = AIAgentDescriptor.builtIns
        XCTAssertEqual(builtIns.count, 5)
        XCTAssertTrue(builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(builtIns.map(\.id), ["claude", "agy", "codex", "aider", "opencode"])
        XCTAssertEqual(builtIns.map(\.builtIn), BuiltInAIAgent.allCases)

        let custom = CustomAIAgentPreset(
            name: "Goose Agent",
            command: "goose",
            defaultArgs: "session --resume",
            symbolName: "bird"
        )
        let customDesc = AIAgentDescriptor(custom: custom)
        XCTAssertEqual(customDesc.id, custom.id.uuidString)
        XCTAssertEqual(customDesc.slug, "goose-agent")
        XCTAssertEqual(customDesc.name, "Goose Agent")
        XCTAssertEqual(customDesc.command, "goose")
        XCTAssertEqual(customDesc.defaultArgs, "session --resume")
        XCTAssertEqual(customDesc.symbolName, "bird")
        XCTAssertFalse(customDesc.isBuiltIn)
        XCTAssertNil(customDesc.builtIn)

        let hostID = UUID()
        let launchCtx = AIAgentLaunchContext(
            agent: builtIns[0],
            sessionName: "termapp-ai-claude-repo",
            workingDirectory: "~/repo",
            hostID: hostID
        )
        XCTAssertEqual(launchCtx.agent, builtIns[0])
        XCTAssertEqual(launchCtx.sessionName, "termapp-ai-claude-repo")
        XCTAssertEqual(launchCtx.workingDirectory, "~/repo")
        XCTAssertEqual(launchCtx.hostID, hostID)
        XCTAssertTrue(launchCtx.isTmuxBacked)

        let directCtx = AIAgentLaunchContext(
            agent: builtIns[0],
            sessionName: "termapp-ai-claude-repo",
            workingDirectory: "~/repo",
            hostID: hostID,
            isTmuxBacked: false
        )
        XCTAssertFalse(directCtx.isTmuxBacked)
    }

    func testLaunchContextDecodingDefaultsIsTmuxBackedToTrue() throws {
        let builtIn = AIAgentDescriptor(builtIn: .claude)
        let original = AIAgentLaunchContext(
            agent: builtIn,
            sessionName: "termapp-ai-claude-repo",
            workingDirectory: "~/repo",
            hostID: UUID(),
            isTmuxBacked: false
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AIAgentLaunchContext.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.isTmuxBacked)

        let legacyPayload: [String: Any] = [
            "agent": try JSONSerialization.jsonObject(with: JSONEncoder().encode(builtIn)),
            "sessionName": "termapp-ai-claude-repo",
            "workingDirectory": "~/repo",
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)
        let legacyDecoded = try JSONDecoder().decode(AIAgentLaunchContext.self, from: legacyData)
        XCTAssertTrue(legacyDecoded.isTmuxBacked)
    }

    func testCustomPresetDecodingDefaultsMissingOptionalFields() throws {
        let id = UUID()
        let minimalJSON = """
        {"id":"\(id.uuidString)","name":"My Tool","command":"mytool"}
        """
        let decoded = try JSONDecoder().decode(CustomAIAgentPreset.self, from: Data(minimalJSON.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "My Tool")
        XCTAssertEqual(decoded.command, "mytool")
        XCTAssertEqual(decoded.defaultArgs, "")
        XCTAssertEqual(decoded.symbolName, "terminal")
    }

    // MARK: - Shell Quoting & Path Expansion

    func testShellQuoteAndTildeExpansion() {
        XCTAssertEqual(TMuxSessionHelper.shellQuote(""), "''")
        XCTAssertEqual(TMuxSessionHelper.shellQuote("simple"), "'simple'")
        XCTAssertEqual(TMuxSessionHelper.shellQuote("path with spaces"), "'path with spaces'")
        XCTAssertEqual(TMuxSessionHelper.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(TMuxSessionHelper.shellQuote("$(rm -rf /)"), "'$(rm -rf /)'")
        XCTAssertEqual(TMuxSessionHelper.shellQuote("`whoami`; ls"), "'`whoami`; ls'")

        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: ""), "\"$HOME\"")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "~"), "\"$HOME\"")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "~/"), "\"$HOME\"")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "  ~/  "), "\"$HOME\"")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "  ~/projects/app"), "\"$HOME\"/'projects/app'")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "~/my projects/term's"), "\"$HOME\"/'my projects/term'\\''s'")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "/srv/app $(evil)"), "'/srv/app $(evil)'")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "/srv/app\nrm -rf /"), "'/srv/apprm -rf /'")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "~/dir\r\nid"), "\"$HOME\"/'dirid'")
    }

    // MARK: - Session Naming

    func testDeterministicSessionNaming() {
        XCTAssertEqual(
            TMuxSessionHelper.sessionName(agentSlug: "claude", workingDirectory: "~/projects/term-app"),
            "termapp-ai-claude-term-app"
        )
        XCTAssertEqual(
            TMuxSessionHelper.sessionName(agentSlug: "claude", workingDirectory: "/Users/me/term-app/"),
            "termapp-ai-claude-term-app"
        )
        XCTAssertEqual(
            TMuxSessionHelper.sessionName(agentSlug: "claude", workingDirectory: "~"),
            "termapp-ai-claude-home"
        )
        XCTAssertEqual(
            TMuxSessionHelper.sessionName(agentSlug: "claude", workingDirectory: "~/"),
            "termapp-ai-claude-home"
        )
        XCTAssertEqual(
            TMuxSessionHelper.sessionName(agentSlug: "claude", workingDirectory: ""),
            "termapp-ai-claude-home"
        )
        XCTAssertEqual(
            TMuxSessionHelper.sessionName(agentSlug: "codex", workingDirectory: "/"),
            "termapp-ai-codex-root"
        )
        XCTAssertEqual(
            TMuxSessionHelper.sessionName(agentSlug: "agy", workingDirectory: "/srv/My Cool_Project.v2!"),
            "termapp-ai-agy-my-cool-project-v2"
        )

        let longDir = "/workspace/" + String(repeating: "a", count: 80)
        let capped = TMuxSessionHelper.sessionName(agentSlug: "opencode", workingDirectory: longDir)
        XCTAssertTrue(capped.hasPrefix("termapp-ai-opencode-"))
        XCTAssertLessThanOrEqual(capped.count, 50)
        XCTAssertFalse(capped.hasSuffix("-"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        XCTAssertTrue(capped.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testNextUniqueSessionName() {
        // No collision returns base session name.
        XCTAssertEqual(
            TMuxSessionHelper.nextUniqueSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: []
            ),
            "termapp-ai-claude-term-app"
        )

        // Unrelated sessions do not trigger numbering.
        XCTAssertEqual(
            TMuxSessionHelper.nextUniqueSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: ["termapp-ai-agy-term-app", "termapp-ai-claude-other"]
            ),
            "termapp-ai-claude-term-app"
        )

        // Collisions increment -2, -3, ... and fill first unused slot.
        XCTAssertEqual(
            TMuxSessionHelper.nextUniqueSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: ["termapp-ai-claude-term-app"]
            ),
            "termapp-ai-claude-term-app-2"
        )
        XCTAssertEqual(
            TMuxSessionHelper.nextUniqueSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: [
                    "termapp-ai-claude-term-app",
                    "termapp-ai-claude-term-app-2",
                ]
            ),
            "termapp-ai-claude-term-app-3"
        )
        XCTAssertEqual(
            TMuxSessionHelper.nextUniqueSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: [
                    "termapp-ai-claude-term-app",
                    "termapp-ai-claude-term-app-3",
                ]
            ),
            "termapp-ai-claude-term-app-2"
        )

        // Custom suffix is sanitized (lowercased, punctuation collapsed, maxLength 16) and incremented on collision.
        XCTAssertEqual(
            TMuxSessionHelper.nextUniqueSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: ["termapp-ai-claude-term-app"],
                customSuffix: "  Bug Fix #1! "
            ),
            "termapp-ai-claude-term-app-bug-fix-1"
        )
        XCTAssertEqual(
            TMuxSessionHelper.nextUniqueSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: [
                    "termapp-ai-claude-term-app",
                    "termapp-ai-claude-term-app-bugfix",
                ],
                customSuffix: "bugfix"
            ),
            "termapp-ai-claude-term-app-bugfix-2"
        )

        // Blank or punctuation-only custom suffix falls back to base naming.
        XCTAssertEqual(
            TMuxSessionHelper.nextUniqueSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: ["termapp-ai-claude-term-app"],
                customSuffix: "   ---!!!  "
            ),
            "termapp-ai-claude-term-app-2"
        )

        // Overlong custom suffix is capped at 16 characters without trailing hyphen.
        let longSuffixName = TMuxSessionHelper.nextUniqueSessionName(
            agentSlug: "agy",
            workingDirectory: "~/repo",
            existingNames: [],
            customSuffix: "abcdefghijklmno-pqrstuv"
        )
        XCTAssertEqual(longSuffixName, "termapp-ai-agy-repo-abcdefghijklmno")
    }

    // MARK: - Command Generation

    func testLaunchOrAttachCommand() {
        let claude = AIAgentDescriptor(builtIn: .claude)
        let cmd = TMuxSessionHelper.launchOrAttachCommand(
            agent: claude,
            workingDirectory: "~/projects/my app",
            extraArgs: "--resume 'latest'"
        )

        XCTAssertFalse(cmd.contains("\n"))
        XCTAssertFalse(cmd.contains("\r"))
        XCTAssertTrue(cmd.contains("export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\""))
        XCTAssertTrue(cmd.contains("command -v tmux >/dev/null 2>&1"))
        XCTAssertTrue(cmd.contains("tmux is not installed on this host"))
        XCTAssertTrue(cmd.contains("tmux new-session -A -s 'termapp-ai-claude-my-app' -c \"$HOME\"/'projects/my app'"))
        XCTAssertTrue(cmd.contains("sh -lc"))
        XCTAssertTrue(cmd.contains("claude --resume"))
        XCTAssertTrue(cmd.contains("${SHELL:-sh}"))

        let overridden = TMuxSessionHelper.launchOrAttachCommand(
            agent: AIAgentDescriptor(custom: CustomAIAgentPreset(
                name: "Goose",
                command: "goose",
                defaultArgs: "session"
            )),
            workingDirectory: "/opt/$(evil)",
            extraArgs: "--debug",
            sessionName: "custom-session-1"
        )
        XCTAssertTrue(overridden.contains("tmux new-session -A -s 'custom-session-1' -c '/opt/$(evil)'"))
        XCTAssertTrue(overridden.contains("goose session --debug"))

        // Non-tmux fallback wraps agentCmd in `sh -lc '...'` so breakout tokens cannot escape `if ... fi`.
        let breakoutAttempt = TMuxSessionHelper.launchOrAttachCommand(
            agent: AIAgentDescriptor(custom: CustomAIAgentPreset(
                name: "Breakout",
                command: "echo hi; }; touch /tmp/pwned; if true; then :",
                defaultArgs: "'"
            )),
            workingDirectory: "~/projects/test"
        )
        XCTAssertFalse(breakoutAttempt.contains("\n"))
        XCTAssertFalse(breakoutAttempt.contains("\r"))
        XCTAssertFalse(breakoutAttempt.contains("&& { "))
        XCTAssertTrue(breakoutAttempt.contains("&& sh -lc '"))

        #if os(macOS)
        for shellPath in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = ["-n", "-c", breakoutAttempt]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(shellPath) -n failed on breakoutAttempt")
        }
        #endif
    }

    func testLaunchOrAttachCommandForceNewSession() throws {
        let claude = AIAgentDescriptor(builtIn: .claude)
        let cmd = TMuxSessionHelper.launchOrAttachCommand(
            agent: claude,
            workingDirectory: "~/projects/my app",
            extraArgs: "--model sonnet",
            sessionName: "termapp-ai-claude-my-app",
            forceNewSession: true
        )

        XCTAssertFalse(cmd.contains("\n"))
        XCTAssertFalse(cmd.contains("\r"))
        XCTAssertFalse(cmd.contains("tmux new-session -A"))
        XCTAssertTrue(cmd.contains("_base='termapp-ai-claude-my-app'; _target=\"$_base\"; _n=2;"))
        XCTAssertTrue(cmd.contains("while tmux has-session -t \"=$_target\" 2>/dev/null; do _target=\"${_base}-${_n}\"; _n=$((_n + 1)); done;"))
        XCTAssertTrue(cmd.contains("tmux new-session -s \"$_target\" -c \"$HOME\"/'projects/my app'"))
        XCTAssertTrue(cmd.contains("claude --model sonnet"))

        // Special characters and quote breakouts stay safely single-quoted in _base.
        let special = TMuxSessionHelper.launchOrAttachCommand(
            agent: claude,
            workingDirectory: "/opt/$(evil)",
            sessionName: "odd'name$(id)",
            forceNewSession: true
        )
        XCTAssertFalse(special.contains("\n"))
        XCTAssertFalse(special.contains("\r"))
        XCTAssertFalse(special.contains("tmux new-session -A"))
        XCTAssertTrue(special.contains("_base='odd'\\''name$(id)';"))
        XCTAssertTrue(special.contains("tmux new-session -s \"$_target\" -c '/opt/$(evil)'"))

        #if os(macOS)
        for shellPath in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            for candidateCmd in [cmd, special] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shellPath)
                process.arguments = ["-n", "-c", candidateCmd]
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, "\(shellPath) -n failed on forceNewSession command")
            }
        }
        #endif
    }

    func testAttachKillAndListCommands() {
        XCTAssertTrue(
            TMuxSessionHelper.attachCommand(sessionName: "termapp-ai-claude-app")
                .contains("tmux attach-session -t '=termapp-ai-claude-app'")
        )
        XCTAssertTrue(
            TMuxSessionHelper.attachCommand(sessionName: "odd'name")
                .contains("tmux attach-session -t '=odd'\\''name'")
        )
        XCTAssertTrue(
            TMuxSessionHelper.killSessionCommand(sessionName: "termapp-ai-agy-repo")
                .contains("tmux kill-session -t '=termapp-ai-agy-repo'")
        )

        let injectedAttach = TMuxSessionHelper.attachCommand(sessionName: "sess\r\nrm -rf /")
        XCTAssertFalse(injectedAttach.contains("\n"))
        XCTAssertFalse(injectedAttach.contains("\r"))
        XCTAssertTrue(injectedAttach.contains("tmux attach-session -t '=sessrm -rf /'"))

        let injectedKill = TMuxSessionHelper.killSessionCommand(sessionName: "sess\nkillall tmux")
        XCTAssertFalse(injectedKill.contains("\n"))
        XCTAssertFalse(injectedKill.contains("\r"))
        XCTAssertTrue(injectedKill.contains("tmux kill-session -t '=sesskillall tmux'"))

        let listCmd = TMuxSessionHelper.listSessionsCommand()
        XCTAssertFalse(listCmd.contains("\n"))
        XCTAssertFalse(listCmd.contains("\r"))
        XCTAssertTrue(listCmd.contains("command -v tmux >/dev/null 2>&1"))
        XCTAssertTrue(listCmd.contains("TERMAPP_TMUX_MISSING"))
        XCTAssertTrue(listCmd.contains("TERMAPP_PANES_BEGIN"))
        XCTAssertTrue(listCmd.contains("tmux list-sessions -F"))
        XCTAssertTrue(listCmd.contains("#{session_name}"))
        XCTAssertTrue(listCmd.contains("#{session_attached}"))
        XCTAssertTrue(listCmd.contains("#{session_windows}"))
        XCTAssertTrue(listCmd.contains("#{session_created}"))
        XCTAssertTrue(listCmd.contains("#{session_activity}"))
        XCTAssertTrue(listCmd.contains("#{pane_current_path}"))
        XCTAssertTrue(listCmd.contains("#{pane_current_command}"))
        XCTAssertTrue(listCmd.contains("tmux list-panes -a -F"))
        XCTAssertTrue(listCmd.contains("2>/dev/null || true"))
    }

    func testRemotePackageManagerDisplayNames() {
        XCTAssertEqual(
            TMuxSessionHelper.RemotePackageManager.allCases,
            [.brew, .apt, .dnf, .yum, .pacman, .apk, .zypper, .pkg, .unknown]
        )
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.brew.displayName, "Homebrew")
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.apt.displayName, "APT")
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.dnf.displayName, "DNF")
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.yum.displayName, "YUM")
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.pacman.displayName, "Pacman")
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.apk.displayName, "APK")
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.zypper.displayName, "Zypper")
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.pkg.displayName, "pkg")
        XCTAssertEqual(TMuxSessionHelper.RemotePackageManager.unknown.displayName, "Unknown")
    }

    func testCheckTmuxCommandAndParseTmuxAvailability() throws {
        let cmd = TMuxSessionHelper.checkTmuxCommand()
        XCTAssertFalse(cmd.contains("\n"))
        XCTAssertFalse(cmd.contains("\r"))
        XCTAssertTrue(cmd.contains("export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\""))
        XCTAssertTrue(cmd.contains("command -v tmux >/dev/null 2>&1"))
        XCTAssertTrue(cmd.contains("TMUX:INSTALLED"))
        XCTAssertTrue(cmd.contains("TMUX:MISSING"))
        XCTAssertTrue(cmd.contains("id -u"))
        XCTAssertTrue(cmd.contains("ROOT:1"))
        XCTAssertTrue(cmd.contains("ROOT:0"))
        for token in ["brew", "apt-get", "PM:apt", "dnf", "yum", "pacman", "apk", "zypper", "pkg", "PM:unknown"] {
            XCTAssertTrue(cmd.contains(token), "Missing expected token \(token) in checkTmuxCommand")
        }

        let macParsed = TMuxSessionHelper.parseTmuxAvailability(from: "TMUX:INSTALLED\nROOT:0\nPM:brew\n")
        XCTAssertEqual(
            macParsed,
            TMuxSessionHelper.TMuxAvailability(isInstalled: true, packageManager: .brew, isRoot: false)
        )

        let linuxMotd = """
        Welcome to Ubuntu 24.04.1 LTS\r
        Last login: Tue Nov 25 09:00:00 2026\r
        TMUX:MISSING\r
        ROOT:1\r
        PM:apt\r
        """
        XCTAssertEqual(
            TMuxSessionHelper.parseTmuxAvailability(from: linuxMotd),
            TMuxSessionHelper.TMuxAvailability(isInstalled: false, packageManager: .apt, isRoot: true)
        )

        for pm in TMuxSessionHelper.RemotePackageManager.allCases {
            let parsed = TMuxSessionHelper.parseTmuxAvailability(from: "TMUX:MISSING\nROOT:0\nPM:\(pm.rawValue)\n")
            XCTAssertEqual(parsed.packageManager, pm)
            XCTAssertFalse(parsed.isInstalled)
            XCTAssertFalse(parsed.isRoot)
        }

        let unrecognizedPM = TMuxSessionHelper.parseTmuxAvailability(from: "TMUX:MISSING\nROOT:0\nPM:nix\n")
        XCTAssertEqual(
            unrecognizedPM,
            TMuxSessionHelper.TMuxAvailability(isInstalled: false, packageManager: .unknown, isRoot: false)
        )

        XCTAssertEqual(
            TMuxSessionHelper.parseTmuxAvailability(from: ""),
            TMuxSessionHelper.TMuxAvailability(isInstalled: false, packageManager: .unknown, isRoot: false)
        )

        let encoded = try JSONEncoder().encode(macParsed)
        let decoded = try JSONDecoder().decode(TMuxSessionHelper.TMuxAvailability.self, from: encoded)
        XCTAssertEqual(decoded, macParsed)
    }

    func testInstallTmuxCommand() {
        let standardPATHPrefix = "export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; "

        // Unknown always returns nil.
        for isRoot in [false, true] {
            for interactive in [false, true] {
                XCTAssertNil(
                    TMuxSessionHelper.installTmuxCommand(packageManager: .unknown, isRoot: isRoot, interactive: interactive)
                )
            }
        }

        // Brew never uses sudo.
        for isRoot in [false, true] {
            for interactive in [false, true] {
                let cmd = TMuxSessionHelper.installTmuxCommand(packageManager: .brew, isRoot: isRoot, interactive: interactive)
                XCTAssertEqual(cmd, standardPATHPrefix + "brew install tmux")
                XCTAssertFalse(cmd?.contains("sudo") ?? true)
            }
        }

        // APT variants.
        XCTAssertEqual(
            TMuxSessionHelper.installTmuxCommand(packageManager: .apt, isRoot: true, interactive: false),
            standardPATHPrefix + "DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tmux"
        )
        XCTAssertEqual(
            TMuxSessionHelper.installTmuxCommand(packageManager: .apt, isRoot: true, interactive: true),
            standardPATHPrefix + "DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tmux"
        )
        XCTAssertEqual(
            TMuxSessionHelper.installTmuxCommand(packageManager: .apt, isRoot: false, interactive: false),
            standardPATHPrefix + "sudo -n sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tmux'"
        )
        XCTAssertEqual(
            TMuxSessionHelper.installTmuxCommand(packageManager: .apt, isRoot: false, interactive: true),
            standardPATHPrefix + "sudo apt-get update && sudo apt-get install -y tmux"
        )

        // Other Linux / BSD package managers.
        let expectations: [(TMuxSessionHelper.RemotePackageManager, String)] = [
            (.dnf, "dnf install -y tmux"),
            (.yum, "yum install -y tmux"),
            (.pacman, "pacman -Sy --noconfirm tmux"),
            (.apk, "apk add --no-cache tmux"),
            (.zypper, "zypper --non-interactive install tmux"),
            (.pkg, "pkg install -y tmux"),
        ]

        for (pm, baseCmd) in expectations {
            XCTAssertEqual(
                TMuxSessionHelper.installTmuxCommand(packageManager: pm, isRoot: true, interactive: false),
                standardPATHPrefix + baseCmd
            )
            XCTAssertEqual(
                TMuxSessionHelper.installTmuxCommand(packageManager: pm, isRoot: false, interactive: false),
                standardPATHPrefix + "sudo -n " + baseCmd
            )
            XCTAssertEqual(
                TMuxSessionHelper.installTmuxCommand(packageManager: pm, isRoot: false, interactive: true),
                standardPATHPrefix + "sudo " + baseCmd
            )
        }
    }

    func testSafeAttachCommand() {
        let cmd = TMuxSessionHelper.safeAttachCommand(sessionName: "termapp-ai-claude-app")
        XCTAssertFalse(cmd.contains("\n"))
        XCTAssertFalse(cmd.contains("\r"))
        XCTAssertTrue(cmd.contains("export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\""))
        XCTAssertTrue(cmd.contains("if command -v tmux >/dev/null 2>&1; then tmux attach-session -t '=termapp-ai-claude-app'; fi"))

        let odd = TMuxSessionHelper.safeAttachCommand(sessionName: "odd'name$(id)\r\nid")
        XCTAssertFalse(odd.contains("\n"))
        XCTAssertFalse(odd.contains("\r"))
        XCTAssertTrue(odd.contains("if command -v tmux >/dev/null 2>&1; then tmux attach-session -t '=odd'\\''name$(id)id'; fi"))
    }

    // MARK: - Output Parsing

    func testParseSessions() {
        XCTAssertEqual(TMuxSessionHelper.parseSessions(from: ""), [])
        XCTAssertEqual(TMuxSessionHelper.parseSessions(from: "\n   \n"), [])

        let sample = [
            "termapp-ai-claude-term-app\t1\t2\t1700000000\t1700000500\t/Users/me/term-app",
            "termapp-ai-agy-backend-api\t0\t1\t1700000100\t\t~/backend api",
            "dev-shell\t2\t3\t1700000200\t1700000600\t/tmp",
            "malformed-single-column",
            "termapp-ai-codex-broken\tnotanint\t1\t1700000000\t1700000000\t/tmp",
            "termapp-ai-aider-missingwindows\t0\tabc\t1700000000\t1700000000\t/tmp",
            "\t0\t1\t1700000000\t1700000000\t/tmp",
            "termapp-ai-opencode-minimal\t0\t1"
        ].joined(separator: "\n")

        let managedOnly = TMuxSessionHelper.parseSessions(from: sample, onlyTermAppManaged: true)
        XCTAssertEqual(managedOnly.count, 3)

        XCTAssertEqual(managedOnly[0].id, "termapp-ai-claude-term-app")
        XCTAssertEqual(managedOnly[0].sessionName, "termapp-ai-claude-term-app")
        XCTAssertEqual(managedOnly[0].agentSlug, "claude")
        XCTAssertEqual(managedOnly[0].projectSlug, "term-app")
        XCTAssertTrue(managedOnly[0].isAttached)
        XCTAssertEqual(managedOnly[0].windowCount, 2)
        XCTAssertEqual(managedOnly[0].createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(managedOnly[0].lastActivityAt, Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertEqual(managedOnly[0].currentPath, "/Users/me/term-app")

        XCTAssertEqual(managedOnly[1].agentSlug, "agy")
        XCTAssertEqual(managedOnly[1].projectSlug, "backend-api")
        XCTAssertFalse(managedOnly[1].isAttached)
        XCTAssertNil(managedOnly[1].lastActivityAt)
        XCTAssertEqual(managedOnly[1].currentPath, "~/backend api")

        XCTAssertEqual(managedOnly[2].agentSlug, "opencode")
        XCTAssertEqual(managedOnly[2].projectSlug, "minimal")
        XCTAssertNil(managedOnly[2].createdAt)
        XCTAssertNil(managedOnly[2].currentPath)

        let allSessions = TMuxSessionHelper.parseSessions(from: sample, onlyTermAppManaged: false)
        XCTAssertEqual(allSessions.count, 4)
        XCTAssertEqual(allSessions[2].sessionName, "dev-shell")
        XCTAssertEqual(allSessions[2].agentSlug, "")
        XCTAssertEqual(allSessions[2].projectSlug, "")
        XCTAssertFalse(allSessions[2].isTermAppManaged)
        XCTAssertNil(allSessions[2].detectedCommand)
        XCTAssertFalse(allSessions[2].isAISession)
        XCTAssertTrue(allSessions[2].isAttached)
        XCTAssertEqual(allSessions[2].windowCount, 3)
        XCTAssertEqual(allSessions[2].currentPath, "/tmp")
    }

    func testDiscoverArbitrarySessionsAndAutoDetectAgents() throws {
        let output = [
            "termapp-ai-claude-term-app\t1\t1\t1700000000\t1700000900\t/Users/me/term-app\tclaude",
            "dev\t1\t2\t1700000100\t1700000800\t/Users/me/my-service\tclaude",
            "0\t0\t1\t1700000200\t1700000700\t/srv/Api_V2\t/opt/homebrew/bin/CODEX",
            "ops\t0\t3\t1700000300\t1700000600\t/home/ubuntu\tzsh",
            "main\t0\t1\t1700000400\t1700000500\t/Users/me\t-zsh",
            "scratch\t1\t1\t1700000450\t1700000480\t/tmp\tnode",
            "custom-run\t0\t1\t1700000460\t1700000470\t/Users/me/goose-repo\tgoose",
            TMuxSessionHelper.panesBeginMarker,
            "ops\tzsh\t/home/ubuntu",
            "ops\t/usr/local/bin/agy\t/home/ubuntu/agent-workspace",
            "main\tbash\t/Users/me",
            "main\tvim\t/Users/me",
            "scratch\tnode\t/tmp",
        ].joined(separator: "\n")

        // Managed-only filter excludes non-termapp-ai sessions even if they run AI CLIs.
        let managedOnly = TMuxSessionHelper.parseSessions(from: output, onlyTermAppManaged: true)
        XCTAssertEqual(managedOnly.map(\.sessionName), ["termapp-ai-claude-term-app"])
        XCTAssertTrue(managedOnly[0].isTermAppManaged)
        XCTAssertEqual(managedOnly[0].detectedCommand, "claude")
        XCTAssertTrue(managedOnly[0].isAISession)

        // All sessions discovery + built-in and custom command detection.
        let sessions = TMuxSessionHelper.parseSessions(
            from: output,
            onlyTermAppManaged: false,
            knownCommands: ["goose": "goose-agent"]
        )
        XCTAssertEqual(sessions.count, 7)

        // 0: TermApp-managed session
        XCTAssertTrue(sessions[0].isTermAppManaged)
        XCTAssertTrue(sessions[0].isAISession)
        XCTAssertEqual(sessions[0].agentSlug, "claude")
        XCTAssertEqual(sessions[0].projectSlug, "term-app")
        XCTAssertEqual(sessions[0].detectedCommand, "claude")

        // 1: Arbitrary session "dev" running claude in 7th column
        XCTAssertEqual(sessions[1].sessionName, "dev")
        XCTAssertFalse(sessions[1].isTermAppManaged)
        XCTAssertTrue(sessions[1].isAISession)
        XCTAssertEqual(sessions[1].agentSlug, "claude")
        XCTAssertEqual(sessions[1].projectSlug, "my-service")
        XCTAssertEqual(sessions[1].detectedCommand, "claude")
        XCTAssertEqual(sessions[1].currentPath, "/Users/me/my-service")

        // 2: Numeric session "0" running /opt/homebrew/bin/CODEX (case-insensitive basename)
        XCTAssertEqual(sessions[2].sessionName, "0")
        XCTAssertFalse(sessions[2].isTermAppManaged)
        XCTAssertTrue(sessions[2].isAISession)
        XCTAssertEqual(sessions[2].agentSlug, "codex")
        XCTAssertEqual(sessions[2].projectSlug, "api-v2")
        XCTAssertEqual(sessions[2].detectedCommand, "codex")

        // 3: Multi-pane session "ops" where active pane is zsh but secondary pane runs agy
        XCTAssertEqual(sessions[3].sessionName, "ops")
        XCTAssertFalse(sessions[3].isTermAppManaged)
        XCTAssertTrue(sessions[3].isAISession)
        XCTAssertEqual(sessions[3].agentSlug, "agy")
        XCTAssertEqual(sessions[3].projectSlug, "agent-workspace")
        XCTAssertEqual(sessions[3].detectedCommand, "agy")
        XCTAssertEqual(sessions[3].currentPath, "/home/ubuntu/agent-workspace")

        // 4: General session "main" running -zsh / bash / vim (not AI)
        XCTAssertEqual(sessions[4].sessionName, "main")
        XCTAssertFalse(sessions[4].isTermAppManaged)
        XCTAssertFalse(sessions[4].isAISession)
        XCTAssertEqual(sessions[4].agentSlug, "")
        XCTAssertEqual(sessions[4].projectSlug, "main")
        XCTAssertEqual(sessions[4].detectedCommand, "zsh")

        // 5: General session "scratch" running node (not AI)
        XCTAssertEqual(sessions[5].sessionName, "scratch")
        XCTAssertFalse(sessions[5].isTermAppManaged)
        XCTAssertFalse(sessions[5].isAISession)
        XCTAssertEqual(sessions[5].agentSlug, "")
        XCTAssertEqual(sessions[5].projectSlug, "scratch")
        XCTAssertEqual(sessions[5].detectedCommand, "node")

        // 6: Custom preset CLI detected via knownCommands
        XCTAssertEqual(sessions[6].sessionName, "custom-run")
        XCTAssertFalse(sessions[6].isTermAppManaged)
        XCTAssertTrue(sessions[6].isAISession)
        XCTAssertEqual(sessions[6].agentSlug, "goose-agent")
        XCTAssertEqual(sessions[6].projectSlug, "goose-repo")
        XCTAssertEqual(sessions[6].detectedCommand, "goose")
    }

    func testAutoDetectAiderOpenCodeAndPathFallbacks() throws {
        let output = [
            "work\t0\t2\t1700000000\t1700000100\t\tzsh",
            "assist\t1\t1\t1700000000\t1700000200\t\topencode",
            TMuxSessionHelper.panesBeginMarker,
            "work\tzsh\t",
            "work\taider\t/srv/billing",
        ].joined(separator: "\n")

        let sessions = TMuxSessionHelper.parseSessions(from: output, onlyTermAppManaged: false)
        XCTAssertEqual(sessions.count, 2)

        XCTAssertEqual(sessions[0].sessionName, "work")
        XCTAssertEqual(sessions[0].agentSlug, "aider")
        XCTAssertEqual(sessions[0].projectSlug, "billing")
        XCTAssertEqual(sessions[0].currentPath, "/srv/billing")
        XCTAssertTrue(sessions[0].isAISession)

        XCTAssertEqual(sessions[1].sessionName, "assist")
        XCTAssertEqual(sessions[1].agentSlug, "opencode")
        XCTAssertEqual(sessions[1].projectSlug, "assist")
        XCTAssertNil(sessions[1].currentPath)
        XCTAssertTrue(sessions[1].isAISession)
    }

    func testRemoteAISessionDefaultsAndCodableBackwardCompatibility() throws {
        // Existing initializer defaults remain backward compatible.
        let defaultInitSession = TMuxSessionHelper.RemoteAISession(
            sessionName: "termapp-ai-claude-app",
            agentSlug: "claude",
            projectSlug: "app",
            isAttached: true,
            windowCount: 1
        )
        XCTAssertTrue(defaultInitSession.isTermAppManaged)
        XCTAssertNil(defaultInitSession.detectedCommand)
        XCTAssertTrue(defaultInitSession.isAISession)

        // Managed session whose agent exited to shell remains an AI session.
        let managedExited = TMuxSessionHelper.RemoteAISession(
            sessionName: "termapp-ai-codex-api",
            agentSlug: "codex",
            projectSlug: "api",
            isAttached: false,
            windowCount: 1,
            isTermAppManaged: true,
            detectedCommand: "zsh"
        )
        XCTAssertTrue(managedExited.isAISession)

        let encoded = try JSONEncoder().encode(managedExited)
        let decoded = try JSONDecoder().decode(TMuxSessionHelper.RemoteAISession.self, from: encoded)
        XCTAssertEqual(decoded, managedExited)

        // Legacy encoded payload lacking isTermAppManaged / detectedCommand decodes cleanly.
        let legacyJSON = """
        {"id":"dev","sessionName":"dev","agentSlug":"","projectSlug":"","isAttached":false,"windowCount":1}
        """
        let legacyDecoded = try JSONDecoder().decode(
            TMuxSessionHelper.RemoteAISession.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertFalse(legacyDecoded.isTermAppManaged)
        XCTAssertNil(legacyDecoded.detectedCommand)
        XCTAssertFalse(legacyDecoded.isAISession)
    }

    func testIsTmuxMissingAndListSessionsShellSyntax() throws {
        XCTAssertTrue(TMuxSessionHelper.isTmuxMissing(in: "TERMAPP_TMUX_MISSING\n"))
        XCTAssertTrue(TMuxSessionHelper.isTmuxMissing(in: "Welcome\r\nTERMAPP_TMUX_MISSING\r\n"))
        XCTAssertFalse(TMuxSessionHelper.isTmuxMissing(in: ""))
        XCTAssertFalse(TMuxSessionHelper.isTmuxMissing(in: "TERMAPP_PANES_BEGIN\n"))
        XCTAssertFalse(
            TMuxSessionHelper.isTmuxMissing(
                in: "TERMAPP_TMUX_MISSING\t0\t1\t1700000000\t1700000000\t/tmp\tzsh\nTERMAPP_PANES_BEGIN\n"
            )
        )
        XCTAssertTrue(TMuxSessionHelper.hasPanesBeginMarker(in: "TERMAPP_PANES_BEGIN\n"))
        XCTAssertTrue(TMuxSessionHelper.hasPanesBeginMarker(in: "sess\t0\t1\r\nTERMAPP_PANES_BEGIN\r\n"))
        XCTAssertFalse(TMuxSessionHelper.hasPanesBeginMarker(in: ""))
        XCTAssertFalse(TMuxSessionHelper.hasPanesBeginMarker(in: "sh -c '... TERMAPP_PANES_BEGIN ...'"))
        XCTAssertFalse(TMuxSessionHelper.hasPanesBeginMarker(in: "TERMAPP_TMUX_MISSING\n"))
        XCTAssertEqual(TMuxSessionHelper.parseSessions(from: "TERMAPP_TMUX_MISSING\n", onlyTermAppManaged: false), [])

        let cmd = TMuxSessionHelper.listSessionsCommand()
        XCTAssertFalse(cmd.contains("\n"))
        XCTAssertFalse(cmd.contains("\r"))
        XCTAssertTrue(cmd.hasPrefix("sh -c '"))
        XCTAssertTrue(cmd.hasSuffix("'"))
        XCTAssertEqual(cmd.filter { $0 == "'" }.count, 2)
        XCTAssertEqual(cmd.filter { $0 == "\"" }.count % 2, 0)
        XCTAssertTrue(cmd.contains("/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"))
        XCTAssertTrue(cmd.contains("${TMPDIR:-/tmp}"))
        XCTAssertTrue(cmd.contains("${TMUX_TMPDIR:-}"))
        XCTAssertTrue(cmd.contains("tmux -S \"$sock\" list-sessions -F"))
        XCTAssertTrue(cmd.contains("tmux -S \"$sock\" list-panes -a -F"))
        XCTAssertTrue(cmd.contains("if command -v tmux >/dev/null 2>&1; then "))
        XCTAssertTrue(cmd.contains("else printf \"TERMAPP_TMUX_MISSING\\n\"; fi"))

        #if os(macOS)
        for shellPath in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            let syntaxProc = Process()
            syntaxProc.executableURL = URL(fileURLWithPath: shellPath)
            syntaxProc.arguments = ["-n", "-c", cmd]
            try syntaxProc.run()
            syntaxProc.waitUntilExit()
            XCTAssertEqual(syntaxProc.terminationStatus, 0, "\(shellPath) -n failed on listSessionsCommand()")
        }

        let missingTmuxCmd = TMuxSessionHelper.listSessionsCommand(searchPath: "/usr/bin:/bin")
        for shellPath in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh"] {
            let execProc = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            execProc.executableURL = URL(fileURLWithPath: shellPath)
            execProc.arguments = ["-c", cmd]
            execProc.standardOutput = stdoutPipe
            execProc.standardError = stderrPipe
            try execProc.run()
            execProc.waitUntilExit()
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(execProc.terminationStatus, 0, "\(shellPath) -c failed: \(stderr)")
            XCTAssertTrue(
                TMuxSessionHelper.hasPanesBeginMarker(in: stdout) || TMuxSessionHelper.isTmuxMissing(in: stdout),
                "Expected completion sentinel or missing marker from \(shellPath), got: \(stdout)"
            )

            let missingProc = Process()
            let missingOut = Pipe()
            let missingErr = Pipe()
            missingProc.executableURL = URL(fileURLWithPath: shellPath)
            missingProc.arguments = ["-c", missingTmuxCmd]
            missingProc.standardOutput = missingOut
            missingProc.standardError = missingErr
            try missingProc.run()
            missingProc.waitUntilExit()
            let mOut = String(data: missingOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let mErr = String(data: missingErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(missingProc.terminationStatus, 0, "\(shellPath) -c missing-tmux failed: \(mErr)")
            XCTAssertTrue(TMuxSessionHelper.isTmuxMissing(in: mOut), "Expected TERMAPP_TMUX_MISSING from \(shellPath), got: \(mOut)")
        }
        #endif
    }

    func testListDirectoriesCommandAndParser() {
        let cmd = TMuxSessionHelper.listDirectoriesCommand(in: "~/my projects")
        XCTAssertTrue(cmd.contains("\"$HOME\"/'my projects'"))
        XCTAssertTrue(cmd.contains("PWD:%s"))

        let output = "PWD:/Users/alice/projects/\r\nalpha/\r\nbeta dir/\r\n.\r\n..\r\ngamma\r\n"
        let listing = TMuxSessionHelper.parseDirectoryListing(from: output)
        XCTAssertEqual(listing.currentPath, "/Users/alice/projects")
        XCTAssertEqual(listing.directories, ["alpha", "beta dir", "gamma"])

        let emptyDirOutput = "PWD:/\n"
        let rootListing = TMuxSessionHelper.parseDirectoryListing(from: emptyDirOutput)
        XCTAssertEqual(rootListing.currentPath, "/")
        XCTAssertEqual(rootListing.directories, [])

        let missingOutput = ""
        XCTAssertEqual(
            TMuxSessionHelper.parseDirectoryListing(from: missingOutput),
            TMuxSessionHelper.RemoteDirectoryListing(currentPath: "", directories: [])
        )
    }

    // MARK: - Bracketed Paste

    func testBracketedPastePayloadAndSanitization() {
        let multiLine = "First line\nSecond line\n  indented"
        let submitData = TMuxSessionHelper.bracketedPastePayload(for: multiLine, submit: true)
        XCTAssertEqual(
            String(data: submitData, encoding: .utf8),
            "\u{1B}[200~First line\nSecond line\n  indented\u{1B}[201~\r"
        )

        let noSubmitData = TMuxSessionHelper.bracketedPastePayload(for: multiLine, submit: false)
        XCTAssertEqual(
            String(data: noSubmitData, encoding: .utf8),
            "\u{1B}[200~First line\nSecond line\n  indented\u{1B}[201~"
        )

        let breakoutAttempt = "hello\u{1B}[201~; rm -rf /\u{1B}[2\u{1B}[201~01~\u{1B}[200~world"
        let sanitized = TMuxSessionHelper.bracketedPastePayload(for: breakoutAttempt, submit: true)
        let rendered = String(data: sanitized, encoding: .utf8)!
        XCTAssertEqual(rendered, "\u{1B}[200~hello; rm -rf /world\u{1B}[201~\r")
        XCTAssertEqual(rendered.components(separatedBy: "\u{1B}[201~").count - 1, 1)
        XCTAssertEqual(rendered.components(separatedBy: "\u{1B}[200~").count - 1, 1)
    }

    // MARK: - HostProjectStore

    func testHostProjectStoreFavoritesRecentsLastAgentAndCleanup() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostA = UUID()
        let hostB = UUID()

        // Initial empty state & corrupt fallback.
        XCTAssertEqual(HostProjectStore.favorites(for: hostA, defaults: defaults), [])
        XCTAssertEqual(HostProjectStore.recents(for: hostA, defaults: defaults), [])
        XCTAssertNil(HostProjectStore.lastAgentID(for: hostA, defaults: defaults))
        defaults.set(Data("corrupt-json".utf8), forKey: HostProjectStore.storageKey)
        XCTAssertEqual(HostProjectStore.favorites(for: hostA, defaults: defaults), [])

        // Favorites: ordering, normalization, dedup, removal.
        HostProjectStore.addFavorite("   ", for: hostA, defaults: defaults)
        HostProjectStore.addFavorite("~/code/app/", for: hostA, defaults: defaults)
        HostProjectStore.addFavorite("~/code/app", for: hostA, defaults: defaults)
        HostProjectStore.addFavorite("/srv/api", for: hostA, defaults: defaults)
        HostProjectStore.addFavorite("/", for: hostA, defaults: defaults)
        XCTAssertEqual(
            HostProjectStore.favorites(for: hostA, defaults: defaults),
            ["~/code/app", "/srv/api", "/"]
        )

        HostProjectStore.removeFavorite("/srv/api/", for: hostA, defaults: defaults)
        XCTAssertEqual(
            HostProjectStore.favorites(for: hostA, defaults: defaults),
            ["~/code/app", "/"]
        )

        // Recents: most-recent-first, dedup promotion, cap at 12.
        for i in 1...15 {
            HostProjectStore.recordRecent("/projects/p\(i)", for: hostA, defaults: defaults)
        }
        let recentsAfterCap = HostProjectStore.recents(for: hostA, defaults: defaults)
        XCTAssertEqual(recentsAfterCap.count, HostProjectStore.maxRecentsCount)
        XCTAssertEqual(recentsAfterCap.first, "/projects/p15")
        XCTAssertEqual(recentsAfterCap.last, "/projects/p4")

        // Re-recording an existing recent promotes it to index 0 without duplicating.
        HostProjectStore.recordRecent("/projects/p10/", for: hostA, defaults: defaults)
        let promoted = HostProjectStore.recents(for: hostA, defaults: defaults)
        XCTAssertEqual(promoted.count, HostProjectStore.maxRecentsCount)
        XCTAssertEqual(promoted.first, "/projects/p10")
        XCTAssertEqual(promoted.filter { $0 == "/projects/p10" }.count, 1)

        // Last-used agent per host.
        HostProjectStore.setLastAgentID("claude", for: hostA, defaults: defaults)
        HostProjectStore.setLastAgentID("agy", for: hostB, defaults: defaults)
        XCTAssertEqual(HostProjectStore.lastAgentID(for: hostA, defaults: defaults), "claude")
        XCTAssertEqual(HostProjectStore.lastAgentID(for: hostB, defaults: defaults), "agy")

        // Custom preset saved globally.
        let custom = CustomAIAgentPreset(name: "Custom", command: "my-agent")
        HostProjectStore.saveCustomPreset(custom, defaults: defaults)

        // deleteAll(for:) clears only hostA, leaving hostB and custom presets intact.
        HostProjectStore.deleteAll(for: hostA, defaults: defaults)
        XCTAssertEqual(HostProjectStore.favorites(for: hostA, defaults: defaults), [])
        XCTAssertEqual(HostProjectStore.recents(for: hostA, defaults: defaults), [])
        XCTAssertNil(HostProjectStore.lastAgentID(for: hostA, defaults: defaults))
        XCTAssertEqual(HostProjectStore.lastAgentID(for: hostB, defaults: defaults), "agy")
        XCTAssertEqual(HostProjectStore.customPresets(defaults: defaults), [custom])
    }

    func testHostProjectStoreCustomPresetsCRUDAndAllPresets() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        XCTAssertEqual(HostProjectStore.customPresets(defaults: defaults), [])
        XCTAssertEqual(HostProjectStore.allPresets(defaults: defaults), AIAgentDescriptor.builtIns)

        var first = CustomAIAgentPreset(name: "Goose", command: "goose", defaultArgs: "session", symbolName: "bird")
        let second = CustomAIAgentPreset(name: "Cursor CLI", command: "cursor-agent")

        HostProjectStore.saveCustomPreset(first, defaults: defaults)
        HostProjectStore.saveCustomPreset(second, defaults: defaults)
        XCTAssertEqual(HostProjectStore.customPresets(defaults: defaults), [first, second])

        // Update in place by matching ID.
        first.defaultArgs = "session --resume"
        first.name = "Goose Pro"
        HostProjectStore.saveCustomPreset(first, defaults: defaults)
        XCTAssertEqual(HostProjectStore.customPresets(defaults: defaults), [first, second])

        let all = HostProjectStore.allPresets(defaults: defaults)
        XCTAssertEqual(all.count, 7)
        XCTAssertEqual(all.prefix(5).map(\.id), ["claude", "agy", "codex", "aider", "opencode"])
        XCTAssertEqual(all[5].id, first.id.uuidString)
        XCTAssertEqual(all[5].name, "Goose Pro")
        XCTAssertEqual(all[5].defaultArgs, "session --resume")
        XCTAssertFalse(all[5].isBuiltIn)
        XCTAssertEqual(all[6].id, second.id.uuidString)

        // Delete unknown ID is a no-op; delete known removes it cleanly.
        HostProjectStore.deleteCustomPreset(id: UUID(), defaults: defaults)
        XCTAssertEqual(HostProjectStore.customPresets(defaults: defaults).count, 2)

        HostProjectStore.deleteCustomPreset(id: first.id, defaults: defaults)
        XCTAssertEqual(HostProjectStore.customPresets(defaults: defaults), [second])
    }

    // MARK: - AISessionCacheStore

    func testCachedAISessionIdentityIsAISessionAndCodable() throws {
        let hostID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_001_000)

        let managed = CachedAISession(
            hostID: hostID,
            hostLabel: "Prod Box",
            sessionName: "termapp-ai-claude-repo",
            agentSlug: "claude",
            projectSlug: "repo",
            currentPath: "~/repo",
            isTermAppManaged: true,
            detectedCommand: "claude",
            lastSeenAt: timestamp,
            wasOpenInApp: true
        )
        XCTAssertEqual(managed.id, "\(hostID.uuidString):termapp-ai-claude-repo")
        XCTAssertTrue(managed.isAISession)

        let unmanagedAI = CachedAISession(
            hostID: hostID,
            hostLabel: "Prod Box",
            sessionName: "dev",
            agentSlug: "codex",
            projectSlug: "api",
            isTermAppManaged: false,
            detectedCommand: "codex",
            lastSeenAt: timestamp
        )
        XCTAssertTrue(unmanagedAI.isAISession)

        let generalShell = CachedAISession(
            hostID: hostID,
            hostLabel: "Prod Box",
            sessionName: "main",
            agentSlug: "",
            projectSlug: "main",
            isTermAppManaged: false,
            detectedCommand: "zsh",
            lastSeenAt: timestamp
        )
        XCTAssertFalse(generalShell.isAISession)

        let encoded = try JSONEncoder().encode(managed)
        let decoded = try JSONDecoder().decode(CachedAISession.self, from: encoded)
        XCTAssertEqual(decoded, managed)
    }

    func testAISessionCacheStoreUpsertSortingAndCorruptFallback() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults), [])
        XCTAssertNil(AISessionCacheStore.lastOpenSession(defaults: defaults))

        defaults.set(Data("not-valid-json".utf8), forKey: AISessionCacheStore.storageKey)
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults), [])

        let hostA = UUID()
        let hostB = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_200)
        let t3 = Date(timeIntervalSince1970: 1_700_000_300)

        let older = CachedAISession(
            hostID: hostA,
            hostLabel: "Alpha",
            sessionName: "termapp-ai-claude-app",
            agentSlug: "claude",
            projectSlug: "app",
            currentPath: "~/app",
            lastSeenAt: t1,
            wasOpenInApp: true
        )
        let sameNameDifferentHost = CachedAISession(
            hostID: hostB,
            hostLabel: "Beta",
            sessionName: "termapp-ai-claude-app",
            agentSlug: "claude",
            projectSlug: "app",
            currentPath: "/srv/app",
            lastSeenAt: t2,
            wasOpenInApp: false
        )

        AISessionCacheStore.upsert(older, defaults: defaults)
        AISessionCacheStore.upsert(sameNameDifferentHost, defaults: defaults)

        let loaded = AISessionCacheStore.load(defaults: defaults)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.hostID), [hostB, hostA])

        // Upsert with matching (hostID, sessionName) updates in place and re-sorts.
        var updatedOlder = older
        updatedOlder.lastSeenAt = t3
        updatedOlder.currentPath = "~/app-v2"
        AISessionCacheStore.upsert(updatedOlder, defaults: defaults)

        let reloaded = AISessionCacheStore.load(defaults: defaults)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.first, updatedOlder)
    }

    func testAISessionCacheStoreReplaceRemoteSessionsPreservesOpenAndPrunesExited() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostA = UUID()
        let hostB = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_200)
        let t3 = Date(timeIntervalSince1970: 1_700_000_300)

        let openSurviving = CachedAISession(
            hostID: hostA,
            hostLabel: "Host A",
            sessionName: "termapp-ai-claude-api",
            agentSlug: "claude",
            projectSlug: "api",
            lastSeenAt: t1,
            wasOpenInApp: true
        )
        let openExited = CachedAISession(
            hostID: hostA,
            hostLabel: "Host A",
            sessionName: "termapp-ai-codex-old",
            agentSlug: "codex",
            projectSlug: "old",
            lastSeenAt: t2,
            wasOpenInApp: true
        )
        let otherHostSession = CachedAISession(
            hostID: hostB,
            hostLabel: "Host B",
            sessionName: "termapp-ai-agy-web",
            agentSlug: "agy",
            projectSlug: "web",
            lastSeenAt: t1,
            wasOpenInApp: true
        )

        AISessionCacheStore.upsert(openSurviving, defaults: defaults)
        AISessionCacheStore.upsert(openExited, defaults: defaults)
        AISessionCacheStore.upsert(otherHostSession, defaults: defaults)

        // Live tmux scan for hostA sees openSurviving (as discovered with wasOpenInApp: false) + a new session.
        let discoveredSurviving = CachedAISession(
            hostID: hostA,
            hostLabel: "Host A",
            sessionName: "termapp-ai-claude-api",
            agentSlug: "claude",
            projectSlug: "api",
            currentPath: "/srv/api",
            lastSeenAt: t3,
            wasOpenInApp: false
        )
        let newlyDiscovered = CachedAISession(
            hostID: hostA,
            hostLabel: "Host A",
            sessionName: "termapp-ai-aider-cli",
            agentSlug: "aider",
            projectSlug: "cli",
            lastSeenAt: t2,
            wasOpenInApp: false
        )
        // Cross-host entry accidentally included should be ignored for hostA replacement.
        let wrongHostEntry = CachedAISession(
            hostID: hostB,
            hostLabel: "Host B",
            sessionName: "should-be-ignored",
            agentSlug: "claude",
            projectSlug: "x",
            lastSeenAt: t3,
            wasOpenInApp: false
        )

        AISessionCacheStore.replaceRemoteSessions(
            for: hostA,
            with: [discoveredSurviving, newlyDiscovered, wrongHostEntry],
            defaults: defaults
        )

        let all = AISessionCacheStore.load(defaults: defaults)
        XCTAssertEqual(all.count, 3)

        // Exited session on hostA was pruned.
        XCTAssertFalse(all.contains { $0.hostID == hostA && $0.sessionName == "termapp-ai-codex-old" })

        // Surviving session kept wasOpenInApp = true and updated path/timestamp.
        let surviving = all.first { $0.hostID == hostA && $0.sessionName == "termapp-ai-claude-api" }
        XCTAssertEqual(surviving?.wasOpenInApp, true)
        XCTAssertEqual(surviving?.currentPath, "/srv/api")
        XCTAssertEqual(surviving?.lastSeenAt, t3)

        // Newly discovered session remains wasOpenInApp = false.
        let discovered = all.first { $0.hostID == hostA && $0.sessionName == "termapp-ai-aider-cli" }
        XCTAssertEqual(discovered?.wasOpenInApp, false)

        // Other host's entries were untouched.
        XCTAssertEqual(all.filter { $0.hostID == hostB }, [otherHostSession])

        // Replacing hostA with [] clears only hostA.
        AISessionCacheStore.replaceRemoteSessions(for: hostA, with: [], defaults: defaults)
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults), [otherHostSession])
    }

    func testAISessionCacheStoreMarkOpenRemoveRemoveAllAndLastOpen() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostA = UUID()
        let hostB = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_200)
        let t3 = Date(timeIntervalSince1970: 1_700_000_300)

        let s1 = CachedAISession(
            hostID: hostA,
            hostLabel: "A",
            sessionName: "shared-name",
            agentSlug: "claude",
            projectSlug: "p1",
            lastSeenAt: t1,
            wasOpenInApp: true
        )
        let s2 = CachedAISession(
            hostID: hostA,
            hostLabel: "A",
            sessionName: "termapp-ai-codex-p2",
            agentSlug: "codex",
            projectSlug: "p2",
            lastSeenAt: t3,
            wasOpenInApp: false
        )
        let s3 = CachedAISession(
            hostID: hostB,
            hostLabel: "B",
            sessionName: "shared-name",
            agentSlug: "agy",
            projectSlug: "p3",
            lastSeenAt: t2,
            wasOpenInApp: true
        )

        AISessionCacheStore.upsert(s1, defaults: defaults)
        AISessionCacheStore.upsert(s2, defaults: defaults)
        AISessionCacheStore.upsert(s3, defaults: defaults)

        // Only open-in-app sessions are returned, sorted most-recent first.
        XCTAssertEqual(AISessionCacheStore.openInAppSessions(defaults: defaults).map(\.hostID), [hostB, hostA])
        XCTAssertEqual(AISessionCacheStore.lastOpenSession(defaults: defaults), s3)

        // Mark s2 open -> becomes lastOpenSession.
        AISessionCacheStore.markOpenInApp(true, hostID: hostA, sessionName: "termapp-ai-codex-p2", defaults: defaults)
        XCTAssertEqual(AISessionCacheStore.lastOpenSession(defaults: defaults)?.sessionName, "termapp-ai-codex-p2")

        // Marking a nonexistent session is a no-op.
        AISessionCacheStore.markOpenInApp(true, hostID: hostA, sessionName: "does-not-exist", defaults: defaults)
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults).count, 3)

        // Dismiss s2 -> falls back to s3.
        AISessionCacheStore.markOpenInApp(false, hostID: hostA, sessionName: "termapp-ai-codex-p2", defaults: defaults)
        XCTAssertEqual(AISessionCacheStore.lastOpenSession(defaults: defaults), s3)

        // Remove only hostB's "shared-name" -> hostA's "shared-name" remains.
        AISessionCacheStore.remove(hostID: hostB, sessionName: "shared-name", defaults: defaults)
        XCTAssertEqual(AISessionCacheStore.lastOpenSession(defaults: defaults), s1)
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults).count, 2)

        // Re-add s3 and removeAll for hostA -> only hostB remains.
        AISessionCacheStore.upsert(s3, defaults: defaults)
        AISessionCacheStore.removeAll(for: hostA, defaults: defaults)
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults), [s3])
        XCTAssertEqual(AISessionCacheStore.lastOpenSession(defaults: defaults), s3)
    }
}
