import Foundation

#if os(macOS)
public enum WorkspaceError: Error, Equatable, Sendable {
    case notAGitRepo, invalidID, git(String), unsafeWrite(String), noChange
}

/// Git operations for one target repo, always inside a separate worktree on branch `hitm/<id>`. Nothing here touches the
/// repo's current branch or working files, pushes, merges or force-anything. macOS only (it starts `git`).
public struct Workspace: Sendable {
    public let repo: URL
    public static let maxFiles = 20
    public static let maxFileBytes = 20_000
    public static let maxDiffScalars = 20_000

    public init(repo: URL) throws {
        let root = repo.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path, isDirectory: &isDir), isDir.boolValue
        else { throw WorkspaceError.notAGitRepo }
        self.repo = root
    }

    public func worktreeURL(_ id: String) -> URL { repo.appendingPathComponent(".hitm/worktrees/\(id)") }
    public static func branchName(_ id: String) -> String { "hitm/\(id)" }

    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Hooks, external diff drivers and filesystem monitors are switched off: this tool only reads and records.
        p.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_OPTIONAL_LOCKS"] = "0"; env["LC_ALL"] = "C"
        for k in env.keys where k.hasPrefix("GIT_") && !["GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS"].contains(k) { env[k] = nil }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { throw WorkspaceError.git("could not start git") }
        // Read both pipes before waiting so a large output cannot block the child.
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw WorkspaceError.git(String(decoding: e, as: UTF8.self).prefix(300).description)
        }
        return String(decoding: o, as: UTF8.self)
    }

    /// Tracked text files the implementer may see: at most 20 files of at most 20 KB each, UTF-8 only, no symlinks.
    public func readableFiles() throws -> [String: String] {
        let names = try Self.git(["ls-files", "-z"], in: repo).split(separator: "\0").map(String.init)
        var out: [String: String] = [:]
        for n in names.sorted() {
            guard ChangeSet.safePath(n) != nil else { continue }
            let u = repo.appendingPathComponent(n)
            let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
            guard attrs?[.type] as? FileAttributeType == .typeRegular, let size = attrs?[.size] as? Int, size <= Self.maxFileBytes,
                  let data = FileManager.default.contents(atPath: u.path), let text = String(data: data, encoding: .utf8) else { continue }
            out[n] = text
            if out.count >= Self.maxFiles { break }
        }
        return out
    }

    public func prepare(id: String) throws -> URL {
        guard CardInbox.isValidID(id) else { throw WorkspaceError.invalidID }
        // Keep this tool's folder out of `git status` without editing tracked files.
        let exclude = URL(fileURLWithPath: try Self.git(["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        if !current.split(separator: "\n").contains(".hitm/") {
            try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + ".hitm/\n").write(to: exclude, atomically: true, encoding: .utf8)
        }
        let wt = worktreeURL(id)
        try FileManager.default.createDirectory(at: wt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.git(["worktree", "add", "-b", Self.branchName(id), wt.path, "HEAD"], in: repo)
        return wt
    }

    /// Writes each edit inside the worktree. Refuses a destination that is a symlink or whose folders resolve outside it.
    public func apply(_ changes: ChangeSet, id: String) throws {
        guard CardInbox.isValidID(id) else { throw WorkspaceError.invalidID }
        let root = worktreeURL(id).resolvingSymlinksInPath()
        for e in changes.edits {
            guard let safe = ChangeSet.safePath(e.path) else { throw WorkspaceError.unsafeWrite(e.path) }
            let dest = root.appendingPathComponent(safe)
            let parent = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            guard parent.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") || parent.resolvingSymlinksInPath().path == root.path
            else { throw WorkspaceError.unsafeWrite(e.path) }
            if let t = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.type] as? FileAttributeType, t != .typeRegular {
                throw WorkspaceError.unsafeWrite(e.path)
            }
            do { try e.content.write(to: dest, atomically: true, encoding: .utf8) } catch { throw WorkspaceError.unsafeWrite(e.path) }
        }
    }

    public struct Diff: Equatable, Sendable {
        public let text: String
        public let truncated: Bool
        public let paths: [String]
        public let added: Int
        public let removed: Int
        /// Added lines only (without the leading +), for the floor's line scan.
        public let addedLineTexts: [String]
    }

    /// Stages everything in the worktree and returns the real diff against HEAD. Throws `noChange` when nothing differs.
    public func diff(id: String) throws -> Diff {
        guard CardInbox.isValidID(id) else { throw WorkspaceError.invalidID }
        let wt = worktreeURL(id)
        try Self.git(["add", "-A"], in: wt)
        let names = try Self.git(["diff", "--cached", "--no-ext-diff", "--name-only", "-z"], in: wt).split(separator: "\0").map(String.init)
        guard !names.isEmpty else { throw WorkspaceError.noChange }
        let full = try Self.git(["diff", "--cached", "--no-ext-diff", "--no-color", "--no-textconv"], in: wt)
        var added = 0, removed = 0
        var addedTexts: [String] = []
        for line in full.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { added += 1; addedTexts.append(String(line.dropFirst())) }
            else if line.hasPrefix("-") { removed += 1 }
        }
        let scalars = full.unicodeScalars
        let truncated = scalars.count > Self.maxDiffScalars
        var shown = String.UnicodeScalarView()
        shown.append(contentsOf: scalars.prefix(Self.maxDiffScalars))
        return Diff(text: String(shown), truncated: truncated, paths: names, added: added, removed: removed, addedLineTexts: addedTexts)
    }

    /// Commits the staged work on the worktree's branch only.
    public func commit(id: String, message: String) throws {
        guard CardInbox.isValidID(id) else { throw WorkspaceError.invalidID }
        let msg = GateResponse.sanitize(message)
        try Self.git(["add", "-A"], in: worktreeURL(id))
        try Self.git(["-c", "user.name=HITM Cockpit", "-c", "user.email=hitm@localhost", "commit", "--no-verify", "-m", msg.isEmpty ? "HITM change" : msg],
                     in: worktreeURL(id))
    }

    /// Removes the worktree and its `hitm/<id>` branch (both created by this tool).
    public func discard(id: String) throws {
        guard CardInbox.isValidID(id) else { throw WorkspaceError.invalidID }
        try Self.git(["worktree", "remove", "--force", worktreeURL(id).path], in: repo)
        try Self.git(["branch", "-D", Self.branchName(id)], in: repo)
    }
}
#endif
