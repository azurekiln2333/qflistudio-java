# Design and change boundary

## Ownership

All standalone products remain in scope, jointly delivered by their current roots. C root is sole common-core UI writer (see global qfli-core-release-sync and D:/MyNewProjects/qfli-core-release-sync.md). Java changes only its own repository and exclusive Java content authoring/generation/test paths in core. Never modify another language's payload or core editor APIs independently.

## Content

Retain existing IDs001-100; add180 distinct useful Java17 tutorial/example pairs101-280. Author in exclusive modules, each program with exact deterministic output, explanatory text, concepts, pitfalls and practice. Update generator cap/integrity tests. Serialize aggregate JSON writes with other owners. Enumerate final emitted payloads; fail missing/extra/mismatched records. Existing verification currently compiles emitted examples, not all independent tutorial payloads; strengthen inventory/parity before claiming complete coverage.

Baseline and final host runs use real JDK17 where available, --release17, UTF-8, bounded processes, deterministic locale/timezone and exact stdout. An exhaustive in-app harness reads final bundled payloads and uses JavaProgramRunner/native OHOS bridge; records runtime/ABI, source identities, exit/stdout/stderr and every assertion. No hdc target currently; host or package success cannot close device gate. Restore normal app after probes.

## Diagnostics

Consume C owner's optional typed analyzer API once published. Compile an isolated snapshot with all dirty buffers overlaid and original-path mapping, preserving sources and local lib/libs JARs. Use -proc:none, bounded processes/output and cancellation; never run source or mutate project buffers. Map actual javac locations (including Unicode) and warnings/errors. Expose toolchain failures separately. Core owns debounce, version checks, squiggles/Problems/navigation.

## Tools and debugging

Existing four cards remain direct in tools tab. Add meaningful offline tools such as JVM descriptors, stack traces, class/JAR manifest inspection and dependency analysis; reuse shipped JDK modules/bridge for real toolchain actions. Research local JDWP/JDI and implement only real tested functionality; packaged modules alone prove nothing about breakpoints. No placeholder menus, network tooling or package downloads. Core owns shared panels; Java supplies compiler/runtime facts.

## Compatibility, checks and rollback

Preserve stable IDs, constructors, offline gates, local project/JAR resolution and native bridge. Focused tests then full Java analyze/test, all final content and core-consumer checks after common batches. Stage only owned paths; conventional commits per verified batch and non-force remote pushes. Roll back only owned failing batches without reverting others.

## October 26 Java EE environment extension

R15 adds an environment, not the user's announcement/user CRUD homework.
qflisql remains the database owner. A packaged JDBC driver alone does not
prove a reachable database or cross-app authentication. Keep connection
availability explicit until the SQL owner publishes the actual contract.

Current ordinary Java execution can keep a JVM alive and stop it. Its missing
web behavior is dependency selection, main/test scoping, resource deployment,
container entry dispatch, readiness and local preview metadata. The existing
Spring bundle is not connected to that runner and lacks JSON/JDBC/JSP packs.

Smallest product boundary: Java-owned runner, a single typed project decoder,
pinned bundled dependencies, Java-owned environment tools and fresh scaffolds.
No common-core/editor/SQL/native changes are implied. Ordinary console Java
must retain its existing source collection and cancellation behavior. An
explicit project config opts into web source/dependency/deployment semantics.
Local services bind loopback. No runtime dependency downloads occur.

The detailed ownership, configuration and acceptance contract lives in
research/javaee-environment-contract-20261026.md. A Tomcat Servlet/JSP profile
must not be described as full Java EE/Jakarta EE platform certification.
