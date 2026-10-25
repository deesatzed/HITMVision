# HITM SWE Cockpit Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the headless core (event log, risk profile, fixed-floor gate) of the HITM SWE cockpit, after the open design decisions are settled.

**Architecture:** A Foundation-only Swift package (`HITMCore`) holds all logic that can commit state, so it is testable with `swift test` without the Vision Pro Simulator. The visionOS cockpit comes later and only reads projections of this core. See `2026-10-25-hitm-swe-cockpit-design.md`.

**Tech Stack:** Swift / SwiftPM (**assumption, needs your approval**: chosen because the cockpit is visionOS and Diagnostic Theater uses the same pattern). Xcode 27.0 is installed; toolchain not yet exercised in this session.

**Status:** nothing below has been run. The directory is not a git repository, so every "Commit" step is blocked until you approve `git init` (or name a repo).

---

## Phase 0 — Decisions only you can make (no code until these are answered)

| # | Decision | Notes |
|---|---|---|
| D1 | Approve Swift/SwiftPM for the core | **Decided 2026-10-25: yes** |
| D2 | Approve `git init` in `/Volumes/WS4TB/DM_FEET/VisOsDx` | **Decided 2026-10-25: yes; repo initialized, nothing committed yet** |
| D3 | Agent roles for the first slice | **Decided 2026-10-25:** start with planner/architect, implementer, reviewer/tester and router/gate model; roles vary by context and use case later |
| D4 | Agent models | **Policy decided 2026-10-25:** initial build uses inexpensive models; once established, run task samples at escalating cost levels to compare. **Default for initial build: `deepseek/deepseek-v4.1-flash-1017`** (picked by you 2026-10-25 from the OpenRouter /models list; $0.15 in / $0.60 out per million tokens; quality untested). Escalation candidates to be chosen later |
| D5 | Gate decision model and what it may see | **Picked 2026-10-25: `typesafe/jev-router`**, with caveats from its OpenRouter entry: it chooses the underlying model and reasoning effort itself per request, pricing is variable (listed as -1), and it supports structured outputs. So it is not a fixed model you chose; behavior and cost must be measured. **May see (decided 2026-10-25): metadata plus a one-or-two-sentence task summary.** Because the summary goes to a hosted router, the risk profile must be able to block it: for projects marked sensitive the gate gets metadata only (to be built and tested) |
| D6 | First tool or harness driving agents | **Decided 2026-10-25: option 1, our own orchestrator calling models directly over the OpenRouter API** (key kept in a git-ignored `.env`). Claude Code CLI and ready-made tools (AgentsRoom, Conductor, OpenCode) may be added later as extra agent types; their terms and claims remain unverified |
| D7 | First vertical slice of the cockpit | **Decided 2026-10-25 (you delegated; I chose from a working SWE's view):** a quiet monitor board (one line per task) that interrupts only for items the floor or gate marks as needing a human; a card with Pass / Modify / Reject for those; a digest for everything else; on-demand drill-down into evidence and rules for any task. Not yet built; fatigue thresholds still unset |
| D8 | Whether fixture data is acceptable for tests | Real data only unless you approve; Phase 1 below needs none |

Phase 1 uses no external services, no models and no data beyond values written inside the tests, so it depends only on D1 and D2.

---

## Phase 1 — Headless core

### Task 1: Package skeleton and append-only event log

**Files:**
- Create: `HITMCockpit/Package.swift`
- Create: `HITMCockpit/Sources/HITMCore/EventLog.swift`
- Test: `HITMCockpit/Tests/HITMCoreTests/EventLogTests.swift`

**Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0   (5.9 fails: `.visionOS(.v2)` needs tools 6.0+; found by running swift test 2026-10-25)
import PackageDescription

let package = Package(
    name: "HITMCockpit",
    platforms: [.macOS(.v13), .visionOS(.v2)],
    products: [.library(name: "HITMCore", targets: ["HITMCore"])],
    targets: [
        .target(name: "HITMCore"),
        .testTarget(name: "HITMCoreTests", dependencies: ["HITMCore"])
    ]
)
```

**Step 2: Write the failing test**

```swift
import XCTest
@testable import HITMCore

final class EventLogTests: XCTestCase {
    func testRevisionsStrictlyIncrease() {
        var log = EventLog()
        let a = log.append(kind: "task", payload: "one", author: "human")
        let b = log.append(kind: "task", payload: "two", author: "human")
        XCTAssertEqual(a.revision, 1)
        XCTAssertEqual(b.revision, 2)
    }

    func testNewLogGetsNewSessionID() {
        XCTAssertNotEqual(EventLog().sessionID, EventLog().sessionID)
    }

    func testCorrectionAppendsAndKeepsOriginal() {
        var log = EventLog()
        let original = log.append(kind: "memory", payload: "X", author: "agent")
        let fix = log.correct(original, reason: "wrong", author: "human")
        XCTAssertEqual(log.events.count, 2)
        XCTAssertEqual(log.events[0], original)
        XCTAssertEqual(fix.kind, "correction")
        XCTAssertGreaterThan(fix.revision, original.revision)
    }
}
```

**Step 3: Run it to confirm it fails**

Run: `cd HITMCockpit && swift test --filter EventLogTests`
Expected: FAIL to compile (`EventLog` not defined).

**Step 4: Implement**

```swift
import Foundation

public struct Event: Codable, Equatable {
    public let sessionID: UUID
    public let revision: Int
    public let kind: String
    public let payload: String
    public let author: String
}

public struct EventLog {
    public let sessionID: UUID
    public private(set) var events: [Event] = []

    public init(sessionID: UUID = UUID()) { self.sessionID = sessionID }

    @discardableResult
    public mutating func append(kind: String, payload: String, author: String) -> Event {
        let event = Event(sessionID: sessionID, revision: events.count + 1,
                          kind: kind, payload: payload, author: author)
        events.append(event)
        return event
    }

    /// Deletion is a recorded correction; the original event stays in the log.
    @discardableResult
    public mutating func correct(_ target: Event, reason: String, author: String) -> Event {
        append(kind: "correction", payload: "rev \(target.revision): \(reason)", author: author)
    }
}
```

(`events.count + 1` is safe only because events are never removed; the test in Step 2 and the absence of any remove API enforce that.)

**Step 5: Run to confirm it passes**

Run: `swift test --filter EventLogTests`
Expected: 3 tests, 0 failures.

**Step 6: Commit** — blocked on D2.

---

### Task 2: Risk profile and fixed-floor gate

**Files:**
- Create: `HITMCockpit/Sources/HITMCore/RiskProfile.swift`
- Create: `HITMCockpit/Sources/HITMCore/FloorGate.swift`
- Test: `HITMCockpit/Tests/HITMCoreTests/FloorGateTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import HITMCore

final class FloorGateTests: XCTestCase {
    func testLightProfileLetsRoutineWorkProceed() {
        XCTAssertEqual(FloorGate.evaluate(.routine, profile: .light), .noFloor)
    }

    func testUniversalFloorAppliesToEveryProfile() {
        for action in [ActionClass.irreversible, .deploy, .externalSend] {
            XCTAssertNotEqual(FloorGate.evaluate(action, profile: .light), .noFloor)
        }
    }

    func testStrictProfileAddsDomainLogicAndSafetyCheckEdits() {
        for action in [ActionClass.editDomainLogic, .editSafetyCheck] {
            XCTAssertNotEqual(FloorGate.evaluate(action, profile: .strict), .noFloor)
            XCTAssertEqual(FloorGate.evaluate(action, profile: .light), .noFloor)
        }
    }

    func testUnsureProfileIsTreatedAsStrict() {
        let unsure = RiskProfile(name: "unsure", extraHumanRequired: [], unsure: true)
        XCTAssertNotEqual(FloorGate.evaluate(.editDomainLogic, profile: unsure), .noFloor)
    }

    func testSmartLayerCanAddButNeverRemoveHuman() {
        let floor = FloorGate.evaluate(.deploy, profile: .light)
        XCTAssertTrue(FloorGate.needsHuman(floor: floor, smartNeedsHuman: false))
        XCTAssertTrue(FloorGate.needsHuman(floor: .noFloor, smartNeedsHuman: true))
        XCTAssertFalse(FloorGate.needsHuman(floor: .noFloor, smartNeedsHuman: false))
    }
}
```

**Step 2: Run to confirm it fails**

Run: `swift test --filter FloorGateTests`
Expected: FAIL to compile.

**Step 3: Implement**

`RiskProfile.swift`:

```swift
public enum ActionClass: String, Codable, CaseIterable {
    case irreversible, deploy, externalSend
    case editDomainLogic, editSafetyCheck
    case routine
}

public struct RiskProfile: Codable, Equatable {
    public let name: String
    public let extraHumanRequired: Set<ActionClass>
    /// If the profile could not be determined, the stricter profile applies.
    public let unsure: Bool

    public init(name: String, extraHumanRequired: Set<ActionClass>, unsure: Bool = false) {
        self.name = name
        self.extraHumanRequired = extraHumanRequired
        self.unsure = unsure
    }

    public static let light = RiskProfile(name: "light", extraHumanRequired: [])
    public static let strict = RiskProfile(name: "strict",
        extraHumanRequired: [.editDomainLogic, .editSafetyCheck])
}
```

`FloorGate.swift`:

```swift
public enum FloorDecision: Equatable {
    case humanRequired(reason: String)
    case noFloor
}

public enum FloorGate {
    static let universal: Set<ActionClass> = [.irreversible, .deploy, .externalSend]

    public static func evaluate(_ action: ActionClass, profile: RiskProfile) -> FloorDecision {
        if universal.contains(action) {
            return .humanRequired(reason: "Universal floor: \(action.rawValue)")
        }
        let required = profile.unsure ? RiskProfile.strict.extraHumanRequired
                                      : profile.extraHumanRequired
        if required.contains(action) {
            return .humanRequired(reason: "Profile '\(profile.name)' floor: \(action.rawValue)")
        }
        return .noFloor
    }

    /// The smart layer may add a human check, never remove one.
    public static func needsHuman(floor: FloorDecision, smartNeedsHuman: Bool) -> Bool {
        if case .humanRequired = floor { return true }
        return smartNeedsHuman
    }
}
```

**Step 4: Run to confirm it passes**

Run: `swift test`
Expected: all tests pass (3 from Task 1 plus 5 here, 8 total, 0 failures). Record the actual counts, not these expected ones, in `HITMCockpit/BUILD_NOTES.md`.

**Step 5: Commit** — blocked on D2.

---

## Phase 2 onward — not planned yet

These depend on Phase 0 answers and will get their own plan once decided: shared-mind store with quarantine for prompt/memory proposals; the smart gate and its decision model; agent adapters; orchestrator; fatigue metrics (gate count per hour, time-to-decide, rubber-stamp rate); the cockpit slice (D7) and flat fallback.

## Open items

- Deferred review notes to act on in later phases (from Task 1 and Task 2 reviews, 2026-10-25):
  - `EventLog.correct` accepts an event from a different log (wrong session or nonexistent revision).
  - `RiskProfile` decoding throws when `unsure` is missing; the profile loader must never resolve a decode failure to `.light` (fall back to unsure/strict). Consider a custom decoder defaulting `unsure` to true.
  - A profile's name is not trusted: quarantine/profile writes must compare contents against the `.light` and `.strict` baselines.
  - `FloorGate.universal` is internal; expose a read-only accessor or route everything through `evaluate` so later code does not re-implement the floor.
  - `evaluate` returns `.noFloor` for unlisted action classes (fail-open for future cases); consider an exhaustive `switch`.
  - The floor only protects if the action is classified correctly: classification must be rule-based or human-confirmed, and the smart gate may only raise a class, never lower it.
- **UX prototype uses PROTOTYPE SAMPLE DATA (approved by you 2026-10-25):** `HITMCockpit/Sources/CockpitPrototype/` has 11 invented tasks, invented agent-confidence values, invented "Now" agent activity lines, invented plain-English impact/reversibility notes, a sample 0.70 confidence threshold standing in for the smart gate, and a sample "stop asking about unsure routine work" offer (relaxes the sample threshold to 0.60 only; never offered for floor rules). The intent bar logs to the real EventLog and updates the Planner line; no agent runs and no undo exists (the "Reversible" badge describes the action only). It is labeled on screen. It must be removed or replaced once real agents and the real gate exist. Decisions in it do go through the real `FloorGate` and `EventLog`.
- The prototype is a flat macOS window, not a Vision Pro/spatial UI; spatial layout is untested.
- D8 (fixture data in tests) is still open; Phase 1 needs none.
- Specific escalation models for later cost-level task samples are not chosen.
- Gate behavior and cost of `typesafe/jev-router` are unmeasured; the sensitive-project "metadata only" rule is not built.
- No tests have been run; Swift toolchain use in this session is unverified.
- Git repo exists at `VisOsDx/` with no commits yet.
