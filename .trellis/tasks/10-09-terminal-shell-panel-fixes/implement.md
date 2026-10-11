# Implementation plan

## Ordered work

- [x] Obtain task-creation/planning consent and create the planning task.
- [x] Inspect the embedded terminal, existing shell layer, editor height constraints, previous task/spec, and dirty worktrees.
- [x] Capture seven relevant shared-core file baselines under `research/baseline/`.
- [x] Ask the existing Herdr `pi-terminal` worker for a read-only planning review; resolve technical choices using the user's stated scope and current code.
- [x] Complete Pi's second pressure-test review; converge PRD and curate real implement/check context entries.
- [x] Present the final plan, obtain the required subsequent approval, then run `task.py start`.
- [x] Recheck core ownership/hashes and dispatch the approved implementation to Pi with explicit files, task context, and baseline preservation instructions.
- [ ] Connect pane local sessions to the shell backend and add portable real-filesystem commands, argument/error handling, streaming, clear control, and per-session cwd.
- [ ] Add session input focus and right scrollbar; preserve selection and scrollback while streaming.
- [ ] Improve tab boundaries/spacing and implement continuous resizing, threshold collapse, drag-to-reopen, viewport limits, and parent/child state agreement.
- [ ] Add meaningful command, session, focus, scroll, resize, and lifecycle regressions; preserve the existing Run/long-press coverage.
- [ ] Run affected-file formatting/analysis and focused shared-core tests; render narrow/wide, light/dark, long-output, and short/keyboard-clamped cases.
- [ ] Run the Java regression suite against the changed local core dependency.
- [ ] Dispatch an independent Trellis check of the actual task delta and evidence; fix actionable findings within explicit ownership.
- [ ] Update the editor-terminal executable contract; review task-only changes and follow the finish workflow without staging unrelated baseline changes.

## Validation

Use `D:/ProgramFiles/flutter_ohos/bin/flutter.bat` and its bundled Dart executable. Run Flutter commands sequentially across workspaces to avoid shared SDK-lock interference. Existing baseline tests are regression evidence, not proof that reported commands already work.

1. Format/analyze only changed Dart files with `D:/ProgramFiles/flutter_ohos/bin/cache/dart-sdk/bin/dart.exe format` and `analyze`.
2. In the shared core, run `flutter test --no-pub --reporter expanded test/terminal_pane_test.dart test/editor_run_test.dart` plus the newly added focused shell-command suite.
3. Command checks use temporary real directories/files: `ls` and normal flags, quoted Unicode/spaced paths, `cd` persistence and failure, `pwd`, `cat`, `echo`, creation/removal, clear, unsupported options, and shell-operator routing. Verify mobile built-ins independently of spawning a host shell; test real desktop external output/cancellation separately.
4. Widget checks exercise public gestures: blank/output canvas taps, long-press/double-click selection, dragging the scrollbar, switching sessions, reading old output during an active stream, shrinking to collapsed state, dragging upward to reopen, preferred-height restoration, tiny/keyboard-shrunken viewport, and clearing without state loss. Preserve lifecycle/disposal coverage.
5. Render the actual widgets, including several tabs and a real scrollbar, at phone and desktop widths in both themes and at short heights. Inspect images for clipping, hit areas, caret gutter, tab distinction, and prompt placement. Store new render artifacts in this task's `research/` directory.
6. In `qfli_java`, run `flutter test --no-pub --reporter expanded` and analyze the app against the changed core dependency. Reuse existing real JDK Main -> Main2 -> Main validation.
7. Run task-scoped whitespace checks and compare against captured baseline files. Broaden/repeat testing only for new changes, failures, or a concrete unresolved concern.

## Handoff and rollback gates

Before implementation: all three planning artifacts and both curated manifests exist; final plan approval has arrived; task status is `in_progress`; Pi owns the agreed shared-core hunks; permissions permit writes to the sibling core. If a tool requires sandbox escalation, request it explicitly instead of bypassing the workspace boundary through another process.

Pi must not commit, change model/provider/settings, launch competing workers, or modify unrelated files. The coordinator may delegate an independent check after Pi releases write ownership. Preserve other language workspaces' concurrent changes, especially neighboring Run/HTML routing code.

If command unification breaks online/attached program ownership or the standalone terminal consumer, repair the contract before continuing visual work. Rollback uses task-specific deltas/baselines only. No blanket reset, recursive deletion, or replacement of a dirty file with Git HEAD.
