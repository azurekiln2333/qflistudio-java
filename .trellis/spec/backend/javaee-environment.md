# Offline Java EE web environments

## Scope

Apply this contract to the project decoder, dependency packs, web runner,
container launcher, environment tool and generated environment scaffolds.
Database runtime and SQL product code remain qflisql-owned.

`javaee8` provides the javax Servlet/JSP subset through embedded Tomcat9.
`spring-boot` provides the Boot3/Tomcat10 Jakarta stack. Neither profile claims
full Java EE/Jakarta EE platform certification. Never merge their container
API classpaths. Runtime dependency downloads are prohibited.

## Project configuration

`lib/java_web_project.dart` owns `JavaWebProject`. All layers import its
decoder. Do not add a second parser in a template or UI adapter.

```json
{
  "schemaVersion": 1,
  "profile": "spring-boot",
  "mainClass": "example.Application",
  "port": 8080,
  "contextPath": "/",
  "webRoot": "src/main/webapp",
  "database": false
}
```

`JavaWebProject.load(projectPath)` returns null for absent configuration and
throws `JavaWebProjectException` for invalid configuration. Only the two named
profiles are accepted. Validate ports, context paths and project-relative web
roots centrally. `databaseEnabled` defaults to false and rejects non-booleans.
No configuration file means ordinary console execution retains its behavior.

## Dependency packs

`lib/spring_boot_bundle.dart` owns `JavaEePacks` and the legacy
`SpringBootBundle` adapter. `materialiseProfile(profile, targetDirectory: ...,
includeDatabase: ...)` supplies verified real files. The hashed manifest is
required. A plain filename list cannot authorize a classpath.

The Spring lock is `tools/spring_boot.lock.json`. The legacy container lock is
`tools/javaee8.lock.json`. Preparation scripts reconstruct the pinned packs
during development. Verify byte counts and SHA-256 before accepting files.
Use core `OfflineDigest.sha256Bytes`. Do not implement another digest.

Compile-only API JARs do not belong on the runtime classpath. Metadata roles
drive capability reporting. File-name substrings cannot establish support.
False `databaseEnabled` excludes the entire JDBC/MyBatis/driver group. True
selects its complete closure. Never silently disable datasource auto-config
to hide missing database configuration.

A cached path must still refer to intact bytes. Keep cache identity bound to
profile, target, selection and pack content. Mobile callers use a writable
application/JDK directory rather than assuming `/tmp` exists. Keep namespaces
in separate materialization directories and retain original license notices.

## Deployment and lifecycle

`JavaProgramRunner` compiles web main sources with Java17 target semantics.
Exclude test/build/output sources. Copy resources into isolated deployment
output and retain user sources. Bundle dependencies supplement project JARs.
Detect mixed javax/jakarta Servlet archive entries before compilation.

`JavaeeContainerLauncher.plan` consumes a `JavaWebProject` and a verified
`JavaeeContainerPack`. The launcher returns source and arguments. It never
starts a process. The runner owns process creation, output, cancellation and
deployment cleanup. JavaEE8 deploys web resources, `WEB-INF/classes` and
`WEB-INF/lib` through `Tomcat.addWebapp`. Bare `addContext` does not supply
the required web.xml, Servlet and JSP initialization.

Bind only `127.0.0.1`. Normalize root context to the empty Tomcat context.
Create the connector before starting Tomcat. Refuse an unavailable application
context. Use a separate writable base/work directory for every launch.

Serialize starts per project. Stop the previous owned JVM before replacing
it. An occupied unrelated port fails explicitly. Use finite JVM heap limits.
Transfer deployment ownership only after a real process starts. Remove its
deployment only after the exact owned process is terminal. Preserve output
through EOF or the existing bounded post-exit drain.

A configured URL is configuration. An HTTP response establishes reachability.
Neither alone establishes ownership of the responding server. Bound connect,
headers and body under one timeout and disable redirects outside loopback.
Report failures and cleanup separately from successful responses.

## User flow and verification

The environment card appears directly in the Java tools section. Read actual
pack metadata and the central project decoder. Create a scaffold only after
an explicit action. Validate paths, reject link escapes and create files
exclusively. Roll back only files created by the current operation.

Tests cover configuration validation, main/test scoping, namespace isolation,
dependency selection/integrity/cache, non-overwriting scaffolds, UI navigation,
concurrent starts, port conflicts, failure cleanup and output tails.

`test/java_web_http_test.dart` is an opt-in host integration suite. Enable
`QFLI_JAVAEE_HTTP_TESTS=1` only in its dedicated host gate. It must use the real
product runner, real compiler/processes and real packaged dependencies. Verify
Boot JSON/form/resources plus Servlet/JSP/JSTL/static assets and Stop/restart.
Skipped tests cannot count as acceptance. Actual Java17 and installed OHOS
require separate runtime evidence. A host target17 compile is not such proof.

JDBC driver discovery does not establish database connectivity. Require the
SQL owner's real endpoint, authentication and lifecycle contract before
claiming a qflisql connection. Never invent credentials or substitute H2.

## Validation and error matrix

| Input or state | Required behavior |
| --- | --- |
| Missing configuration | Retain ordinary console execution |
| Unknown schema/profile or invalid port/context/web root | Return decoder error before compilation |
| Mixed javax/jakarta Servlet archive entries | Refuse the selected runtime |
| Missing hashed manifest or corrupt JAR | Report dependency unavailability |
| Cached JAR changed or deleted | Reverify and restore verified bytes or fail |
| Database disabled | Omit all database auto-configuration dependencies |
| Unrelated process owns the configured port | Refuse before process launch |
| An earlier start still owns the project | Wait or refuse without bypassing its ownership |
| Project path changes during inspection | Discard stale results and settle the operation's busy state |
| Stop or cleanup fails | Keep failure visible and retain a retry path |
| SQL endpoint/authentication missing | Keep connectivity unverified |

## Good, base and bad cases

Base: a project with no web configuration runs its ordinary Java entry.
Good: an opted-in Boot project compiles main sources, answers its nonce JSON
and UTF-8 form requests, then releases its owned port on Stop.
Good: a javaee8 project renders JSP/JSTL through Tomcat and loads its deployed
resources. Its source files remain byte-identical.
Bad: a responding unrelated listener must never establish owned readiness.
Bad: a retired second waiter must not unblock a third waiter while the first
start remains pending. Bad: a stale project report must not write to a newly
selected project.

## Wrong and correct

Wrong: return cached classpath strings without checking the files, report a
configured URL as readiness, or complete cancellation before owned pipes settle.
Correct: verify cached bytes, retain process ownership through Stop and output
settlement, and test actual nonce-bearing responses from the product runner.

Wrong: preparation resolves the newest compatible Maven metadata on every run.
Correct: normal preparation reconstructs exact lock entries. Verification
compares current bytes and metadata without repairing manifests or licenses.
