import Foundation
import XCTest
@testable import Store

final class VibeCoderTests: XCTestCase {
    // MARK: - GitDiffHelper

    func testStatusAndDiffCommandStructureAndQuoting() {
        let cmd = GitDiffHelper.statusAndDiffCommand(in: "~/my projects/term's")
        XCTAssertFalse(cmd.contains("\n"))
        XCTAssertFalse(cmd.contains("\r"))
        XCTAssertTrue(cmd.contains("\"$HOME\"/'my projects/term'\\''s'"))
        XCTAssertTrue(cmd.contains("NOT_A_GIT_REPO"))
        XCTAssertTrue(cmd.contains("TERMAPP_GIT_ROOT:"))
        XCTAssertTrue(cmd.contains("TERMAPP_GIT_BRANCH:"))
        XCTAssertTrue(cmd.contains("TERMAPP_GIT_STATUS_BEGIN"))
        XCTAssertTrue(cmd.contains("TERMAPP_GIT_STATUS_END"))
        XCTAssertTrue(cmd.contains("TERMAPP_GIT_DIFF_BEGIN"))
        XCTAssertTrue(cmd.contains("TERMAPP_GIT_DIFF_END"))
        XCTAssertTrue(cmd.contains("git rev-parse --show-toplevel"))
        XCTAssertTrue(cmd.contains("git symbolic-ref --short HEAD"))
        XCTAssertTrue(cmd.contains("git status --porcelain=v1"))
        XCTAssertTrue(cmd.contains("git diff HEAD --no-color"))
        XCTAssertTrue(cmd.contains("git diff --no-color"))

        let evilCmd = GitDiffHelper.statusAndDiffCommand(in: "/srv/$(rm -rf /)/app")
        XCTAssertTrue(evilCmd.contains("'/srv/$(rm -rf /)/app'"))
    }

    func testStageCommitAndDiscardCommandsQuoting() {
        let commitCmd = GitDiffHelper.stageAndCommitCommand(
            in: "~/code/app",
            message: "fix: handle 'single' \"double\" `tick` $(sub)\nline2"
        )
        XCTAssertTrue(commitCmd.contains("\"$HOME\"/'code/app'"))
        XCTAssertTrue(commitCmd.contains("git add -A && git commit -m 'fix: handle '\\''single'\\'' \"double\" `tick` $(sub)\nline2'"))

        let trackedDiscard = GitDiffHelper.discardFileCommand(
            in: "/srv/repo",
            path: "Sources/It's Bad.swift",
            isUntracked: false
        )
        XCTAssertTrue(trackedDiscard.contains("cd -- '/srv/repo' && git checkout -- 'Sources/It'\\''s Bad.swift'"))

        let untrackedDiscard = GitDiffHelper.discardFileCommand(
            in: "~/repo",
            path: "notes $(id).txt",
            isUntracked: true
        )
        XCTAssertTrue(untrackedDiscard.contains("cd -- \"$HOME\"/'repo' && rm -f -- 'notes $(id).txt'"))
    }

