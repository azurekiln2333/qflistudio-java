# Java analysis and local debugging

## 1. Scope / Trigger

Apply when changing `java_diagnostics.dart`, `java_debugger.dart`, runner process
transport, or their Java-only tools page. Common editor scheduling, Problems,
underline rendering and stale-snapshot checks belong to shared core.

## 2. Signatures

`JavaDiagnosticAnalyzer implements CodeAnalyzer` and exposes
`Future<CodeAnalysisResult> analyze(CodeAnalysisRequest request)`. Import the
frozen types from `package:qfli_studio_core/services/code_analysis.dart`.

`JavaDebugger.launch({required String projectPath, required String entryFile,
Map<String,String> unsavedBuffers = const {}, List<JavaBreakpoint> breakpoints
= const [], List<String> arguments = const []})` returns `JavaDebugSession`
immediately. A session exposes `ready`, `done`, `events`, `vmInfo`,
`setBreakpoint`, `removeBreakpoint`, `pause`, `resume`, `stepInto`, `stepOver`,
`stepOut`, `variables({frame = 0})`, `stackTrace`, `terminate`, and idempotent
`stop`. A breakpoint contains stable `id`, binary `className`, and one-based
`line`.

## 3. Contracts

- Analyze exact UTF-16 dirty document text, including CRLF, in an isolated copy
  of the project. Map diagnostics back to absolute owned source paths with
  half-open `startOffset`/`endOffset`. Use the trusted JSR-199 helper to obtain
  javac offsets; do not infer offsets from display columns.
- Compile with Java 17 compatibility and `-proc:none`. Analysis never invokes
  user main, annotation processors, remote resolution or writes user sources.
  Preserve local lib/libs JAR support. A new check cancels the previous check
  for the same root.
- Source errors are completed analysis with diagnostics. Infrastructure,
  cancellation, timeout and unreadable-JAR failures must provide a nonnull
  `unavailableReason`; an empty diagnostic list alone cannot mean success.
- Debugging intentionally runs a saved or supplied snapshot. JDI helper and
  target use the same bounded runner/native bridge. Bind only loopback with an
  ephemeral listener; use atomic ordered command files on OHOS, whose stdin is
  EOF. Never advertise external attach or network access.
- Variable inspection reads primitive/String values or reference identity;
  never invoke user `toString`. Stop remains available during compile/attach,
  cancels owned processes, drains bounded output, then removes temporary state.
- The direct Java debugger page uses saved project files and says so explicitly.
  It does not claim access to editor dirty buffers. Only controls supported by
  the actual session state are actionable. Dispose stops the owned session.

## 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Dirty path outside root | Unavailable/failure, no source write |
| javac source error | Diagnostic on exact submitted buffer |
| Missing/broken JDK or helper | Unavailable with actual reason |
| Compiler timeout/output/source budget | Cancel owned check and report failure |
| Unsupported JDI or attach failure | Actual error, no fake paused/clean state |
| Stop during startup | Cancel late-started owned children too |
| Descendant retains pipe after root exit | Bounded post-exit drainage |
| Consumer pauses stream | Preserve buffered bytes within drain deadline |

## 5. Good/Base/Bad Cases

Good: an unsaved CRLF buffer after an emoji produces a javac UTF-16 range while
saved bytes stay unchanged. Good: a real breakpoint stops before a statement,
locals change after stepping, continue produces actual stdout and exit status.
Base: clean compilation returns empty diagnostics and no unavailable reason.
Bad: no compiler or no JDI is reported as success from packaged filenames.

## 6. Tests Required

Run diagnostics and debugger tests against the available real JDK; test dirty
multi-file snapshots, Unicode offsets, cancellation, limits and no execution.
Run the real-JVM widget route test for breakpoint/locals/step/output and source
preservation. Unit/UI passes do not prove OHOS. Run the in-app runtime acceptance
target on each available ABI, retain its detailed JSON and rebuild normal main.

## 7. Wrong vs Correct

Wrong: parse javac's tab-expanded column as a Dart string index, or return clean
when the compiler could not start. Correct: use compiler source offsets and
separate unavailable results. Wrong: keep a backend-only debugger and claim the
feature is accessible. Correct: wire a direct tools card to real session actions
and verify it through the user interface and actual target runtime.
