# Rewrite Java tutorials and examples: 100 real progressive lessons

## Goal

Replace every bundled Java tutorial and example record with 100 distinct,
progressive, real Java lessons. Each topic has a full runnable Java example,
verified by real `javac`/`java` against a supported release. Add a content
version + cache migration so existing installs stop showing the old generated
records. Fix line-break handling on both pages (display, copy, import).

## Background

- Two offline pages consume Java content:
  - "教程" -> `LocalTutorialsTab` (`lib/pages/local_content_pages.dart`) ->
    `LocalContentAdapter.loadTutorial` -> `AssetContentRepository` ->
    `assets/content/tutorials.json`.
  - "示例代码" -> `ExampleCodeTab` -> `LocalContentAdapter.loadExamples` ->
    `assets/content/examples.json`, plus an editable overlay in
    `ExampleCodeStore` (persisted as `examples.json` under the app storage dir).
- There is also a legacy per-language bundle `assets/tutorials/java.json`
  loaded by `TutorialService` (used by tests/other surfaces).
- Current Java content is machine-generated padding: 100 tutorial entries and
  100 example entries whose code is the *same* weighted-sum program with
  different constants (`java-tutorial-001` vs `java-tutorial-050` identical
  apart from literals). It does not teach distinct concepts.
- The runner (`qfli_java/lib/java_runner.dart`) compiles **all** `.java` files
  under the project with `javac -encoding UTF-8`, derives the main class from
  the entry file's package + basename, runs with UTF-8 stdout/stderr, and feeds
  `input.txt` on stdin. Multiple sources and packages are supported. Version
  probe accepts any modern OpenJDK.

## Requirements

- R1 Count and identity: exactly 100 tutorial entries and 100 example entries,
  paired one-to-one by stable id, from fundamentals to advanced practical Java.
  Unique ids and titles. No title-only, clone, TODO, ellipsis, pseudocode, or
  repeated trivial printing. Exactly one introductory Hello World.
- R2 Real runnable examples: each entry's `code` is complete, formatted Java
  that compiles and runs on the supported release, with deterministic output
  asserted against `expectedOutput`. Standard library only; no external
  services/files/keys. Multi-file/package examples are allowed only with real
  fixtures created and cleaned up by the runner or content.
- R3 Lesson quality: each lesson has objective, prerequisites where useful,
  accurate Chinese explanation, complete code, expected output/observable
  behavior, and important pitfalls.
- R4 Replace outdated content: remove all old built-in Java tutorial/example
  data feeding these two pages, including generated seeds and stale fallbacks.
  Add a scoped content version/cache migration so existing installs drop
  obsolete tutorial/example records. Deletion is limited to built-in
  tutorial/example data and their caches; user projects, sources, account data
  and unrelated preferences are preserved.
- R5 Line breaks: display, copy and editor import preserve real line breaks and
  indentation and produce valid Java source, on BOTH pages. Do not corrupt
  legitimate literal `\n` sequences inside Java string literals.
- R6 Scope: Java content + necessary Java integration + focused tests and
  content-verification tooling. Shared `qfli_studio_core` changes only where
  needed for these pages. No SQL/other-language content, no navigation changes.

## Acceptance Criteria

- [ ] AC1 Exactly 100 tutorial + 100 example entries, stable 1:1 pairing,
  unique ids/titles, no placeholders/near-duplicates; a beginner->advanced
  progression is evident across the ordered set.
- [ ] AC2 All 100 example codes (and all 100 lesson codes) compile and run with
  real `javac`/`java`; each produces the declared expected output; a per-id
  result report is captured.
- [ ] AC3 Each lesson has objective, explanation, complete code, expected output
  and pitfalls, in useful Chinese; concepts are distinct per topic.
- [ ] AC4 Old generated records are replaced and a migration/version makes
  existing installs drop obsolete tutorial/example records; unrelated user data
  is untouched (verified by a migration test).
- [ ] AC5 Display/copy/import on both pages preserves real line breaks and
  indentation, with automated coverage; literal `\n` in Java strings is intact.
- [ ] AC6 Focused analysis and tests pass; representative beginner/intermediate/
  advanced tutorial + example pages render at phone width with real content and
  are inspected.

## Out of scope

- Non-Java languages, SQL, MySQL, native JDK work, main navigation changes.

## Notes

- Content is authored in a reviewed Dart source of truth and emitted to the two
  JSON assets so the pipeline is reproducible and the 100 examples can be
  compiled as part of verification.
