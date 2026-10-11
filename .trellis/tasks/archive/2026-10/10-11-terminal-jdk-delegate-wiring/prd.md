# Wire the terminal JDK delegate at app level and remove debug prints

## Goal

`java`/`javac` typed in the **app-level** terminal (home built-in terminal and
quick-tools local terminal) must work exactly like in the editor terminal, and
no leftover debug prints may remain in shipped code.

## Background (verified)

- `StudioProfile.terminalCommandDelegate` is honoured by the editor terminal
  (`lib/editor/terminal_pane.dart` passes it to `createSandboxShell`).
- `TerminalManager` exposes `commandDelegate`, but **nobody assigns it**.
  `lib/pages/terminax_terminal_page.dart` calls
  `_manager.create(sandboxRoot: path, startDirectory: path)` only, so the app
  terminal's backend gets `delegate: null` and `java`/`javac` fall through to
  the "unsupported" branch.
- `LocalTerminalPage` (quick tools) already delegates to `TerminaxTerminalPage`,
  so fixing the page fixes both entry points.
- Debug leftovers: `lib/main.dart` (2× `print('PROBE …')`) and
  `test/java_app_test.dart` (1× `print('PROBE …')`).

## Requirements

- R1 The app-level terminal uses the same JDK delegate as the editor terminal,
  sourced from `StudioProfile.current?.terminalCommandDelegate`.
- R2 No `print('PROBE …')` (or equivalent debug output) remains in `lib/` or
  `test/`.
- R3 Existing app-terminal behaviour is preserved: multiple sessions, tabs,
  history, shortcut bar, auto-recreate of a session when all are closed.
- R4 `qfli_studio_core` must not gain a dependency on the Java app; the profile
  field stays the only coupling point.

## Acceptance Criteria

- [x] AC1 An app-terminal session's backend receives the profile delegate (unit
      or widget test proves `java`/`javac` is claimed, not reported unsupported).
      (Verified; note the `_createSession` re-assert is redundant because the
      manager keeps `commandDelegate` across `create()`, and the test only pins
      `initState` — see verification report.)
- [x] AC2 `rg "PROBE" lib test` returns nothing in the Java repo; the studio
      core has no debug prints introduced by this work.
- [x] AC3 Existing `test/sandbox_terminal_test.dart` and
      `test/terminal_pane_test.dart` still pass.

## Out of scope

- Compound-syntax honesty and cwd-relative java operand resolution (sibling task).
- Retiring `LocalShellBackend` on desktop.
