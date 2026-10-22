# Final Java integration review (2026-10-22)

Reviewer: trellis-check. Current Java source state passes static analysis and
the complete serial test suite after the mobile temporary-directory repair.
This review does not establish an OHOS device pass or umbrella completion.

## Findings fixed

- `lib/java_debugger.dart` and `lib/java_debugger_page.dart`: ASCII-only
  package/breakpoint expressions rejected valid Chinese Java identifiers.
  Expanded the existing expressions to accept Unicode UTF-16 units. The real
  JVM page regression now compiles package `示例`, binds its actual breakpoint,
  inspects local values, steps, resumes and verifies output/exit/source integrity.
- `test/java_unicode_package_test.dart`: added a real ordinary Run regression
  for package `示例.中文包`, emoji output, the resolved launch title and unchanged
  source bytes. The runtime owner applied the matching package parser fix in
  `lib/java_runner.dart` while owning the mobile temporary-directory repair.
- `.trellis/spec/backend/mobile-jdk.md`: documented actual creation of
  `home/tmp`, recovery through cached preparation, explicit Java/javac temporary
  properties, caller override order, the shared OHOS launch path and desktop
  isolation. The corresponding real-JVM and transport regressions are recorded.
- Earlier tools/catalog parser, bounds, cancellation and verifier corrections
  remain detailed in `java-review.md`; the final full suite includes them.

## Reviewed integration

- Real profile -> tools builder -> direct grid -> debugger route: ProjectStore
  and terminal callback reach the content-only tools body. Nine Java tools,
  nine common tools and the optional terminal remain directly reachable.
  `javaProfile` wires the actual diagnostics provider and stays offline.
- Debugger startup, isolated source/JAR compilation, trusted local JDI helper,
  loopback-only ephemeral JDWP, commands/frames/locals, stop and disposal were
  checked against actual code and real-JVM tests. Inspection does not invoke
  user `toString`; tests exercise real breakpoint/local/step/output behavior.
- The mobile runtime owner's `MobileJvmLaunch` repair reaches Android Java and
  javac, OHOS ordinary/module/helper launches and cached JDK preparation. It
  prepends sandbox `java.io.tmpdir` before explicit caller options and leaves
  desktop JDK resolution independent of a cached mobile layout.
- The runtime acceptance harness uses actual diagnostics and debugger services,
  checks exact CRLF/UTF-16 ranges, dirty multi-file snapshots, no source writes
  or user execution, and retains a failing gate when cleanup is unconfirmed.
  Host execution cannot satisfy its OHOS device gates.
- Read the current tools, content, mobile JDK, Java analysis/debugging and Java
  catalog audit contracts. The main session already synchronized tools-tab
  counts to 9 Java /18 standalone /19 with terminal; no stale spec issue remains.

## Findings not fixed

- **Windows supplementary-plane class names:** a real Run of package
  `示例.𐐀包` compiled successfully but the selected Windows JDK25 launcher
  reported `ClassNotFoundException: 示例.??包.Main`. A separate real UTF-8
  `@argfile` probe also failed to preserve the main-class name. The main session
  approved keeping the verified BMP Chinese regression and recording this
  limitation rather than changing the launch protocol during review. A future
  Windows launch solution needs actual class-name and argument round-trip,
  stdin, cancellation and cleanup evidence. No universal Unicode-launch claim
  is made. This failure has no established OHOS applicability.
  - Failed full-suite evidence: `java-final-full-test-supplementary-failure.log`
    (**234 pass /1 fail**; the failing original test is explicitly retained in
    that log).
  - Probe used `D:/ProgramFiles/Java/jdk-25/bin/java.exe` and javac `--release17`.
    Direct and UTF-8 argument-file launches both exited1. The probe workspace
    is `D:/AppData/Local/Temp/qfli-java-argv-71c6c76a31e04f7a84ae16372d3fa0d9`.
- **Shared URI-read boundary:** `PickerService.readUri` materializes the native
  byte response before Java can enforce its input cap. Local file reads are
  bounded beforehand. A bounded URI-read contract belongs to the common
  core/platform owner; this reviewer did not change that public boundary.
- Root owns final exhaustive host280, actual OHOS catalog/diagnostics/debugger
  reports, normal-app restoration, device handoff, scoped commits and remote
  pushes. Physical ARM64 and other products require independent evidence.
  Passing Java host tests does not close these acceptance gates.

## Final verification

- Lint and type-check: `flutter analyze --no-pub` — **No issues found**, exit0.
  Full output: `java-final-analysis.log`.
- Full tests: `flutter test --no-pub --concurrency=1 --timeout 120s
  --reporter expanded` — **235/235 pass**, exit0, 1m49s.
  Full output: `java-final-full-test.log`.
- Focused final Unicode ordinary Run + actual debugger page — **2/2 pass**.
- Earlier focused debugger page suites after the parser fix — **10/10 pass**.
- Earlier core catalog inventory —1120 snippets,280 distinct payloads,0 issues;
  this is inventory evidence from `qfli_studio_core/build/java-review-inventory.json`.
- No staging, commit, device manipulation or common-core UI edits by this review.
