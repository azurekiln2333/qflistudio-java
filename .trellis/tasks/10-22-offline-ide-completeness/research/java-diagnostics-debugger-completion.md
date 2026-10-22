# Java diagnostics and debugger worker handoff

Date: 2026-10-22. No commits made. Root owns integration, UI, final checks and commits. Common core remains exclusively C coordinator owned.

## Delivered files and interfaces

- `lib/java_runner.dart`: normal Run enforces Java17 compatibility; javac has bounded time/output/heap and awaits termination. Reusable `startToolchainProcess` exposes raw bytes; `runToolchainCommand` preserves line-stream terminal integration. Trusted analysis/debugger starts clear Java environment injection options. OHOS javac VM options precede its compiler module entry. Windows explicit cancellation kills the owned process tree; desktop post-exit pipe drainage has a two-second active-consumption budget, suspended during consumer pause and resumed with the remaining budget.
- `lib/java_diagnostics.dart`: `JavaDiagnosticAnalyzer implements CodeAnalyzer` consumes the published core contract. Real trusted JSR199 javac snapshots all Java source/dirty buffers and local lib/libs JARs. Actual UTF-16 offsets, source identities, errors/warnings and infrastructure failures remain distinct. Analysis never writes project buffers, runs user code or invokes annotation processors. Cancellation, size/output/time limits and cleanup are covered.
- `test/java_diagnostics_test.dart`: 20 tests, including real compiler behavior, Java17 API/syntax boundary, unsaved multifile buffers, same-name sources, CRLF/emoji ranges, local JARs, annotation-processor exclusion, cancellation/limits/tool absence and preservation of actual output paused across process exit.
- `lib/java_debugger.dart`: real two-JVM JDI/JDWP backend through the same toolchain/native bridge. `JavaDebugger.launch` returns a stoppable `JavaDebugSession` immediately, with ready/done/events, actual deferred and dynamic line breakpoints, pause/resume, step into/over/out, stack/locals and termination. A listener remains bound to loopback on its assigned ephemeral port. Atomic per-session files carry commands because the OHOS bridge supplies EOF stdin. Inspection reads metadata and never invokes user methods. Actual VM flags are reported; unsupported frame-pop/force-return actions are absent.
- `test/java_debugger_test.dart`: 13 genuine JVM tests, including smoke, concurrency/session isolation, dirty sources, class filters, Unicode/reference inspection, preparation failure, running/paused termination, inherited-output descendants and raw-byte output limits.
- `tools/java_debug_smoke.dart`: run `flutter run -t tools/java_debug_smoke.dart -d TARGET`; require `QFLI_JAVA_DEBUG_SMOKE` with every check and ok=true, actual platform/JVM/ABI/capabilities. Restore the normal app after any device probe.
- `research/java-debugger-design.md` and `research/java-debugger-jdk17-evidence.json`: pre-implementation design, native audit boundaries and actual JDK17 proof.

## Final checks

`flutter test --no-pub test/java_debugger_test.dart test/java_diagnostics_test.dart --concurrency 1 --reporter expanded --timeout 90s`: 33/33 passed. Runner resolves the host JAVA_HOME `D:/ProgramFiles/Java/jdk-25` (Java25+37-LTS-3491); all user compilation uses release17. The identical JDI helper separately passed 13 actual protocol checks on WSL OpenJDK17.0.20.1, as recorded in the evidence JSON. A read-only reviewer also verified the exact final drain method with real host processes: retained paused output and finite4443ms drainage with continuous descendant output and repeated short downstream pauses.

`dart analyze lib/java_runner.dart lib/java_debugger.dart lib/java_diagnostics.dart test/java_debugger_test.dart test/java_diagnostics_test.dart tools/java_debug_smoke.dart`: no issues. `git diff --check -- lib/java_runner.dart`: passed.

The earlier combined run could not load `java_app_test.dart`: concurrently edited core `editor_problems_bar.dart` referenced absent `CodeDiagnostic.line/column` and `EditorFileDiagnostics.pending`. Root was notified; re-run the app/integration suite after the core owner's batch is consistent.

## Remaining gates and limits

- `hdc list targets` is Empty. No OHOS debugger/diagnostics runtime pass or UI availability is claimed. Host tests, staged JDWP libraries and native source review do not close that gate.
- The existing native bridge cancels its owned PID; Unix desktop fallback similarly cancels the owned root. Only Windows live-root cancellation has an implemented/tested descendant-tree guarantee. Natural root exit can leave user-spawned descendants alive; output drainage and debugger snapshot cleanup still complete in bounded time, and regression fixtures explicitly reap their descendants.
- The trusted diagnostics helper is recompiled per request. Correctness and cancellation are tested; root may subsequently optimize caching with a source/toolchain identity key.
- An earlier failed regression left `D:/AppData/Local/Temp/java debugger project df8ca2bb`. The child's kill was issued but the test originally did not await its exit before deleting its cwd; that test race is fixed and the final complete run passes. Optional removal of the old fixture was rejected by automatic approval review with `blocked by policy`, so it was left in place; no broad cleanup was attempted.
- Root owns product/core UI and final verification. No shared-core, main/tools UI, other product content or commit changes were made by this worker. The umbrella task remains open.
