# HITM Cockpit Phase 2 Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (chosen by you 2026-10-25) to implement task-by-task. Subagents do not commit; the controller commits after both reviews pass.

**Goal:** Replace the prototype's invented behavior with real behavior, in the order you approved ("proceed with all 6").

**Context:** Phase 1 and the flat prototype are committed (`39cc15e`, `cf8f9ae`). Decisions D1–D7 are in `2026-10-25-hitm-swe-cockpit-plan.md`. Default model `deepseek/deepseek-v4.1-flash-1017`; gate model `typesafe/jev-router`; our own orchestrator calls OpenRouter directly; key lives in a git-ignored `.env` that must never be read into logs, chat or commits.

**Standing rules:** real services and real data only; the prototype's sample data stays labeled until replaced; every outside-service call is logged with its source; sensitive projects send metadata only to the gate; no model chooses anything the floor forbids.

---

## Step 2 — Close the deferred safety notes (small, fully specified)

Files: `Sources/HITMCore/EventLog.swift`, `RiskProfile.swift`, `FloorGate.swift` and their tests.

- **2.1 `EventLog.correct` must reject a foreign event.** Add `public enum EventLogError: Error, Equatable { case foreignEvent }`. `correct` becomes `throws`: it must throw unless `target` is exactly the event stored in this log at `target.revision` (same session, same contents). Tests: correcting an event from another log throws; correcting one with a forged revision throws; the valid case still appends and keeps the original.
- **2.2 A profile that cannot be decoded must never become `.light`.** Custom `init(from:)` defaults a missing `unsure` to `true`. Add `public static func decodeOrStrict(_ data: Data) -> RiskProfile` returning `RiskProfile(name: "undecodable", extraHumanRequired: [], unsure: true)` on any decode failure. Tests: missing `unsure` decodes as unsure; garbage and unknown action classes yield an unsure profile whose `.editDomainLogic` requires a human; a valid profile round-trips unchanged.
- **2.3 No fail-open for new action classes, and a read-only floor.** Rewrite `FloorGate.evaluate` as an exhaustive `switch` over `ActionClass` with no `default`; add `public static let universalFloor: Set<ActionClass>` (same set used by `evaluate`). Existing tests must pass unchanged; add a test that `universalFloor` equals the three expected classes.

Done when: `swift test` all green, red steps shown, both reviews approved.

## Step 3 — Real gate call (`GateClient`)

New core pieces, tested without the network where possible, plus one live check:
- `GateRequest` (typed): `{actionClass, profileName, filePaths, changeSize, agentConfidence, overrideHistorySummary, summary?}`. **`summary` is omitted when the profile is marked sensitive** (metadata only).
- `GateResponse` (typed, strict decoding): `{route, needsHuman, detailLevel, confidence, reason}`; anything missing or malformed is rejected and treated as "needs human" (fail closed).
- `GateDecision.combine(floor:gate:)`: the floor always wins; a gate response can only add a human check, never remove one (reuses `FloorGate.needsHuman`).
- `OpenRouterGateClient`: calls `typesafe/jev-router` with a structured-output request; reads the key from the environment (never printed); logs model used, token counts and latency per call to the event log; any network or parse failure returns "needs human".
- **Live-call boundary:** the first live calls send only invented sample-task metadata and summaries (prototype data), which you approved for the gate in D5b. Real project text is not sent until you approve it for that destination. Measure and report real latency, cost and how often it asks for a human; no estimates.
- Prototype switch-over: replace the invented 0.70 threshold with the real client behind a visible "LIVE GATE" vs "SAMPLE GATE" label.

## Step 4 — Real intent: a Planner agent

- `AgentAdapter` protocol (any role, any model) and a `PlannerAgent` using `deepseek/deepseek-v4.1-flash-1017` through OpenRouter.
- Intent bar submits to the Planner; its reply is a typed `Proposal` card that passes the gate before it reaches the human. The agent never executes anything; it proposes.
- Same logging and fail-closed rules as step 3. Intent text counts as project content: it is sent only if the profile allows it and you have approved that destination.