    func testParseSnapshotFullAndEdgeCases() {
        XCTAssertEqual(GitDiffHelper.parseSnapshot(from: ""), GitRepoSnapshot(isGitRepo: false))
        XCTAssertEqual(
            GitDiffHelper.parseSnapshot(from: "Welcome!\nNOT_A_GIT_REPO\n"),
            GitRepoSnapshot(isGitRepo: false)
        )

        let rawOutput = """
        Last login: Wed Nov 25 10:00:00 2026\r
        TERMAPP_GIT_ROOT:/srv/term-app\r
        TERMAPP_GIT_BRANCH:feature/vibe-toolkit\r
        TERMAPP_GIT_STATUS_BEGIN\r
         M Sources/Existing.swift\r
        M  Sources/Staged.swift\r
        A  Sources/NewFile.swift\r
         D Sources/Deleted.swift\r
        R  Sources/OldName.swift -> Sources/NewName.swift\r
        ?? Scratch/Notes.md\r
        TERMAPP_GIT_STATUS_END\r
        TERMAPP_GIT_DIFF_BEGIN\r
        diff --git a/Sources/Existing.swift b/Sources/Existing.swift\r
        index 1111111..2222222 100644\r
        --- a/Sources/Existing.swift\r
        +++ b/Sources/Existing.swift\r
        @@ -1,3 +1,4 @@\r
         import Foundation\r
        -let oldVal = 1\r
        +let newVal = 2\r
        +let extraVal = 3\r
        diff --git a/Sources/NewFile.swift b/Sources/NewFile.swift\r
        new file mode 100644\r
        index 0000000..3333333\r
        --- /dev/null\r
        +++ b/Sources/NewFile.swift\r
        @@ -0,0 +1,2 @@\r
        +struct NewFile {}\r
        +// ok\r
        diff --git a/Sources/Deleted.swift b/Sources/Deleted.swift\r
        deleted file mode 100644\r
        index 4444444..0000000\r
        --- a/Sources/Deleted.swift\r
        +++ /dev/null\r
        @@ -1 +0,0 @@\r
        -let obsolete = true\r
        TERMAPP_GIT_DIFF_END\r
        """

        let snapshot = GitDiffHelper.parseSnapshot(from: rawOutput)
        XCTAssertTrue(snapshot.isGitRepo)
        XCTAssertEqual(snapshot.repoRoot, "/srv/term-app")
        XCTAssertEqual(snapshot.branch, "feature/vibe-toolkit")
        XCTAssertEqual(snapshot.files.count, 6)

        XCTAssertEqual(snapshot.files[0], GitChangedFile(
            path: "Sources/Existing.swift",
            indexStatus: " ",
            workTreeStatus: "M",
            isStaged: false,
            isUntracked: false,
            displayBadge: "M"
        ))
        XCTAssertEqual(snapshot.files[1], GitChangedFile(
            path: "Sources/Staged.swift",
            indexStatus: "M",
            workTreeStatus: " ",
            isStaged: true,
            isUntracked: false,
            displayBadge: "M"
        ))
        XCTAssertEqual(snapshot.files[2], GitChangedFile(
            path: "Sources/NewFile.swift",
            indexStatus: "A",
            workTreeStatus: " ",
            isStaged: true,
            isUntracked: false,
            displayBadge: "A"
        ))
        XCTAssertEqual(snapshot.files[3], GitChangedFile(
            path: "Sources/Deleted.swift",
            indexStatus: " ",
            workTreeStatus: "D",
            isStaged: false,
            isUntracked: false,
            displayBadge: "D"
        ))
        XCTAssertEqual(snapshot.files[4], GitChangedFile(
            path: "Sources/NewName.swift",
            indexStatus: "R",
            workTreeStatus: " ",
            isStaged: true,
            isUntracked: false,
            displayBadge: "R"
        ))
        XCTAssertEqual(snapshot.files[5], GitChangedFile(
            path: "Scratch/Notes.md",
            indexStatus: "?",
            workTreeStatus: "?",
            isStaged: false,
            isUntracked: true,
            displayBadge: "??"
        ))

        XCTAssertEqual(snapshot.diffs.count, 3)

        let firstDiff = snapshot.diffs[0]
        XCTAssertEqual(firstDiff.id, "Sources/Existing.swift")
        XCTAssertEqual(firstDiff.additions, 2)
        XCTAssertEqual(firstDiff.deletions, 1)
        XCTAssertEqual(firstDiff.lines.map(\.kind), [
            .header, .header, .header, .header,
            .hunk, .context, .removed, .added, .added,
        ])

        let secondDiff = snapshot.diffs[1]
        XCTAssertEqual(secondDiff.path, "Sources/NewFile.swift")
        XCTAssertEqual(secondDiff.additions, 2)
        XCTAssertEqual(secondDiff.deletions, 0)

        let thirdDiff = snapshot.diffs[2]
        XCTAssertEqual(thirdDiff.path, "Sources/Deleted.swift")
        XCTAssertEqual(thirdDiff.additions, 0)
        XCTAssertEqual(thirdDiff.deletions, 1)
        XCTAssertTrue(snapshot.rawDiff.contains("diff --git a/Sources/Existing.swift"))
    }

