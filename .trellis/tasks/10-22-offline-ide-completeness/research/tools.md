# Java offline developer tools — research and evidence

Scope: PRD R5 for the Java root of `10-22-offline-ide-completeness`. Exclusive
files: `lib/java_tools_page.dart`, `lib/java_developer_tools.dart` (new),
`lib/java_developer_tool_pages.dart` (new), `test/java_developer_tools_test.dart`
(new), `test/java_developer_tool_pages_test.dart` (new),
`test/fixtures/java_developer_tools/**` (new). No core, `main.dart`, runner or
existing-test edits.

## 1. Capability research

What a Java IDE's offline toolbox normally offers, and what this repo can
honestly support without network, new packages or a subprocess:

| Capability | Real offline implementation | Decision |
| --- | --- | --- |
| JVM descriptor decode/encode (`javap`-style) | Pure text transform over the class-file grammar | Implemented |
| Stack-trace parsing/filtering | Pure text transform; no runtime needed | Implemented |
| Class-file inspection | Direct binary parse of `CAFEBABE`, constant pool, members | Implemented |
| JAR/manifest inspection | ZIP central directory + raw-deflate via `dart:io` zlib | Implemented |
| Dependency analysis (classpath graph) | Needs the project model and a JAR set; belongs to the diagnostics batch | Deferred (documented, not stubbed) |
| `javap`/`jar` toolchain actions | Requires the JDK bridge and a project cwd; the terminal already routes `javac`/`java` | Not duplicated here |
| JDWP/JDI debugging | Investigated separately in the debug batch | Out of scope for this file |

Rejected alternatives:

- `package:archive` is only a transitive dependency of `qfli_studio_core`. Using
  it here would need a new direct dependency declaration, and the task forbids
  adding dependencies. The ZIP reader is ~110 lines of central-directory parsing
  and is fully covered by tests, so it stays inside the Java package.
- A generic "Java tools" menu page would violate the direct-card contract in
  `.trellis/spec/frontend/tools-tab.md` §3.

## 2. Existing helpers reused (search first)

- `ToolDefinition` / `ToolSection` / `ToolsGrid` — `qfli_studio_core/pages/tools_grid.dart`.
  Cards are appended to the existing `Java` section; `ToolsGrid` still adds the
  nine common tools and the terminal card, so nothing is duplicated.
- `ToolScaffold`, `ToolField`, `ToolError`, `ToolResultCard`, `ResultRow`,
  `Copy` — `qfli_studio_core/widgets/tool_widgets.dart`.
- `PickerService.pickDocument` / `readUri` — `qfli_studio_core/services/picker_service.dart`.
  Desktop returns a path, HarmonyOS/Android returns a content URI; both shapes
  are handled in `pickJavaFileBytes`, matching `settings_page.dart`'s import path.
- `package:path` (`basename`) — already a declared dependency of `qfli_java`.
- No existing descriptor, class-file, manifest or ZIP helper exists in core or
  Java (searched `manifest|Manifest|CAFEBABE|descriptor|jar`); nothing was
  duplicated.

## 3. What was added

`lib/java_developer_tools.dart` — pure logic, no Flutter import:

- `JavaDescriptors.parseField/parseMethod/parseAny/descriptorOf/methodDescriptorOf`
  with `JavaDescriptorType` (base name, array dimensions, primitive flag) and
  `JavaMethodDescriptor` (parameters, return type, readable signature,
  `rebuiltDescriptor` round trip).
- `JavaStackTrace.parse` → `JavaStackTraceReport` with `JavaThrowable`
  (primary / `Caused by:` / `Suppressed:`, wrapped messages, `... N more`) and
  `JavaStackFrame` (module prefix, native, unknown source, line number).
  `JavaStackTrace.render` filters runtime frames and/or a text needle, caps the
  output and drops now-inaccurate `... N more` markers when filtering.
- `JavaClassFile.parse` — magic, minor/major → Java release, access flags,
  this/super class, interfaces, constant-pool tag census, fields, methods
  (descriptors decoded through `JavaDescriptors`), class attributes.
- `JavaZip.entries` / `JavaZip.readEntry` — ZIP central directory (little-endian
  reader, ZIP64 and encryption rejected explicitly) plus stored/raw-deflate
  payload extraction through `dart:io`'s `ZLibDecoder`.
- `JavaManifest.parse` / `parseBytes` — 72-byte line folding, unfolded at the
  byte level so a multi-byte UTF-8 character split across a fold survives;
  main attributes plus named sections.
- `JavaJarInspection.fromBytes` — entry list, class count, packages, total
  inflated size, modular flag, manifest or the reason it is missing.
- `JavaBytesFormat.human` — binary byte units.

