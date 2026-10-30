import Foundation

/// How far a standing rule may reach, narrow to wide. Declaration order is the ordering.
public enum ScopeLevel: Int, Comparable, Codable, CaseIterable, Sendable {
    case session, projectFolder, project, all
    public static func < (a: ScopeLevel, b: ScopeLevel) -> Bool { a.rawValue < b.rawValue }
}

public enum CommandFamilyID: String, Codable, CaseIterable, Sendable {
    case readOnlySearch, localGit, buildAndTest
}

/// Extra limits for one subcommand: only these flags are allowed. Used where "list only" is the intent.
public struct FlagWhitelist: Equatable, Sendable {
    public let allowed: [String]
    /// Allowed flags that take their value as the next argument (when not written `--flag=value`).
    public let takesValue: [String]
    /// Plain (non-flag) arguments are allowed only if one of these flags is present, or as a flag's value.
    public let positionalsNeedAnyOf: [String]
}

public struct CommandSpec: Equatable, Sendable {
    /// Exact argv[0]. No path forms, no case folding.
    public let command: String
    /// Allowed subcommands. Empty means the command takes none. With `subcommandAnywhere` false the
    /// subcommand must be argv[1] exactly, so any option before it fails to match. With it true (xcodebuild)
    /// the action words are the non-flag words that are not the value of a flag in `valueFlags`; there must
    /// be at least one and every one must be in `subcommands`.
    public let subcommands: [String]
    public let subcommandAnywhere: Bool
    /// Denied flags by subcommand; the key "*" applies to every use of the command. `-x` (two characters)
    /// also denies any short cluster containing x; `--name` also denies `--name=value`, longer names that
    /// start with it and abbreviations of three or more characters; other single-dash flags match exactly.
    public let deniedFlags: [String: [String]]
    /// Flag names (lowercase, no dashes) denied whatever the case or number of leading dashes: xcodebuild
    /// accepts `-exportArchive` and `--exportArchive` alike.
    public let looseDeniedFlags: [String]
    /// Loose flag names (lowercase, no dashes) whose value is the next word. Used to find the action word.
    public let valueFlags: [String]
    /// Plain words that disqualify the command wherever they appear (compared ignoring case).
    public let deniedWords: [String]
    /// Any `NAME=value` word that is not a flag's value is a build setting and disqualifies the command.
    public let denyAssignments: Bool
    /// Subcommands where a pathspec naming a whole tree (`.`, `..`, `dir/.`, `:/`, `:`-magic) is denied, so
    /// only explicitly named paths are staged. A named DIRECTORY is still allowed: KNOWN GAP.
    public let denyWholeTreePathspecs: [String]
    /// Subcommands where an absolute path or a `..` path component is denied (git diff would otherwise
    /// compare files outside the repository, like --no-index).
    public let relativePathsOnly: [String]
    public let flagWhitelists: [String: FlagWhitelist]
    /// git: any argument with `*`, `?`, `[`, a backslash, or starting with `:` is a pathspec git expands itself
    /// (quoting does not stop it), so the command asks. Commit message text (`-m`) is exempt.
    public let denyMagicPathspecs: Bool
    /// Any argument naming a path under `/dev/` (endless or blocking device files) is denied.
    public let denyDevicePaths: Bool

    init(_ command: String, subcommands: [String] = [], subcommandAnywhere: Bool = false,
         deniedFlags: [String: [String]] = [:], looseDeniedFlags: [String] = [], valueFlags: [String] = [],
         deniedWords: [String] = [], denyAssignments: Bool = false, denyWholeTreePathspecs: [String] = [],
         relativePathsOnly: [String] = [], flagWhitelists: [String: FlagWhitelist] = [:],
         denyMagicPathspecs: Bool = false, denyDevicePaths: Bool = false) {
        self.command = command; self.subcommands = subcommands; self.subcommandAnywhere = subcommandAnywhere
        self.deniedFlags = deniedFlags; self.looseDeniedFlags = looseDeniedFlags; self.valueFlags = valueFlags
        self.deniedWords = deniedWords; self.denyAssignments = denyAssignments
        self.denyWholeTreePathspecs = denyWholeTreePathspecs; self.relativePathsOnly = relativePathsOnly
        self.flagWhitelists = flagWhitelists
        self.denyMagicPathspecs = denyMagicPathspecs; self.denyDevicePaths = denyDevicePaths
    }
}

