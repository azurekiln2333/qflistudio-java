# Java tools and catalog verification review (2026-10-22)

Scope: Java developer tool logic/pages and new tests; Java in-app catalog audit;
core `lib/content/java_catalog_audit.dart` and `tool/verify_java_content.dart`.
No runner, diagnostics, debugger, common UI, authoring/generator or asset edits.

## Fixed findings

- `lib/java_developer_tools.dart`: reject void fields/parameters, invalid JVM
  internal names, malformed Java type names, arrays beyond 255 dimensions and
  method signatures exceeding 255 parameter slots. Void remains valid for a
  method return. Regressions cover both descriptor parsing and writing.
- Class inspection now decodes actual modified UTF-8 code units rather than
  replacing NUL/surrogates with standard UTF-8 replacement text. Fixed
  `CONSTANT_Dynamic` four-byte width, long/double second-slot bounds, invalid
  UTF8/class references, trailing bytes, method bridge/varargs flag names and
  duplicate interface declaration keywords.
- Stack trace inspection preserves suppression flags on the correct throwable,
  wrapped messages, Unicode class/method names and versioned module/loader
  prefixes. Orphan frames/count markers remain unparsed evidence.
- ZIP facade now reuses existing archive package central-record parsing,
  bounded DEFLATE output and CRC implementation. Added direct dependency on
  the already resolved archive4.3.0 via `archive:^4.0.7`; offline pub get changed
  only lockfile dependency classification. Validates EOCD/comment, disk/count,
  central lengths, duplicate names, local metadata/data descriptors, payload
  bounds, extracted length and CRC. Archive input is capped at32MiB/16384
  entries, general extraction at32MiB and manifest extraction at1MiB. Bounded
  output checks every write/back-reference, including forged declared sizes.
  Unreadable manifests retain a listing and a real error, never invented data.
- Local-path picker reads are bounded before allocation and during reads;
  the shared OHOS URI method contract is exercised through actual channel mocks.
- `lib/java_catalog_audit.dart`: create workspace before JDK probes. Retain
  snapshots and abort further payloads if cancellation does not prove exit;
  cancel a late-starting process before cleanup. Serialize report writes and
  expose late cleanup completion. Device acceptance additionally requires actual
  javac17 evidence alongside Java17.
- Core host verifier now uses an independent default expected count280
  (`--expected-topics` permits explicitly declared historical baselines),
  requires actual java17/javac17 probes for runtime verification, fails on UTF8
  decode/stream failures, verifies termination before cleanup and retains the
  workspace if termination remains unproven.

## Fixture provenance

- Preserved original real javac17 fixture as `greeting.bin` so it is not hidden
  by the repository's `*.class` ignore rule; fixture loaders map display name
  `greeting.class` to those bytes. Existing JAR/standalone parity test passes.
- `unicode.class.bin` is real JDK17 `javac --release17 -encoding UTF-8 -g:none`
  output from `src/fixtures/UnicodeNames.java`; contains Chinese and supplementary
  letter identifiers plus NUL/emoji constants.
- `dynamic.class.bin` is emitted by `GenerateDynamicFixture.java` using the
  JDK's bundled ASM with explicit module export. The generator loaded the emitted
  class and invoked its dynamic-constant method on actual Java17 successfully.
  No downloaded fixture-generation dependency or product ASM dependency added.

## Verification

- Scoped `dart analyze` across both tool files, audit/harness, three new test
  files and both reviewed core files: **No issues found**.
- `flutter test --no-pub --concurrency=1 --timeout60s` for
  `java_developer_tools_test.dart`, `java_developer_tool_pages_test.dart`,
  `java_catalog_audit_test.dart`: **97/97 pass** after final fixes.
- Core inventory-only command: **1120 snippets,280 distinct payloads,0 issues**;
  evidence `qfli_studio_core/build/java-review-inventory.json`. This is inventory
  evidence and explicitly reports no device execution.

## Findings left to other owners / limits

- Shared `PickerService.readUri` returns a complete byte array; Java applies its
  cap after that native transfer. A bounded URI-read API would require a common
  core/platform contract change, outside this review's ownership. Local paths
  are bounded before reading.
- Host verifier fixes locale/timezone to en_US/UTC; the normal in-app runner
  currently exercises device defaults. Content must remain deterministic or
  the runner owner can add an explicit audit configuration. Host results do not
  establish device-default behavior.
- No OHOS execution, full application suite, debugger review or current shared
  editor integration proof was produced by this subtask. Root owns those gates
  and final spec sync/commit/push. Umbrella acceptance remains open.
