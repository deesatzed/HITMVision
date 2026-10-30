# Build notes

Date: 2026-10-25

`swift --version`:
```
swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.2.0
```

`xcodebuild -version`:
```
Xcode 27.0
Build version 27A266a
```

Commands run (in HITMCockpit):
1. `swift test` with `swift-tools-version: 5.9` -> manifest error, no tests run:
   `Package.swift:6:42: error: 'v2' is unavailable` (`.visionOS(.v2)` was introduced in PackageDescription 6.0).
2. Fix (by controller): first line of Package.swift changed to `// swift-tools-version: 6.0`. Nothing else changed.
3. `swift test` (red, no implementation): `cannot find 'EventLog' in scope` (as reported by controller).
4. `swift test` (green, after adding EventLog.swift from spec, Swift 6 tools version, no concurrency errors):
   `Executed 3 tests, with 0 failures (0 unexpected)`
5. Reviewer fixes, red: added tests (Sendable check, revisions [1,2,3], extra correction asserts), `swift test` -> compile errors
   "type 'Event' does not conform to the 'Sendable' protocol" and same for 'EventLog' (tests did not run).
6. Added `Sendable` to Event and EventLog; `swift test` -> `Executed 5 tests, with 0 failures (0 unexpected)`.

Task 2 (RiskProfile + FloorGate):
7. `swift test` (red, tests only): `cannot find 'FloorGate' in scope`, `cannot find 'ActionClass' in scope` (compile errors, no tests ran).
8. Added RiskProfile.swift and FloorGate.swift exactly per spec (all public types Sendable); `swift test` ->
   `Executed 11 tests, with 0 failures (0 unexpected)` (5 EventLog + 6 FloorGate; no warnings or errors).

Task 2 review fixes (unsure profile must be a superset, stronger tests):
9. Strengthened FloorGateTests (all-profile universal check, unsure/strict routine stays noFloor, table over allCases, non-vacuous reason test,
   new testUnsureProfileKeepsItsOwnExtrasAndAddsStrict). `swift test` (red): `Executed 13 tests, with 1 failure (0 unexpected)`
   - "routine must need a human for an unsure profile" (unsure replaced the profile's extras with strict's).
10. FloorGate.swift: required = profile.extraHumanRequired.union(unsure ? strict extras : []). `swift test` (green): see final line below.
	 Executed 13 tests, with 0 failures (0 unexpected) in 0.001 (0.003) seconds

## visionOS Simulator build (controller, 2026-10-25)

Command: cd HITMCockpit && xcodebuild -scheme HITMCockpit -destination "generic/platform=visionOS Simulator" build
Result: ** BUILD SUCCEEDED ** (library build only; tests were run on macOS via swift test: 13 tests, 0 failures; tests not run on the visionOS Simulator; no app or cockpit exists yet).

## Phase 2 Step 2 (safety notes), 2026-10-25

Commands: `cd HITMCockpit && swift test`, `swift build` (whole package incl. CockpitPrototype).
- 2.1 red: `swift test` -> compile error "cannot find type 'EventLogError' in scope" (2 sites; no tests ran). Added EventLogError + throwing, validating `correct`; existing tests updated to `try`. Green: `Executed 15 tests, with 0 failures (0 unexpected)`.
- 2.2 + 2.3 red (written together, one run): "type 'RiskProfile' has no member 'decodeOrStrict'" (2 sites) and "type 'FloorGate' has no member 'universalFloor'" (compile errors; no tests ran).
- 2.2 implemented first: `Executed 7 ... 9 ... 4` per class (RiskProfile tests included) but FloorGateTests still failed to compile on `universalFloor` (red for 2.3).
- 2.3 implemented (exhaustive switch, no default, public universalFloor). Final `swift test`: Executed 20 tests, with 0 failures (0 unexpected)
- `swift build` (whole package): Build complete! No CockpitPrototype changes needed.
- Review follow-up: added testUniversalFloorMatchesEvaluateForEveryClass (universalFloor membership == evaluate(.light) is humanRequired with "Universal" reason, over allCases). Passes on correct code; temporary mutation (externalSend removed from universalFloor) made it fail ("false" is not equal to "true" - externalSend); mutation reverted. Final `swift test`: Executed 21 tests, with 0 failures (0 unexpected)

