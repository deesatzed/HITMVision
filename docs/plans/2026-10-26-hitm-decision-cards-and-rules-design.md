# HITM Cockpit: Decision Cards, Broader-Pass Rules and Rule Onboarding

Status: design agreed in conversation 2026-10-26. No code written for this yet. Builds on `2026-10-25-hitm-swe-cockpit-design.md`. Triggered by feedback on the step 6 flat window: one panel, every card the same shape, three equal-weight disclosure rows that expand in place, agents as one line of small text, unused space around the panel.

## Goal

Intuitive and informative without visual overload. Every element has a purpose and is either actionable or actively worth monitoring. Design from what a human wants at each step: purpose, why it flagged, what the decision covers, how the system worked it out, and what the decision means overall.

## Decision card: five questions, fixed places

1. **What is it?** One plain sentence, the asking agent, the task it belongs to.
2. **Why did it flag?** The actual source: floor rule, project profile, agent's own confidence, or the gate model's reason.
3. **What does my decision cover?** The scope of Pass (see Decisions).
4. **How was this worked out?** Only what the system really did: fixed rule or model gate, which inputs, which model, what was withheld (sensitive profiles), the gate's confidence (not the agent's). Shows only real information; sample data can only show the shape of it.
5. **What happens next?** What Pass, Modify and Reject each do; which agents and tasks unblock.

## Using the space (proposal, not yet approved in detail)

- Main panel stays a calm queue: one line per card, ordered by urgency, text plus icon, never color alone.
- Tapping a card opens its five answers as an attached card beside the queue; the queue does not reflow; closing returns to the same place.
- Evidence, rules and how-it-was-worked-out are separate small cards at fixed positions around the focused card, opened only on tap.
- Agents become small nodes outside the main panel: state (working, waiting on you, blocked, done) and a thread to the card each waits on.
- The effect of a decision is shown before committing.
- Nothing moves on its own.

## Decisions made 2026-10-26

- **R1. Pass covers this one action only, by default.**
- **R2. A broader pass is a separate, deliberate step** ("Allow like this..." beside Pass), never a side effect of Pass. It opens a rule card: plain-language rule, what it does and does not cover, preview against real history when history exists, scope, one-tap revoke.
- **R3. Scopes: session, project folder, project, all.** Different tools get different reach (example: `grep` can be all, `git` project).
- **R4. Each kind of action has a maximum scope**, set by a fixed rule table, never by a model. The card suggests a scope and says why; the human may pick narrower or wider up to the ceiling.
- **R5. Floor items offer no broader pass:** irreversible, deploy, externalSend, plus the profile floor (strict adds domain logic and safety checks).
- **R6. A narrower rule overrides a wider one; ask or deny beats allow; the floor beats everything.**
- **R7. Rules are matched by a deterministic matcher on the exact command shape,** not substrings and not a model. Compound or piped commands are not covered by a simple-command rule (`grep ... | curl ...` still asks).
- **R8. A rule is a policy entry in the shared mind:** gated, confirmed by a named human, logged. Widening a rule's scope is a new gated change.
- **R9. Auto-allowed actions stay visible:** each rule keeps a use count and last-used time; a Standing rules card groups rules by scope; the activity log records uses.
- **R10. Rule onboarding per project** (once, short, re-openable): (1) what are you building, AI may propose a profile, human confirms, unsure means strict; (2) starter rules by tool family from a fixed table, with suggested scope, and locked floor items that cannot be switched off; (3) a preview of what will and will not interrupt, with examples from the project. In strict, unsure or sensitive projects an "All" rule is off until switched on for that project at onboarding. Onboarding reopens from the Standing rules card and automatically on suspected risk drift.
- **R11. Skipping onboarding makes the project strict,** with only the locked floor items and no allow rules, plus a persistent "Set up rules to ask less" prompt.

## Additions agreed 2026-10-27 (from an outside list of agent-workflow ideas; one practitioner's opinion, unmeasured here)

- **E1. Evidence on every decision card.** An Evidence slot shows real proof (tests run, before/after output, an end-to-end result) or the words "no proof attached". Nothing may be shown as proof that the system did not produce. Project agent instructions carry the line "this is not evidence" for claims without output.
- **E2. Planner states the goal and the done-test, not the method.** The proposal says what success looks like and how it will be checked; the agent chooses the method.
- **E3. Choose-among-options card (later).** For "20 variations" or "4 theories": the human compares and picks instead of Pass or Reject. Needs real agents first.
- **E4. Batching.** Related waiting items can be answered together ("5 of these"). The floor still applies per item.
- **E5. Scheduled wake-ups (later).** "Check the logs at 9am", "tell me when it's live". The wake-up appears as a card; anything it does still goes through the floor.
- **E6. Decisions and mind entries record the git commit hash (later),** so "why did we do this?" is answerable.
- **E7. Per-agent isolated workspaces (later, orchestrator work),** so agents can build and test end to end without clashing.
- **E8. Control/treatment experiments** for the model-cost trials and for checking whether agents actually use the project's instructions and skills.
- **E9. Read-only access to project state (logs, tests, status) first.** Acting (deploy, send, flip flags, email customers) stays on the floor.
- **Rejected for this app:** "stop worrying about slop" (a strict or clinical project keeps review of domain logic, units, thresholds and safety checks whatever the code looks like); "don't let agents write for humans" (cards are written for a human reader; it applies only to logs and debugging notes); autonomous deploy, email or flag changes.

## Known gaps and cautions

- The classifier has no separate read-only class; `grep` classifies as routine today. The exact-command matcher is new work.
- The starter tool families are a guess, unverified against the commands real agents run. Check against real commands once agents run.
- Rules that decide without a card must not weaken the floor: the floor evaluation happens first, always.
- "How was this worked out" and the history preview need the live gate, planner and shared mind wired in; sample data cannot honestly fill them.
- Spatial placement of the attached and satellite cards is unproven; compare against the flat version with measured results before claiming a benefit (one tester only, so exploratory).

## Not yet decided

- Build order for these pieces against the remaining step 6 and wiring work.
- Exact set of tool families and their ceilings.
- Retention or expiry of standing rules beyond session scope.
- Conflict handling when two projects' rules disagree on an All rule.
