# HITM SWE Cockpit — Design

Status: design approved in conversation 2026-10-25; no code written; nothing built or tested.

## Purpose

A software-engineering app for Apple Vision Pro where a team of AI agents works as a shared mind and the human sits in the middle at gates ("human in the middle", HITM). It is built first, then used to build Diagnostic Theater (`DiagnosticTheater/`). `id1.md` and the example screenshots are loose inspiration only; agent roles, models, routing and decision models are open design topics.

## UX principles (apply to every section)

The point of HITM is value added per interruption, not volume of interruptions.

1. **Quiet by default.** Work that the risk profile allows proceeds without a card. Only decisions whose outcome could change the result reach the human.
2. **Attention budget.** Gate output includes whether a human is needed and why. Low-stakes items are batched into a digest instead of interrupting. Urgent items are visually distinct from routine ones.
3. **Progressive disclosure.** A card opens one layer at a time: one-line summary, then evidence, rules, full detail. Routine items show one line; risky ones open further.
4. **One glance, one decision.** Each card shows what is proposed, why it reached the human, and the Pass / Modify / Reject actions. No hunting.
5. **Fatigue is measured.** Track gate count per hour, time-to-decide, how often the human passes without opening detail, and override rate. A rising rubber-stamp rate means the gate is asking too much or showing too little.
6. **A flat fallback is fully functional.** Spatial layout must earn its place; head and hand effort must not dominate.
7. **Cutting interruptions never lowers the floor.** Fatigue is reduced by better gating above the floor, not by weakening it.

## Gating loop

Every unit of agent work passes a gate that decides: proceed alone, go to the human, or go to a stronger model first.

- **Inputs:** risk profile (build type), task needs (reversibility, blast radius, cost, novelty, data sensitivity), agent confidence, the human's history on similar gates.
- **Output (typed):** `{route, needs_human, detail_level, confidence, reason}`. The reason is always shown.
- **Risk profile sets the floor.** Each project has a versioned profile in its repo: what is built, who or what could be harmed, data touched, regulations. A small universal floor applies to all projects (irreversible actions, deploys, sending data off this machine). The profile adds its own floor: a stuffed-toy design app is light; a medication dosing app always sends changes to dosing logic, units, thresholds, tests, or anything weakening a safety check to the human.
- **The smart layer sits above the floor.** It may ask more, never less.
- **Profile ownership:** the human sets it; the AI may propose one, and defaults to the stricter profile when unsure. If signals show the project has drifted (e.g. a toy app gains payments or health data), the gate pauses and asks the human to re-confirm.
- **Learning:** Pass / Modify / Reject choices are logged. The system may propose gate-threshold changes; the human approves them. No silent self-modification.

## Shared mind

One local store with an append-only event log. Content kinds, each with author, time and evidence: **context**, **memory**, **prompts**, **profile and policy**.

- Agents read only the slices relevant to their role and task, plus summaries; no full-history re-injection.
- Writes are proposals held in quarantine until they pass a gate. **Every prompt change goes through a gate or HITM, with strictness set by context and risk.**
- The human can view, edit, expire or delete any memory; deletion is a recorded correction, not erasure.
- Conflicting or stale memories are flagged on a card.
- Material the profile marks sensitive never enters memory readable by a hosted model without approval for that specific destination.

## Parts and data flow

| Part | Role |
|---|---|
| Cockpit | Vision Pro app plus flat fallback; shows cards; submits human decisions; never changes state directly |
| Orchestrator | Local process; runs agents; carries all inter-agent messages; the only component that commits; enforces gates |
| Gate engine | Fixed floor rules plus a small typed decision model; always gives a reason |
| Shared mind | Local store over the event log, read by cockpit, gate and agents |
| Agent adapters | Thin layer so any agent (any role, any model) plugs in the same way |
| Usage tracking | Logs every model call and its source |

Flow: task arrives → orchestrator pulls relevant slice of the shared mind → gate picks route → agent works → result returns as a proposal → gate again → card if the human is needed → decision appended to log → everything rebuilt from the log.

## Testing

Orchestrator, gate and shared mind live in a headless core with its own tests, independent of the Simulator. The Simulator is used only for the cockpit. Tests use real services and real data; mocks, stubs or synthetic data need explicit human approval, are labeled where used, and stay on the open-items list.

## Open decisions (to be settled in discussion)

- Agent roles and which models fill them (model IDs must be looked up and chosen by the human, not taken from memory).
- Routing between agents, and when messages bypass the human.
- Which model runs the gate (decision model) and what it is allowed to see.
- Which tool or harness drives agents first, including whether its terms permit the subscription use intended (unverified).
- First vertical slice of the cockpit.
- Fatigue targets: no thresholds set yet; to be chosen after measurement exists.