`lib/java_developer_tool_pages.dart` — four pages, each reached directly:

| Card | Page | Real behaviour |
| --- | --- | --- |
| JVM 描述符 | `JavaDescriptorToolPage` | decode a pasted descriptor, write one from Java type names |
| 栈异常分析 | `JavaStackTraceToolPage` | parse pasted trace, toggle application-frames-only, filter by class/file, render |
| class 文件检查 | `JavaClassFileToolPage` | pick a local `.class`, parse its bytes |
| JAR 清单检查 | `JavaJarToolPage` | pick a local `.jar`, parse manifest + structure |

`lib/java_tools_page.dart` now exposes eight cards in one `Java` section: the
four original converters/reference tables, unchanged, followed by the four new
tools. No intermediate menu, no second `Scaffold`, no `commonTools` duplication.

File picking is injectable (`JavaFileBytesLoader`) so widget tests drive the real
pages with committed fixtures instead of a native dialog; production uses
`PickerService` through `pickJavaFileBytes`.

## 4. Fixtures (real toolchain output, committed)

`test/fixtures/java_developer_tools/`:

- `src/fixtures/Greeting.java` — source, documented with the exact commands.
- `greeting.class` — `javac --release 17` output, major version 61.
- `src/manifest.mf` + `greeting.jar` — `jar --create` output containing
  `META-INF/MANIFEST.MF`, `fixtures/Greeting.class`, real deflate payloads.

Regeneration:

```powershell
cd test/fixtures/java_developer_tools
javac --release 17 -d build/classes src/fixtures/Greeting.java
Copy-Item build/classes/fixtures/Greeting.class greeting.class
jar --create --file greeting.jar --manifest src/manifest.mf -C build/classes .
Remove-Item -Recurse -Force build
```

## 5. Tests and current results

`test/java_developer_tools_test.dart` — 40 cases: descriptor decode/encode and
error messages, round trips, stack-trace headers/frames/causes/suppressed/
wrapped messages/filters/caps/non-trace input/custom throwables/javac
diagnostic rejection, class-file version/declaration/fields/methods/constant
pool/truncation, manifest folding (including a UTF-8 character split across the
fold) and named sections, JAR listing, manifest inflation, and the assertion
that the inflated `.class` entry is byte-identical to the standalone `.class`
fixture, ZIP rejection paths, byte formatting.

`test/java_developer_tool_pages_test.dart` — 22 cases: eight unique direct
definitions, standalone grid composition, each page's live behaviour
(decode/write descriptor, invalid input error, stack-trace summary/switch/
filter/non-trace input, class-file inspection and error, picker cancel and
picker failure, JAR inspection and error), dark-mode rendering and a phone-width
scroll without overflow.

Results on this machine:

```
flutter analyze                      -> No issues found!
flutter test test/java_developer_tools_test.dart \
             test/java_developer_tool_pages_test.dart -> 62 passed
flutter test (whole package)         -> 151 passed, 8 failed
```

The six failures owned by this change are exactly the pre-existing hard-coded
cardinalities, which the root owner adjusts as agreed (this worker must not edit
those tests):

- `test/java_tools_page_test.dart` — expects `javaTools` length 4 / 13 cards.
- `test/java_tools_wiring_test.dart` — expects `javaTools` length 4, 13 tools,
  14 tab cards (actual: 8, 17, 18).

Every failure is a length assertion (`Expected: length 4/14, Actual: 8/18`); the
per-card reveal loop still reached and hit-tested all eight Java cards at 360 px
and 1100 px in light and dark, so there is no reachability, duplication or
overflow regression.

The remaining two failures in the package-wide run
(`java_diagnostics_test.dart`, `java_app_test.dart`) come from the concurrent
diagnostics/runner worker's in-progress `lib/java_diagnostics.dart` and
`lib/java_runner.dart` changes; they are outside this worker's ownership and
were not touched.

## 6. Offline and platform notes

- No network call, no new dependency, no subprocess, no source or project write.
  File access is read-only and capped at 32 MiB (`kJavaToolMaxBytes`).
- `dart:io` `ZLibDecoder(raw: true)` is the only non-pure API used by the logic
  layer. If a platform ever lacks it, `JavaZip.readEntry` returns `null` and the
  JAR page shows "清单压缩方式不受支持或数据损坏" while still listing entries —
  the degradation is explicit, not silent.
- Constant-pool strings are decoded as tolerant UTF-8 (modified UTF-8 surrogate
  pairs degrade to replacement characters instead of failing the inspection).
- Device/OHOS execution of these pages is **not** claimed here: they are pure
  Dart over local bytes, verified on the host VM. The app-level OHOS gate stays
  with the umbrella task.
