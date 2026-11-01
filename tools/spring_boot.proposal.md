# Java EE offline packs — acquisition record

Supersedes the earlier proposal in this file. The acquisition happened under a
bounded grant: plain HTTP only, no SDK, no JVM, no Maven, no Gradle.

Owner: p4. Recipe: `tools/prepare_javaee_packs.py`. Validator:
`tools/validate_javaee_packs.py`. API note: `tools/javaee_pack_api.md`.

## 1. Result

| | `spring-boot` | `javaee8` |
| --- | --- | --- |
| Profile name | `spring-boot` | `javaee8` |
| Servlet namespace | `jakarta.servlet` | `javax.servlet` |
| Directory | `assets/spring_boot/3.5.16` | `assets/javaee8` |
| Files | 43 | 9 |
| Bytes | 26,701,686 (25.46 MiB) | 11,958,520 (11.40 MiB) |
| Default runtime jars | 34 | 7 |
| Database group | 8 | 0 |
| Compile-only jars | 1 | 2 |
| Licence documents | 76 | 13 |

89 documents total across both packs.
| Published digest evidence | 43 of 43 | 9 of 9 |
| Highest base class major | 61 (Java 17) | 61 (Java 17) |

Joint size: 36.86 MiB. Both packs are Git-ignored. Only the recipes are tracked.

## 2. Versions, and where each came from

No version was invented. Sources:

- `bom` — read from `spring-boot-dependencies-3.5.16.pom` in the local Maven
  cache, 97,350 bytes, SHA-256
  `b99b1870802b9a652221c99c491678f37773a8c0ad14e80bd6b275ae9201638a`, and from
  `jackson-bom-2.21.4.pom`.
- `metadata` — resolved from the coordinate's own `maven-metadata.xml`, which is
  the only offline source for Tomcat 9 and ECJ.
- `pom` — resolved from the MyBatis starter's parent POM chain.

| Artifact | Version | Source |
| --- | --- | --- |
| Spring Boot | 3.5.16 | pre-existing, verified |
| Spring Framework (all modules) | 6.2.19 | `bom` |
| Tomcat embed (Jakarta) | 10.1.55 | `bom` |
| `jakarta.servlet-api` | 6.0.0 | `bom` |
| Jackson | 2.21.4, annotations 2.21 | `jackson-bom` |
| HikariCP | 6.3.3 | `bom` |
| `mysql-connector-j` | 9.7.0 | `bom` |
| `mybatis` | 3.5.19 | `pom` |
| `mybatis-spring` | 3.0.5 | `pom` |
| `mybatis-spring-boot-starter` | 3.0.5 | `metadata` |
| `mybatis-spring-boot-autoconfigure` | 3.0.5 | `metadata` |
| Tomcat embed (javax) | 9.0.123 | `metadata`, highest stable 9.0.x |
| `ecj` | 3.46.100 | `metadata`, highest stable 3.x |
| `javax.servlet-api` | 4.0.1 | fixed, last javax release |
| `javax.servlet.jsp-api` | 2.3.3 | fixed |
| `javax.servlet.jsp.jstl-api` | 1.2.2 | `metadata` |
| `javax.servlet.jsp.jstl` | 1.2.5 | `metadata` |

Two corrections the acquisition forced, both worth recording because a guess
would have shipped a wrong pin:

1. My first draft guessed Jackson 2.19. The BOM says 2.21.4.
2. `javax.servlet:jstl:1.2` does not exist, and neither does
   `javax.servlet.jsp.jstl:…:1.2`. The published coordinates are
   `javax.servlet.jsp.jstl:javax.servlet.jsp.jstl-api:1.2.2` and
   `org.glassfish.web:javax.servlet.jsp.jstl:1.2.5`. The first attempt returned
   HTTP 404 for both, which is why the coordinates were probed rather than
   assumed.

## 3. What the `javaee8` pack contains, and what it does not

