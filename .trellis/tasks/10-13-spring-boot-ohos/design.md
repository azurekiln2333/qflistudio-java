# Design: Spring Boot Support on HarmonyOS

## 1. Goal And Shape

Deliver an honest, measured answer to "can Spring Boot run on ohos", and only
then a template backed by a bundled dependency set and a server-mode run path.

The work is deliberately staged so the expensive, uncertain part (does it run at
all, and how slowly) is answered first, with the cheapest possible instrument.
Each stage produces an independently verifiable result.

```
Stage 1  Desktop: prepare JAR set, prove the exact classpath works
   |
   |  (input: exact JAR list + classpath proven on a JVM)
   v
Stage 2  ohos probe: same JARs on device, measure cold start + HTTP
   |
   |  (gate: only continue if it starts in usable time)
   v
Stage 3  Product: template + classpath wiring + server-mode run + result view
```

## 2. Stage 1 — Bundled JAR Set And Desktop Proof

### 2.1 Why desktop first

The ohos JVM is the same OpenJDK 17.0.20 build; if the classpath is wrong, it is
wrong everywhere. Proving it on the host JVM (already present, JDK 24) removes
classpath errors as a variable before the expensive device loop.

### 2.2 Preparation script

New script `tools/prepare_spring_boot.ps1` (PowerShell 7, matching the existing
`native/openjdk/stage.ps1` style):

- Takes an explicit dependency list with pinned versions.
- Downloads each artifact from Maven Central over HTTPS.
- Verifies SHA-256 against a checked-in lock file
  (`tools/spring_boot.lock.json`).
- Writes the verified JARs to `assets/spring_boot/<version>/`.

The lock file is the source of truth; the script refuses to proceed on a hash
mismatch. This mirrors the pinned-input discipline already used for the
OpenJDK recipes.

### 2.3 Candidate dependency set

Start minimal and grow only if the probe fails for a missing class. Expected
core (versions pinned at implementation time, Spring Boot 3.x on JDK 17):

| Artifact | Role |
| --- | --- |
| `spring-boot` | `SpringApplication` bootstrap |
| `spring-boot-autoconfigure` | autoconfiguration |
| `spring-core` | core utilities |
| `spring-context` | application context |
| `spring-beans` | bean factory |
| `spring-aop` | proxying |
| `spring-expression` | SpEL |
| `spring-web` | web abstractions |
| `spring-webmvc` | MVC layer |
| `tomcat-embed-core` | embedded servlet container |
| `tomcat-embed-el` | EL for MVC |
| `jakarta.annotation-api` | `@PostConstruct`, `@Resource` |
| `jakarta.servlet-api` | servlet API |
| `slf4j-api` + `logback-classic` + `logback-core` | logging |

Total is expected around 20–30 MB. If the HAP asset budget rejects that, the set
is trimmed by dropping autoconfiguration and building the `WebServerFactory`
manually — decided from Stage 2 evidence, not upfront.

### 2.4 Desktop proof procedure

A scratch project is compiled and run against the prepared set on the host JVM:

```
src/main/java/demo/ProbeApplication.java   @SpringBootApplication
src/main/java/demo/ProbeController.java    @RestController, GET / returns text
```

Success is: `javac` exits 0 with the set on the classpath, the process reaches
"Tomcat started on port", and an HTTP GET to the bound port returns the
controller body. This is done with a plain `java` invocation, matching how
`JavaProgramRunner` builds its command line.

## 3. Stage 2 — ohos Probe

### 3.1 Instrument

Extend the existing pattern of `tools/jdk_smoke.dart`: a dedicated entry
(`tools/spring_boot_probe.dart`) run inside the app on the device. It must use
the product's real path:

1. `MobileJdk.prepare()` to get the installed JDK layout.
2. `OhosJdkProcess.start(...)` with the bundled Spring Boot JARs on the
   classpath — the same fork + `dlopen` + `JLI_Launch` bridge the product uses.
3. Read streamed stdout, timestamp the first line and the moment
   "Tomcat started" appears.
4. Issue an HTTP request from Dart to `127.0.0.1:<port>` and record the response.
5. Stop the child via `cancel`.

Timing is measured in Dart around the native child, because the JVM is a forked
child with no direct instrumentation. The probe reports a single JSON line with
`ok`, `jvmStartMs`, `serverReadyMs`, `httpStatus`, and the port, in the same
style as `QFLI_JDK_SMOKE`.

### 3.2 Why a separate entry and not the product runner

`JavaProgramRunner.run` returns a `ProgramRunResult` whose `exitCode` future
completes when the program ends. A server never ends. Running the probe through
the product runner would require the server-mode mechanism to already exist,
which is Stage 3. Keeping the probe on `OhosJdkProcess` directly isolates the
measurement from product changes and keeps the gate honest.

### 3.3 Port selection

The probe binds port 0 inside Spring Boot if possible, or a fixed high port
(e.g. 18080) with the port parsed from the "Tomcat started on port(s): N" line
as a fallback. The Dart side must not assume 8080.

### 3.4 Gate

- If cold start is within a usable bound (target: under 60 s) and HTTP responds,
  proceed to Stage 3 with the measured budget in the task notes.
- If it is far slower, hangs, or fails, stop. Record the failure, its diagnostic,
  and the numbers. Do **not** ship a template. Update
  `.trellis/spec/backend/mobile-jdk.md` with the finding so the limitation
  survives future sessions.

