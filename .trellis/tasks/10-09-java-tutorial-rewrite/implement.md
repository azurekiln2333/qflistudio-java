# Implementation plan: Java tutorial/example rewrite

## Status

Content, import/rename, inline run, spinner fix and verification are landed and
reported. See `research/java-content-final-report.md` and
`research/import-run-spinner-verification.md`.

## Ordered work

- [x] 1. Discover exact sources/caches (done in research/content-inventory.md) and
  confirm runtime constraints from `lib/java_runner.dart`.
- [x] 2. Author the 100-topic Java content module under
  `qfli_studio_core/tool/java_content/java_topics.dart` (data only), grouped by
  the PRD progression. Each topic: id, level, title, summary, concepts, objective,
  prerequisites, explain (Chinese), code (complete, formatted), output, pitfalls,
  tasks.
- [x] 3. Write `tool/generate_java_content.dart`: load existing JSON, drop Java
  entries, insert the new Java entries, preserve other languages and metadata,
  and regenerate `assets/tutorials/java.json`. Deterministic output.
- [x] 4. Write `tool/verify_java_content.dart`: cross-check authored topics
  against emitted tutorial/example/legacy records and compile/run the emitted
  payload with `--release 17`; emit `research/java-content-verification.json`
  with real version strings and asset fingerprints; fail on mismatch. Order is
  generate-then-verify.
- [x] 5. Run the generator; verify the emitted payload (100/100).
- [x] 6. Line-break handling: real multi-line structure enforced and covered by
  `test/java_content_test.dart`.
- [x] 7. Migration/version: `ExampleCodeStore.contentVersion = 2` purges all
  pre-version Java records while preserving other languages; idempotent.
- [x] 8. Focused tests: integrity, migration, rename, ASCII dirs, import
  overwrite agreement, inline run lifecycle, real-JDK smokes.
- [x] 9. Analyzer + focused Flutter tests + content verifier; render
  beginner/intermediate/advanced tutorial + example pages, inline-run pages and
  the import dialog at phone width; PNGs saved under `research/screenshots/`.
- [x] 10. Write records: content inventory, final report, import/run/spinner
  verification, outline, task checklist.
- [x] 11. Import class-name UI + source rename (declaration/ctor/self types),
  ASCII `demo_*` dirs with Chinese display titles, inline run below the code on
  both pages, and the stuck-spinner fix.
- [x] 12. Independent review findings S1-S4 dispositioned
  (`research/java-content-final-report.md`).

## Remaining

- None. Independent Pi review revision 5 PASS for U1/U2/U3, stale callbacks
  and R-a; coordinator visually inspected the refreshed real-run and terminal
  screenshots. Work is verified and uncommitted.

## Final verification (exact)

- Core: `dart analyze lib` clean; `flutter test` of the five Java suites =
  **54/54**.
- Java: `dart analyze test` clean; `flutter test` whole suite = **24/24**.
- Terminal task (reused, not rerun): 79/79 focused, 7/7 render.
- Screenshots under `research/screenshots/` with provenance in
  `research/import-run-spinner-verification.md`.

## Validation commands

- Generator: `dart run tool/generate_java_content.dart`
- Verifier: `dart run tool/verify_java_content.dart` (uses system JDK)
- Analyzer: bundled dart `analyze` on changed files.
- Tests: `flutter test --no-pub test/java_content_test.dart test/tutorial_test.dart
  test/content_repository_test.dart test/content_code_import_test.dart` plus a new
  line-break/migration suite.
- Render: a task render harness under `research/` producing phone-width PNGs.

## Rollback

- Keep a copy of the pre-change `assets/content/*.json` Java entries under
  `research/baseline/` for comparison. Revert only this task's hunks.

## Risks

- 200 hand-authored programs is large; the generator keeps content reviewable and
  the verifier guarantees runnability. If the JDK is unavailable, record that
  blocker explicitly instead of claiming verification.
- Other-language entries must not change; the generator diff guards this.
