# Mobile JVM temporary-directory fix

2026-10-22. Root's real OHOS catalog run completed 266/280, with 14 failures
in default `Files.createTempFile` / `Files.createTempDirectory` calls because
the packaged JVM selected `/tmp`, which does not exist in this app sandbox.
The native bridge already sets `TMPDIR` to the app JDK's `home/tmp`; that
environment value alone did not initialize `java.io.tmpdir` in this runtime.
The failing report is retained by root at `build/java-ohos-catalog-progress.json`.

## Product fix

`MobileJvmLaunch` creates the actual `home/tmp` directory and prepends the
JVM argument `-Djava.io.tmpdir=<home/tmp>`. The Android `javac` launcher receives
the equivalent `-J-Djava.io.tmpdir=<home/tmp>`. Explicit per-command property
options remain after the default, preserving the launcher's existing override
semantics and leaving argument tokens unchanged.

OHOS `OhosJdkProcess.start` applies this default at its common launch boundary.
It therefore covers runtime execution, compiler module execution, version
probes, diagnostic compilers, debugger helpers, and debugger targets. Android
process launches in `JavaProgramRunner` and `MobileJdk.prepare` use the same
helper. Cached mobile preparation recreates a missing temporary root before
Dart-side compiler/debugger/analyzer temporary directories are allocated.

Desktop/WSL JDK launches do not receive mobile JVM defaults. No process
environment sanitation or inheritance behavior was changed. No content,
shared-core source, native bridge, app data, or device state was changed.

The separately reviewed Unicode package-name expression was also applied
mechanically to the normal runner while it was exclusively owned. The review
worker owns its real-JVM Unicode package regression.

## Verification

- `dart analyze` on the four changed runtime files and two regression files:
  no issues.
- `flutter test test/mobile_jvm_launch_test.dart test/ohos_jdk_process_test.dart
  test/java_diagnostics_test.dart test/java_debugger_test.dart --reporter expanded`:
  42 passed. Full log: `build/java-mobile-tmp-tests.log`.
- Tests check actual OHOS channel argument payloads and directory existence
  for regular Java, compiler-module, JDI-helper and explicit-property calls.
- Tests cover Android javac JVM forwarding, argument preservation, cached-root
  recreation, and a desktop process ignoring a cached mobile sandbox path.
- An actual host JVM compiles Java17 code and successfully creates both a
  default temporary file and directory under the supplied sandbox root.

These checks do not substitute for the root's repeated full OHOS catalog run.
The fixed catalog HAP build evidence is recorded separately in
`java-catalog-ohos-x64-tmpfix-build.json`; root owns installation and runtime
acceptance and must retain the initial failure as well as subsequent results.
