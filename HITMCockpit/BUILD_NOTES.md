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
