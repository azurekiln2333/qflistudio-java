# Stage 1 — Bundled JAR Set And Desktop Proof

Date: 2026-10-13
Host: Windows 10, JDK 24.0.2 (compile target 17), Maven 3.6.3

## Result: PASS

| Step | Outcome |
| --- | --- |
| 0.1 Maven Central reachable | HTTP 200 |
| 0.2 Host JDK | `javac 24.0.2`, `java 24.0.2` |
| 1.1 Lock file written | `tools/spring_boot.lock.json`, 28 artifacts |
| 1.2 Prepare script | `tools/prepare_spring_boot.ps1` |
| 1.3 Download + verify | 28/28 fetched, all SHA-256 verified |
| 1.4 Gitignore | `/assets/spring_boot/` ignored; lock + script tracked |
| 1.6 `javac --release 17` | exit 0 |
| 1.7 Run | reached `Tomcat started on port 54687` |
| 1.8 HTTP GET | status 200, body `PROBE_OK` |
| 1.9 Set size | 17.46 MB across 28 JARs |

## Timing

- Desktop cold start (JIT available): **1.87 s** wall clock from `java` launch to
  the `PROBE_READY` line. Spring Boot self-reported `Started ProbeApplication in
  1.45 seconds`.

This is the **desktop baseline only**. It says nothing about the ohos Zero
interpreter, where no JIT exists. The Stage 2 gate remains open.

## Pinned Versions

| Component | Version |
| --- | --- |
| Spring Boot | 3.5.16 |
| Spring Framework | 6.2.19 |
| Embedded Tomcat | 10.1.55 |
| SLF4J | 2.0.18 |
| Logback | 1.5.34 |
| Micrometer | 1.15.12 |

Source of truth: `tools/spring_boot.lock.json`. All 28 artifacts were
cross-checked against Maven Central — SHA-256 where the repository publishes it
(9 artifacts), SHA-1 otherwise (28 artifacts). **0 mismatches.**

## Dependency Set (28 JARs, 17.46 MB)

```
spring-boot-starter-web, spring-boot-starter-tomcat, spring-boot-starter-json,
spring-boot-starter-logging, spring-boot-starter,
spring-boot, spring-boot-autoconfigure,
spring-core, spring-jcl, spring-beans, spring-context, spring-aop,
spring-expression, spring-web, spring-webmvc,
tomcat-embed-core, tomcat-embed-el, tomcat-embed-websocket,
jakarta.annotation-api, snakeyaml,
slf4j-api, logback-classic, logback-core, log4j-to-slf4j, log4j-api,
jul-to-slf4j, micrometer-commons, micrometer-observation
```

Jackson was excluded via the POM (`spring-boot-starter-json` remains only as a
marker JAR, 10 KB). If the probe or template needs JSON later, add it to the POM
and regenerate the lock file.

## Artifacts Produced

- `tools/spring_boot.lock.json` — pinned versions + SHA-256 (tracked)
- `tools/prepare_spring_boot.ps1` — idempotent download + verify (tracked)
- `assets/spring_boot/3.5.16/*.jar` — verified set (ignored by Git)
- `build/spring_boot_probe/` — scratch proof project (ignored by Git)

## Reproduce

```powershell
pwsh ./tools/prepare_spring_boot.ps1
cd build/spring_boot_probe
mvn -q -B dependency:build-classpath "-Dmdep.outputFile=classpath.txt" "-Dmdep.includeScope=runtime"
javac --release 17 -encoding UTF-8 -d out -classpath (Get-Content classpath.txt -Raw) src/probe/*.java
pwsh ./run_probe.ps1
```

## Gate 1 Decision

Set is 17.46 MB, HAP-viable (the JDK zip is already 47 MB). **No trimming
needed.** Proceed to Stage 2.
