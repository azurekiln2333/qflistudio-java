# Java EE pack API — p3 and p6 integration note

Owner: p4. Source: `lib/spring_boot_bundle.dart`.
Locks: `tools/spring_boot.lock.json`, `tools/javaee8.lock.json`.
Recipe: `tools/prepare_javaee_packs.py`. Validator: `tools/validate_javaee_packs.py`.

Status: the API below is implemented in source. No SDK, JVM or device run was
performed. Every compile and runtime field stays `UNRUN` until a named host gate.

## 1. Import

```dart
import 'package:qfli_java/spring_boot_bundle.dart';
```

Both entries are in that one file. `JavaEePacks` is the real entry point.
`SpringBootBundle` remains as a compatibility adapter.

## 2. Frozen profile names

```dart
JavaEeProfiles.springBoot   // 'spring-boot'
JavaEeProfiles.javaee8      // 'javaee8'
JavaEeProfiles.all          // <String>['spring-boot', 'javaee8']
```

These are the only profile names. There is no `jakarta` or `javax` profile name.
A namespace is a property of a pack, not a profile. The web project module
re-exports the same two wire names as top-level constants in
`java_web_templates.dart` (lines 13 to 15): `javaWebProfileSpringBoot`,
`javaWebProfileJavaee8` and `javaWebProfiles`, which delegate to
`JavaWebProject.profileSpringBoot`, `JavaWebProject.profileJavaee8` and
`JavaWebProject.knownProfiles`. Pass `JavaEeProfiles.javaee8`, or
`javaWebProfileJavaee8`, and no mapping is needed. There is no `JavaWebProfile`
class and no `wireName` property, so do not write `JavaWebProfile.wireName`.

## 3. Materialise a classpath — the call p3 needs

```dart
static Future<List<String>> materialiseProfile(
  String profile, {
  String? targetDirectory,
  bool includeDatabase = false,
})
```

- Returns absolute JAR paths, deterministic order, ready for `-classpath`.
- Writes into `<targetDirectory>/<profile>/`. If `targetDirectory` is null a
  temporary directory is created. The per-profile subdirectory is what makes it
  impossible for a `javax.servlet` jar and a `jakarta.servlet` jar to share a
  classpath.
- `includeDatabase` **false** (the default) leaves the whole database group off
  the classpath. This is required: with HikariCP and MyBatis auto-configuration
  present and no datasource URL, a health-only Boot application fails at startup.
- `includeDatabase` **true** adds the group back. It has no effect on `javaee8`,
  which has no database group.
- `compile`-scope jars are never returned by this call. They belong on the
  `javac` classpath only, so the runtime keeps one copy of the Servlet classes.
- Every returned file has been verified against its manifest SHA-256. A missing,
  empty, wrong-length or wrong-hash file is rewritten from the asset first.
- Results are cached per `(profile, targetDirectory, includeDatabase)`.

p3 currently calls `SpringBootBundle.materialiseProfile(...)`. That forwarder
exists and compiles, and it calls the same implementation. New code should call
`JavaEePacks.materialiseProfile` instead, because a class named for Spring Boot
should not be the way to obtain a `javaee8` classpath.

## 4. Names for the compiler and for display

```dart
static Future<List<String>> jarNames(String profile, {JavaEeJarScope scope = JavaEeJarScope.all})
static Future<List<String>> runtimeJarNames(String profile, {bool includeDatabase = false})
static Future<List<String>> compileJarNames(String profile)
static Future<List<String>> plainNames(String profile)
static Future<String> identity(String profile)
```

- `jarNames` — the whole pack, selection independent. Use this for a capability
  or inventory display, and for p6's `bundleJars` argument.
- `runtimeJarNames` — exactly what `materialiseProfile` would return, as names.
- `compileJarNames` — `jakarta.servlet-api`, `javax.servlet-api`,
  `javax.servlet.jsp-api`.
- `plainNames` — the `manifest.json` name list, kept for the older contract.
- `identity` — SHA-256 over the sorted `name:hash` list. Content identity, not a
  path.

For p6: `inspectJavaWebEnvironment(..., bundleJars: await JavaEePacks.jarNames(profile))`
gives `boot3`, `jakartaServlet`, `jsp`, `jdbc` and `javaee8` from the real pack.

