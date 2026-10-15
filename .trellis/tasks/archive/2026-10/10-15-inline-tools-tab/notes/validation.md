# Validation

## Delivery 1

- Core and Java: `dart analyze lib test` — no issues.
- Java: `flutter test --timeout 60s` — 101 passed.
- Core affected suites: `flutter test --timeout 60s test/studio_profile_test.dart
  test/home_navigation_test.dart` — 15 passed.
- The initial core full run reported 375 passed and 9 failures in
  `test/widget_test.dart`; running that file alone reproduced the failures.
  This was a historical incomplete gate, not a full-suite pass.
- Later investigation corrected the earlier blanket description of these
  failures as unrelated obsolete editor behavior. The test harness mixed real
  filesystem I/O with widget fake time and asserted routes/lazily loaded tree
  content before completion. Fixtures require initialized AppPaths/activity
  state, `tester.runAsync` for real I/O and bounded route/tree waits, followed
  by widget disposal before temporary-directory cleanup.
- Stale expectations were also concrete: navigation has five tabs rather than
  four; projects live under `ProjectTemplate.directoryName` and template main
  files under `src/`; backup directories include `.metadata.json` sidecars.
  Count payload files/ZIP archives separately and assert their metadata instead
  of interpreting sidecars as duplicate backups.
- Two existing title assertions in the edited profile test were corrected to
  match the per-tab title contract. Added coverage includes no-store legacy
  construction and explicit-widget-vs-profile builder precedence.
- Delivery 1 commits: core `1281298`; Java `6966df6`.

## Delivery 2

Final results reported by the main session after the shared implementation and
test-harness corrections:

- Core: `flutter test --no-pub --timeout 60s --reporter expanded` — 438 passed.
- Java: full Flutter suite with `--timeout 60s` — 84 passed.
- Core and Java: `dart analyze lib test` — no issues.
- Core and Java: `git diff --check` — clean.
- Delivery 2 commits: core `39507ba`; Java `0232a1d`.
- Final review found no unresolved items. HSL saturation and supplementary
  Unicode escape regressions are covered in core's migrated helper suite.
- Coverage includes the pure shared helpers, all common tool routes/forms,
  retained product entry callbacks, Java's unique 13/14-card composition,
  four dedicated Java tools, terminal callbacks and narrow/wide light/dark
  layouts. Java detail-route assertions wait through the final route-layout
  frame with a bounded two-second fake-clock `pumpAndSettle`.
- No device build, installation or push is claimed by these checks.

## Preserved local state

`ohos/build-profile.json5` was a preexisting local change and was excluded from
task edits. Its SHA256 is unchanged from the recorded starting value:
`C8718B1C5803A65AFA34610EBEA224A8258682CA2B9A316D350360B01F79551B`.
