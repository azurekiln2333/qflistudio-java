# Implement: Spring Boot Support on HarmonyOS

Ordered checklist. Stages are gated: do not start a stage before the previous
stage's validation passes.

## Stage 0 — Environment And Baseline

- [ ] 0.1 Confirm the host can reach Maven Central
      (`Invoke-WebRequest https://repo1.maven.org/maven2/`). If not, stop and
      report; the JAR set cannot be prepared offline.
- [ ] 0.2 Confirm host JDK for Stage 1: `javac -version` / `java -version`.
      JDK 24 is present; Spring Boot 3.x targets 17, which is fine.
- [ ] 0.3 On the ohos device, run the **existing** baseline first:
      `flutter run -t tools/jdk_smoke.dart -d <device>`
      and require `QFLI_JDK_SMOKE {"ok":true,...}` with all eight checks.
      A baseline failure must be fixed before the Spring Boot probe is
      meaningful. Record the device model, OS version, and ABI.

## Stage 1 — Bundled JAR Set And Desktop Proof

- [ ] 1.1 Create `tools/spring_boot.lock.json` with the pinned artifact list,
      versions, and SHA-256 values. Start with the §2.3 list in `design.md`.
- [ ] 1.2 Create `tools/prepare_spring_boot.ps1`: download from Maven Central,
      verify SHA-256 against the lock file, write to
      `assets/spring_boot/<version>/`. Refuse on mismatch.
- [ ] 1.3 Run the script and verify every artifact downloaded and verified.
- [ ] 1.4 Add `assets/spring_boot/` to `.gitignore` (track only the lock file
      and the script), consistent with how `native/build` is handled.
- [ ] 1.5 Create a scratch Spring Boot project (not a product template):
      `ProbeApplication.java` + `ProbeController.java` as described in
      `design.md` §2.4.
- [ ] 1.6 Compile it with the host `javac` and the prepared JARs on the
      classpath. Require exit 0.
- [ ] 1.7 Run it with host `java` and the prepared JARs on the classpath.
      Require the log to reach the "Tomcat started on port" line.
- [ ] 1.8 Issue an HTTP GET to the bound port and require the controller body.
      Record the exact classpath string that worked — this is Stage 2's input.
- [ ] 1.9 Record the total size of the prepared JAR set.

**Gate 1:** classpath proven on desktop, set size known. If the set is too large
for a HAP asset, decide the trim here (drop autoconfiguration, hand-build
`WebServerFactory`) and redo 1.5–1.8.

## Stage 2 — ohos Probe (the real gate)

- [ ] 2.1 Create `tools/spring_boot_probe.dart` using `MobileJdk.prepare()` +
      `OhosJdkProcess.start(...)`, following `tools/jdk_smoke.dart` structure.
- [ ] 2.2 Ensure the prepared JARs are reachable on the device. Add the asset
      staging needed for the probe (asset → app data directory), following how
      the JDK zip is staged in `JavaBridge.ets`.
- [ ] 2.3 Compile the probe sources with `javac` through the app's JDK path
      (`javac` module entry on ohos), with the bundled JARs on the classpath.
- [ ] 2.4 Launch with `OhosJdkProcess`, timestamp the JVM launch and the
      server-ready line, parse the port.
- [ ] 2.5 Issue an HTTP request from Dart to `127.0.0.1:<port>`; record status
      and body.
- [ ] 2.6 Stop the child via `cancel`; confirm it is reaped.
- [ ] 2.7 Emit one JSON line: `ok`, `jvmStartMs`, `serverReadyMs`, `httpStatus`,
      `port`, plus `error`/`stack` on failure — same style as `QFLI_JDK_SMOKE`.
- [ ] 2.8 Run on the user's ARM64 device; also run on x86_64 if available.
- [ ] 2.9 Record the measured numbers in `notes/` under the task directory.

**Gate 2 (hard):**
- If cold start is under the usable bound (target 60 s) and HTTP responds →
  proceed to Stage 3.
- Otherwise → **stop.** Record the failure and diagnostics, update
  `.trellis/spec/backend/mobile-jdk.md`, and report to the user that Spring Boot
  is not viable on ohos. Do not implement Stage 3.

## Stage 3 — Product Integration

Only after Gate 2 passes. Read `.trellis/spec/backend/mobile-jdk.md` and
`.trellis/spec/frontend/editor-terminal.md` before touching these files.

- [ ] 3.1 Add bundled-JAR resolution to `JavaProgramRunner`: locate the prepared
      set (asset extraction on mobile, `assets/spring_boot/` on desktop), cache
      it, and append to the classpath in both the compile and run arguments.
- [ ] 3.2 Add `ProjectTemplate.springBoot` to
      `../qfli_studio_core/lib/services/project_templates.dart` (enum member,
      `type`, and the template file list). Keep the shared core free of any
      Spring-specific logic.
- [ ] 3.3 Add the template to `StudioProfile.templates` in `lib/main.dart`.
- [ ] 3.4 Add Spring Boot entry detection: an `@SpringBootApplication` source is
      recognised as the entry (reuse the `_packageName` scan pattern).
- [ ] 3.5 Implement server mode in the runner: watch stdout for the server-ready
      line, open `http://127.0.0.1:<port>` through the existing `openUrl` path,
      and keep `cancel` as the stop mechanism.
- [ ] 3.6 Confirm the terminal transcript handles a never-exiting program
      without a synthetic success line (per the editor-terminal contract).
- [ ] 3.7 Add tests: bundled-JAR classpath inclusion does not regress plain Java;
      template creation; Spring Boot entry detection; server-ready line parsing.
- [ ] 3.8 Run `flutter analyze` in both repositories; run `flutter test`.
      Existing suites must stay green.
- [ ] 3.9 Build `flutter build hap --debug --target-platform ohos-arm64` and
      verify the HAP packs the bundled assets.
- [ ] 3.10 Device run: create a Spring Boot project in the app, run it, confirm
      the browser opens and shows the controller response.

## Review Gates

| Gate | After | Pass condition |
| --- | --- | --- |
| 1 | Stage 1 | classpath proven on host JVM; set size known and HAP-viable |
| 2 | Stage 2 | measured cold start under bound and HTTP responds on the device |

Gate 2 is the project's decision point. Everything before it is measurement;
everything after it is only justified by its numbers.

## Validation Commands

```powershell
# Stage 1
pwsh ./tools/prepare_spring_boot.ps1
javac -encoding UTF-8 -cp "<jars>" -d out <sources>
java -cp "out;<jars>" demo.ProbeApplication

# Stage 2 baseline, then probe (device required)
flutter run -t tools/jdk_smoke.dart -d <device>
flutter run -t tools/spring_boot_probe.dart -d <device>

# Stage 3
flutter analyze
flutter test --no-pub
flutter build hap --debug --target-platform ohos-arm64
```

## Rollback Points

- After Stage 1: delete the script, lock file, and `assets/spring_boot/`. No
  product code touched.
- After Stage 2: additionally delete `tools/spring_boot_probe.dart` and any
  probe-only asset staging.
- After Stage 3: revert the runner, template, and profile commits. Plain Java
  behavior is unaffected throughout, so a partial revert is safe.

## Open Decisions Deferred To Implementation

- Whether server mode adds a `serverReady` future to `ProgramRunResult` or the
  runner owns the open-URL side effect. Constraint: the shared core must not
  learn about Spring Boot.
- Whether to bind port 0 or a fixed high port. Depends on what Spring Boot
  reports on ohos.
- Final JAR set size, decided by Gate 1 and the HAP asset budget.
