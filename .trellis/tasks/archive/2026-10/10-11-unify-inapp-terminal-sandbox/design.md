# Design: unified in-app sandbox terminal

## Boundaries

Owned by this task (shared core): `lib/terminal/**` (shell backends, sandbox
backend, manager/session, terminal pages), `lib/editor/terminal_pane.dart`
local-command path, `lib/pages/quick_tools_page.dart` local terminal,
`lib/pages/terminax_terminal_page.dart` wiring, `lib/services/app_paths.dart`
(root resolution), and focused tests. Java-side integration (JDK dispatch from
the terminal) lives in `qfli_java/lib` and reuses `JavaProgramRunner` /
`MobileJdk` / `OhosJdkProcess`. Do not touch packaging/native recipes.

## Unified backend

Introduce one `SandboxShellBackend` in `lib/terminal/shell/` implementing the
existing `ShellBackend` contract, with:
- a `sandboxRoot` (absolute path) that all paths resolve under;
- `cwd` initialized from an entry-provided start directory;
- built-in filesystem commands implemented in Dart against real files under
  the root (`ls/dir/cd/pwd/cat/echo/mkdir/touch/rm/cp/mv/clear/cls/help`);
- path resolution that rejects escaping `..`/rooted paths;
- an optional **command delegate** for external tools.

The existing `LocalShellBackend` (real process) stays for desktop-only external
tools; the sandbox backend is the default everywhere and delegates unknown
commands to:
1. the JDK dispatcher (java/javac), then
2. the real process backend when allowed (desktop), else
3. an honest "unsupported on this platform" message.

`createLocalShell({workingDirectory, sandboxRoot, jdkDispatcher})` becomes the
single factory used by `TerminalManager`, the editor pane and quick tools.

## Sandbox root by entry point

- Editor: `TerminalPane(workingDirectory: project.path)` -> sandbox root =
  project path.
- Home/quick tools: sandbox root = `AppPaths.storageDirectory()` (the app
  private data dir containing `projects/`), so all projects are reachable.
Expose this as a parameter (`sandboxRoot`) so callers decide; the backend does
not guess.

## JDK dispatch (java/javac)

The terminal must not exec on mobile. Add a small `TerminalJdkDispatcher`
interface in the shared shell layer; `qfli_java` provides the implementation:
- desktop: run `jdk.javac` / `jdk.java` via the same resolution `JavaProgramRunner`
  uses (`_findJdk`), streaming stdout/stderr;
- mobile: `MobileJdk.prepare()` + `OhosJdkProcess.start` (javac = module entry
  `jdk.compiler/...`), then the java run path, streaming real output.
Because `JavaProgramRunner.run` is project/entry oriented, add a
`compileAndRunCommand`-style entry that accepts a terminal command line and cwd,
reusing the same JDK resolution and mobile bridge. The shared terminal receives
stdout/stderr/exitCode just like `attachOutput`.

## Interaction with the editor pane

`terminal_pane.dart` local `_run` currently spawns `sh`. Replace its local
execution with the shared sandbox backend (rooted at the project) so editor
commands and home commands behave identically. Preserve attached-run/online
paths, layout, history, prompt, cancellation and scroll behavior.

## Tests

- `test/sandbox_shell_test.dart`: built-in commands on a temp fixture, quote/
  space handling, escape prevention, unsupported-tool message, root
  parameterization (project vs app dir).
- `test/terminal_pane_test.dart` additions: editor local command now runs via
  the sandbox backend (e.g. `ls` lists real project files) without regressing
  attached runs.
- `qfli_java/test`: JDK dispatcher unit + a real desktop `javac`/`java` through
  the terminal dispatcher (bounded).
- Keep existing Run/long-press/online suites green.

## Risks

- Exec cancellation and stream ownership must stay with the originating session.
- Desktop real-process backend vs mobile sandbox must not diverge in user-visible
  behavior; both must share the same command surface.