public struct CommandFamily: Equatable, Sendable {
    public let id: CommandFamilyID
    /// Widest scope any rule for this family may have. Fixed here, never chosen by a model (R4).
    public let ceiling: ScopeLevel
    public let commands: [CommandSpec]
}

public enum FamilyMatch: Equatable, Sendable {
    case matched(CommandFamilyID)
    /// Not in any family, or in one but with a denied flag or form. Always means ask.
    case unknown(String)
}

/// Shell and file systems see Unicode scalars, not grapheme clusters: "/" followed by a combining mark is
/// still a path separator. Everything that inspects arguments here works on scalars.
extension String {
    func sHasPrefix(_ p: String) -> Bool { unicodeScalars.starts(with: p.unicodeScalars) }
    func sHasSuffix(_ p: String) -> Bool { unicodeScalars.reversed().starts(with: p.unicodeScalars.reversed()) }
    func sSame(_ o: String) -> Bool { unicodeScalars.elementsEqual(o.unicodeScalars) }
    var sCount: Int { unicodeScalars.count }
    func sDrop(_ n: Int) -> String { String(unicodeScalars.dropFirst(n)) }
    func sSplit(_ seps: Set<Unicode.Scalar>, omitEmpty: Bool = true) -> [String] {
        unicodeScalars.split(omittingEmptySubsequences: omitEmpty, whereSeparator: { seps.contains($0) })
            .map { String(String.UnicodeScalarView($0)) }
    }
    func sContains(_ sub: String) -> Bool {
        let h = Array(unicodeScalars), n = Array(sub.unicodeScalars)
        guard !n.isEmpty, h.count >= n.count else { return n.isEmpty }
        return (0...(h.count - n.count)).contains { i in Array(h[i..<(i + n.count)]) == n }
    }
}

/// PROPOSED first table, from the piece 2 plan. The owner confirms it; it is unverified against the
/// commands real agents run. Hooks, shell aliases, git config and environment are outside the engine.
///
/// Secret paths: any argument naming a secret file or directory (see `isSecretPath`) makes the command
/// match NO family, whatever the scope, so it asks.
///
/// PENDING OWNER CONFIRMATION (stricter defaults chosen by the implementer, 2026-10-30):
/// - Recursive search is denied (`grep -r/-R/--recursive/--dereference-recursive`, `-d recurse`,
///   `--directories`, `ls -R/--recursive`) and `rg` is NOT in the table, because it is recursive by default
///   and argv cannot show whether it will walk into a folder holding secrets. Those commands ask.
/// - `grep -f/--file/--exclude-from` and `wc --files0-from` (reads a file list) are denied.
/// - buildAndTest denies flags that redirect paths, tools or sandboxing (`swift --package-path`,
///   `-Xswiftc`, `--disable-sandbox`...; `xcodebuild -derivedDataPath`, `-xcconfig`, any `NAME=value`).
/// By design `cat /etc/passwd` and other non-secret absolute paths are allowed: only names are checked.
/// Paths under /dev/ and `tail -f/-F/--follow` (endless or blocking reads) are denied.
/// Git expands pathspecs itself, even when quoted, so any git argument with `*`, `?`, `[`, `\` or a leading `:`
/// asks (commit message text excepted).
/// KNOWN GAPS (surface to the owner): the secret check is a NAME list only (see `isSecretPath`); a plain `git add <directory>` stages unignored secrets inside that
/// directory because argv does not name them; `cat`, `head`, `tail` still read any file not on the denylist;
/// the denylist is a list of names, not a guarantee that no secret is read. `swift build/test` and
/// `xcodebuild` run project code by nature.
public enum CommandFamilies {
    // --ext-diff and --textconv run programs named in git config; --output writes a file;
    // --no-index compares arbitrary files outside the repository.
    private static let gitDiffLike = ["--output", "--ext-diff", "--textconv", "--no-index"]

