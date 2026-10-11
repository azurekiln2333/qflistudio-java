# Terminal verification: analyze, focused tests, spec update

## Goal

Prove the unified in-app sandbox terminal is done: both repos analyze clean and
the focused terminal/Run suites pass, then capture the contract in the frontend
spec so it is not re-litigated next session.

## Background (verified)

- Work completed: `SandboxShellBackend`, `createSandboxShell`,
  `TerminalManager.create({sandboxRoot, startDirectory})`, editor wiring,
  `TerminaxTerminalPage` root at the app private data dir, `LocalTerminalPage`
  delegating to `TerminaxTerminalPage`, `StudioProfile.terminalCommandDelegate`,
  `JavaProgramRunner.runToolchainCommand`.
- Tests present: `qfli_studio_core/test/sandbox_terminal_test.dart`,
  `test/terminal_pane_test.dart` (includes an `ls` case), and
  `qfli_java/test/java_app_test.dart` (terminal JDK group).
- `.trellis/spec` currently has **no** terminal spec file; `implement.md` step 10
  requires one.

## Requirements

- R1 `dart analyze` is clean for changed files in both repos.
- R2 Focused suites pass — one Flutter command at a time, bounded timeouts,
  `runAsync` for real IO.
- R3 Regressions found are fixed or explicitly reported with evidence, never
  masked by deleting or weakening an assertion to make it pass.
- R4 A frontend spec document captures: the single backend contract, the
  `sandboxRoot` vs `startDirectory` rule per entry point, the delegate hook and
  its honesty requirement, and the JDK dispatch path.

## Acceptance Criteria

- [ ] AC1 `dart analyze` output recorded for core and Java repos.
- [ ] AC2 Passing output recorded for
      `test/sandbox_terminal_test.dart`, `test/terminal_pane_test.dart`,
      `test/editor_run_test.dart`, `test/shell_command_test.dart` (core) and
      `test/java_app_test.dart` (Java).
- [ ] AC3 Spec file added under `.trellis/spec/frontend/` and referenced from the
      frontend spec index.
- [ ] AC4 The parent task's AC1–AC5 can be checked off with this evidence.

## Out of scope

- New features; only verification, regression fixes and documentation.
