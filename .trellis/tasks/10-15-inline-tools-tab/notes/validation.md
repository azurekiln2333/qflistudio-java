# Validation

## Delivery 1

- Core and Java: `dart analyze lib test` — no issues.
- Java: `flutter test --timeout 60s` — 101 passed.
- Core affected suites: `flutter test --timeout 60s test/studio_profile_test.dart
  test/home_navigation_test.dart` — 15 passed.
- Core full suite — 375 passed, 9 failures, all in unchanged `test/widget_test.dart`.
  Running that file alone reproduces all 9. Its assertions assume obsolete
  four-tab navigation (actual five), previous editor tree controls/auto-open,
  template output names and nonduplicated backup paths. The current change only
  passes the store and optional inline builder in HomePage; it does not change
  these features. These unrelated failures remain explicit validation limits.
- Corrected two existing title assertions in the edited profile test to match
  the current per-tab title contract; added no-store SQL-call compatibility and
  actual widget-vs-profile builder precedence coverage.
- Signing config SHA256 before work:
  `C8718B1C5803A65AFA34610EBEA224A8258682CA2B9A316D350360B01F79551B`.