    public static let table: [CommandFamily] = [
        CommandFamily(id: .readOnlySearch, ceiling: .all, commands: [
            CommandSpec("grep", deniedFlags: ["*": ["-r", "-R", "--recursive", "--dereference-recursive", "-d",
                                                    "--directories", "-f", "--file", "--exclude-from"]],
                        deniedWords: ["recurse"], denyDevicePaths: true),
            CommandSpec("ls", deniedFlags: ["*": ["-R", "--recursive"]]),
            CommandSpec("cat", denyDevicePaths: true), CommandSpec("head", denyDevicePaths: true),
            CommandSpec("tail", deniedFlags: ["*": ["-f", "-F", "--follow"]], denyDevicePaths: true),
            CommandSpec("wc", deniedFlags: ["*": ["--files0-from"]], denyDevicePaths: true)
        ]),
        CommandFamily(id: .localGit, ceiling: .project, commands: [
            CommandSpec("git",
                subcommands: ["status", "diff", "log", "show", "add", "commit", "branch"],
                deniedFlags: [
                    "diff": gitDiffLike, "log": gitDiffLike, "show": gitDiffLike,
                    "commit": ["--amend", "--no-verify", "-n", "-F", "--file", "--template", "-t",
                               "--pathspec-from-file", "--pathspec-file-nul"],
                    "add": ["-f", "--force", "-A", "--all", "-u", "--update", "--no-ignore-removal", "-p", "--patch",
                            "-i", "--interactive", "-e", "--edit", "--pathspec-from-file", "--pathspec-file-nul"],
                    "branch": ["-d", "-D", "-m", "-M", "-f", "--delete", "--move", "--force"]
                ],
                denyWholeTreePathspecs: ["add"],
                relativePathsOnly: ["diff"],
                flagWhitelists: ["branch": FlagWhitelist(
                    allowed: ["-a", "-r", "-v", "-l", "-i", "-q", "--all", "--remotes", "--verbose", "--list",
                              "--show-current", "--merged", "--no-merged", "--contains", "--no-contains",
                              "--points-at", "--sort", "--format", "--color", "--no-color", "--column",
                              "--no-column", "--abbrev", "--no-abbrev", "--ignore-case"],
                    takesValue: ["--merged", "--no-merged", "--contains", "--no-contains", "--points-at",
                                 "--sort", "--format"],
                    positionalsNeedAnyOf: ["--list", "-l"])],
                denyMagicPathspecs: true)
        ]),
        CommandFamily(id: .buildAndTest, ceiling: .project, commands: [
            CommandSpec("swift", subcommands: ["build", "test"],
                deniedFlags: ["*": ["--disable-sandbox", "--package-path", "--scratch-path", "--build-path",
                                    "-Xswiftc", "-Xcc", "-Xcxx", "-Xlinker", "-Xbuild-tools-swiftc", "--plugin",
                                    "--cache-path", "--config-path", "--security-path", "--toolset", "--toolchain",
                                    "-Xmanifest", "--netrc", "--swift-sdk", "--sdk", "--triple",
                                    "--allow-writing-to-directory", "--xunit-output", "--experimental-"]]),
            CommandSpec("xcodebuild", subcommands: ["build", "test"], subcommandAnywhere: true,
                looseDeniedFlags: ["derivedDataPath", "resultBundlePath", "archivePath", "exportArchive",
                                   "exportNotarizedApp", "exportLocalizations", "importLocalizations", "xcconfig",
                                   "toolchain", "skipMacroValidation", "skipPackagePluginValidation",
                                   "allowProvisioningUpdates", "allowProvisioningDeviceRegistration",
                                   "authenticationKey*"].map { $0.lowercased() },       // trailing * = prefix
                valueFlags: ["scheme", "project", "workspace", "configuration", "destination", "sdk", "target",
                             "arch", "jobs", "only-testing", "skip-testing", "testplan", "destination-timeout",
                             "enablecodecoverage", "parallel-testing-enabled", "test-iterations"],
                deniedWords: ["archive", "install", "installsrc", "installhdrs", "installapi", "clean",
                              "analyze", "docbuild"],
                denyAssignments: true)
        ])
    ]

    /// Never traps: an id missing from the table gets the narrowest ceiling and no commands.
    public static func family(_ id: CommandFamilyID) -> CommandFamily {
        table.first { $0.id == id } ?? CommandFamily(id: id, ceiling: .session, commands: [])
    }