## 5. Capabilities — from roles, not from file names

```dart
static Future<JavaEePackCapabilities> capabilities(String profile)

class JavaEePackCapabilities {
  final bool web;          // role 'web'
  final bool json;         // role 'json'
  final bool servlet;      // role 'servlet'
  final bool jsp;          // role 'jsp'
  final bool jstl;         // role 'jstl'
  final bool jdbc;         // role 'jdbc'
  final bool persistence;  // role 'persistence'
  final List<String> roles;
  bool get hasDatabaseGroup => jdbc || persistence;
}
```

Every flag comes from a `role` recorded in the hashed manifest. No flag is
inferred from a file-name substring. Observed today:

| Pack | roles | web | json | servlet | jsp | jstl | jdbc | persistence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `spring-boot` | core, jdbc, json, logging, metrics, persistence, servlet, web | true | true | true | false | false | true | true |
| `javaee8` | jsp, jstl, servlet | false | false | true | true | true | false | false |

`javaee8` reports `web=false` and `json=false` because the pack is a container
only: it ships no Spring Framework, by design. The `jsp` flag is
true when any entry carries `role: 'jsp'` and false otherwise:
the code reads `roles.contains('jsp')` and does not itself check for a specific
file. The role is recorded per artifact in the manifest, and today four
`javaee8` artifacts carry it (`tomcat-embed-jasper`, `ecj`,
`javax.servlet.jsp-api` and the JSTL pair), so the flag is correct for the
current pack. Treat it as a claim about the recorded roles, not as a check the
materialisation performs. JSP in the `spring-boot` pack is deferred, so
`jsp=false` and `jstl=false` there are accurate and must not be presented as
support.

## 6. Errors

All pack failures throw `JavaEePackException` with a message that names the pack
and the remedy. Cases:

- unknown profile name — refused, never defaulted.
- `manifest.hashed.json` missing, malformed, empty, wrong `packId`, or an entry
  without a usable hash or byte count — refused, with **no** fallback to the
  plain name list. A name list proves nothing and would mark every file runtime,
  which silently switches the database group on.
- an asset whose bytes or hash disagree with the manifest.
- a materialised file that still disagrees after writing.

Handle it as "the pack is unavailable", not as a retryable transient error.

## 7. Package declarations

`pubspec.yaml` declares four asset directories:

```yaml
    - assets/spring_boot/3.5.16/
    - assets/spring_boot/3.5.16/licenses/
    - assets/javaee8/
    - assets/javaee8/licenses/
```

Flutter asset directory declarations are not recursive, which is why the licence
directory is declared separately and why licence documents are stored flat as
`licenses/<artifactId>__<entry>`.

Both pack directories are Git-ignored. The tracked recipe is the two lock files
plus `tools/prepare_javaee_packs.py`, which reconstructs both packs from the
locks, verifies every SHA-256 against the published `.sha1`, rewrites both
manifests from the lock, and restores the licence documents.

## 8. Contents

| Pack | Directory | Files | Default runtime | Database group | Compile-only |
| --- | --- | --- | --- | --- | --- |
| `spring-boot` | `assets/spring_boot/3.5.16` | 43 | 34 | 8 | 1 |
| `javaee8` | `assets/javaee8` | 9 | 7 | 0 | 2 |

`spring-boot`: Spring Boot 3.5.16, Spring Framework 6.2.19, Tomcat embed 10.1.55,
Jackson 2.21.4, MyBatis 3.5.19 with `mybatis-spring` 3.0.5 and the Boot 3 starter
and auto-configuration, HikariCP 6.3.3, Connector/J 9.7.0, logback 1.5.34,
slf4j 2.0.18, log4j 2.24.3, micrometer 1.15.12, snakeyaml 2.4.

`javaee8`: Tomcat embed 9.0.123 core, EL and Jasper, `tomcat-annotations-api`
9.0.123, ECJ 3.46.100, `javax.servlet-api` 4.0.1, `javax.servlet.jsp-api` 2.3.3,
JSTL 1.2.2 API and 1.2.5 implementation. No Spring Framework.

Roles in `javaee8`: `servlet` (core, EL, annotations API, Servlet API), `jsp`
(Jasper, ECJ, JSP API) and `jstl` (JSTL API and implementation).