## Step 5 — Shared mind (design first)

Needs a short design note and your decisions before code: storage format (local files vs a small database), what a memory/prompt/context entry looks like, the quarantine queue for proposals, and the rule that every prompt change passes a gate. Then tasks: store, quarantine, gated prompt changes, correction events, conflict flags, sensitive-data exclusion. Not planned in code here to avoid inventing those decisions.

## Step 6 — Vision Pro cockpit (design first)

**Decided 2026-10-25: a bounded volume** (your choice; my recommendation had been windows first). Conditions carried from the design doc, not yet met: the flat cockpit stays fully functional and shares the same state; the spatial layout must be shown to help (compare against the flat version on the same tasks, with measured results, before any claim); no moving cards, no unreadable 3D text. Still needed first: an Xcode visionOS app project (none exists), the layout design (which information gets which stable place in the volume), and a Simulator validation plan.

Needs an Xcode visionOS app target (none exists in `HITMCockpit/`), a decision on windows vs a bounded volume, and a flat/spatial parity test plan, per the design doc. Tasks after that: app target, move the card views, spatial landmarks only where they prove useful, Simulator validation with real captures and exact versions recorded in `BUILD_NOTES.md`.

## Cautions carried into step 3 (from step 2 reviews)
- Always decide through `FloorGate.evaluate`; never read `profile.extraHumanRequired`, `profile.name` or `isEmpty` to judge strictness (the undecodable fallback has an empty set and is strict only via `evaluate`).
- Load profiles only through `RiskProfile.decodeOrStrict`; never `try? decode ?? .light`.
- Strict does not gate `.routine`; if the fallback should be stricter, make it require a human for every non-universal class (decision for you).
- `EventLog.correct` can correct a correction or the same event twice; fine unless step 3 relies on one correction per event.
- The floor/universalFloor equivalence test matches the reason prefix "Universal"; reword the reason and the test must change with it.

## Notes from step 3a reviews (2026-10-25)
- `GateResponse.confidence` is validated but deliberately NOT used by `combine` yet; the gate's own `needsHuman`/`route` and the floor decide. Revisit once real gate output is measured.
- Duplicate keys in a gate response: first value wins (JSONDecoder); extra keys are ignored. A later, more cautious value would be ignored. Not exploitable (combine only adds humans) but should be tightened if the model ever repeats keys.
- `GateRequest`/`GateResponse` have only internal memberwise inits; step 3b must live in HITMCore (or add public inits).
- Sensitive profiles send metadata only: no paths, no override text, no summary, and a generic profile name.

## Step 3b live results (2026-10-25, invented sample data; see BUILD_NOTES.md)
- Works end to end: 6/6 calls HTTP 200, real response parsed; total latency 23.3 s sequential (1.2 to 7.2 s per call); total reported cost 0.0057 USD for 6 calls.
- **Router picks different providers per call** (deepseek, openai, google, z-ai). Your approved destination was `typesafe/jev-router`; the underlying providers vary and you did not choose them. Decision needed from you before any real project text is sent.
- **Gate asked a human for 6 of 6**, including a trivial typo fix. Possibly caused by the word "INVENTED" in the test summaries. As measured, this does not yet support the "quiet by default" goal; needs a re-run with neutral wording and, ideally, a gate prompt tuned to the profile.

## Step 3b regression run (2026-10-25, invented sample data)
- After hardening: 71 tests pass; live 6/6 HTTP 200; total 15.6 s, 0.0082 USD reported.
- Same input gave different gate answers across runs (README typo: asked a human in run 1, proceeded in run 2) and a different mix of underlying providers, including one call to anthropic/claude-opus-5.5 at 0.005 USD. Variability in decisions, providers and cost is a measured property of the router.

## Open items
- Step 4 (Planner) and any real project text to the gate are paused pending your routing decision.
- Steps 5 and 6 await design notes and your decisions.
- Live gate behavior, cost and latency are unmeasured until step 3 runs.
- D8 (fixture data in tests) is still open; steps 2 and most of 3 need none.