Contents: `tomcat-embed-core`, `tomcat-embed-el`, `tomcat-embed-jasper`,
`tomcat-annotations-api` (all 9.0.123), `ecj` 3.46.100, `javax.servlet-api`
4.0.1, `javax.servlet.jsp-api` 2.3.3, JSTL API 1.2.2 and JSTL implementation
1.2.5.

It contains **no Spring Framework**. Java EE 8 here is a container and a tag
library, not a second application framework. That also keeps the pack small: a
Spring 5 web stack would roughly have doubled it and pinned an unsupported
branch.

Roles: `servlet` (core, EL, annotations API, Servlet API), `jsp` (Jasper, ECJ,
JSP API), `jstl` (JSTL API and implementation). JSP is claimed only because the
engine, the compiler and the tag library are all present.

Not provided: a launcher, deployment descriptors, a document base, or any claim
that a JSP has rendered. Those stay open.

## 4. Database group, and why the default excludes it

The `spring-boot` pack carries eight database jars: `spring-jdbc`, `spring-tx`,
HikariCP, `mybatis`, `mybatis-spring`, `mybatis-spring-boot-starter`,
`mybatis-spring-boot-autoconfigure`, and `mysql-connector-j`.

`materialiseProfile(..., includeDatabase: false)`, the default, leaves all eight
off the classpath. This is a correctness requirement, not a size optimisation:
with MyBatis auto-configuration and a pooled DataSource present and no datasource
URL, a health-only Spring Boot application fails at startup. `includeDatabase:
true` adds the closure back. Nothing is excluded at run time. The classpath
itself carries the choice, so no `spring.autoconfigure.exclude` is needed.

`javaee8` has no database group, so the flag is a no-op there.

The driver is for qflisql. Java bundles it and invents no credentials. Driver
presence is not a connection, and no connectivity claim is made.

Not present, by rule: H2, HSQLDB, Derby, SQLite, Hibernate, `jakarta.persistence`,
Spring Data, Spring Security, and any full Tomcat distribution. The lock records
each forbidden pattern with its reason.

## 5. Licence evidence

Every one of the 52 artifacts stores real packaged evidence, quoted from its own
archive or its published POM. No legal conclusion is drawn anywhere.

- 43 artifacts ship a standalone licence or notice text, and it is copied out.
- 9 ship no standalone text. Their packaged `META-INF/maven/**/pom.xml` is
  stored instead, because it carries the licence block: logback classic and
  core, HikariCP, `jakarta.servlet-api`, both MyBatis starter jars, snakeyaml,
  `javax.servlet.jsp-api` and `javax.servlet.jsp.jstl`. The last two declare
  "CDDL + GPLv2 with classpath exception" from Oracle Corporation.
- 89 documents are stored in total.

The one licence that differs from Apache-2.0 in a way worth quoting is
Connector/J 9.7.0. Its own `LICENSE` entry (82,896 characters, stored beside the
pack) states: "This software is released under version 2 of the GNU General
Public License (GPLv2) ... with the following additional permissions" and "this
Connector is also subject to the Universal FOSS Exception, version 1.0, a copy of
which is reproduced below". Copyright line in the same file: "Copyright (c) 2017,
2026, Oracle and/or its affiliates." That is the text, not an interpretation.

## 6. Integrity evidence

- 52 of 52 artifacts were cross-checked against the repository's own published
  digest: 24 against the published SHA-256 and 28 against the published SHA-1.
  The lock records which digest, per artifact, with a timestamp.
- `tools/validate_javaee_packs.py` — 1252 checks, 0 failures. It proves lock
  shape, lock to disk hashes, lock to manifest equality, plain manifest
  equality, namespace purity, frozen profile names, database group selection,
  JSTL roles, licence evidence and class major compatibility.
- Class majors: the highest base class major is 61 in both packs, so a Java 17
  runtime can load them. Three jars also ship `META-INF/versions` overlays at
  major 65 (Jackson core, logback core, Spring core). A Java 17 JVM never loads
  those, so they do not raise the requirement. The validator reports them
  separately rather than folding them into the base number.

