# Implementation plan: unified in-app sandbox terminal

## Ordered work

1. `lib/terminal/shell/sandbox_shell_backend.dart` (new): `SandboxShellBackend`
   implementing `ShellBackend` with real-file built-ins rooted at `sandboxRoot`,
   cwd/escape guards, and a `TerminalCommandDelegate` hook for unknown commands.
2. `lib/terminal/shell/shell_backend.dart`: add a `TerminalCommandDelegate`
   interface (returns handled/not) and reuse existing built-in helpers.
3. `lib/terminal/shell/local_shell.dart` + `local_shell_io.dart`: change
   `createLocalShell` to build the unified backend (sandbox + desktop delegate
   + JDK dispatcher) and keep the web stub honest.
4. `lib/terminal/state/terminal_manager.dart`: accept and pass `sandboxRoot`.
5. `lib/editor/terminal_pane.dart`: replace the raw `sh -c` local command path
   with the shared backend rooted at the project; keep attached/online/layout.
6. `lib/pages/terminax_terminal_page.dart`: root = app private data dir.
7. `lib/pages/quick_tools_page.dart`: replace `LocalTerminalPage`'s ad-hoc
   engine with the shared backend (same root as home).
8. `qfli_java`: `TerminalJdkDispatcher` implementation reusing `JavaProgramRunner`
   JDK resolution + `MobileJdk`/`OhosJdkProcess`; expose it to the shared
   terminal via `StudioProfile` (like `runner`).
9. Tests: `test/sandbox_shell_test.dart`; editor pane additions; Java dispatcher
   real-JDK smoke (bounded).
10. Analyze + focused tests in both repos; update spec
    `frontend/editor-terminal.md` and this task's records.

## Validation commands

- `dart analyze` on changed files (both repos).
- `flutter test --no-pub test/sandbox_shell_test.dart test/terminal_pane_test.dart
  test/editor_run_test.dart test/shell_command_test.dart` (core).
- `flutter test --no-pub test/java_app_test.dart` plus the new dispatcher test.
- One Flutter command at a time; bounded outer timeouts; `runAsync` for real IO.

## Rollback

- The change is additive: `SandboxShellBackend` is new; wiring swaps are small.
  Revert only this task's hunks per file.

## Risks

- Terminal pages and the editor have existing tests asserting raw-shell behavior
  (`test/shell_command_test.dart`, `terminal_pane_test.dart`); those must be
  updated to the unified sandbox contract, not deleted.
- Mobile JDK dispatch timing/cancellation must reuse the proven bridge and stay
  bounded; no PTY.
