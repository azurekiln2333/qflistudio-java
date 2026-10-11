# Design: Java tutorial/example rewrite

## Source of truth and generation

Hand-editing a 3.5 MB aggregate JSON for 200 records is unreviewable. Instead:

- Author the 100 topics in a **Dart content module** under
  `qfli_studio_core/tool/java_content/` (data only, no `dart:io` in the data
  file). Each topic is a record:
  `id, level, title, summary, concepts, explain, code, output, pitfalls,
  objective, prerequisites, examples(optional extra fixtures), tasks`.
- A generator `tool/generate_java_content.dart` emits:
  - `assets/content/tutorials.json` (Java entries replaced; other languages
    preserved byte-for-byte by targeted in-place replacement).
  - `assets/content/examples.json` (Java entries replaced; others preserved).
  - `assets/tutorials/java.json` (legacy per-language bundle) regenerated from
    the same module.
- A verifier `tool/verify_java_content.dart` compiles and runs every code sample
  with the real JDK and diffs stdout against `output`, writing a per-id report.

To avoid rewriting the other 1500 entries by hand, the generator will **load the
existing JSON, drop all `language == "java"` entries, and insert the newly
authored Java entries**, preserving everything else and the top-level metadata.

## Content plan (100 topics, ordered)

Stable ids `java-tutorial-001..100` and `java-example-001..100`; example N is
paired to tutorial N by `sourceLessonId`. Progression:

- 001-015 fundamentals: program structure, Hello World, variables, primitive
  types, operators, casting, String basics, conditionals, switch, loops, arrays,
  methods, recursion, varargs, enums.
- 016-030 OOP: classes/objects, constructors, encapsulation, inheritance,
  polymorphism, abstract classes, interfaces, `super`/`this`, static members,
  nested/inner classes, records, enums with behavior, equals/hashCode.
- 031-045 core library: String/StringBuilder, regex, wrappers/autoboxing,
  BigDecimal, dates (java.time), Optional, Collections (List/Set/Map), iterators,
  Comparable/Comparator, generics basics/bounds/wildcards, arrays utilities.
- 046-060 errors/IO: exceptions checked vs unchecked, try/catch/finally,
  try-with-resources, custom exceptions, files (java.nio), paths, reading/writing,
  serialization basics, charsets/UTF-8, streams of bytes.
- 061-075 functional/streams: lambdas, functional interfaces, method refs,
  built-in functional interfaces, streams map/filter/reduce, collectors,
  grouping, parallelism basics, CompletableFuture.
- 076-085 concurrency: threads, Runnable, synchronization, volatile, atomic,
  locks, executors, concurrent collections, deadlock avoidance.
- 086-100 practical/advanced: design patterns (singleton, factory, builder,
  strategy, observer, decorator), algorithms (sorting/searching, DFS/BFS,
  dynamic programming), data structures, immutability, records+sealed types,
  pattern matching, JSON-like parsing without deps, text-processing mini apps,
  a small MVC-ish console app, testing-ish assertions, performance basics.

Every example is a single `Main.java` (or `Main` + a helper class in the same
file, which javac handles) with deterministic stdout. Where input is needed, the
runner's `input.txt` path is used and the expected output documents it. No
network, no external files beyond `input.txt`.

## Line-break handling

Diagnosis target: code strings already contain real `\n`; the pages render via
`SelectableText`/`TextField`. Verify and, if needed, fix:
- `CodeSnippet` copy uses `_code` verbatim (keep).
- Editor import (`CodeImportService`) must write the code with real `\n`.
- Ensure no path re-encodes `\n` to a literal two-char sequence, and none strips
  newlines. Add a widget test that asserts the displayed code contains multiple
  lines and that copy/import payloads match the source with real newlines.

## Migration / version

- Add a content version marker (e.g. bump `updatedAt` and introduce a Java
  content `contentVersion`/`id` scheme). `ExampleCodeStore` persists user edits
  in `examples.json`; on load it merges user records over defaults by id. To drop
  obsolete generated records:
  - Change ids/definitions, and add a **migration** in `ExampleCodeStore` (or a
    small `ContentMigration`) that, on first load after the version bump,
    removes persisted custom records whose ids are in the known obsolete set
    (previous `java-example-*`/`java-tutorial-*` generated ids are reused by the
    new content, so the real risk is stale *user-saved* copies of the old code).
  - Introduce a `schemaVersion`/`contentVersion` bump and have the store drop
    custom entries whose `contentVersion` is older than current for built-in
    ids, while preserving user-created entries.
- Migration must be scoped: only tutorial/example built-in records and their
  cache. Verify with a test that a stale persisted record is dropped while an
  unrelated user project/other-language record survives.

## Boundaries

- Owned by this task: Java content module + generator/verifier,
  `assets/content/{tutorials,examples}.json` Java portions,
  `assets/tutorials/java.json`, the scoped migration/store change, focused tests,
  and records.
- Shared-core edits limited to `lib/content/` (migration/line-break if needed),
  `lib/services/example_code_store.dart`, `lib/widgets/code_snippet.dart`.
- Not touched: navigation, other languages, SQL/MySQL, native JDK.
