# Java EE environment integration contract

Status: active implementation, 2026-10-26. Requirement R15 extends the existing
umbrella. Every previous incomplete requirement remains open.

## User intent

Complete the environment that runs Java EE web projects beyond the JDK.
Do not implement the user's CRUD homework or replace qflisql with H2.
Database runtime, data and SQL product files remain SQL-owned.

## Ownership

All four existing Herdr Pi in workspace w28 accepted source assignments.

| Owner | Exclusive source scope |
| --- | --- |
| p3 | java_runner.dart, new java_web_project.dart, focused runner/config tests |
| p4 | spring_boot_bundle.dart, offline dependency locks/preparation/assets, bundle tests |
| p5 | SQL read-only contract research, proposed Java connection model/tests after review |
| p6 | java_web_environment_page.dart, java_web_templates.dart, java_tools_page.dart and their tests |
| root | PRD/design/implementation records, contract integration, verification and scoped publication |

No shared core, SQL or sibling writes. Workers do not stage, commit or push.
Workers preserve pending debugger/analyzer/process ownership edits. Root owns
selective integration. lib/main.dart edits require coordination because it
already contains pending debugger/analyzer wiring.

## Typed project boundary

p3 owns `JavaWebProject` in `lib/java_web_project.dart`. All consumers import
that decoder. File name: `.qfli-java-web.json`. Version one keys:

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

Public entry: `static Future<JavaWebProject?> load(String projectPath)`.
Absent config returns null. Invalid or unsupported config fails explicitly.
Expose immutable fields, `configFileName` and `toJson()`. Bound paths to the
project and reject ambiguous namespaces. `mainClass` is optional for the
Boot entry source and must be a valid class name when present. Port is a real
usable TCP port. Context path is root or a normalized slash-prefixed path.

Web mode compiles main sources, excludes Maven/Gradle test/output trees, and
deploys `src/main/resources` without altering original files. Classpath
contains the selected profile's offline dependency pack and project JARs.
Container-owned API dependencies must not mix javax and jakarta namespaces.

Boot profile uses the existing Boot3/Tomcat10 Jakarta line. A separate
`javaee8` Servlet/JSP profile is required before claiming legacy javax support.
Its exact deployment/launcher API is a follow-up contract, not an inferred
capability of the Boot pack. JSP/JSTL support requires actual packaged parser,
compiler, tag libraries and real rendered-response acceptance.

`database` is an optional boolean, default false. `databaseEnabled` is its
typed projection. False selects web/JSON dependencies. True also selects the
JDBC, MyBatis and MySQL dependency closure. Keep the full pack installed, but
do not activate DataSource auto-configuration for every web project. Do not
silently inject auto-configuration exclusions or invent database credentials.
The environment tool exposes this choice. An actual database still requires
the SQL owner's endpoint/auth/lifecycle contract.

Bundle interface: `materialiseProfile(String profile,
{String? targetDirectory, bool includeDatabase = false})`. The existing
`materialise()` API remains a web/JSON selection for compatibility. P4 owns
metadata and the exact return shape and publishes it to p3/p6 before freeze.

## Runtime and user flow

Retain existing live stdout/stderr, exit code and Stop ownership. A displayed
URL is a configured address until an actual response proves readiness.
Process creation or a log line alone must not imply HTTP success. Repeated
Run must stop or reject an existing owned server before starting another.
Keep deployment output until its exact process is terminal. Stop/restart,
startup failures and port collisions need bounded, truthful results.

Add a direct Java EE environment card. Inspect actual local assets/config.
Create scaffolds only after a user action and never overwrite an existing
project. A generic health/form environment scaffold is permitted. Homework
tables, CRUD implementation and fabricated database credentials are excluded.
Keep native `openUrl` offline restrictions unless an explicitly scoped local
preview path is implemented and checked.

## Verification and publication

- Source tests: config errors, namespace isolation, source/resource scopes,
  duplicate starts, failure/cancel cleanup, extraction integrity/cache, UI
  reachability and non-overwriting scaffold creation.
- Actual host: compile/run with the product runner, GET and form POST,
  JSON mapping, resource loading, JSP rendering where supported, port clash,
  Stop, restart and exact process cleanup.
- JDBC: driver discovery is separate from an actual qflisql connection.
  Require owner-published endpoint/auth/lifecycle before connectivity claims.
- OHOS: installed current-source HTTP/lifecycle plus target/runtime evidence.
  Host tests, historical proof and unsigned packaging cannot close this gate.
- A fresh named host grant is required before SDK/JVM/Flutter execution.
  Old grants are consumed. Source-only changes reserve no host/device slot.
- Run Chinese mechanical lint first, then semantic review. Complete scoped
  quality gates, conventional commits and non-force pushes to all remotes.

## Official references checked

- Spring Boot3.5 system requirements: Java17+, Tomcat10.1 Servlet6.
- MyBatis Boot starter3.0 compatibility: Boot3.2-3.5 and Java17+.
- Tomcat migration9 to10: javax to jakarta is a binary/source API boundary.

These references establish compatibility requirements, not local runtime
acceptance or a claim that the bundled environment is complete.