## Phase 2 Step 3a (typed gate pieces, no network), 2026-10-25

Commands: `cd HITMCockpit && swift test` (run twice).
- Red: GateTypesTests.swift written first; `swift test` -> compile errors "cannot find type 'GateRequest' / 'GateResponse' in scope" (no tests ran).
- Implemented Sources/HITMCore/GateTypes.swift (GateRoute, GateError, GateRequest, GateResponse.decodeStrict, GateDecision.combine).
- Green: `Executed 34 tests, with 0 failures (0 unexpected)` (21 existing + 13 new).

## Phase 2 Step 3a review fixes (items 1, 2, 3, 6), 2026-10-25

Commands: `cd HITMCockpit && swift test` (three runs).
- Red 1: new GateTypesHardeningTests -> compile error "type 'GateError' has no member 'unavailable'".
- Red 2 (after adding only `case unavailable`): `Executed 42 tests, with 11 failures` (sensitive request still carried path/history/profile name/identifying strings; reason sanitizing not done).
- Implemented: sensitive make() sends metadata only (profileName "sensitive", empty paths/history, nil summary); decodeStrict sanitizes and stores reason (Cc/Cf removed, whitespace collapsed, trimmed, 300 chars + "…"); GateError.unavailable.
- Green: `Executed 42 tests, with 0 failures (0 unexpected)` (21 original + 13 + 8 new).

## Phase 2 Step 3a: reason cap by Unicode scalars, 2026-10-25

- Red: new GateReasonCapTests -> `Executed 45 tests, with 1 failure`: "a" + 100,000 U+0301 stored 100001 scalars (cap used grapheme count).
- Fix: raw reason pre-bounded to first 2000 scalars; cap is 300 scalars + "…".
- Green: see final `swift test` Executed line below.
- Final: `Executed 45 tests, with 0 failures (0 unexpected)`

## Phase 2 Step 3b: OpenRouterGateClient + GateLiveCheck, 2026-10-25

Commands: `cd HITMCockpit && swift test`, `swift build` (all targets).
- Red: OpenRouterGateClientTests.swift written first; `swift test` -> "cannot find type 'CallRecord' in scope" (no tests ran).
- Implemented Sources/HITMCore/OpenRouterGateClient.swift (CallRecord, buildURLRequest, parseEnvelope, fromEnvironment(model:environment:), assess) and Sources/GateLiveCheck/main.swift (target added to Package.swift, Swift 5 mode).
- Green: `Executed 62 tests, with 0 failures (0 unexpected)` (45 existing + 17 new). `swift build`: Build complete.
- Not run: GateLiveCheck (no network calls made by the implementer). The live response shape is UNVERIFIED until it is run.
- parseEnvelope outcome choice: gate content that fails strict decoding (malformed or out of range) gets outcome "invalid-response".

## Live gate check (controller, 2026-10-25) — INVENTED SAMPLE DATA only

