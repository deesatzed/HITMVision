# Piece 1: Decision Card with Five Answers and Evidence (flat window first)

> **For Claude:** Use superpowers:subagent-driven-development. Subagents do not commit; the controller commits named files after both reviews pass. Tests first, real file I/O, no mocks.

**Goal:** Replace the in-place disclosure rows on each queue card with a compact queue row plus an attached decision card that answers the five questions and shows Evidence, using only information the system really has. Design: `2026-10-26-hitm-decision-cards-and-rules-design.md` (five questions, E1).

**Architecture:** A pure, testable `DecisionBrief` value is built from a `SampleTask`, its `Gate`, the profile and the current queue. The store gains a `focusedID`. The queue shows one compact row per item; the focused item's brief appears in an attached card beside the queue. Same panels and same store in the Mac window, the visionOS flat window and the volume.

**Stays sample:** tasks, confidences and proof entries remain labeled PROTOTYPE SAMPLE DATA. Fields the system cannot fill yet show "Not available in sample mode"; nothing is invented to fill them.

**Out of scope here:** rules engine, "Allow like this…", onboarding, agent nodes, choose-among-options card, wake-ups, commit links (design doc E3 to E7).

## Files
- Create `HITMCockpit/Sources/CockpitUI/DecisionBrief.swift`
- Create `HITMCockpit/Sources/CockpitUI/DecisionDetailCard.swift`
- Modify `Store.swift` (focus), `SampleData.swift` (`proof` field), `NeedsYouPanel.swift` (compact rows), `Layouts.swift` (attached card)
- Test `HITMCockpit/Tests/CockpitUITests/DecisionBriefTests.swift`, extend `CockpitStoreTests.swift`

## Task 1: DecisionBrief (pure model)
Fields, one per question:
1. **what:** title, plain sentence, role, task id.
2. **why:** `source` (floor-universal, floor-profile, agent-confidence), plain reason, technical reason from the real `FloorGate` or the sample threshold.
3. **scope:** fixed text "This one action only." plus "Broader rules arrive later" marker (no button yet).
4. **how:** `method` (fixed floor rule, or sample confidence threshold stand-in), `inputs` (action class, profile, confidence), `unavailable` list: gate-model reasoning, inputs sent to a model, history preview, each marked "Not available in sample mode".
5. **next:** one line each for Pass, Modify, Reject, and `unblocks`: other waiting tasks with the same role (derived from the queue).
6. **evidence:** `proof` entries, or the single state `noProofAttached`.

Tests (red first): floor-universal task yields source floor-universal and a reason beginning "Universal"; strict profile editDomainLogic yields floor-profile; low-confidence routine yields agent-confidence with the threshold in the reason; quiet task has no brief; a task with empty proof yields `noProofAttached`; `unavailable` is never empty in sample mode; `unblocks` counts only same-role waiting tasks; brief text for a sensitive profile adds no field the gate would not see.

## Task 2: Store focus
`focusedID` (nil means the first waiting item). `focus(_:)`, cleared when that item is resolved or the profile change removes it from the queue; Reset clears it.
Tests: default focus is the first waiting item; focusing another item sticks; resolving the focused item moves focus to the next waiting item; profile change that drops the item moves focus; reset clears.

## Task 3: Sample proof field
`SampleTask.proof: [String]`, labeled sample. Some tasks carry proof entries (for example a test result line), others none, so both states show. These entries are invented for UX review and listed as sample data.

## Task 4: UI
- Queue row: tag with icon, title, role, one-line plain reason, Pass / Modify… / Reject. No disclosure groups.
- Tapping a row focuses it. `DecisionDetailCard` shows the five answers in fixed order and fixed places, with Evidence as a distinct block ("No proof attached" when empty). "Not available in sample mode" items use secondary text and an icon, never color alone.
- Order change (review fix): Evidence sits directly under "What is it" so it is visible without scrolling; the other four headings follow in their original order.
- Opening or closing the detail card does not reflow the queue.
- Text sizes taken from the existing `small()` helper or larger; none smaller than today.

## Task 5: Layouts and checks
- `FlatCockpitView` and `VolumeCockpitView` show queue plus attached card from the same store.
- Run `swift test` (all targets), `swift build`, the `xcodebuild` visionOS Simulator build, launch in the Simulator, capture the Simulator screen only (never the whole desktop).
- Check against the sample set: universal-floor card, project-rule card (Strict), agent-unsure card, a card with proof, a card with no proof.

## Task 6: Record and review
`BUILD_NOTES.md` entry with exact commands and counts; spec review then quality review; fix findings; commit named files only.

## Done when
All tests pass with exact counts reported; the Simulator capture shows queue and attached card; every field on the card is either real or marked "Not available in sample mode"; both reviews approved; unverified items listed (headset comfort, volume look, live gate content).
