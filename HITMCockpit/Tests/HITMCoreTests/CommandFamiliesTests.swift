import XCTest
@testable import HITMCore

final class CommandFamiliesTests: XCTestCase {
    private func match(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> FamilyMatch {
        guard case .simple(let argv) = CommandParser.parse(s) else {
            XCTFail("test command must parse as simple: \(s)", file: file, line: line)
            return .unknown("unparsed")
        }
        return CommandFamilies.match(argv: argv)
    }

    private func assertFamily(_ s: String, _ id: CommandFamilyID, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(match(s), .matched(id), s, file: file, line: line)
    }

    private func assertUnknown(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .unknown(let reason) = match(s) {
            XCTAssertFalse(reason.isEmpty, file: file, line: line)
        } else {
            XCTFail("expected unknown for \(s)", file: file, line: line)
        }
    }

    // MARK: the table as data

    func testTableMatchesThePlanCeilings() {
        let ceilings = Dictionary(uniqueKeysWithValues: CommandFamilies.table.map { ($0.id, $0.ceiling) })
        XCTAssertEqual(ceilings, [.readOnlySearch: .all, .localGit: .project, .buildAndTest: .project])
    }

    func testTableListsTheCommandsFromThePlan() {
        func commands(_ id: CommandFamilyID) -> [String] {
            CommandFamilies.table.first { $0.id == id }!.commands.map(\.command)
        }
        XCTAssertEqual(Set(commands(.readOnlySearch)), ["grep", "ls", "cat", "head", "tail", "wc"])
        XCTAssertEqual(commands(.localGit), ["git"])
        XCTAssertEqual(Set(commands(.buildAndTest)), ["swift", "xcodebuild"])
        let git = CommandFamilies.table.first { $0.id == .localGit }!.commands[0]
        XCTAssertEqual(Set(git.subcommands), ["status", "diff", "log", "show", "add", "commit", "branch"])
    }

    func testScopeLevelsAreOrderedNarrowToWide() {
        XCTAssertLessThan(ScopeLevel.session, .projectFolder)
        XCTAssertLessThan(ScopeLevel.projectFolder, .project)
        XCTAssertLessThan(ScopeLevel.project, .all)
    }

    // MARK: read-only search

    func testPlainReadOnlyCommandsMatch() {
        for s in ["grep -n foo f", "ls -la", "cat README.md", "head -5 f", "tail -n 20 f", "wc -l f"] {
            assertFamily(s, .readOnlySearch)
        }
    }

    func testRgIsNotInTheTableSoItAlwaysAsks() {
        for c in ["rg foo", "rg foo src", "rg --pre cmd foo", "rg -z foo", "rg --hostname-bin cmd foo", "rg -i --max-count=3 foo"] {
            assertUnknown(c)
        }
        XCTAssertFalse(CommandFamilies.table.flatMap(\.commands).contains { $0.command == "rg" })
    }

    func testPathFormsAreNotMatched() {
        assertUnknown("/usr/bin/grep x f")
        assertUnknown("./grep x f")
        assertUnknown("../bin/grep x f")
        assertUnknown("bin/grep x f")
        assertUnknown("Grep x f")
        assertUnknown("grep.sh x f")
    }

    // MARK: git

    func testAllowedGitSubcommandsMatch() {
        for s in ["git status", "git diff", "git diff HEAD", "git log --oneline", "git show abc123", "git add file.swift",
                  "git commit -m \"msg\"", "git branch", "git branch -a", "git branch --list", "git branch --contains abc123"] {
            assertFamily(s, .localGit)
        }
    }

    func testGitOptionsBeforeSubcommandDoNotMatch() {
        assertUnknown("git -c core.pager=x status")
        assertUnknown("git -C /tmp status")
        assertUnknown("git --exec-path=/x status")
        assertUnknown("git --git-dir=/x status")
    }

    func testGitOutsideTheListIsUnknown() {
        for s in ["git push", "git push origin main", "git reset --hard", "git checkout main", "git restore f",
                  "git clean -fd", "git rebase main", "git", "git STATUS", "git status2"] {
            assertUnknown(s)
        }
    }

    func testGitOutputFlagsDoNotMatch() {
        assertUnknown("git diff --output=f")
        assertUnknown("git diff --output f")
        assertUnknown("git log --output=f")
        assertUnknown("git diff --outp=f")
        assertUnknown("git show --output=f")
    }

    func testGitCommitDeniedFlagsDoNotMatch() {
        assertUnknown("git commit --amend -m x")
        assertUnknown("git commit --no-verify -m x")
        assertUnknown("git commit -n -m x")
        assertUnknown("git commit -nm x")
        assertUnknown("git commit --no-verif -m x")
        assertUnknown("git commit --amen")
    }

    func testGitAddForceDoesNotMatch() {
        assertUnknown("git add -f secrets.txt")
        assertUnknown("git add --force secrets.txt")
        assertUnknown("git add -Af x")
        assertFamily("git add Sources/File.swift", .localGit)
    }

    func testGitBranchIsListOnly() {
        for s in ["git branch -d x", "git branch -D x", "git branch -m old new", "git branch -M old new", "git branch -f x",
                  "git branch --delete x", "git branch --move a b", "git branch --force x y", "git branch -c a b",
                  "git branch newbranch", "git branch -u origin/main", "git branch --set-upstream-to=origin/main"] {
            assertUnknown(s)
        }
        assertFamily("git branch -av", .localGit)
        assertFamily("git branch --list 'feat-x'", .localGit)
        assertFamily("git branch --merged main", .localGit)
    }

    // MARK: build and test

    func testSwiftBuildAndTestMatch() {
        assertFamily("swift build", .buildAndTest)
        assertFamily("swift test --filter FooTests", .buildAndTest)
        assertFamily("xcodebuild -scheme App build", .buildAndTest)
        assertFamily("xcodebuild test -scheme App", .buildAndTest)
    }

    func testSwiftAndXcodebuildOutsideTheListAreUnknown() {
        assertUnknown("swift run")
        assertUnknown("swift package update")
        assertUnknown("swift")
        assertUnknown("swift -v build")
        assertUnknown("xcodebuild -exportArchive -archivePath a")
        assertUnknown("xcodebuild archive -scheme App")
        assertUnknown("xcodebuild -scheme App")
        assertUnknown("xcodebuild build -exportArchive")
    }

    // MARK: secret paths and extra denied flags

    func testSecretPathsNeverMatchAnyFamily() {
        let commands = ["cat .env", "cat ./config/.env.production", "cat /Users/x/.aws/credentials", "grep key .env",
                  "ls .ssh", "ls .ssh/", "cat id_rsa", "cat keys/id_rsa.pub", "head x/id_ed25519", "cat server.pem",
                  "cat a/b/server.KEY", "cat cert.p12", "cat .netrc", "cat .npmrc", "cat .pypirc", "cat credentials",
                  "cat credentials.json", "cat login.keychain-db", "cat a.keychain", "ls /Users/x/.gnupg",
                  "cat proj/.kube/config", "cat proj/.hitm/mind.json", "cat .ENV", "cat .Env.local",
                  "cat --file=.env", "grep --file=secrets/id_rsa x", "head -n1 .env", "cat -n.env",
                  "git add .env", "git diff -- .aws/credentials", "git show HEAD:config/.env", "git show HEAD:.env",
                  "git show :.env", "git show HEAD:.ssh/id_rsa", "swift build --package-path .ssh"]
        for s in commands {
            guard case .simple = CommandParser.parse(s) else { XCTFail("test input must be simple: \(s)"); continue }
            assertUnknown(s)
        }
    }

    func testSecretPathDenialAppliesInEveryFamily() {
        assertUnknown("git add .env")
        assertUnknown("git diff .aws/credentials")
        assertUnknown("swift build --package-path .ssh")
        assertUnknown("xcodebuild -scheme App build -xcconfig .env")
    }

    func testTildePathsToSecretsAreStillNotSimple() {
        guard case .notSimple = CommandParser.parse("head -n 3 ~/.ssh/id_rsa") else { return XCTFail("must not be simple") }
    }

    func testOrdinaryFilesAreNotMistakenForSecrets() {
        assertFamily("cat README.md", .readOnlySearch)
        assertFamily("grep -n foo src/main.swift", .readOnlySearch)
        assertFamily("cat environment.md", .readOnlySearch)
        assertFamily("cat src/envelope.swift", .readOnlySearch)
        assertFamily("ls keychain-notes", .readOnlySearch)
        assertFamily("cat monkey.txt", .readOnlySearch)
        assertUnknown("cat .environment")     // any name starting with .env is treated as a secret
        assertFamily("cat .github/workflows/ci.yml", .readOnlySearch)
    }

    func testCodeExecutingDiffAndSearchFlagsDoNotMatch() {
        assertUnknown("git diff --ext-diff")
        assertUnknown("git log --ext-diff -p")
        assertUnknown("git show --ext-diff")
        assertUnknown("git diff --textconv")
        assertUnknown("git log --textconv -p")
        assertUnknown("git show --textconv HEAD")
        assertFamily("git diff --no-ext-diff --no-textconv", .localGit)
    }

    // MARK: not in any family

    func testCommandsNotInAnyFamilyAreUnknown() {
        for s in ["find . -name x", "sed s/a/b/ f", "awk 1 f", "curl example.com", "ssh host", "rm f", "mv a b", "cp a b",
                  "chmod 600 f", "xargs ls", "sh -c x", "bash -c x", "python x.py", "totally-new-tool --flag"] {
            assertUnknown(s)
        }
    }

    func testEmptyArgvIsUnknown() {
        if case .unknown = CommandFamilies.match(argv: []) {} else { XCTFail("empty argv must be unknown") }
    }

    // MARK: review round: denylist gaps

    func testColonSplitsPathsSoGitObjectSpecsAreChecked() {
        for c in ["git show HEAD:.env", "git show :.env", "git show main:config/.aws/credentials", "git show HEAD:id_rsa"] {
            assertUnknown(c)
        }
        assertFamily("git show HEAD:README.md", .localGit)
    }

    func testAttachedValuesAfterAnyShortClusterAreChecked() {
        for c in ["grep -nf.env x f", "head -n1.env", "cat -vA.ssh", "head -qn.aws/credentials", "tail -c.npmrc"] {
            assertUnknown(c)
        }
    }

    func testEnvPrefixAndMoreSecretNamesAreDenied() {
        for c in ["cat .envrc", "cat .env-prod", "cat a/.env_local", "cat .git/config", "cat sub/.git/config",
                  "cat .git-credentials", "ls .docker", "cat .docker/config.json", "cat .pgpass", "cat .bash_history",
                  "cat .zsh_history", "cat state.tfstate", "cat terraform.tfstate.backup", "cat a.pfx", "cat a.p8", "cat a.jks",
                  "cat a.gpg", "cat a.asc", "cat id_ecdsa", "cat id_ecdsa.pub", "cat secrets.yml", "cat secrets.yaml",
                  "cat config/secrets.json", "cat SECRETS.JSON"] {
            assertUnknown(c)
        }
        assertFamily("cat .gitignore", .readOnlySearch)
        assertFamily("cat .github/ci.yml", .readOnlySearch)
        assertFamily("cat git/config.md", .readOnlySearch)
    }

    func testCombiningMarksCannotHidePathSeparatorsOrFlags() {
        for m in ["\u{301}", "\u{FE0F}", "\u{200D}"] {
            assertUnknown("cat .ssh/\(m)x")
            assertUnknown("cat a/.ssh/\(m)")
            assertUnknown("cat .env\(m)")
            assertUnknown("git commit -n\(m) -m x")
            assertUnknown("git add -f\(m) x")
            assertUnknown("ls -R\(m)")
        }
        assertUnknown("cat .s\u{200B}sh/id")          // invisible character inside a secret directory name
    }

    func testGitAddNeedsExplicitNamedPaths() {
        for c in ["git add .", "git add ./", "git add -A", "git add --all", "git add -u", "git add --update", "git add -Au",
                  "git add src/.", "git add ..", "git add --no-ignore-removal", "git add :/", "git add -A src"] {
            assertUnknown(c)
        }
        assertFamily("git add Sources/A.swift Tests/B.swift", .localGit)
    }

    // MARK: review round: recursive search, read gaps

    func testRecursiveSearchAndListingDoNotMatch() {
        for c in ["grep -r x .", "grep -R x .", "grep -rn x src", "grep --recursive x .", "grep --dereference-recursive x .",
                  "grep --rec x .", "grep -d recurse x .", "grep --directories=recurse x .", "grep --directories recurse x .",
                  "ls -R", "ls --recursive", "ls -laR src", "ls --rec"] {
            assertUnknown(c)
        }
        assertFamily("grep -n foo src/main.swift", .readOnlySearch)
        assertFamily("ls -la src", .readOnlySearch)
    }

    func testFileListReadsDoNotMatch() {
        for c in ["grep -f patterns x", "grep --file=patterns x", "grep --file patterns x", "grep --exclude-from=list x f",
                  "grep -nf patterns x", "wc --files0-from=list", "wc --files0-from list", "wc --files0 list"] {
            assertUnknown(c)
        }
        assertFamily("wc -l f", .readOnlySearch)
    }

    func testGitNoIndexAndOutsideTreeDiffDoNotMatch() {
        for c in ["git diff --no-index a b", "git log --no-index", "git show --no-index a", "git diff --no-ind a b",
                  "git diff /etc/passwd /tmp/x", "git diff -- /etc/hosts", "git diff ../other a", "git diff -- ../x"] {
            assertUnknown(c)
        }
        assertFamily("git diff HEAD..main", .localGit)
        assertFamily("git diff main...feature -- src/a.swift", .localGit)
    }

    func testGitBranchOptionalValueFlagsDoNotSwallowTheNextFlag() {
        assertUnknown("git branch --contains --edit-description")
        assertUnknown("git branch --merged --unset-upstream")
        assertUnknown("git branch --no-merged --edit-description")
        assertUnknown("git branch --no-contains --unset-upstream")
        assertFamily("git branch --contains abc123", .localGit)
        assertFamily("git branch --merged main -a", .localGit)
    }

    // MARK: review round: build and test flag controls

    func testSwiftFlagControlsAreDenied() {
        for f in ["--disable-sandbox", "--package-path /x", "--scratch-path /x", "--build-path /x", "-Xswiftc -foo", "-Xcc -foo",
                  "-Xcxx -foo", "-Xlinker -foo", "-Xbuild-tools-swiftc -foo", "--plugin-dir /x", "--plugin-x", "--cache-path /x",
                  "--config-path /x", "--security-path /x", "--package-path=/x", "--scratch-path=/x"] {
            assertUnknown("swift build \(f)")
            assertUnknown("swift test \(f)")
        }
        assertFamily("swift build -c release", .buildAndTest)
        assertFamily("swift test --filter FooTests", .buildAndTest)
    }

    func testXcodebuildFlagControlsAreDeniedInAnyCaseAndDashStyle() {
        for f in ["-derivedDataPath /x", "--derivedDataPath /x", "-DERIVEDDATAPATH /x", "-resultBundlePath /x", "-archivePath /x",
                  "-exportArchive", "--exportArchive", "-EXPORTARCHIVE", "-exportarchive", "-xcconfig /x", "-toolchain x",
                  "FOO=bar", "OTHER_SWIFT_FLAGS=-x", "CODE_SIGN_IDENTITY=-", "-derivedDataPath=/x"] {
            assertUnknown("xcodebuild -scheme App build \(f)")
        }
        for w in ["ARCHIVE", "Install", "CLEAN", "Docbuild"] { assertUnknown("xcodebuild build \(w)") }
    }

    func testXcodebuildActionWordMustBeAnActionNotAFlagValue() {
        assertUnknown("xcodebuild -scheme build")
        assertUnknown("xcodebuild -scheme test")
        assertUnknown("xcodebuild -project test")
        assertUnknown("xcodebuild -configuration build")
        assertUnknown("xcodebuild -unknownflag value build")
        assertFamily("xcodebuild -scheme App build", .buildAndTest)
        assertFamily("xcodebuild -scheme build build", .buildAndTest)
        assertFamily("xcodebuild test -scheme App -destination 'platform=macOS'", .buildAndTest)
        assertFamily("xcodebuild -project A.xcodeproj -configuration Debug build", .buildAndTest)
    }

    func testTableLookupHasNoForceUnwrap() {
        for id in CommandFamilyID.allCases { XCTAssertEqual(CommandFamilies.family(id).id, id) }
    }

    // MARK: second review round

    func testQuotedGlobsAndMagicPathspecsAskForEveryGitSubcommand() {
        for c in ["git add '.en?'", "git add '.en[v]'", "git add '*'", "git add '*.env'", "git add 'a/*'", "git add \"*\"",
                  "git add 'a\\b'", "git diff -- '.en?'", "git log -p -- '.en*'", "git show 'HEAD:.en?'", "git show 'HEAD:*'",
                  "git diff ':(top).env'", "git status ':/'", "git log -- ':!x'", "git branch --list 'feat-*'", "git diff '[.]env'"] {
            assertUnknown(c)
        }
        assertFamily("git commit -m \"fix [x]: why? a*b\"", .localGit)
        assertFamily("git commit -am \"fix [x]: why?\"", .localGit)
        assertFamily("git commit --message=\"why? [x]\"", .localGit)
        assertFamily("git commit -m'why? [x]'", .localGit)
        assertUnknown("git commit -m ok '*'")
    }

    func testGitAddAndCommitInteractiveAndFileInputFormsAreDenied() {
        for c in ["git add --pathspec-from-file=list", "git add --pathspec-from-file list", "git add --pathspec-file-nul x",
                  "git add -p", "git add --patch", "git add -i", "git add --interactive", "git add -e", "git add --edit",
                  "git add -pu", "git commit -F msg.txt", "git commit --file=msg.txt", "git commit --file msg.txt",
                  "git commit --template=t", "git commit --template t", "git commit -t t", "git commit -m x -F y",
                  "git commit --pathspec-from-file=list"] {
            assertUnknown(c)
        }
    }

    func testCaseFoldingAndNormalisationCannotHideSecretNames() {
        for c in ["cat .\u{17F}sh/config", "cat .aw\u{17F}/credentials", "cat secret\u{17F}.yml", "cat .\u{17F}\u{17F}h/x",
                  "cat server.\u{212A}ey", "cat server.\u{212A}EY", "cat .\u{212A}ube/config", "cat ID_RSA", "cat .GnuPG/x",
                  "cat .env\u{17F}", "cat A/.Aw\u{17F}/x"] {
            assertUnknown(c)
        }
        assertFamily("cat README.md", .readOnlySearch)
        assertFamily("ls \u{17F}rc", .readOnlySearch)
        assertFamily("cat src/\u{17F}ample.txt", .readOnlySearch)
        assertFamily("cat caf\u{E9}.txt", .readOnlySearch)
        assertFamily("cat cafe\u{301}.txt", .readOnlySearch)
    }

    func testMoreSecretNames() {
        for c in ["cat config.env", "cat prod.env", "cat .flaskenv", "cat application_default_credentials.json",
                  "cat my-credentials-backup", "cat .vault-token", "cat .secrets", "cat secrets.toml", "cat app.keystore",
                  "cat db.kdbx", "cat .azure/accessTokens.json", "cat ~/x".replacingOccurrences(of: "~/", with: ".config/gcloud/"),
                  "cat .config/gh/hosts.yml", "cat .config/op/config", "cat x/.config/gcloud", "ls .config/gcloud"] {
            assertUnknown(c)
        }
        assertFamily("cat .config/app.toml", .readOnlySearch)
        assertFamily("cat environment.md", .readOnlySearch)
        assertFamily("cat gcloud/notes.md", .readOnlySearch)
    }

    func testMoreSwiftAndXcodebuildFlagsAreDenied() {
        for f in ["--toolset x", "--toolchain x", "-Xmanifest -foo", "--netrc", "--netrc-file x", "--netrc-optional", "--swift-sdk x",
                  "--sdk x", "--triple x", "--allow-writing-to-directory /x", "--xunit-output /x", "--experimental-foo",
                  "--toolchain=x"] {
            assertUnknown("swift build \(f)")
            assertUnknown("swift test \(f)")
        }
        for f in ["-skipMacroValidation", "-SKIPMACROVALIDATION", "--skipMacroValidation", "-skipPackagePluginValidation",
                  "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "-authenticationKeyPath /x",
                  "-authenticationKeyID x", "-authenticationKeyIssuerID x", "-AUTHENTICATIONKEYPATH /x"] {
            assertUnknown("xcodebuild -scheme App build \(f)")
        }
        assertFamily("xcodebuild -scheme App build", .buildAndTest)
    }

    func testTailFollowAndDeviceFilesAreDenied() {
        for c in ["tail -f log", "tail -F log", "tail --follow log", "tail --follow=name log", "tail -fn5 log", "tail --fol log",
                  "cat /dev/zero", "head -c 5 /dev/urandom", "tail /dev/tty", "wc /dev/stdin", "grep x /dev/stdin",
                  "cat //dev/zero", "cat /./dev/zero", "cat -n/dev/zero"] {
            assertUnknown(c)
        }
        assertFamily("tail -n 20 f", .readOnlySearch)
        assertFamily("cat /etc/passwd", .readOnlySearch)       // by design: names only, see the table comment
        assertFamily("cat devices.md", .readOnlySearch)
        assertFamily("cat src/dev/x.swift", .readOnlySearch)
    }

    func testActionWordsOfXcodebuildAreExposedForRuleMatching() {
        XCTAssertEqual(CommandFamilies.subcommandWords(argv: ["xcodebuild", "-scheme", "X", "test"]), ["test"])
        XCTAssertEqual(CommandFamilies.subcommandWords(argv: ["xcodebuild", "-scheme", "test", "build"]), ["build"])
        XCTAssertEqual(CommandFamilies.subcommandWords(argv: ["git", "status"]), ["status"])
        XCTAssertEqual(CommandFamilies.subcommandWords(argv: ["grep", "x"]), [])
    }
}