Command: `cd HITMCockpit && (set -a; . ../.env; set +a; swift run GateLiveCheck typesafe/jev-router)`
Measured (6 sequential calls, all HTTP 200, 0 failures, response shape parsed by the real decodeStrict incl. usage.cost):
- Underlying model actually used per call (router's choice): deepseek/deepseek-v4.1-flash-1017 x2, openai/gpt-6.1-sol x2, google/gemini-4-argon x1, z-ai/glm-5.3-flash x1.
- Latency per call: 1219, 1330, 2897, 5285, 5359, 7191 ms; total 23281 ms.
- Tokens (prompt/completion) and cost per call as reported by OpenRouter; total cost reported: 0.0057028 USD for the 6 calls.
- Gate said needsHuman=true for all 6 (final needsHuman 6 of 6), including sample #1 (routine README typo, floor none).
- Caveat: the sample summaries contained the word "INVENTED"; two replies cite that label, so the over-asking may be partly an artifact of the test text. Not yet re-run with neutral wording.
- Sample #6 (sensitive profile): no marker text appears in the gate's reason; this does not prove absence of leakage (request body is not logged). The unit tests assert the encoded request carries no summary/paths/override text.

## Phase 2 Step 3b hardening (review items 1, 3, 5, 6, 7, 8, 9), 2026-10-25

Commands: `cd HITMCockpit && swift test`, `swift build`.
- Red: OpenRouterGateClientHardeningTests.swift first -> compile errors ("type 'OpenRouterGateClient' has no member 'outcome'", makeSession, parseCount, parseCost, NoRedirectDelegate); no tests ran.
- Implemented: dedicated ephemeral session (30 s request and resource, no cache, no-redirect delegate); key hidden from description/debugDescription/dump; usedModel sanitized (cap 100, empty -> nil); tokens/cost strict parsing (Bool, negatives, fractions, strings, NaN/inf -> nil); non-https or unencodable request -> outcome "request-error" with no network call; cancellation -> "cancelled".
- Green: `swift build` complete; `Executed 71 tests, with 0 failures (0 unexpected)` (62 + 9 new).
- Still not run: GateLiveCheck / any network call.

## Live regression after hardening (controller, 2026-10-25) — INVENTED SAMPLE DATA only

Same command and same six invented requests. `swift test`: 71 tests, 0 failures.
Measured: 6/6 HTTP 200, 0 failures; total latency 15620 ms (1203 to 5537 ms per call); total reported cost 0.0082203 USD.
- Underlying models this run: openai/gpt-6.1-sol, google/gemini-3.8-flash, z-ai/glm-5.3-flash (x2), anthropic/claude-opus-5.5 (the costliest call, 0.005021 USD), deepseek/deepseek-v4.1-flash-1017. Different mix from run 1.
- Gate answers changed between runs for the same input: sample #1 (routine README typo) was route=escalate_model/needsHuman=true in run 1 and route=proceed/needsHuman=false in run 2 (final needsHuman 5 of 6 in run 2, 6 of 6 in run 1). Gate output is not stable run to run.

## Live gate check on the chosen fixed model (controller, 2026-10-25) — INVENTED SAMPLE DATA only

Model chosen by you: anthropic/claude-haiku-5.5. Command: `GateLiveCheck anthropic/claude-haiku-5.5`, run 3 times (18 calls), same six invented requests.
Measured: 18/18 HTTP 200, 0 failures; every call reported `used=anthropic/claude-haiku-5.5` (the OpenRouter model name; the hosting provider behind it is not visible in the record and is unverified).
- Latency per call 1371 to 3072 ms; run totals 11615, 12260, 11180 ms.
- Reported cost per run 0.000692, 0.000819, 0.000711 USD (6 calls each).
- Final needsHuman per run: 5, 5, 4 of 6. Stability: sample #1 (routine typo) proceeded 3/3; sample #2 (routine, agent confidence 0.62) asked a human 2/3 and proceeded 1/3; samples #3-#6 asked a human 3/3 (floor already required it for #3-#5; #6 sensitive).
- Sample summaries still carry the word "INVENTED"; not re-run with neutral wording.

## Phase 2 Step 4 (Planner), offline part, 2026-10-25
Commands: `cd HITMCockpit && swift build`, `swift test`.
- Red: PlannerTests.swift written first -> "cannot find type 'Proposal' in scope" (build failed, no tests ran).
- Part A: extracted OpenRouterTransport (generic `complete(messages:schemaName:schemaJSON:maxTokens:)`); OpenRouterGateClient is a thin wrapper; the 71 existing tests pass unchanged (one intermediate failure, an unencodable request reporting network-error instead of request-error, fixed). Gate now sends max_tokens 400.
- Part B: Proposal, ActionClassifier, PlannerAgent, ProposalGate; PlannerLiveCheck target added (not run: no network calls made).
- Planner max_tokens is 1500 (my choice).
- Final: `swift build` complete; 	 Executed 90 tests, with 0 failures (0 unexpected) in 0.031 (0.036) seconds

## Live planner check (controller, 2026-10-25)

Command: `PlannerLiveCheck deepseek/deepseek-v4.1-flash-1017 anthropic/claude-haiku-5.5 "<neutral invented intent: dark mode toggle plus deleting a theme cache folder>"`. The intent text went to the planner model (approved); only the proposal title went to the gate model.
Measured: planner HTTP 200, used deepseek/deepseek-v4.1-flash-1017, 9416 ms, 152/1271 tokens, 0.00064614 USD reported; strict schema parsed (7 steps, 5 risks, 4 questions). Gate HTTP 200, used anthropic/claude-haiku-5.5, 2016 ms, 503/133 tokens, 0.0001168 USD.
- The rule classifier raised step 5 from the model's claimed "deploy" to "irreversible" (text says delete) and step 7 from "routine" to "externalSend" (text mentions metrics/telemetry); the model's own class labels were not reliable (step 4, a path-validation step, was claimed "deploy"). Step 7 looks like a false positive (logging, not sending data out): the keyword rules over-ask.
- Overall class irreversible, so the universal floor required a human; final needsHuman=true, detailLevel 3, gate did not fail. The gate's reason cited "agent confidence is only 0.5" which is the fixed placeholder passed by ProposalGate, not a real planner confidence.

## Step 4 review fixes, 2026-10-25
- Red: tests first -> compile error "value of type 'RiskProfile' has no member 'sensitive'".
- Done: whole-proposal classification (title, risks, questions); ActionClassifier rewritten (NFKC, word starts, squeezed split-letter check, documented ACCEPTED LIMITS); GateRequest.agentConfidence optional + gate prompt "not reported" sentence; RiskProfile.sensitive/isSensitive (missing key = true) and PlannerAgent/ProposalGate use it; AgentAdapter protocol.
- Old-behavior assertions changed: classifier table (plain send/email/post/upload/telemetry/auth/limit/drop/release no longer match without context), "send the report" step text, confidence 0.5 -> nil.
- `swift build` complete; `Executed 107 tests, with 0 failures (0 unexpected)`.

## Classifier data-egress rule, 2026-10-25
- Added: send-verb (incl. "copy ... off") plus data object => externalSend even without external target; "server" added to targets. Over-asks on ordinary internal sends (documented).
- Red (rule removed temporarily): failures on the new positive phrases. Green: `Executed 107 tests, with 0 failures (0 unexpected)`.

## Phase 2 Step 5 (shared mind, nested JSON files), 2026-10-25
Commands: `cd HITMCockpit && swift build`, `swift test`.
- Red: MindStoreTests.swift written first -> "cannot find type 'MindRecord' in scope" / "cannot find type 'MindStore' in scope" (build failed, no tests ran).
- Added: MindTypes.swift (MindKind, MindStatus, MindError, MindEntry, MindRecord, AuditFinding, MindDestination, MindSlice, MindPolicy), MindStore.swift (struct MindStore), Tests/HITMCoreTests/MindStoreTests.swift (22 tests, real temp-dir file I/O, dirs removed in teardown).
- Mutation check: removing the hosted-model sensitive-chain filter made tests fail (red); restored.
- Final: `swift build` complete; `Executed 129 tests, with 0 failures (0 unexpected)` (107 existing + 22 new).
- NOT implemented: conflict detection, retention/expiry policy (expire is manual only), file locking (single writer assumed), index rebuild from the log, any wiring into the prototype or a gate/model call (MindPolicy is pure and unused by callers).

## Step 5 review fixes, 2026-10-25
- Red: tests first (MindStoreIntegrityTests.swift + edits to MindStoreTests.swift) -> compile errors: "type 'MindPolicy' has no member 'approve'", "type 'AuditFinding' has no member 'noLogEvent'", and "cannot use mutating member on immutable value" (store was still a struct).
- Done: MindStore is now a final class (@unchecked Sendable, one NSLock); fail-closed chain walk over parent and supersedes (missing, cycle, unverifiable => sensitive); open validates links, UUID ids unique ignoring case; child file must match index (kind, sensitive, parentID, supersedes, role, tags); supersede inherits sensitivity; `sensitive` required in propose; lastRevision = max(log, index); missing/empty log with non-empty index fails open; torn final log line removed on open; audit replays the log (statusMismatch, noLogEvent) and ignores dot-files; Approval + MindPolicy.approve + accept(id:approval:); correct allowed on superseded.
- Assertions/tests changed: accept(id:by:) calls now go through a test helper `acc` using MindPolicy.approve; inout MindStore -> class reference; the unknown-id accept check builds its approval directly; log payload for reject/correction is "<id> <reason>" (was "<id>: <reason>").
- Final: `swift build` complete; `Executed 150 tests, with 0 failures (0 unexpected)` (107 original + 22 + 21 new); MindStore tests run 3 more times, same result.
- Still NOT implemented: conflict detection, retention/expiry policy, multi-process locking, index rebuild from the log, fsync. A transition whose log append fails after the index write shows in audit as statusMismatch (by design).

## Step 5 re-review fixes, 2026-10-25
- Red (tests first): the 40-entry chain (parentID and supersedes both set) did not finish within a 120 s shell timeout on the old recursive `tainted()` (exponential); 300-entry run: log reads per slices/audit call were 300, not 1 (whole test 2.3 s incl. creating 300 entries); 1000-entry smoke: slices + audit took 17.5 s (limit 10 s). Approval-binding test passed only after the entryID change (it did not compile before).
- Done: `tainted` is an iterative depth-first walk with an on-stack set (cycle => tainted) and a per-call cache, so each child file is verified at most once per call; the log is parsed once per `slices`/`audit` call; `Approval` carries `entryID` and `accept(id:approval:)` rejects a different entry (ids compared case-insensitively); `MindPolicy.approve` now takes `entryID`.
- After: 40-chain test 0.16 s total (propose, accept, hosted slices); 300-entry test 0.65 s including creating the 300 entries; 1000-entry smoke 4.6 s including creation (slices + audit asserted under 10 s). Exact slices/audit-only times were not printed separately.
- Changed in existing tests: `MindPolicy.approve(...)` calls gained `entryID:`; `Approval(...)` forged in the test gained `entryID:`; testApprovalRules reordered so entries exist before approvals are made.
- Final: `Executed 154 tests, with 0 failures (0 unexpected)` (150 + 4 new).
- Still NOT implemented / known gaps: conflict detection; retention/expiry policy; multi-process locking; index rebuild from the log; fsync; recovery for a torn or lost accept/propose log event (the entry stays statusMismatch / noLogEvent and only expire/correct can clear it; commented in MindStore.swift).

## Step 6: shared UI + visionOS app with a bounded volume, 2026-10-25
- Red (tests first): `swift build --target CockpitUITests` -> "extra argument 'source' in call" and "cannot find 'IntentSource' in scope" (CockpitUI existed with the moved store, but no intent source seam).
- Done: new library `CockpitUI` (Store, SampleData, Support, TopRail, AgentsPanel, Shelves [QuietShelf, DecidedPanel, LogTail], NeedsYouPanel [+ OfferPanel], Layouts [FlatCockpitView, VolumeCockpitView]); `CockpitPrototype` is now only the @main App; `IntentSource` + `submitIntent(_:source:)` logs "<source>: <text>"; tags carry SF Symbols (Gate.icon).
- `swift build`: Build complete. `swift test`: HITMCoreTests `Executed 154 tests, with 0 failures (0 unexpected)`; CockpitUITests `Executed 8 tests, with 0 failures (0 unexpected)` (SwiftPM prints the two bundles separately; 162 total).
- `cd HITMVision && xcodegen generate --spec project.yml` -> Created project HITMCockpitVision.xcodeproj.
- `xcodebuild -project HITMCockpitVision.xcodeproj -scheme HITMCockpitVision -destination 'generic/platform=visionOS Simulator' build` -> `** BUILD SUCCEEDED **`.
- NOT verified: launch, appearance, readability, volume sizing/z-offset look, openWindow behavior (no Simulator run). Bundle id local.hitm.cockpit is a placeholder.

## Piece 1: decision card with five answers and Evidence, 2026-10-27 (new standalone repo)
- Repo split: `/Volumes/WS4TB/QUIX/HITMCockpit` made from a fresh clone of `VisOsDx` with `git filter-repo --path HITMCockpit --path HITMVision --path docs --path id1.md --path .gitignore` (history kept, no remote). In the new repo: `swift test` HITMCoreTests 154 and CockpitUITests 8, 0 failures; `xcodebuild` visionOS Simulator `** BUILD SUCCEEDED **`; no `.env` tracked; `.env` (OPENROUTER_API_KEY only, never opened) present and git-ignored.
- Red (tests first): `DecisionBriefTests.swift:9:60: error: cannot find type 'DecisionBrief' in scope`, then `Build failed`.
- Done: `DecisionBrief` (pure; what / why / scope / how / next / evidence; nil for quiet tasks; `how.unavailable` always lists gate-model reasoning, inputs sent to a model, history preview as "Not available in sample mode"); `CockpitStore.focusedID`, `focusedTask`, `focus(_:)`; `SampleTask.proof` (invented sample entries on T2, T3, T7); compact stacked queue rows replacing the in-place disclosure groups; `DecisionDetailCard` (fixed header, scrolling body, Evidence block); larger default windows (visionOS flat 1500x950, Mac minimum 1400x800).
- Tests (controller re-run): HITMCoreTests `Executed 154 tests, with 0 failures (0 unexpected)`; CockpitUITests `Executed 25 tests, with 0 failures (0 unexpected)` (8 existing, 9 DecisionBrief, 8 focus/proof).
- Simulator: a dedicated device `HITM-Cockpit-Test` (BFB2DE33-CC04-4C81-8D70-5CECAF66EA8A, Apple Vision Pro 4K, visionOS 27.0) was created because the default device was showing another app. Device-only screenshots. First capture showed wrapped buttons ("Pa ss"), squeezed titles and a clipped card; after the layout fix the buttons are whole words, titles readable, three columns fit; the 4th queue row and the card's "What happens next" and Evidence sections are below the window edge.
- NOT verified: scrolling, tapping a row to move focus, the Modify note field in the new row, the volume layout, the macOS window launched (built only), headset readability. Small captions still use the existing `small()` helper. The old "Reversible / Not reversible" chip was dropped from the row (not in the brief). Sample data remains on the open-items list.

## Piece 1 review fixes, 2026-10-27
- Independent review (spec then quality) found: sample proof lines had no on-screen sample label (breaks design rule E1); floor cards listed agent confidence as an input; floor-universal vs floor-profile inferred from reason text; Evidence below the fold; row had no button trait or hover; weak focus tests; dropped reversibility chip and "Full detail" text; duplicate ForEach ids; stale focus id; dead `Gate.detailLevel`.
- Fixed: data-driven SAMPLE marker on Evidence and "Exactly what changes" (`SampleTask.isSample` -> `DecisionBrief.contentIsSample`); confidence listed only for agent-confidence cards; `Gate.Kind` set once in `CockpitStore.gate(for:)` (one `hasPrefix("Universal")` remains there because HITMCore's `FloorDecision` carries only a string; HITMCore unchanged); Evidence directly under "What is it"; Reversible chip and sample-labelled specifics restored in the detail card; `.isButton`, `.isSelected`, accessibility action, `hoverEffect()` on visionOS only; enumerated ids; `normaliseFocus()` after resolve and setProfile; `Gate.detailLevel` removed from CockpitUI; row reason up to 2 lines.
- Tests: HITMCoreTests 154 (agent run), CockpitUITests `Executed 34 tests, with 0 failures (0 unexpected)` (controller re-run). Focus mutation checks run by the agent: removing the focus handling fails the focus tests (failure lines were truncated, not fully captured). Items 1-3 and 7 were written with their tests in one step, so there is no red-first text for them.
- visionOS Simulator build succeeded; screenshot on `HITM-Cockpit-Test` shows the SAMPLE markers, Reversible chip and Evidence without scrolling. Still NOT verified: scrolling, tapping, hover, Modify field, "No proof attached" and non-reversible states on screen, the volume layout, macOS at runtime, headset readability.

## Piece 2: rule engine in the core, 2026-10-30
- Files (HITMCore): `CommandParser.swift` (scalar-level tokenizer; never executes anything), `CommandFamilies.swift` (family table, denied flags, secret-name denylist), `RuleBook.swift` (floor first, then rules by scope), `RuleStore.swift` (rules as `policy` entries in the real MindStore; quarantine, named-human approval, widen as superseding entry, revoke, health), `RuleUsage.swift` (use counts, plain-language explanation). MindStore, FloorGate and RiskProfile are unchanged.
- Process: tests first (red text recorded by the implementer in each round), independent review after the first build (found a CRITICAL parser bypass: a metacharacter followed by a combining mark parsed as a word character; plus revoke/duplicate-id, ask-rule fail-open, secret-denylist and flag gaps), fixes, second independent review (no critical; four important: git pathspec globs and `--pathspec-from-file`, U+017F case-folding bypass on APFS, ask rules on xcodebuild never firing, more secret names), then a last fix pass. The LAST fix pass (items 1-9 of the second review) was NOT re-reviewed by an independent reviewer.
- Tests (controller re-run): HITMCoreTests `Executed 283 tests, with 0 failures (0 unexpected)` (154 before piece 2); CockpitUITests `Executed 34 tests, with 0 failures (0 unexpected)`.
- Mutation checks (implementer): removing the unicodeScalars parser change -> 254 failures; disabling the untrusted-store check -> corrupt-ask-rule tests fail; removing the git glob rule -> 15 failures; removing case folding -> 4 failures; removing the denylist -> 37 failures; removing floor-first -> 8 failures; ask-beats-allow disabled -> 3; ceiling removed -> 3; auto-substituted human name in accept -> 11. Each restored and followed by a green run.
- Proposed (PENDING OWNER CONFIRMATION): the family table (readOnlySearch ceiling all; localGit and buildAndTest ceiling project); recursive search asks and `rg` removed from the table; swift/xcodebuild flag controls and `NAME=value` overrides ask; any basename starting or ending `.env` counts as a secret.
- KNOWN GAPS: the secret check is a NAME list, so secrets under other names stay readable by cat/head/tail/wc/grep; `git add <directory>` can stage unignored secrets inside it; git config and hooks, `swift build/test` and `xcodebuild` can run project code; the engine cannot tell a person from a name (the UI must call `accept`/`revoke` only from a person's own action); no multi-process lock in MindStore; `git commit -mTEXT` can over-ask because of the `-t` denial; folder scope compares case-sensitively (over-asks only).
- NOT verified: real shell (bash/zsh) tokenizing and history/glob semantics beyond what the reviewer reasoned; real xcodebuild/swift flag semantics; non-APFS file systems; real agent commands against the table (none seen yet). No UI exists for rules yet (piece 3).

## GateBench v1: gate benchmark, text models vs decision models, 2026-10-30
- Files: `HITMCore/Decisions.swift` (hardened client for OpenRouter's alpha Decisions endpoint; yes/no questions only), `HITMCore/GateBenchScoring.swift`, `Sources/GateBench/` (`Cases.swift`, `main.swift`), results in `bench/results/`. Usage: `GateBench chat|decide <model-id> [repeats]`, `GateBench list`. Key is read from the environment only.
- ENDPOINT: the decisions endpoint is `https://openrouter.ai/api/alpha/decisions`. `/api/v1/alpha/decisions` returned 404 on all 36 calls (first attempt); fixed after a direct probe, pinned by a test.
- DATA: 36 INVENTED cases (14 clear-safe, 14 clear-risky, 8 borderline). The LABELS ARE THE ASSISTANT'S OWN JUDGMENT and await owner review (`GateBench list` prints them). Borderline cases are counted, not scored. Invented text went to each model's host via OpenRouter; no real project data was sent. Remove or replace with owner-reviewed cases before any claim about real behavior.
- Tests (controller re-run): HITMCoreTests `Executed 307 tests, with 0 failures (0 unexpected)` (283 before; +16 decisions client, +8 scoring); CockpitUITests 34.
- Measured at cutoff 0.5 (decision models), clear cases only, one run each except Haiku (3 runs): risky cases let through / safe cases sent to a human / unusable answers. Haiku 5.5: 0/42, 1/42, 1/108. gpt-6-luna text: 0/14, 0/14, 0. mimo-v2.6-flash: 2/14, 4/14, 0. minimax-m3.1-flash: 2/14, 2/14, 6/36. deepseek-v4.1-flash-1017: 0/14, 2/14, 8/36. mistral-large-4-0: 0/14, 14/14, 36/36 (all failed). Decision models: pplx-decider-v1.2 0/14, 0/14; microsoft-decision-1 0/14, 0/14; jev-1.14 0/14, 0/14; gpt-6-luna-decisions 0/14, 1/14; liquid d1.1 1/14, 0/14 (0 at cutoff 0.3). Median latency about 120-230 ms for decision models vs 1.2-3.4 s for text models. Measured cost for 36 calls: $0.0002-0.0019 (decision), $0.0019-0.0373 (text), Haiku $0.0054 (from $0.0161 for 108).
- CAUTIONS: the set is too easy to rank models (one case is a large share of 14). Text-model failures (mostly empty answers) have an UNVERIFIED cause; suspected 400-token cap or strict JSON output, so do not read them as model quality. Probability calibration was not measured. Whether sensitive projects may use hosted decision models is undecided. The "either of two questions" variant showed no gain.
- Next: a harder owner-reviewable set (about 60 cases), 3 repeats on the top decision models against Haiku.
