# Terminal compound syntax honesty and cwd-relative Java operands

## Goal

Two correctness gaps left in the unified sandbox terminal:

1. Compound commands (pipes, redirection, chaining) must produce an honest
   "not supported on this platform" message on mobile rather than a generic
   unsupported-command error.
2. `javac`/`java` operands given as cwd-relative paths must resolve against the
   terminal's cwd, matching what the user sees on screen.

## Background (verified)

- `BaseShellBackend.handleBuiltin` classifies a line with `|`, `>`, `<`, `&`,
  `;`, backticks, `$(...)`, `*`, `?`, `[` as `CommandSyntax.compound` and
  returns `false`, routing the whole line to `runExternal`.
- `SandboxShellBackend.runExternal` hands the raw line to the delegate. The
  Java delegate (`_javaTerminalDelegate`) only matches when the first
  whitespace-separated token is exactly `javac`/`java`, so `javac Main.java |
  tail` is not claimed and falls into the generic unsupported message, which
  does not tell the user that pipelines specifically are unavailable.
- `JavaProgramRunner.runToolchainCommand` forwards `arguments.sublist(1)`
  verbatim to `javac`/`java` with `workingDirectory: workingDirectory`. On
  POSIX that is fine for `javac -d out src/Main.java`, but a bare
  cwd-relative operand such as `java src/Main.java` is resolved by the JVM
  against the process cwd, which is already correct — the gap is that the
  terminal cwd and the toolchain cwd can diverge after `cd` inside the sandbox
  if the caller passes a stale directory. Verify and pin whichever case is real;
  do not add speculative rewriting that breaks `-cp`/`--module-path` syntax.

## Requirements

- R1 A compound line on a platform without a real shell reports explicitly that
  pipelines/redirection/chaining are unavailable, naming the construct.
- R2 On desktop, compound lines keep working through `LocalShellBackend`
  (no regression to `git`/`grep`/pipes).
- R3 The Java delegate receives the sandbox cwd (not a stale project dir) so
  `javac`/`java` see the directory the prompt shows.
- R4 Argument handling stays passed-through: no reordering or rewriting of
  `-d`, `-cp`, `--module-path`, `-encoding`, or quoted operands.

## Acceptance Criteria

- [x] AC1 `SandboxShellBackend` (no delegate / non-claiming delegate) emits a
      pipeline-specific honest message for `a | b`, `a > f`, `a && b`.
- [x] AC2 A focused test in `test/sandbox_terminal_test.dart` covers the
      compound-on-mobile message and asserts no generic wording is used.
- [x] AC3 The Java delegate test proves the cwd it receives equals
      `SandboxShellBackend.cwd` after a `cd`.
- [x] AC4 Existing suites stay green.

### Verification corrections (2026-10-12)

The original claim that R1 was satisfied was only true for a *test* delegate that
rejected compound lines itself. The shipping `_javaTerminalDelegate` claimed any
line starting with `javac`/`java`, so `javac a | b` ran javac with `|` and `b` as
operands and the honest pipeline message never appeared. Fixed by having the
delegate classify with `CommandParser` and refuse non-`simple` lines. R4's
passthrough test also bypassed the delegate (it called `runToolchainCommand`
with a pre-split list); the delegate splits on whitespace and mangled quoted
operands, so a quoted `javac "src/Hello World.java"` failed. Fixed by tokenizing
with `CommandParser` under `EscapePolicy.backslashLiteral`. Both cases now have
regression tests that fail when the fix is reverted.

## Out of scope

- Implementing real pipes/redirection in Dart.
- Bundling coreutils, `sh`, or a PTY.