    /// Exact match of argv against the table. Pure: nothing is run or resolved.
    public static func match(argv: [String]) -> FamilyMatch {
        guard let first = argv.first else { return .unknown("empty command") }
        if let bad = argv.dropFirst().first(where: { isSecretArgument($0) }) {
            return .unknown("'\(bad)' names a file or folder that may hold secrets")
        }
        for family in table {
            guard let spec = family.commands.first(where: { $0.command.sSame(first) }) else { continue }
            if let why = rejection(spec, args: Array(argv.dropFirst())) { return .unknown(why) }
            return .matched(family.id)
        }
        return .unknown("'\(first)' is not in any known command family")
    }

    // MARK: secret paths

    private static let separators: Set<Unicode.Scalar> = ["/", ":"]
    private static let secretDirectories: Set<String> = [".ssh", ".aws", ".gnupg", ".kube", ".hitm", ".docker", ".azure"]
    private static let secretNames: Set<String> = [".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass",
        ".bash_history", ".zsh_history", "secrets.yml", "secrets.yaml", "secrets.json", "secrets.toml", ".flaskenv",
        ".vault-token", ".secrets"]
    private static let secretSuffixes = [".pem", ".key", ".p12", ".pfx", ".p8", ".jks", ".gpg", ".asc", ".env",
                                         ".keystore", ".kdbx"]
    private static let secretPrefixes = [".env", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
    private static let secretPairs = [(".git", "config"), (".config", "gcloud"), (".config", "gh"), (".config", "op")]

    /// Canonical forms and case folding as a case-insensitive, normalisation-insensitive file system sees names:
    /// NFC and NFD, invisible characters removed, long s (U+017F) and Kelvin (U+212A) mapped to `s` and `k`, then
    /// full case folding.
    static func foldedForms(_ path: String) -> [String] {
        [path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping].map { form in
            var v = String.UnicodeScalarView()
            for u in form.unicodeScalars where !u.properties.isDefaultIgnorableCodePoint {
                switch u {
                case "\u{17F}": v.append("s")
                case "\u{212A}": v.append("k")
                default: v.append(u)
                }
            }
            return String(v).folding(options: [.caseInsensitive], locale: nil).lowercased()
        }
    }

    /// Components split on `/` and `:` (so `HEAD:.env` is seen) of the folded forms, working on scalars so a mark
    /// after a separator cannot hide it.
    static func components(_ path: String) -> [[String]] { foldedForms(path).map { $0.sSplit(separators) } }

    /// True if any component is a secret directory, an adjacent pair is a secret location (`.git/config`,
    /// `.config/gcloud`...), or the last component is a secret file name. THIS IS A NAME LIST: it does not know
    /// what a file contains. Over-asks on ordinary names such as `my-credentials-notes`.
    static func isSecretPath(_ path: String) -> Bool { components(path).contains { isSecret(parts: $0) } }

    private static func isSecret(parts: [String]) -> Bool {
        if parts.contains(where: { p in secretDirectories.contains { $0.sSame(p) } }) { return true }
        for i in parts.indices.dropLast() {
            if secretPairs.contains(where: { parts[i].sSame($0.0) && parts[i + 1].sSame($0.1) }) { return true }
        }
        guard let name = parts.last else { return false }
        if secretNames.contains(where: { $0.sSame(name) }) { return true }
        if secretSuffixes.contains(where: { name.sHasSuffix($0) }) { return true }
        if secretPrefixes.contains(where: { name.sHasPrefix($0) }) { return true }
        return name.sContains("credentials") || name.sContains(".keychain") || name.sContains(".tfstate")
    }

    /// The argument itself, the part after `=` (`--file=.env`), and every suffix after the dash of a
    /// single-dash word (`-rf.env`, `-n1.env`): places a path can hide as a flag's attached value.
    static func pathCandidates(_ arg: String) -> [String] {
        var out = [arg]
        let scalars = Array(arg.unicodeScalars)
        if let eq = scalars.firstIndex(of: "=") { out.append(String(String.UnicodeScalarView(scalars[(eq + 1)...]))) }
        if arg.sHasPrefix("-"), !arg.sHasPrefix("--") {
            for k in 1..<max(1, scalars.count) { out.append(String(String.UnicodeScalarView(scalars[k...]))) }
        }
        return out
    }

    static func isSecretArgument(_ arg: String) -> Bool { pathCandidates(arg).contains { isSecretPath($0) } }

    /// Absolute, or has a `..` component: reaches outside the current tree.
    static func pathLeavesTree(_ candidate: String) -> Bool {
        candidate.sHasPrefix("/") || candidate.sSplit(["/"]).contains { $0.sSame("..") }
    }

    // MARK: matching

    /// The subcommand or action words of a command, for matching rule subcommands: argv[1] for ordinary
    /// commands, every action word wherever it sits for `subcommandAnywhere` commands (xcodebuild).
    static func subcommandWords(argv: [String]) -> [String] {
        guard let first = argv.first,
              let spec = table.flatMap(\.commands).first(where: { $0.command.sSame(first) }),
              !spec.subcommands.isEmpty else { return [] }
        let args = Array(argv.dropFirst())
        return spec.subcommandAnywhere ? actionWords(spec, args: args) : (args.first.map { [$0] } ?? [])
    }

    /// Non-flag words that are not the value of a known value flag.
    private static func actionWords(_ spec: CommandSpec, args: [String]) -> [String] {
        var skip = false
        var words: [String] = []
        for arg in args {
            if skip { skip = false; continue }
            if arg.sHasPrefix("-") {
                if !arg.unicodeScalars.contains("="), spec.valueFlags.contains(where: { $0.sSame(looseName(arg)) }) { skip = true }
                continue
            }
            words.append(arg)
        }
        return words
    }

    private static func rejection(_ spec: CommandSpec, args: [String]) -> String? {
        var sub: String? = nil
        var rest = args
        if !spec.subcommands.isEmpty {
            if spec.subcommandAnywhere {
                if let why = actionWordRejection(spec, args: args) { return why }
            } else {
                guard let s = args.first, spec.subcommands.contains(where: { $0.sSame(s) }) else {
                    return "'\(spec.command)' is only covered with one of: \(spec.subcommands.joined(separator: ", ")) directly after it"
                }
                sub = spec.subcommands.first { $0.sSame(s) }
                rest = Array(args.dropFirst())
            }
        }
        let words = spec.deniedWords.map { $0.lowercased() }
        if let bad = rest.first(where: { a in words.contains { $0.sSame(a.lowercased()) } }) {
            return "'\(spec.command) \(bad)' is not covered"
        }
        let denied = (spec.deniedFlags["*"] ?? []) + (sub.flatMap { spec.deniedFlags[$0] } ?? [])
        if let bad = rest.first(where: { isDenied($0, by: denied) }) {
            return "the flag '\(bad)' is not covered for '\(spec.command)'"
        }
        if let bad = rest.first(where: { a in a.sHasPrefix("-") && spec.looseDeniedFlags.contains { d in
            d.sHasSuffix("*") ? looseName(a).sHasPrefix(String(d.unicodeScalars.dropLast())) : d.sSame(looseName(a))
        } }) {
            return "the flag '\(bad)' is not covered for '\(spec.command)'"
        }
        if spec.denyDevicePaths, let bad = rest.first(where: { a in pathCandidates(a).contains { isDevicePath($0) } }) {
            return "'\(bad)' is a device file"
        }
        if spec.denyMagicPathspecs, let bad = magicPathspec(rest, subcommand: sub) {
            return "'\(bad)' is a pathspec git expands itself (wildcard or magic), which may reach files not named"
        }
        guard let sub else { return nil }
        if spec.denyWholeTreePathspecs.contains(sub), let bad = rest.first(where: { !$0.sHasPrefix("-") && isWholeTreePathspec($0) }) {
            return "'\(bad)' would stage a whole folder; name the files explicitly"
        }
        if spec.relativePathsOnly.contains(sub),
           let bad = rest.first(where: { a in pathCandidates(a).contains { pathLeavesTree($0) } }) {
            return "'\(bad)' points outside the repository"
        }
        if let wl = spec.flagWhitelists[sub], let why = whitelistRejection(wl, args: rest, label: "\(spec.command) \(sub)") {
            return why
        }
        return nil
    }

    private static func isDevicePath(_ candidate: String) -> Bool {
        guard candidate.sHasPrefix("/") else { return false }
        return candidate.sSplit(["/"]).first { !$0.sSame(".") }?.sSame("dev") ?? false
    }

    /// First argument that git would expand: wildcard or backslash characters, or a leading `:` magic pathspec.
    /// For `commit`, the text of `-m`/`--message` is a message, not a pathspec.
    private static func magicPathspec(_ args: [String], subcommand: String?) -> String? {
        var messageNext = false
        for a in args {
            if messageNext { messageNext = false; continue }
            if subcommand == "commit" {
                if a.sSame("--message") { messageNext = true; continue }
                if a.sHasPrefix("--message=") { continue }
                if a.sHasPrefix("-m"), a.sCount > 2 { continue }                                   // -mTEXT
                if a.sHasPrefix("-"), !a.sHasPrefix("--"), a.unicodeScalars.last == "m" { messageNext = true; continue }   // -m, -am
            }
            if a.sHasPrefix(":") || a.unicodeScalars.contains(where: { "*?[\\".unicodeScalars.contains($0) }) { return a }
        }
        return nil
    }

    private static func looseName(_ arg: String) -> String {
        let noDashes = String(arg.unicodeScalars.drop(while: { $0 == "-" }))
        return String(noDashes.unicodeScalars.prefix { $0 != "=" }).lowercased()
    }

    private static func isWholeTreePathspec(_ arg: String) -> Bool {
        if arg.sHasPrefix(":") { return true }
        let segs = arg.sSplit(["/"])
        guard let last = segs.last else { return true }       // "" or "/"
        return last.sSame(".") || last.sSame("..")
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.unicodeScalars.firstIndex(of: "="), eq != word.unicodeScalars.startIndex else { return false }
        return word.unicodeScalars[..<eq].allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil)) }
    }

    /// xcodebuild: every non-flag word (after skipping known flag values) must be an allowed action, and
    /// there must be one. An unknown flag's value then shows up as a stray word and the command asks.
    private static func actionWordRejection(_ spec: CommandSpec, args: [String]) -> String? {
        let actions = actionWords(spec, args: args)
        if spec.denyAssignments, let bad = actions.first(where: isAssignment) { return "'\(bad)' sets a build setting, which is not covered" }
        guard !actions.isEmpty else { return "'\(spec.command)' needs an action: \(spec.subcommands.joined(separator: ", "))" }
        if let bad = actions.first(where: { a in !spec.subcommands.contains { $0.sSame(a) } }) {
            return "'\(spec.command) \(bad)' is not covered; only \(spec.subcommands.joined(separator: ", ")) are"
        }
        return nil
    }

    private static func isDenied(_ arg: String, by denied: [String]) -> Bool {
        guard arg.sHasPrefix("-"), arg.sCount > 1 else { return false }
        let name = String(arg.unicodeScalars.prefix { $0 != "=" })
        if arg.sHasPrefix("--") {
            return denied.contains { d in
                d.sHasPrefix("--") && (name.sSame(d) || (name.sCount >= 3 && d.sHasPrefix(name)) || name.sHasPrefix(d))
            }
        }
        let body = arg.unicodeScalars.dropFirst()
        return denied.contains { d in
            guard d.sHasPrefix("-"), !d.sHasPrefix("--") else { return false }
            if d.sCount == 2, let letter = d.unicodeScalars.last { return body.contains(letter) }  // anywhere in a cluster
            return name.sSame(d)                                  // single-dash word flag such as -Xswiftc
        }
    }

    private static func whitelistRejection(_ wl: FlagWhitelist, args: [String], label: String) -> String? {
        let hasListFlag = args.contains { a in wl.positionalsNeedAnyOf.contains { $0.sSame(a) } }
        func allowed(_ f: String) -> Bool { wl.allowed.contains { $0.sSame(f) } }
        var expectValue = false
        for arg in args {
            // An optional-value flag only takes the next word when it is not itself a flag.
            if expectValue, !arg.sHasPrefix("-") { expectValue = false; continue }
            expectValue = false
            if arg.sSame("--") { return "'\(label)' is covered only for listing, without '--'" }
            if arg.sHasPrefix("--") {
                let name = String(arg.unicodeScalars.prefix { $0 != "=" })
                guard allowed(name) else { return "'\(label)' is covered only for listing; '\(name)' is not a listing flag" }
                if !arg.unicodeScalars.contains("="), wl.takesValue.contains(where: { $0.sSame(name) }) { expectValue = true }
            } else if arg.sHasPrefix("-"), arg.sCount > 1 {
                for letter in arg.unicodeScalars.dropFirst() where !allowed("-\(letter)") {
                    return "'\(label)' is covered only for listing; '-\(letter)' is not a listing flag"
                }
            } else if !hasListFlag {
                return "'\(label)' with a name would create a branch; only listing is covered"
            }
        }
        return nil
    }
}
