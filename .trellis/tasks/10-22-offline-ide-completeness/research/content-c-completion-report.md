# Completion report — Java content batch C (ids 221..280)

Owner: content author C. Umbrella task:
`.trellis/tasks/10-22-offline-ide-completeness` (R3 content expansion).
Date: 2026-10-22. Status: **delivered and verified (host scope)**; device scope
remains open, see *Open gates*.

## Delivered

| Deliverable | Location | Evidence |
| --- | --- | --- |
| 60 new Java 17 topics/tutorial pairs, ids 221..280 | `qfli_studio_core/tool/java_content/java_topics_language.dart` (new, ~4,220 lines / 157,670 bytes, 60 `JavaTopic(` entries) | real JDK 17 run below |
| Durable research + topic map + integration notes | `.trellis/tasks/10-22-offline-ide-completeness/research/content-c.md` | — |
| Machine-readable verification evidence | `research/content-c-verification.json` | 60 `status: ok` records, class major 61.0 |
| Real JDK 17 sweep (raw TSV) | `research/content-c-jdk17-results.tsv` | 60 `OK`, `javac 17.0.20.1`, `java 17.0.20.1` |
| Scratch verifier (not a product file) | `research/verify_language_topics.dart` | exit code 0 |
| Real JDK 17 runner (not a product file) | `research/run_j17.sh` | 60/60 OK |
| Warning sweep (not a product file) | `research/warn_check.dart` | 2 intentional `-Xlint:all` warnings |

Exported symbol: `const List<JavaTopic> javaLanguageTopics`. Module imports only
`java_topic.dart`, contains no `dart:io` and no `$` interpolation hazards, so it
can be imported by the aggregator as data.

## What the 60 topics cover

Grouped as contracted: object contracts (221..228), generics (229..236),
reflection (237..242), annotations (243..248), records + sealed types
(249..254), design patterns (255..270, 16 patterns incl. template method,
decorator, adapter, command+undo, state, visitor, chain of responsibility,
prototype, flyweight, virtual proxy, composite, bridge, iterator, null object,
reflection DI container, specification), and algorithms (271..280: quicksort,
mergesort, heap Top-K, binary-search bounds, linked-list reverse/cycle,
LRU cache, union-find, Dijkstra, backtracking, edit distance + LIS).

Each topic carries a complete multi-line `Main.java`, byte-exact deterministic
stdout, Chinese summary/objective/explain/concepts/pitfalls and one concrete
exercise with prompt/hint/answer derived from that program's own data.

No duplication: ids, titles and whitespace-normalised code bodies were checked
against the original 100 topics (`java_topics.dart`) — **0 title, 0 id and 0
code-body overlaps**, and all 60 are `advanced`, so no basic lesson
(variables, loops, arrays, conditions, first class) is re-taught.

## Verification performed

Source-list confirmation printed by the checker:

```
topics=60 runPassed=60 runFailed=0
baseline=100 titleOverlap=0 idOverlap=0 codeOverlap=0
ids=221..280 uniqueIds=60 uniqueTitles=60 uniqueBodies=60
```

### Pass 1 — real JDK 17 (primary evidence, WSL `qfli-java-build`)

```
dart run .trellis/tasks/10-22-offline-ide-completeness/research/verify_language_topics.dart \
  --emit .trellis/tasks/10-22-offline-ide-completeness/research/j17-emit
wsl -d qfli-java-build bash <repo>/.trellis/tasks/10-22-offline-ide-completeness/research/run_j17.sh \
  /mnt/d/MyNewProjects/qfli_java/.trellis/tasks/10-22-offline-ide-completeness/research/j17-emit
```

Toolchain: `/usr/lib/jvm/java-17-openjdk-amd64`, `javac 17.0.20.1`,
`openjdk version "17.0.20.1"` — the same 17.0.20 family as the OpenJDK 17.0.20
Zero JVM bundled in the OHOS app.

Result (`content-c-jdk17-results.tsv`): **60 topics, 60 `OK`, 0 failures**,
`classmajor=61` for every topic, and every stdout byte-identical to the
authored `output`.

### Pass 2 — host JDK 24 with `--release 17` (cross-check)

```
dart run .trellis/tasks/10-22-offline-ide-completeness/research/verify_language_topics.dart
```

Result: `topics=60 runPassed=60 runFailed=0`, zero authoring-rule violations,
exit code 0, `Main.class major.minor = 61.0`.

The verifier enforces, per topic:

1. ids are exactly 221..280 with no gap, duplicate, or collision with ids 1..100;
2. unique title and unique code body, both also distinct from the original 100;
3. non-empty summary/objective/explain/code/output/concepts/pitfalls/tasks;
4. code shape: ≥6 lines, `class Main` line, `static void main`, 8-space indented
   statements, no tabs, no TODO/FIXME/placeholder/省略 markers;
5. `. / javac -encoding UTF-8` compile of the authored source (on JDK 24 this
   is invoked with `--release 17`);
6. `. / java -Dfile.encoding=UTF-8` run with exit code 0 and stdout exactly
   equal to the authored `output` (after CRLF normalisation and trailing-LF trim,
   the same normalisation the product verifier uses).

Compile/run toolchains: (a) real JDK 17.0.20.1 in WSL `qfli-java-build`, plain
`javac`/`java` 17, class major 61; (b) host `jdk-24` javac 24.0.2 with
`--release 17`, class major 61, run on JDK 24. Both passes agree on 60/60.

## Deliberate non-actions (per instruction)

- Did **not** modify `java_topics.dart` (aggregator), `tool/generate_java_content.dart`,
  `tool/verify_java_content.dart`, `tool/java_content/outline.dart`, any asset
  (`assets/content/*.json`, `assets/tutorials/java.json`), or any test.
- Did **not** edit other authors' modules, other languages' payloads, or the
  shared core editor APIs.
- Did **not** commit and did **not** spawn sub-agents.
- Concurrent sibling work in both repos (`lib/editor/file_explorer.dart`,
  `lib/java_runner.dart`, `lib/java_tools_page.dart`,
  `lib/content/java_catalog_audit.dart`, other task dirs) was left untouched;
  `git status` confirms my only product change is the new content module.

## Open gates (explicitly not claimed)

1. **Device/OHOS execution**: the sources are now proven against a real JDK
   17.0.20.1 runtime (same 17.0.20 family as the bundled OpenJDK 17.0.20 Zero),
   but they have not been executed **on an OHOS target**: `hdc list targets`
   reports Empty in the current research. On-device execution remains part of
   the product/device gate and is not claimed here.
2. **Catalogue emission and parity**: the 60 topics are authored but not yet
   emitted into the aggregate/legacy assets, because that requires the
   aggregator import plus the generator cap (`>100` throws today) and the tests
   that hard-code 100, all of which are outside this author's boundary and are
   listed as hand-off steps in `content-c.md`.
3. Two `-Xlint:all` warnings remain by design (id 221 intentional counter-example,
   id 276 inherits `Serializable` from `LinkedHashMap`); neither is an error and
   both are explained in the research note.

## Hand-off summary for the Java integration owner

Import `java_topics_language.dart`, append `...javaLanguageTopics` to
`javaTopics`, raise the generator cap and the hard-coded 100 counts in
`test/java_content_test.dart`, regenerate serially with the other owners, then
run `dart run tool/verify_java_content.dart <jdk17home>` for emitted-payload
parity and real on-device execution through the in-app harness.
