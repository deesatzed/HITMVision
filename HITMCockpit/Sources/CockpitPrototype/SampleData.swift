import Foundation
import HITMCore

// PROTOTYPE SAMPLE DATA: every task, confidence value, activity line and note below is invented for UX feedback.
// The FloorGate and EventLog it flows through are the real HITMCore ones.

struct SampleTask: Identifiable {
    let id: String
    let title: String
    let summary: String
    let role: String
    let action: ActionClass
    let confidence: Double
    let plain: String          // plain-English "what changes for you"
    let reversible: Bool       // describes the action, not a built undo feature
    let evidence: [String]
    let ruleNotes: [String]
    let detail: String
}

/// Sample threshold for the stand-in smart layer; not a tuned or measured value.
let sampleConfidenceThreshold = 0.70
/// Sample threshold applied if the user accepts the "stop asking about unsure routine work" offer.
let relaxedConfidenceThreshold = 0.60

let sampleTasks: [SampleTask] = [
    SampleTask(id: "T1", title: "Fix typo in README", summary: "One-word spelling fix in the setup section.",
               role: "Implementer", action: .routine, confidence: 0.96,
               plain: "One word changes in the docs. Nothing else is touched.", reversible: true,
               evidence: ["Spell-check flagged 'recieve'.", "Change touches 1 line, docs only."],
               ruleNotes: ["Routine edit: no floor applies."], detail: "README.md line 14: recieve -> receive."),
    SampleTask(id: "T2", title: "Rename a helper function", summary: "Rename parseDate to parseISODate in utils; 4 call sites.",
               role: "Implementer", action: .routine, confidence: 0.93,
               plain: "A function gets a clearer name in 4 places. Behavior is the same.", reversible: true,
               evidence: ["4 call sites found, all updated.", "Build and tests unchanged."],
               ruleNotes: ["Routine edit: no floor applies."], detail: "utils/dates.swift and 3 callers."),
    SampleTask(id: "T3", title: "Add a unit test for date parsing", summary: "New test covers leap-day input.",
               role: "Reviewer", action: .routine, confidence: 0.91,
               plain: "A new test is added. No product code changes.", reversible: true,
               evidence: ["Test fails on old code, passes on new.", "No production code changed."],
               ruleNotes: ["Routine edit: no floor applies."], detail: "Tests/DateTests.swift: testLeapDay."),
    SampleTask(id: "T4", title: "Split session handling into two files", summary: "Refactor touching 6 files; agent is unsure about shared state.",
               role: "Planner", action: .routine, confidence: 0.62,
               plain: "Session code moves into two files. It should behave the same, but the agent isn't sure.", reversible: true,
               evidence: ["Agent confidence 0.62.", "Two files share a mutable cache.", "No tests cover the cache."],
               ruleNotes: ["Routine edit: no floor applies.", "Smart layer asks you because confidence is under the threshold."],
               detail: "Proposed: SessionStore.swift -> SessionStore.swift + SessionCache.swift."),
    SampleTask(id: "T5", title: "Change retry limit in core logic", summary: "Raise retries from 3 to 5 in the request handler.",
               role: "Implementer", action: .editDomainLogic, confidence: 0.88,
               plain: "The app will retry failed requests 5 times instead of 3.", reversible: true,
               evidence: ["Matches issue #41.", "Existing tests pass.", "Changes core behavior."],
               ruleNotes: ["Strict profile: edits to core domain logic always need you."],
               detail: "Core/RequestHandler.swift: maxRetries 3 -> 5."),
    SampleTask(id: "T6", title: "Loosen an assertion in a safety test", summary: "Tolerance in a limit check widened from 0.01 to 0.05.",
               role: "Implementer", action: .editSafetyCheck, confidence: 0.74,
               plain: "A safety check gets 5x more forgiving, so it could miss problems it catches today.", reversible: true,
               evidence: ["Test was failing intermittently.", "Widening makes the check weaker.", "No reviewer sign-off yet."],
               ruleNotes: ["Strict profile: anything that weakens a safety check always needs you."],
               detail: "Tests/LimitTests.swift: accuracy 0.01 -> 0.05."),
    SampleTask(id: "T7", title: "Deploy build to staging", summary: "Push the latest build to the staging environment.",
               role: "Implementer", action: .deploy, confidence: 0.90,
               plain: "Build 118 goes to the staging site where testers can see it. Production is untouched.", reversible: true,
               evidence: ["All checks green.", "Staging only; production untouched."],
               ruleNotes: ["Universal floor: deploys always need you."], detail: "Target: staging. Build 118."),
    SampleTask(id: "T8", title: "Upload crash logs to an external service", summary: "Send 12 log files to a hosted analysis tool.",
               role: "Implementer", action: .externalSend, confidence: 0.85,
               plain: "12 files leave this machine for a hosted tool. They can't be recalled.", reversible: false,
               evidence: ["Logs may contain file paths.", "Destination not yet approved."],
               ruleNotes: ["Universal floor: sending data off this machine always needs you."], detail: "12 files, 3.1 MB."),
    SampleTask(id: "T9", title: "Drop an old migration table", summary: "Delete table legacy_events; cannot be restored.",
               role: "Planner", action: .irreversible, confidence: 0.97,
               plain: "A table of old data is deleted for good. There is no backup.", reversible: false,
               evidence: ["No readers found in code.", "No backup exists."],
               ruleNotes: ["Universal floor: irreversible actions always need you."], detail: "DROP TABLE legacy_events."),
    SampleTask(id: "T10", title: "Reformat config files", summary: "Normalize indentation in 9 config files.",
               role: "Implementer", action: .routine, confidence: 0.66,
               plain: "Whitespace changes in 9 config files. Meaning should not change.", reversible: true,
               evidence: ["Agent confidence 0.66.", "One file uses tabs on purpose."],
               ruleNotes: ["Routine edit: no floor applies.", "Smart layer asks you because confidence is under the threshold."],
               detail: "config/*.yaml"),
    SampleTask(id: "T11", title: "Bump a dependency version", summary: "Update one library from 2.3 to 2.4.",
               role: "Reviewer", action: .routine, confidence: 0.68,
               plain: "One library is upgraded to its next minor version.", reversible: true,
               evidence: ["Agent confidence 0.68.", "Changelog lists one deprecation."],
               ruleNotes: ["Routine edit: no floor applies.", "Smart layer asks you because confidence is under the threshold."],
               detail: "Package.resolved: lib 2.3.1 -> 2.4.0."),
]
