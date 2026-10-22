# Combined Java runtime acceptance entry

Date: 2026-10-22. Worker owns only the new harness, its focused test and this evidence handoff. Production services, core, UI, device, daemon, build and signing were not changed or operated by this worker. Preserve concurrent owners' changes.

## Entry and durable evidence

Use `tools/java_runtime_acceptance.dart` as the temporary Flutter target after the current catalog audit finishes. It uses `AppPaths.storageDirectory()` and writes `qfli-java-runtime-acceptance.json` directly in that app storage, with flushed intermediate stages and a final complete report. A unique private work directory is removed only when cleanup is confirmed. Restore `lib/main.dart` after device probes.

The expected OHOS pull location for this product is:

```text
/data/app/el2/100/base/com.azurekiln.qfli.java/files/qfli-java-runtime-acceptance.json
```

Use the actual `report` path printed by the harness if the platform returns a different AppPaths storage directory. The expected bundle is **com.azurekiln.qfli.java**, not com.azurekiln.qfli.jvmx. A typical root-owned pull is:

```text
hdc -t TARGET file recv /data/app/el2/100/base/com.azurekiln.qfli.java/files/qfli-java-runtime-acceptance.json DESTINATION.json
```

`QFLI_JAVA_RUNTIME_STAGE` logs short progress. Final `QFLI_JAVA_RUNTIME_ACCEPTANCE` logs only overall/separate device gate flags, OS, report path and report SHA256. Detailed compiler/JVM messages, stack traces and every exact submitted buffer remain in the JSON rather than relying on truncated log lines.

## Actual checks

1. Start the real Java and javac through `JavaProgramRunner.startToolchainProcess`, including real JVM settings. Record full stdout/stderr, exit status, Java/runtime version, VM name and architecture. Require both runtime and compiler major17 for acceptance; host JDK25 is explicitly a failed17 gate, never target-runtime proof.
2. Run `JavaDiagnosticAnalyzer.analyzeProject` three times against three unsaved CRLF buffers containing emoji, Chinese and tabs. The two existing saved sources are intentionally invalid, so successful clean analysis requires the supplied buffers; a third public class exists only in memory and is required by Main. The type case verifies the complete `"wrong"` literal in Main and `42` in Helper at exact UTF-16 offsets/lengths. The syntax case verifies the semicolon insertion offset and javac's zero/one-unit error range. The clean case requires no diagnostics.
3. Record exact buffer text, UTF-16 length, SHA256, every diagnostic's original path/offset/length/line/column/code/message and selected fragment. Require in-bounds ranges, unchanged original bytes/hashes, no saved Extra buffer, no class/project output and cleaned compiler scratch after each case. Submitted Main has static-initializer and main marker writes: absence of `USER_CODE_WAS_EXECUTED` proves those user-code entry paths were not executed by analysis.
4. Reuse the existing `runJavaDebugSmoke` unchanged. Its full genuine breakpoint/locals/stack/step/dynamic-breakpoint/resume/stdout/repeat/termination observations and actual VM flags are retained. If it fails, additionally collect full native JDI module and loopback JDWP agent probe stdout/stderr/exit status for diagnosis. Those prerequisite probes never count as a debugger pass.

The JSON includes `diagnosticsDeviceGatePassed`, `debuggerDeviceGatePassed` and overall `deviceGatePassed`. Device flags require the actual OS to be ohos plus real Java/javac17 and the corresponding real service assertions. Overall additionally requires confirmed work cleanup. An unsupported Zero/JDI behavior is retained as a failure, not inferred from bundled module names.

## Deadlines and failure semantics

AppPaths resolution:20s; mobile preparation:90s; raw process start:30s and execution/drain:30s; raw output:64KiB total; cancellation:10s and each subscription cleanup:5s. Each diagnostic check has a120s service timeout, an outer15s allowance, explicit cancellation and another15s cleanup allowance. File report writes/deletion have10s deadlines. Debug smoke's enclosing deadline is8min; its own existing startup/command/observation bounds remain active.

The reused debug smoke does **not** expose an external cancellation handle. If its enclosing deadline expires or its cleanup throws, the harness reports `ok:false`, `cleanupConfirmed:false`, retains its work directory and explains that the root must stop the app before cleanup. It never claims a timed-out underlying smoke was cancelled. Late native starts from simple runtime probes are cancelled if they eventually arrive, while cleanup remains honestly unconfirmed for that timed-out attempt.

## Worker checks

`dart analyze tools/java_runtime_acceptance.dart test/java_runtime_acceptance_test.dart`: no issues.

`flutter test --no-pub test/java_runtime_acceptance_test.dart --reporter expanded --timeout 180s`:1/1 passed with actual desktop Java services (about8s). It runs all three compiler checks and the real complete debug smoke, round-trips the durable JSON, verifies exact Unicode range and all checks, preserves an existing sentinel file, confirms fixture cleanup, and rejects a host OHOS gate. The host runner uses JAVA_HOME JDK25; this is harness validation only.

No build, install, device run, signing or daemon operation was performed here. The root is currently running a real OHOS x86 catalog audit; this new harness still needs that root-owned build/install/run and report pull before its device gates can pass.
