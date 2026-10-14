# Spring Boot Support on HarmonyOS

## Goal

Let a user create a Spring Boot project in QFLIJVMX and actually run it on a
HarmonyOS (ohos) device — with the app compiling the sources, starting the
embedded web server, and opening the result in a browser — instead of handing
back a template whose imports cannot resolve.

The first deliverable is an honest feasibility answer. The ohos runtime uses
OpenJDK's Zero interpreter (no JIT) inside a forked, one-shot VM child. Spring
Boot loading tens of thousands of classes under those conditions may be
impractically slow. We do not ship a Spring Boot template until we have measured
that.

## Background

Current state (verified in this repository on 2026-10-13):

- `lib/java_runner.dart` compiles every project `.java` with `javac` and runs the
  entry class with `java`. The classpath is the temporary output directory plus
  every JAR under `lib/` and `libs/`. There is **no dependency resolver**: no
  Maven, no Gradle, no download.
- The in-app terminal sandbox rejects `mvn`, `gradle`, `curl`, and all compound
  syntax, so a user cannot fetch dependencies themselves.
- `ohos/entry/src/main/cpp/jdk_process.cpp` forks a child per command, `dlopen`s
  the JDK libraries, calls `JLI_Launch`, and `_exit`s. There is **no resident
  server concept**.
- `native/openjdk/ohos/zero-memory.patch` forces Zero interpreter entry records
  to be non-executable because HarmonyOS rejects executable anonymous mappings.
  JIT is therefore unavailable.
- `ohos/entry/src/main/ets/entryability/EntryAbility.ets` already implements the
  `openUrl` platform method via `ohos.want.action.viewData`, and `module.json5`
  already requests `ohos.permission.INTERNET`.
- Staged ohos inputs exist: `native/build/ohos/assets/jdk-x86_64.zip` (47.1 MB),
  `native/build/ohos/assets/jdk-arm64-v8a.zip` (47.1 MB), and 40 native files per
  ABI under `ohos/entry/libs/<abi>`.

## Requirements

### R1 — Measured feasibility on ohos (primary)

Run a minimal Spring Boot application on a real HarmonyOS device and record:

- cold-start time from JVM launch to the embedded server accepting connections
- whether the JVM stays alive and serves repeated HTTP requests
- peak memory behaviour if observable
- failure mode and diagnostics when it does not work

The probe must exercise the same code path the product would use (the JDK
installed by `JavaBridge.ets`, launched through `startJava`/`pollJava`), not a
desktop JVM.

### R2 — Bundled dependency set

Spring Boot classes must be available without network access at project run
time. Provide a pinned, checksummed set of Spring Boot JARs that the app can add
to the compile and run classpath, prepared by a repeatable script that records
versions and SHA-256 values, in the same spirit as the pinned `native/openjdk`
recipe inputs.

### R3 — Spring Boot project template

Add a Spring Boot project template that produces a standard layout and a real,
runnable application: an `@SpringBootApplication` entry class and at least one
`@RestController`. The template must compile and run against the bundled JARs
with no user-supplied dependencies.

### R4 — Compile and run with the bundled JARs

The Java runner must add the bundled Spring Boot JARs to both the `javac`
classpath and the `java` classpath, in addition to the existing project `lib/`
and `libs/` JARs, without regressing plain Java projects.

### R5 — Server-mode run and result viewing

When the entry class is a Spring Boot application, the run must be treated as a
long-running server: streamed startup output, no premature success/failure, a
way to stop it, and the ability to view `http://127.0.0.1:<port>` in a browser
via the existing `openUrl` path. A plain Java program must keep its current
one-shot semantics.

### R6 — Honest failure

If the probe shows Spring Boot cannot start in a usable time on ohos, the
template must not be shipped as if it works. Either it is gated to platforms
where it does work, or it is withheld, and the measured numbers are recorded.

## Constraints

- **Zero interpreter only on ohos.** No JIT. Performance decisions must be made
  from measurements, not assumptions.
- **No dependency resolution.** Bundled JARs only; no network fetch at runtime.
- **No resident VM exists today.** Server mode requires new lifecycle handling
  in the Dart runner and possibly the native bridge.
- **The sandbox terminal cannot evaluate compound commands.** Probe steps must
  not depend on shell pipelines or redirection.
- **ARM64 execution is unverified.** The ohos README records that only the
  x86_64 phone simulator passed smoke checks; ARM64 packaging passed but
  execution has not been proven on a physical device.
- **Two-repository layout.** The shared core lives in `../qfli_studio_core` and
  must not depend on the Java app; coupling goes through `StudioProfile`.
- Generated runtime assets and third-party JARs stay out of Git unless the repo
  already tracks that class of file.

## Out Of Scope

- Maven or Gradle build support, `pom.xml`/`build.gradle` parsing, or any online
  dependency resolution.
- Spring Data, JPA, a database, Spring Security, and Spring Cloud.
- Hot reload, debugger attachment, or classpath scanning optimisation.
- Multi-module Spring projects.
- Changing the Android runtime path (Android is a separate ABI/runtime story).

## Acceptance Criteria

- [ ] A minimal Spring Boot app is launched on a HarmonyOS device through the
      app's real JDK path, and cold-start time plus HTTP responsiveness are
      recorded as concrete numbers.
- [ ] The measured result is written into the task artifacts and, when relevant,
      into `.trellis/spec/backend/mobile-jdk.md`.
- [ ] A repeatable preparation script produces the bundled Spring Boot JAR set
      with pinned versions and SHA-256 values, and the set is present at run time.
- [ ] The Spring Boot template compiles with the bundled JARs and no
      user-supplied dependencies.
- [ ] The run reaches the point where the embedded server answers an HTTP
      request, or the failure is reported with its real diagnostic.
- [ ] Plain Java projects behave exactly as before: same compile path, same
      titles, same exit-code semantics, existing suites green.
- [ ] `flutter analyze` and `flutter test` pass; ARM64 packaging succeeds.
- [ ] If Spring Boot cannot run usably on ohos, no template claims otherwise and
      the limitation is documented in the spec.

## Notes

- The probe is the gate. Do not build the template before the measurement exists.
- Prefer the smallest possible Spring Boot app for the probe: one
  `@SpringBootApplication`, one `@RestController`, no `spring-boot-starter-web`
  autoconfiguration beyond what is needed to bind a port.
- `spring-boot-starter-web` pulls a large transitive set; the bundled JAR list
  must be explicit and minimal rather than the whole starter closure if that
  proves too heavy for the HAP.
