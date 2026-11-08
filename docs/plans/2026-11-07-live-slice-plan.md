# Live slice: one real agent job through the gate to a human decision (2026-11-07)

Owner approved starting this slice on 2026-11-07 ("yes") after the qJig reassessment. Outside services used:
OpenRouter only (models chosen by the owner: planner and implementer `deepseek/deepseek-v4.1-flash-1017`, gate
`anthropic/claude-haiku-5.5`). Only a throwaway repo is sent to them. No sample data is involved.

## Goal
Prove the loop once, headless, before wiring the cockpit: intent -> Planner -> Implementer (real diff in an
isolated git worktree) -> floor + gate -> either a quiet pass or a pending card -> human pass/reject -> recorded.

## Pieces (each with tests; one commit each where practical)
1. `CallLedger` (HITMCore): append-only JSONL. An intent line is written BEFORE every paid call and a receipt AFTER
   it. Call and known-cost caps are derived from the file, so they survive a restart. An intent with no receipt is
   "unresolved": no new call is allowed until a person reconciles it (never a blind retry). Unknown cost stays
   unknown. No bodies, no key. Pattern borrowed from qJig's journal (idea only, no dependency).
2. `Implementer` + `ChangeSet` (HITMCore): the model returns whole-file replacements as strict JSON; paths are
   validated (relative, inside the repo, not `.git`, `.hitm` or `.env`), counts and sizes bounded. It proposes only.
3. `Workspace` (macOS only): `git worktree` on branch `hitm/<id>` under `<repo>/.hitm/worktrees/<id>`; apply edits,
   real `git diff`, commit on the branch only (never main, never push), discard on reject.
4. `ReviewCard` + `CardInbox` (HITMCore): one JSON file per card in `<repo>/.hitm/inbox/`; a card is decided once;
   decisions are appended to `events.jsonl`. The cockpit app will read this same folder in the next slice.
5. `SliceRunner` + `LiveSlice` executable: the flow above. Floor class = highest of the plan, the implementer
   summary, the changed paths and each added line (conservative; over-asks are measured, not hidden).
6. Real runs on the throwaway repo `/Volumes/WS4TB/QUIX/hitm-sandbox`, results recorded in BUILD_NOTES.

## Defaults I chose (change on request)
- Per-run caps: 6 calls, 0.25 USD known cost. A normal run uses 3 calls.
- Profile `light` unless given; a sensitive or unsure profile makes no model call at all.

## Not in this slice
Cockpit reading the inbox, rule onboarding, merging a branch to main, local models, retrieval.
