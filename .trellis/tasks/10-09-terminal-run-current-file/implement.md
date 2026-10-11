# Implementation plan

1. Finish pi review of active-file selection and gestures; capture the relevant dirty-file baselines and record the bounded changes.
2. Curate implement/check context with the mobile JDK contract and task research. Present the final plan for the required Trellis review, then start the task after approval.
3. In the right Herdr pane, assign pi the shared editor terminal/Run implementation. Pi reads the curated context and owns the specified files only. Main coordinates and owns the Java title change/spec update or assigns it explicitly.
4. Unify terminal transcript/prompt layout; remove success and preparation noise; keep error, cancellation, session and scroll behavior.
5. Add long-press active-file routing through the existing save/run method with correct gesture exclusivity and entry validation.
6. Simplify Java titles on both desktop/Android and OHOS paths. Update the existing test which currently requires a JDK title.
7. Add focused behavior tests for Main vs Main2 routing, single-fire long press, dirty-save behavior, invalid active files, prompt continuity/scrolling and nonzero error display. Use real Java execution for the current-entry backend regression.
8. Run formatting and targeted analysis/tests in both affected repositories; then run the Java app suite and any required shared-core checks.
9. Have an independent check agent review the actual task delta and verification evidence; fix real findings. Update the terminal/Run contract, review git scope, and finish per workflow.

## Verification commands

- `dart format` for changed Dart files only (use the installed Flutter fork toolchain).
- `flutter analyze` for the Java shell and targeted shared-core files.
- `flutter test test/java_app_test.dart` plus focused terminal/editor widget tests.
- `flutter test` in qfli_java after the targeted checks pass.

## Rollback and pre-start checks

Rollback only task-owned hunks using captured baselines; never reset the two dirty repositories. No product edits before the final planning review. Check pi findings for selected-file validation and asynchronous save/disposal edge cases before activating the task.