## 9. What this does not provide

- No launcher. Starting a Tomcat 9 container, deployment descriptors, document
  base and request readiness are p5 scope under a separate contract.
- No database credentials, no connection, and no claim that Connector/J connects.
  Driver presence is not connectivity. That needs the SQL owner's endpoint and
  lifecycle contract.
- No full EE platform: no EAR, EJB, JTA or a Tomcat distribution.
- No JPA, Spring Data or Spring Security artifact, and no embedded database.
- No `javax` and `jakarta` mixing. A caller that concatenates the two packs
  produces an unsupported classpath, and the validator refuses it.

## 10. Asks

- **p3**: import `JavaEePacks`. Keep the `mainClass`, port, context path and web
  root decoding in `java_web_project.dart`. Mapping the decoded profile string to
  `materialiseProfile` is a direct pass-through. Add
  `includeDatabase: project.databaseEnabled` rather than deciding per caller. Pass
  a writable `targetDirectory` that lives under the installed JDK's writable temp
  area, because the pack copies the JARs before `javac` and `java` read them, and
  the app's asset directory is not writable on device.
- **p6**: pass `await JavaEePacks.jarNames(profile)` as `bundleJars`. Use
  `capabilities(profile)` for the environment card, and treat
  `JavaEePackException` as "pack unavailable".
- **p5**: the container launcher consumes `materialiseProfile('javaee8')` and
  `compileJarNames('javaee8')`. No pack change is needed for a Tomcat 9 launcher.

## 11. Verification state

- `tools/validate_javaee_packs.py` — 1294 checks, 0 failures, run on this source.
  It covers lock shape, lock to disk hashes, lock to manifest equality, plain
  manifest equality, namespace purity, both frozen profile names, the database
  group selection, the JSTL roles, the licence evidence, the licence digests, the
  recipe's source structure, and a filesystem drift fixture.
- `tools/validate_javaee_pack_controls.py` — 8 mutations, 8 caught, 0 missed.
  It reintroduces each defect in a scratch tree and asserts a control goes red,
  so the controls above are proven to bite rather than merely present.
- Every one of the 52 artifacts carries published-digest evidence: 24 verified
  against the repository's published SHA-256 and 28 against its published SHA-1.
- Every artifact carries packaged licence evidence, quoted from its own archive
  or its published POM, with a recorded digest: 76 documents for `spring-boot`,
  13 for `javaee8`, 89 in total. The JSTL API ships a real `LICENSE`. The JSTL
  implementation and `javax.servlet.jsp-api` ship only their packaged POM, which
  carries the licence block, so that POM is the stored notice.
- Base class major version is at most 61 in both packs, so a Java 17 runtime can
  load them. Three jars also ship multi-release overlays at major 65. A Java 17
  JVM never loads those, so they do not change the base requirement.
- `python tools/prepare_javaee_packs.py --packs all --verify-only` is read-only.
  Measured on a 95-file snapshot of both packs: 0 requests, 0.12 s, no file
  added, removed or changed. Drift is reported, never repaired.
- `python tools/prepare_javaee_packs.py --packs all` is idempotent on a complete
  pack: 0 requests, 0.21 s, nothing changed. It reconstructs exactly the lock and
  resolves no version.
- Source-only Dart tests are in `test/spring_boot_bundle_test.dart`. They cover
  cache deletion, same-length corruption, truncation and six malformed-manifest
  shapes. They are authored and **not run**. No SDK execution has happened.
- A real HTTP acceptance test — start the container, GET, POST, JSP render, then
  clean up the exact process — is not done. It needs a named host gate.

## 12. The preparation contract

| Command | Network | Writes | Resolves a version |
| --- | --- | --- | --- |
| `--packs all` | only a file the lock names and disk lacks | manifests, licences, digests | no |
| `--packs all --verify-only` | none | nothing | no |
| `--packs all --refresh` | metadata and candidate jars | a `*.refresh.json` candidate only | yes, explicitly |

`--verify-only` cannot be combined with `--refresh` or `--verify-digests`, because
neither can be honoured without network or a lock write. `--report` has no
default, so a verify run writes a report only when a path is given.
