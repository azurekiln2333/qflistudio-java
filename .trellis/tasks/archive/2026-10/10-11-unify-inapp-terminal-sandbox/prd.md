# Unify in-app terminals with sandbox root and JDK command support

## Goal

Make the built-in terminal consistent across the whole app and genuinely usable:
one terminal implementation, a real in-app sandbox rooted at the app private
data directory (or the current project when opened from the editor), and
`java`/`javac` runnable from the terminal exactly as the Run button runs them.

## Background (current state, verified)

- Three separate terminal implementations exist:
  1. Editor pane: `qfli_studio_core/lib/editor/terminal_pane.dart` spawns raw
     `sh -c`/`cmd /c`; no built-in commands, no JDK, unusable on mobile.
  2. Home built-in terminal: `lib/pages/terminax_terminal_page.dart` ->
     `TerminalManager` -> `createLocalShell` (`LocalShellBackend`).
  3. Quick tools "local terminal": `lib/pages/quick_tools_page.dart`
     (`LocalTerminalPage`) — a third ad-hoc implementation.
- The bundled JDK is wired only into the Run path (`lib/java_runner.dart`,
  `mobile_jdk.dart`, `OhosJdkProcess`, native bridge). The terminal never
  consults it, so typing `javac`/`java` fails with a "platform forbids exec"
  message even though the app can compile and run Java.
- There is no sandbox backend: `shell_backend.dart` mentions a "bundled virtual
  filesystem used for practice" but none is implemented; `createLocalShell`
  only returns a real-process backend or a web stub.

## Requirements

- R1 One terminal implementation. The editor run terminal, the home built-in
  terminal and the quick-tools local terminal share a single backend/engine.
  No third copy.
- R2 Sandbox root parameterized by entry point:
  - opened from the editor: root = the current project directory;
  - opened from the app/home: root = the app private data directory, so every
    project file (all projects) is reachable.
- R3 In-sandbox filesystem commands operate on the real app private files:
  `ls`/`dir`, `cd`, `pwd`, `cat`, `echo`, `mkdir`, `touch`, `rm`, `cp`, `mv`,
  `clear`/`cls`, with quoted paths/spaces/`~`; `..`/rooted paths cannot escape
  the sandbox root. Errors are honest.
- R4 `java`/`javac` work from the terminal on the same platforms and through
  the same path as the Run button: desktop uses the resolved JDK binaries;
  mobile (OHOS/Android) routes through the native bridge (`OhosJdkProcess` /
  `mobile_jdk`). Compiling/running a real `.java` in the terminal produces real
  output and exit status.
- R5 Honest unsupported handling: system tools that cannot run (e.g. `git`,
  `grep`, `python`, `apt`, pipelines/redirection on mobile) report a clear
  "not supported on this platform" message instead of a misleading exec error
  or a silent failure.
- R6 Preserve existing behavior: Run button, long-press active-file run, online
  terminal, attached program output, cancellation, command history, the
  editor terminal's continuous scroll/prompt layout, sandbox close/resize, and
  all unrelated dirty work in both repositories.
- R7 OHOS and desktop are the target platforms; the sandbox must not depend on
  exec'ing arbitrary binaries.

## Acceptance Criteria

- [x] AC1 Editor, home and quick-tools terminals all use one shared backend;
  the duplicate implementations are removed or delegate to it.
- [x] AC2 Opening the terminal from the editor starts at the project root;
  opening it from the app starts at the app private data directory; both can
  list and read real project files.
- [x] AC3 The listed sandbox file commands work against real app-private files
  with correct quotes/spaces and cannot escape the root.
- [x] AC4 `javac Foo.java` and `java Foo` typed in the terminal compile/run for
  real via the same JDK path as Run; unsupported tools give honest messages.
  (Verified 2026-10-12: the delegate now tokenizes with `CommandParser` and
  refuses compound lines, so quoted operands compile and `javac a | b` reports
  the pipeline message instead of feeding `|` to javac.)
- [x] AC5 Focused tests cover the shared backend, root parameterization,
  sandbox file commands, JDK dispatch, escape prevention and unsupported
  messages; existing terminal/Run suites stay green.

## Out of scope

- Bundling a full POSIX userspace (no Termux-style coreutils/apt/git).
- Network/SSH tooling, new PTY emulation.
- Changing Java/native packaging or the JDK recipes.

## Notes

- If a capability is genuinely unavailable on a platform, the terminal must say
  so plainly; it must never imply it works.