What this does not prove: that the runtime works. Compiling, starting a
container, serving a request and rendering a JSP need a named host gate. Every
such field stays `UNRUN`.

## 7. Reconstructing a pack

Both asset directories are Git-ignored, so the tracked material is the complete
recipe:

```
pwsh ./tools/prepare_spring_boot.ps1 -Packs all
# or directly
python tools/prepare_javaee_packs.py --packs all
python tools/validate_javaee_packs.py
```

The lock is the only source of truth. Normal preparation reconstructs exactly the
frozen artifacts and resolves no version, so two runs a year apart produce the
same bytes. A file is fetched only when the lock names it and disk does not
already hold matching bytes.

| Command | Network | Writes | Resolves a version |
| --- | --- | --- | --- |
| `--packs all` | only a file the lock names and disk lacks | manifests, licences, digests | no |
| `--packs all --verify-only` | none | nothing | no |
| `--packs all --refresh` | metadata and candidate jars | a `*.refresh.json` candidate only | yes, explicitly |

```
pwsh ./tools/prepare_spring_boot.ps1 -Packs all
# or directly
python tools/prepare_javaee_packs.py --packs all
python tools/prepare_javaee_packs.py --packs all --verify-only
python tools/validate_javaee_packs.py
python tools/validate_javaee_pack_controls.py
```

`--verify-only` is read-only. It fetches nothing, rewrites no manifest, licence or
lock, and reports drift instead of repairing it. `--report` has no default, so a
verify run writes a report only when a path is given. `--refresh` is the only
operation that reads `maven-metadata.xml` or walks a parent POM. It writes a
candidate lock for review and never touches the live lock.

A measured re-run on a complete pack performs no downloads and changes no file:
python tools/prepare_javaee_packs.py --packs all --budget 40, then
`--verify-only`.

## 8. Defects found while doing this, and fixed

1. `manifest.hashed.json` initially listed only the newly acquired files, so the
   bundle would have produced a classpath with no Spring Boot in it. Manifests
   are now derived from the lock.
2. Four lock entries had a truncated version (`spring-boot` plus
   `autoconfigure-3.5.16`) because `spring-boot` is a prefix of
   `spring-boot-autoconfigure`. Coordinates are now derived from `mavenPath`.
3. The bundle's hand-written SHA-256 rotated the wrong way, so every digest was
   wrong. It is now a thin wrapper over the shared core `OfflineDigest`.
4. `assets/javaee8` was not Git-ignored, so 11.4 MiB of JARs would have been
   committed.
5. The hashed manifest was optional, so a pack could fall back to a hashless name
   list and silently enable the database group. It now fails closed.
6. Normal preparation used to resolve versions from `maven-metadata.xml` and from
   the MyBatis starter's live parent POM, ignoring the frozen locks, then wrote
   newer jars beside the frozen ones and polluted the pack directory. The normal
   path is now lock-first and resolves nothing. Mutable resolution is confined to
   the explicit `--refresh` operation, which writes a candidate lock.
7. `--verify-only` used to rewrite both manifests, recreate licence files and
   fetch digest URLs, so it silently repaired the drift it exists to report. It
   is now read-only, with a recorded licence digest per file so licence drift is
   detectable at all.
8. The Dart materialisation cache returned cached paths without revalidating, so
   a deleted or corrupted jar kept being served. Every cache hit now rechecks the
   recorded length and SHA-256, and a stale entry is dropped and rebuilt.

## 9. Open items

1. `pubspec.yaml` declares all four asset directories, including
   `assets/javaee8/` and both `licenses/` directories. Declarations are not
   recursive, which is why the licence directories are named separately. The
   `javaee8` pack holds 9 JARs, both manifests and 13 licence documents.
2. p3 must pass a writable `targetDirectory` inside the mobile JDK temp area.
3. p5 owns the Tomcat 9 launcher. The pack is dependency assets only.
4. The HTTP acceptance test and the JSP render test need a named host gate. The
   Dart cache and malformed-manifest tests are authored and not run.