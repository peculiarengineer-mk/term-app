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
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "~/my projects/term's"), "\"$HOME\"/'my projects/term'\\''s'")
        XCTAssertEqual(TMuxSessionHelper.shellPathExpression(for: "/srv/app $(evil)"), "'/srv/app $(evil)'")
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
    }

    func testAttachKillAndListCommands() {
        XCTAssertTrue(
            TMuxSessionHelper.attachCommand(sessionName: "termapp-ai-claude-app")
                .contains("tmux attach-session -t 'termapp-ai-claude-app'")
        )
        XCTAssertTrue(
            TMuxSessionHelper.attachCommand(sessionName: "odd'name")
                .contains("tmux attach-session -t 'odd'\\''name'")
        )
        XCTAssertTrue(
            TMuxSessionHelper.killSessionCommand(sessionName: "termapp-ai-agy-repo")
                .contains("tmux kill-session -t 'termapp-ai-agy-repo'")
        )

        let listCmd = TMuxSessionHelper.listSessionsCommand()
        XCTAssertTrue(listCmd.contains("tmux list-sessions -F"))
        XCTAssertTrue(listCmd.contains("#{session_name}"))
        XCTAssertTrue(listCmd.contains("#{session_attached}"))
        XCTAssertTrue(listCmd.contains("#{session_windows}"))
        XCTAssertTrue(listCmd.contains("#{session_created}"))
        XCTAssertTrue(listCmd.contains("#{session_activity}"))
        XCTAssertTrue(listCmd.contains("#{pane_current_path}"))
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
        XCTAssertTrue(cmd.contains("if command -v tmux >/dev/null 2>&1; then tmux attach-session -t 'termapp-ai-claude-app'; fi"))

        let odd = TMuxSessionHelper.safeAttachCommand(sessionName: "odd'name$(id)")
        XCTAssertTrue(odd.contains("if command -v tmux >/dev/null 2>&1; then tmux attach-session -t 'odd'\\''name$(id)'; fi"))
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
        XCTAssertTrue(allSessions[2].isAttached)
        XCTAssertEqual(allSessions[2].windowCount, 3)
        XCTAssertEqual(allSessions[2].currentPath, "/tmp")
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
}
