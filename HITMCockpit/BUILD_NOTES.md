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