## 4. Stage 3 — Product Integration

### 4.1 Classpath wiring

`JavaProgramRunner` gains a bundled-JAR source. Today `_collectJars` only walks
the project. The change adds the bundled set after the project JARs:

```
classPath = [output, ...projectJars, ...bundledSpringBootJars].join(separator)
```

The bundled set is located once at startup (extracted from assets into the app
data directory on mobile, read from `assets/spring_boot/` on desktop) and cached,
mirroring how `MobileJdk` caches its layout. Plain Java projects are unaffected:
their behavior depends only on `javac`/`java` receiving a longer classpath, which
is a no-op when the extra JARs are not referenced.

### 4.2 Template

Add `ProjectTemplate.springBoot` with:

```
src/main/java/com/example/demo/DemoApplication.java
src/main/java/com/example/demo/HelloController.java
src/main/resources/application.properties
```

The `ProjectTemplate` enum and its `type`/`directoryName` switch live in the
shared core (`../qfli_studio_core/lib/services/project_templates.dart`). The Java
app narrows visible templates through `StudioProfile.templates`, so the template
must be declared in the core enum and then opted into by `_createJavaProfile()`.

Entry detection: the template's main file is the `@SpringBootApplication` class,
not `Main.java`. `entryFileNames` currently lists `Main.java`/`src/Main.java`;
Spring Boot entries need either an added entry name or a content-based
`@SpringBootApplication` scan. The runner already has `_packageName(source)`;
the same reuse pattern applies for a `_isSpringBoot(source)` check.

### 4.3 Server mode

This is the largest new mechanism. A Spring Boot run is a long-running server,
so `ProgramRunResult.exitCode` cannot be the completion signal.

Proposed shape, kept inside the existing `ProgramRunResult` contract where
possible:

- The runner returns `ProgramRunResult` with streamed stdout/stderr and a
  `cancel` that stops the server.
- The runner watches stdout for the server-ready line (`Tomcat started on port`,
  or the Jetty/Netty equivalent) and, on match, triggers `RunnerService.openUrl`
  for `http://127.0.0.1:<port>`. `openUrl` already works on ohos via the Want
  path in `EntryAbility.ets`.
- The terminal must not print a synthetic success line while the server is up;
  the editor-terminal spec already suppresses exit code 0 for successful runs,
  and a server has no exit code until stopped.

The exact plumbing (whether a `serverReady` future is added to
`ProgramRunResult`, or the runner owns the open-URL side effect) is decided at
implementation. The constraint is that the shared core must not learn about
Spring Boot; all Spring-specific knowledge stays in the Java app.

### 4.4 Android

Android is explicitly out of scope for the first delivery. The Android path uses
installed ELF launchers and a different runtime story; the probe result on ohos
does not transfer. If Spring Boot works on desktop and ohos, Android is a
follow-up with its own measurement.

## 5. Contracts Touched

| Contract | File | Change |
| --- | --- | --- |
| Mobile JDK channel | `lib/mobile_jdk.dart`, `ohos` bridge | unchanged API; probe consumes `start`/`poll`/`cancel` as-is |
| Java runner | `lib/java_runner.dart` | classpath gains bundled JARs; optional Spring Boot entry detection and server mode |
| Project templates | `../qfli_studio_core/lib/services/project_templates.dart` | new `springBoot` enum member |
| Profile | `lib/main.dart` | `templates` gains the Spring Boot template; entry names if needed |
| Editor/terminal | shared core | no change beyond what already exists; server output streams through the existing transcript path |

## 6. Risks And Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Zero is too slow for Spring Boot | Probe fails; no product work justified | Stage 2 gate exists precisely for this |
| HAP asset size vs 20–30 MB JARs | Packaging or install failure | Trim the set; measure HAP size in Stage 2 |
| `ProcessBuilder` restrictions on ohos | Some Spring component fails to spawn | Probe uses no subprocess; if a needed component spawns, it fails visibly in the probe |
| ARM64 physical execution unverified | Probe may fail on the user's device for reasons unrelated to Spring Boot | Run `tools/jdk_smoke.dart` first on the same device to establish the baseline; a baseline failure is a different bug |
| fork-per-command model needs change for server mode | Larger change than expected | Stage 3 only; the probe proves the native child can stay alive without code changes |
| Third-party JARs entering Git | Repo bloat | `assets/spring_boot/` ignored like `native/build`; only the lock file is tracked |

## 7. Rollback

Artifacts are additive: a new script, a new lock file, a new template enum
member, and a classpath argument. Deleting the template declaration and the
bundled-JAR source restores current behavior. No existing contract is modified
in a way that affects plain Java projects, so rollback is a revert of the
Stage 3 commits.

## 8. Verification Strategy

- Stage 1: script run + desktop `javac`/`java` against the set + HTTP response.
- Stage 2: device run of `tools/spring_boot_probe.dart`, one JSON line with
  measured timings; baseline `tools/jdk_smoke.dart` run first.
- Stage 3: `flutter analyze`, `flutter test` (existing suites must stay green),
  `flutter build hap --debug --target-platform ohos-arm64`, plus a device run
  showing the browser opens and serves the controller response.
- The probe's measured numbers and any spec update are part of the deliverable,
  not optional commentary.