    func testParsePorcelainAndUnifiedDiffEdgeCases() {
        let porcelain = """
        MM Sources/Both.swift
        C  Sources/Orig.swift -> Sources/Copy.swift
        M  "dir/quoted file.txt"
        R  "old name.txt" -> "new name.txt"
        """
        let files = GitDiffHelper.parsePorcelainStatus(porcelain)
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(files[0].path, "Sources/Both.swift")
        XCTAssertTrue(files[0].isStaged)
        XCTAssertEqual(files[0].displayBadge, "M")
        XCTAssertEqual(files[1].path, "Sources/Copy.swift")
        XCTAssertEqual(files[1].displayBadge, "A")
        XCTAssertEqual(files[2].path, "dir/quoted file.txt")
        XCTAssertTrue(files[2].isStaged)
        XCTAssertEqual(files[2].displayBadge, "M")
        XCTAssertEqual(files[3].path, "new name.txt")
        XCTAssertEqual(files[3].displayBadge, "R")

        let diff = """
        diff --git a/dir/my file.txt b/dir/my file.txt
        index 1234567..89abcdef 100644
        --- a/dir/my file.txt
        +++ b/dir/my file.txt
        @@ -1 +1 @@
        -before
        +after
        \\ No newline at end of file
        diff --git a/old name.swift b/new name.swift
        similarity index 90%
        rename from old name.swift
        rename to new name.swift
        --- a/old name.swift
        +++ b/new name.swift
        @@ -1 +1 @@
        -let x = 1
        +let x = 2
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..abcdef1
        Binary files /dev/null and b/logo.png differ
        """

        let parsed = GitDiffHelper.parseUnifiedDiff(diff)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].path, "dir/my file.txt")
        XCTAssertEqual(parsed[0].additions, 1)
        XCTAssertEqual(parsed[0].deletions, 1)
        XCTAssertEqual(parsed[0].lines.last?.kind, .header)

        XCTAssertEqual(parsed[1].path, "new name.swift")
        XCTAssertEqual(parsed[1].additions, 1)
        XCTAssertEqual(parsed[1].deletions, 1)

        XCTAssertEqual(parsed[2].path, "logo.png")
        XCTAssertEqual(parsed[2].additions, 0)
        XCTAssertEqual(parsed[2].deletions, 0)
        XCTAssertTrue(parsed[2].lines.allSatisfy { $0.kind == .header })
    }

    // MARK: - ListeningPortsHelper

    func testListListeningPortsCommand() {
        let cmd = ListeningPortsHelper.listListeningPortsCommand()
        XCTAssertFalse(cmd.contains("\n"))
        XCTAssertTrue(cmd.contains("ss -tlnp"))
        XCTAssertTrue(cmd.contains("ss -tln"))
        XCTAssertTrue(cmd.contains("lsof -nP -iTCP -sTCP:LISTEN"))
        XCTAssertTrue(cmd.contains("netstat -tln"))
        XCTAssertTrue(cmd.contains("|| true"))
        XCTAssertEqual(
            ListeningPortsHelper.commonDevPorts,
            [3000, 3001, 3002, 4000, 4200, 4321, 5000, 5173, 5174, 5175, 8000, 8080, 8081, 8443, 8888, 9000, 1313]
        )
    }

    func testParseLinuxSSOutputDedupExclusionAndSorting() {
        let ssOutput = """
        State   Recv-Q  Send-Q   Local Address:Port     Peer Address:Port  Process
        LISTEN  0       128            0.0.0.0:22            0.0.0.0:*      users:(("sshd",pid=100,fd=3))
        LISTEN  0       128               [::]:22               [::]:*      users:(("sshd",pid=100,fd=4))
        LISTEN  0       511          127.0.0.1:9999          0.0.0.0:*      users:(("postgres",pid=200,fd=5))
        LISTEN  0       511          127.0.0.1:3000          0.0.0.0:*
        LISTEN  0       511          127.0.0.1:3000          0.0.0.0:*      users:(("node",pid=1234,fd=20))
        LISTEN  0       128              [::1]:5173             [::]:*      users:(("vite",pid=2345,fd=21))
        LISTEN  0       128                  *:8080                *:*      users:(("python3",pid=999,fd=3))
        LISTEN  0       128          127.0.0.1:4567          0.0.0.0:*      users:(("uvicorn",pid=3333,fd=9))
        """

        let ports = ListeningPortsHelper.parseListeningPorts(from: ssOutput)
        XCTAssertFalse(ports.contains(where: { $0.port == 22 }))
        XCTAssertEqual(ports.map(\.port), [3000, 4567, 5173, 8080, 9999])

        XCTAssertEqual(ports[0], ListeningPort(port: 3000, address: "127.0.0.1", processName: "node", isLikelyDevServer: true))
        XCTAssertEqual(ports[1], ListeningPort(port: 4567, address: "127.0.0.1", processName: "uvicorn", isLikelyDevServer: true))
        XCTAssertEqual(ports[2], ListeningPort(port: 5173, address: "::1", processName: "vite", isLikelyDevServer: true))
        XCTAssertEqual(ports[3], ListeningPort(port: 8080, address: "*", processName: "python3", isLikelyDevServer: true))
        XCTAssertEqual(ports[4], ListeningPort(port: 9999, address: "127.0.0.1", processName: "postgres", isLikelyDevServer: false))

        let withSSH = ListeningPortsHelper.parseListeningPorts(from: ssOutput, includeSSH: true)
        XCTAssertTrue(withSSH.contains(where: { $0.port == 22 }))
    }

    func testParseMacOSLsofOutput() {
        let lsofOutput = """
        COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        sshd      111   root    3u  IPv4 0x1111111111111111      0t0  TCP *:22 (LISTEN)
        node     1234  alice   20u  IPv4 0x2222222222222222      0t0  TCP 127.0.0.1:3000 (LISTEN)
        Python   1235  alice    5u  IPv6 0x3333333333333333      0t0  TCP [::1]:8000 (LISTEN)
        ruby     1236  alice    7u  IPv4 0x4444444444444444      0t0  TCP *:4500 (LISTEN)
        ControlCe 400  alice   10u  IPv4 0x5555555555555555      0t0  TCP *:7000 (LISTEN)
        """

        let ports = ListeningPortsHelper.parseListeningPorts(from: lsofOutput)
        XCTAssertEqual(ports.map(\.port), [3000, 4500, 8000, 7000])
        XCTAssertEqual(ports[0].processName, "node")
        XCTAssertTrue(ports[0].isLikelyDevServer)
        XCTAssertEqual(ports[1].processName, "ruby")
        XCTAssertTrue(ports[1].isLikelyDevServer)
        XCTAssertEqual(ports[2].address, "::1")
        XCTAssertEqual(ports[3].processName, "ControlCe")
        XCTAssertFalse(ports[3].isLikelyDevServer)
    }

    func testParseNetstatOutputAndDevProcessEdgeCases() {
        let netstatOutput = """
        Active Internet connections (only servers)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State
        tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN
        tcp        0      0 127.0.0.1:5432          0.0.0.0:*               LISTEN
        tcp        0      0 127.0.0.1:5173          0.0.0.0:*               LISTEN
        tcp6       0      0 :::8080                 :::*                    LISTEN
        tcp6       0      0 ::1:3001                :::*                    LISTEN
        """

        let ports = ListeningPortsHelper.parseListeningPorts(from: netstatOutput)
        XCTAssertEqual(ports.map(\.port), [3001, 5173, 8080, 5432])
        XCTAssertEqual(ports.map(\.isLikelyDevServer), [true, true, true, false])
        XCTAssertEqual(ports[2].address, "::")
        XCTAssertEqual(ports[3].address, "127.0.0.1")

        let processCases = """
        LISTEN 0 128 127.0.0.1:27017 0.0.0.0:* users:(("mongod",pid=1,fd=1))
        LISTEN 0 128 127.0.0.1:7777  0.0.0.0:* users:(("go",pid=2,fd=2))
        LISTEN 0 128 127.0.0.1:7778  0.0.0.0:* users:(("bun",pid=3,fd=3))
        LISTEN 0 128 127.0.0.1:7779  0.0.0.0:* users:(("ubuntu-daemon",pid=4,fd=4))
        LISTEN 0 128 127.0.0.1:7780  0.0.0.0:* users:(("webpack-dev-server",pid=5,fd=5))
        """
        let procPorts = ListeningPortsHelper.parseListeningPorts(from: processCases)
        XCTAssertEqual(procPorts.map(\.port), [7777, 7778, 7780, 7779, 27017])
        XCTAssertEqual(procPorts.map(\.isLikelyDevServer), [true, true, true, false, false])
    }

    // MARK: - AgentActivityDetector

    func testStripANSIAndControlCharacters() {
        let csiAndOsc = "\u{1B}]0;claude — ~/repo\u{07}\u{1B}[32mHello\u{1B}[0m\t\u{1B}[1;34mWorld\u{1B}[0m\r\nNext line\u{1B}]8;;https://example.com\u{1B}\\ link\u{1B}]8;;\u{1B}\\\u{00}\u{08}"
        XCTAssertEqual(AgentActivityDetector.stripANSI(csiAndOsc), "Hello\tWorld\nNext line link")
    }

    func testDetectApprovalPromptPatternsAndNonMatches() {
        let claudePrompt = """
        \u{1B}[36mBash\u{1B}[0m: npm test
        ╭──────────────────────────────────────╮
        │ Do you want to proceed?              │
        │ ❯ 1. Yes                             │
        │   2. Allow always                    │
        ╰──────────────────────────────────────╯
        """
        XCTAssertEqual(AgentActivityDetector.detectApprovalPrompt(in: claudePrompt), "Do you want to proceed?")

        let cliYesNo = "Compiling module...\nApply patch to 3 files? [y/N] "
        XCTAssertEqual(AgentActivityDetector.detectApprovalPrompt(in: cliYesNo), "Apply patch to 3 files? [y/N]")

        let patterns = [
            "Continue? [Y/n]",
            "Overwrite file? (y/n)",
            "Allow once for this tool call",
            "Allow always for this repository",
            "Press Enter to continue",
            "Approve?",
            "Confirm?",
            "Would you like to run tests now?",
            "Esc to cancel · Enter to confirm",
        ]
        for pattern in patterns {
            XCTAssertNotNil(
                AgentActivityDetector.detectApprovalPrompt(in: "\u{1B}[33m\(pattern)\u{1B}[0m"),
                "Expected match for: \(pattern)"
            )
        }

        let longPrompt = "Would you like to " + String(repeating: "very-long-argument-", count: 10) + "?"
        let snippet = AgentActivityDetector.detectApprovalPrompt(in: longPrompt)
        XCTAssertNotNil(snippet)
        XCTAssertLessThanOrEqual(snippet?.count ?? 999, 90)

        let normalLogs = """
        \u{1B}[32mCompiling Store...\u{1B}[0m
        Linking StoreTests
        Test Suite 'All tests' passed at 2026-11-25 12:00:00.
        Executed 42 tests, with 0 failures in 0.123 seconds.
        """
        XCTAssertNil(AgentActivityDetector.detectApprovalPrompt(in: normalLogs))

        // Stale approval prompt scrolled well above recent output should not trigger.
        let staleOutput = "Do you want to proceed?\n" + (1...10).map { "Log line \($0)" }.joined(separator: "\n")
        XCTAssertNil(AgentActivityDetector.detectApprovalPrompt(in: staleOutput))
    }

    func testIsMeaningfulOutputAndStateEquatable() {
        XCTAssertFalse(AgentActivityDetector.isMeaningfulOutput(""))
        XCTAssertFalse(AgentActivityDetector.isMeaningfulOutput("   \t\r\n  "))
        XCTAssertFalse(AgentActivityDetector.isMeaningfulOutput("\u{1B}[?25h\u{1B}[?25l"))
        XCTAssertFalse(AgentActivityDetector.isMeaningfulOutput("\u{1B}]0;termapp — zsh\u{07}\u{1B}[2K\u{1B}[1G"))
        XCTAssertTrue(AgentActivityDetector.isMeaningfulOutput("\u{1B}[32m✓\u{1B}[0m"))
        XCTAssertTrue(AgentActivityDetector.isMeaningfulOutput("\u{1B}[1;1HRunning tests..."))

        XCTAssertEqual(AgentActivityState.waitingForApproval(prompt: "Approve?"), .waitingForApproval(prompt: "Approve?"))
        XCTAssertNotEqual(AgentActivityState.idle, .running)
        XCTAssertNotEqual(AgentActivityState.running, .completed)
    }

    // MARK: - RemoteAttachmentHelper

    func testRemotePathSanitizationAndGeneration() {
        let fixedID = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-0123456789AB")!

        XCTAssertEqual(
            RemoteAttachmentHelper.remotePath(filename: "Screen Shot 1.PNG", id: fixedID),
            "/tmp/termapp-attach-a1b2c3d4.png"
        )
        XCTAssertEqual(
            RemoteAttachmentHelper.remotePath(filename: "photo.JPEG", id: fixedID, directory: "/var/tmp/"),
            "/var/tmp/termapp-attach-a1b2c3d4.jpeg"
        )
        XCTAssertEqual(
            RemoteAttachmentHelper.remotePath(filename: "noext", id: fixedID),
            "/tmp/termapp-attach-a1b2c3d4.png"
        )
        XCTAssertEqual(
            RemoteAttachmentHelper.remotePath(filename: ".hidden", id: fixedID),
            "/tmp/termapp-attach-a1b2c3d4.png"
        )
        XCTAssertEqual(
            RemoteAttachmentHelper.remotePath(filename: "../../etc/evil.veryLongExt123", id: fixedID, directory: "/tmp/../etc"),
            "/tmp/termapp-attach-a1b2c3d4.verylong"
        )

        let metacharPath = RemoteAttachmentHelper.remotePath(
            filename: "bad name.sh; rm -rf /",
            id: fixedID,
            directory: "/tmp/sub dir; $(whoami)"
        )
        XCTAssertFalse(metacharPath.contains(" "))
        XCTAssertFalse(metacharPath.contains(";"))
        XCTAssertFalse(metacharPath.contains("$"))
        XCTAssertFalse(metacharPath.contains(".."))
        XCTAssertTrue(metacharPath.contains("termapp-attach-a1b2c3d4."))
    }

    func testPromptInsertion() {
        XCTAssertEqual(
            RemoteAttachmentHelper.promptInsertion(forRemotePath: "/tmp/termapp-attach-a1b2c3d4.png", existingPrompt: ""),
            "/tmp/termapp-attach-a1b2c3d4.png"
        )
        XCTAssertEqual(
            RemoteAttachmentHelper.promptInsertion(forRemotePath: "/tmp/termapp-attach-a1b2c3d4.png", existingPrompt: "   "),
            "/tmp/termapp-attach-a1b2c3d4.png"
        )
        XCTAssertEqual(
            RemoteAttachmentHelper.promptInsertion(forRemotePath: "/tmp/termapp-attach-a1b2c3d4.png", existingPrompt: "Inspect this"),
            "Inspect this /tmp/termapp-attach-a1b2c3d4.png"
        )
        XCTAssertEqual(
            RemoteAttachmentHelper.promptInsertion(forRemotePath: "/tmp/termapp-attach-a1b2c3d4.png", existingPrompt: "Inspect this "),
            "Inspect this /tmp/termapp-attach-a1b2c3d4.png"
        )
        XCTAssertEqual(
            RemoteAttachmentHelper.promptInsertion(forRemotePath: "/tmp/termapp-attach-a1b2c3d4.png", existingPrompt: "Inspect:\n"),
            "Inspect:\n/tmp/termapp-attach-a1b2c3d4.png"
        )
    }
}
