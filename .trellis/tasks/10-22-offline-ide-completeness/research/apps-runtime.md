# Standalone runtime and Java tooling research

Inspected 2026-10-22. Research only; no product files modified. Initial scope covered the eleven standalone roots; parent coordination then restricted implementation ownership to Java plus separately coordinated shared core. Other products already have active instances of this request, so their directories must remain read-only here.

## Current target environment

- `Get-Command hdc` resolves to `D:/ProgramFiles/Huawei/OpenHarmony/Sdk/23/toolchains/hdc.exe`.
- `hdc list targets` returned `[Empty]` during this research. There is no currently attached OHOS target. This blocks claiming new packaged OHOS execution passes; compilation, packaging, static inspection, and host execution remain possible.
- Installed OpenHarmony SDK directories include `20` and `23`. `DEVECO_SDK_HOME` and `HOS_SDK_HOME` are `D:/ProgramFiles/Huawei/DevEco Studio/sdk`; that directory contains `default`, `hmscore`, and `openharmony`.
- PATH selects `D:/ProgramFiles/flutter_ohos/bin/flutter.bat`, the accompanying Dart, Python 3.13, and Node. `JAVA_HOME` is `D:/ProgramFiles/Java/jdk-25`; installed Windows JDK directories are `jdk-24` and `jdk-25`.
- A host JDK 25 test is not evidence that source runs on the bundled OHOS Java 17 runtime. Host catalog compilation must use `--release 17`, and actual OHOS execution remains a separate acceptance requirement.

## Java runtime: authoritative present behavior

`lib/java_runner.dart` owns the real compiler/runtime adapter. `JavaProgramRunner` implements the shared `ProgramRunner.run(projectPath, entryFile)` interface. It currently has no public check-only operation and no structured diagnostic result.

The `run` path:

1. Accepts `.java`, normalizes absolute paths, and rejects an entry outside the project or missing on disk.
2. Resolves `MobileJdk.prepare()` on Android/OHOS; desktop resolves explicit `javaHome`, `QFLI_JAVA_HOME`, `JAVA_HOME`, then PATH.
3. Recursively collects every `.java` source except hidden directories and `build`; does not follow links. It collects JARs under both `lib/` and `libs/`.
4. Compiles all collected sources with UTF-8, a temporary classes directory and the local classpath.
5. Returns compilation diagnostics with `kProgramNotRunExitCode` (127) on compiler failure; no user main runs after a failed compile.
6. Derives the selected main class from its package declaration and filename, starts Java, feeds finite project `input.txt`, captures stdout/stderr, and removes temporary classes after process termination.

`JavaProgramRunner.runToolchainCommand(workingDirectory, arguments)` already streams `javac` and `java` through this same resolution path and returns a cancellable `ProgramRunResult`. `_javaTerminalDelegate` in `lib/main.dart:65` tokenizes quoted arguments with the shared parser and claims only simple `javac`/`java` commands. Compound shell constructs fall back to the sandbox.

`lib/mobile_jdk.dart:60` exposes the shared installation/preparation path. Preparation caches successful actual Java and javac version probes, rather than merely checking asset names. The public `MobileJdkLayout` exposes home, Java, javac and native library directory, with required environment paths.

OHOS transport is `lib/ohos_jdk_process.dart`:

```dart
OhosJdkProcess.start({
  required String home,
  required String libraryDirectory,
  required List<String> arguments,
  required String workingDirectory,
  String? inputFile,
});
// stdout/stderr are byte streams; exitCode is Future<int>; cancel awaits exit.
```

It calls channel `qfli_jvmx/jdk` methods `start`, `poll`, and `cancel`; arguments sent to the bridge include `java` as argv[0]. Each child spools stdout/stderr to owned files and is polled every 40 ms. Javac is launched with `-m jdk.compiler/com.sun.tools.javac.Main`, so OHOS does not require executing a standalone javac ELF from writable storage.

`native/openjdk/ohos/README.md:3` describes headless OpenJDK 17.0.20, built for OHOS ARM64 and x86_64 with Zero. The child forks, loads installed native libraries and calls `JLI_Launch`; this avoids tested sandbox restrictions on ELF execution, symlinks and executable anonymous mappings. Java `ProcessBuilder` is still subject to the OS execution policy.

This version was independently verified from the actual staged `jdk-arm64-v8a.zip` and `jdk-x86_64.zip` `release` members, not inferred solely from the recipe:

| Property | ARM64 | x86_64 |
| --- | --- | --- |
| JAVA_VERSION | 17.0.20 | 17.0.20 |
| JAVA_RUNTIME_VERSION | 17.0.20-internal+0-adhoc.root.source | same |
| OS_ARCH | aarch64 | x86_64 |
| LIBC | musl | musl |
| ZIP entries | 262 | 262 |
| ZIP bytes | 49,403,026 | 49,396,996 |

Both release descriptors list `java.compiler`, `jdk.compiler`, `jdk.jartool`, `jdk.javadoc`, `jdk.jdeps`, `jdk.jdwp.agent`, `jdk.jdi`, `jdk.jshell`, `jdk.httpserver`, `jdk.jfr` and `jdk.management`. Installed native directories contain `libjdwp.so` and `libdt_socket.so`. This proves bundled components, not successful operation of every tool or debugger on OHOS.

`native/openjdk/stage.ps1:86` stages conf/lib/legal plus release metadata while excluding src.zip and executable helper files from the data ZIP. New OHOS tools should reuse Java module entrypoints or a Java helper class through the current child bridge, rather than assuming extra shell executables exist.

## Java direct tool surfaces and gaps

`lib/main.dart:34` embeds `JavaToolsGrid` using `StudioProfile.toolsTabBuilder`; `toolsPageBuilder` also supplies a standalone wrapper. `lib/java_tools_page.dart` contributes four Java cards directly to shared `ToolsGrid`:

- `整数与进制`: exact Java primitive widths, two's complement, overflow and bit operations.
- `字符串转义`: Java literal encoding/decoding and text block output.
- `JSON 转 Java 类`: nested POJO/record generation.
- `关键字速查`: primitives, keywords and escapes.

The grid includes the shared terminal callback and nine shared tools. Existing tests pin 13 standalone cards / 14 inline cards, unique titles and direct access. Current Java has no intermediate generic `功能` card. Each real tool card opens its own form route. The attached request rejects an intermediate product tool hub; it does not itself establish whether every substantial form must occupy the tools tab simultaneously. Preserve direct tool access and do not introduce a new product hub.

Pure helpers are in `lib/java_tools.dart` and reference data in `lib/java_tools_extra.dart`. All current Java tool forms are in `lib/java_tools_pages.dart`. `JavaToolsGrid` currently lacks a `ProjectStore` parameter; project-aware additions need it passed from the existing profile callback.

Useful offline Java additions supported by present components:

| Tool | Existing building block | Needed implementation / proof |
| --- | --- | --- |
| Project checks and compiler diagnostics | javac plus local lib/libs classpath | Public compile-only service; structured file/range diagnostics; buffer snapshot support; actual OHOS compiler invocation |
| Runtime/version/capability inspector | MobileJdk version probes and release metadata | Project-independent direct tool; display measured version and target facts, avoid declaring all modules functional from manifest presence |
| JAR / class compatibility inspector | Local files and bundled Java modules | Read actual JAR manifest/class headers; identify Java class major versions and duplicate classes; no Maven download |
| Bytecode disassembly | `jdk.jdeps`/javap module present | Run real module entrypoint against selected project class/JAR; capture actual errors/output; prove module launch on OHOS |
| Dependency inspection | `jdk.jdeps` and local JAR inputs | Run local jdeps; report unresolved local dependencies without automatic fetch |
| JAR packaging | `jdk.jartool` present | Owned output path, class/file selection, real produced JAR verified by reopening/execution |
| Javadoc generation | `jdk.javadoc` present | Generate/read local documentation; contain output inside project/build; no online lookup |
| Java regular-expression tester | Current common regex uses Dart semantics | Execute `java.util.regex` through Java helper for Java-specific semantics; do not relabel Dart RegExp as Java |

This list identifies feasible mechanisms, not existing completed features. Parser-based rename/import optimization/full completion require additional real Java analysis; the current brace formatter is not a Java parser and must not be described as semantic formatting.

`lib/spring_boot_bundle.dart` contains an offline materializer for pinned Spring Boot 3.5.16 assets. `assets/spring_boot/3.5.16` currently has 29 files (28 JARs plus manifest). `tools/prepare_spring_boot.ps1` and `tools/spring_boot.lock.json` are build-time reproduction inputs. The ordinary runner only adds project `lib/` and `libs/`; it does not automatically call `SpringBootBundle.materialise`. An inspector/import-local-JAR workflow can expose this relationship honestly; it must not introduce runtime downloads. Spring Boot is optional local capability, not proof that every related catalog example currently runs.

## Diagnostics integration boundary

Shared core `lib/services/studio_profile.dart:297` currently defines only:

```dart
abstract interface class ProgramRunner {
  Future<ProgramRunResult?> run({
    required String projectPath,
    required String entryFile,
  });
}
```

`ProgramRunResult` carries title, line streams, exitCode, optional cancel. No diagnostic DTO, check-only capability or background analyzer hook exists. Existing `EditorFileTool` accepts only `(file, projectPath)` and returns `EditorFileToolResult(success, message)`; `EditorPage._runEditorTool` saves the file before invocation. This hook is appropriate for explicit saved-file actions, but cannot implement live unsaved-buffer diagnostics correctly without extending the contract.

Required Java diagnostic behavior:

- Compile an owned snapshot containing dirty editor buffers and the remaining project sources, preserving relative filenames/package layout and local JAR classpath. Do not overwrite unsaved files merely to check them.
- Add `-proc:none` for automatic checks, so compile checks cannot execute annotation processors from local dependencies. No user main should run.
- Prefer stable compiler diagnostic positions/codes; a Java `DiagnosticCollector` helper can supply file, start/end offsets, line, column, severity and message. If parsing CLI text instead, explicitly test localized diagnostics, Windows drive-colon paths, multiple diagnostics and caret/range mapping; `-XDrawDiagnostics` produces codes/positions but user-facing messages need deliberate handling.
- Share compiler/JDK/process resolution with the runner; do not create a second independent mobile launcher or fallback evaluator.
- Expose cancellation before expensive compilation, impose a bounded check, discard stale generations and clean snapshot/classes after the actual child exits. Current `run` waits for compilation before returning a handle, so it cannot cancel compilation through its current public interface.
- Remap snapshot paths to original absolute project paths, use the shared editor's UTF-16 coordinate convention, and clamp malformed/EOF ranges. Distinguish compiler diagnostics from infrastructure failures and preserve raw output for troubleshooting.
- Make auto checks debounced and editor-owned; typing/caret movement must not publish stale results or run an expensive check for selection-only notifications.

Core `lib/editor/editor_page.dart:2357` hosts vendored `CodeEditor`. The current editor exposes `indicatorBuilder` for gutter content, but no public diagnostic range/squiggle API. `vendor/re_editor/lib/src/code_line.dart` exposes controller span building and render paragraphs; `_code_field.dart` owns actual text layout/foreground/background painting. True wave underlines therefore require a coordinated core/vendor rendering change that follows actual glyph geometry, horizontal/vertical scrolling, font scale, folding and selection. A gutter icon alone does not satisfy the requested wave underline behavior.

`lib/editor/highlight_themes.dart:26` already registers Java. Its built-in language map currently has no Go, Rust, Lua or SQL; those gaps are shared-core scope and should be assigned to the core owner.

## Debugging / output / ports

The current Java adapter supports normal source execution, real stdout/stderr, runtime exit codes and cancellation. No breakpoint, stepping, variable inspection, stack/frame, DAP/JDWP/JDI frontend or debug-session interface exists in Java/core source inspected.

Bundled JDI/JDWP modules and native libraries make an offline Java debugger technically investigable. They do not prove that the Zero VM's actual debug capabilities work through the forked OHOS child. A concrete target probe must launch with the debug agent, attach locally, hit a real breakpoint, inspect a variable, step/resume, terminate and run again. A UI displaying breakpoints without this protocol is not a debugger. Network-dependent remote debug should be excluded; local loopback-only transport, if used, must never bind an external interface or introduce remote fetches.

Problems, compiler/build output and debug console should be shared editor panels with product-owned data. Java must not add a second terminal backend. A ports panel has no real Java process/port enumeration service today; avoid decorative entries. App-managed local server sessions could eventually expose their measured ports, but that requires a real owner/session contract.

## Catalog baseline relevant to Java

Current shared core files were parsed as JSON during this research:

- `assets/content/examples.json`: 1,640 total entries, exactly 100 with language `java`.
- `assets/content/tutorials.json`: 1,640 total entries, exactly 100 with language `java`.
- `assets/tutorials/java.json`: five chapters and exactly 100 examples.

Java currently does not set `contentRepositoryFactory`, so it uses shared content. Other standalone products demonstrate a product-owned `ContentRepository` seam. A Java-local curriculum expansion can use that seam and dedicated assets instead of simultaneously modifying the aggregate shared catalogs owned by other agents. Inspect the actual repository loading rules before selecting a catalog source; counts alone do not prove which code the UI currently runs.

Existing Java tests validate representative host projects, not all 100 catalog entries and not packaged OHOS execution of those entries. Current 100-entry counts are baseline only; the user's request for more than 100 additional examples and exhaustive target-toolchain validation remains open.

## Existing verification assets and limits

- `test/java_app_test.dart`: real host multi-source/package compilation, compiler failure, preserved guest exits, input, UTF-8, demo import/run, terminal cwd/quoting/compound fallback and compiler argument forwarding.
- `test/ohos_jdk_process_test.dart`: OHOS transport behavior with channel doubles, including stream/exit/cancel behavior. Does not execute an OHOS JVM.
- `test/java_tools_test.dart`, `test/java_tools_extra_test.dart`, `test/java_tools_page_test.dart`, `test/java_tools_wiring_test.dart`: current helper and UI behavior, card routing/layout/terminal integration.
- `tools/jdk_smoke.dart`: in-app `QFLI_JDK_SMOKE` JSON with eight required checks: java-version, javac-version, multiple-sources, stdin, utf8, compiler-diagnostics, exit-code, cancel. Must use the actual packaged target and restore the ordinary app afterward.
- `native/openjdk/README.md:75` records an OHOS x86_64 phone-simulator eight-case pass on 2026-09-30. This is historical representative evidence; it neither covers the current full catalog nor proves current ARM64 execution.
- Current `hdc list targets` is empty. New required target runtime passes must remain explicitly pending until real packaged target execution is available.

## Other standalone products: read-only context

| Product | Existing tool surface / runtime facts inspected |
| --- | --- |
| C/C++ | `forge_tools_page.dart`: three tabs (base conversion, bits, ASCII), `toolsPageBuilder` only. `native_clang_runner.dart`, `clang_runner.dart`, OHOS ArkTS/native bridge, compiler selected-source and portable WASI paths. Existing fixture `test/fixtures/desktop_native/mixed_c_main/include/helper.h` and mixed helper.cpp show real header/multifile tests exist. Device native audits under `tool/ohos_native_audit.dart` and `tool/ohos_terminal_audit.dart`. |
| Dart | `dart_tools_page.dart`: real project/file buffer, format, parser diagnostics, compile, run/artifact/stop; `toolsPageBuilder` only. `.trellis/spec/backend/dart-native-runtime.md` explicitly keeps OHOS on dart_eval; full SDK only Android/desktop. Portable compatibility must not be advertised as full Dart SDK. |
| Go | Native bridge/runner and terminal delegate, no product tools-page/grid hook in main. `.trellis/spec/backend/native-go-runtime.md` owns real runtime boundary; curriculum tooling already has host/native/mobile evidence separation. |
| JSON | Minimal product profile in main, no product tools hook found. Shared JSON tooling remains the integration route. |
| Lua | No product tools-page hook; `lua_editor_tools.dart` contributes native check/bytecode actions. Native C exports include check, compile, version and cancellation; execution hook currently handles stop rather than debugger stepping. |
| Markdown | Product `toolsPageBuilder` opens notes hub; substantial product-owned Markdown workspace/preview/export/analysis/actions already exist. |
| Python | `toolsTabBuilder` contributes one `检查与运行` card that opens `PythonToolsPage`; page has real project check/run/compile/stop. Native engine is MicroPython 1.24.1, not CPython. `native-python-runtime.md` explicitly excludes pip, CPython extensions, os/networking; `.py` and upstream `.mpy` project imports and file I/O are supported. `sys.path` starts entry directory then project root, VM/modules reset per run. A pure-source compatible offline module library is plausible; wheel/pip UI requires a genuine new runtime/install compatibility design. Do not claim ordinary CPython wheels work. |
| Rust | No product tools grid hook found. Real pinned rustc/Miri bridge, terminal controls and manifest-checked packaged assets. `.trellis/spec/backend/native-runtime.md` keeps OHOS status unavailable until packaged source execution; Cargo external dependency support is explicitly excluded. |
| SQL | `sql_tools_tab.dart` custom inline body, workbench/query library plus native SQLite/local MySQL integration and offline policy tests. Do not introduce cloud MySQL in offline-only surfaces. |
| Web | `web_tools_overview.dart` inline direct cards and `web_tools_page.dart` server/codec tools; local nginx/dev-server sessions already own measured process/runtime behavior. |

## Shared source changed concurrently

During this research, another owner edited shared `lib/editor/file_explorer.dart` and `lib/editor/project_history.dart`. The initial source had `initState -> _rebuildRoot` clearing `_expanded`, while restore happened only on explicit project switch. The current source now calls `_restoring = _restoreExpanded()` in `_rebuildRoot`, uses generation checks and preserves queued history writes. This is active concurrent work, not a completed/tested claim by this researcher. Re-read current core before planning a duplicate file-tree fix.

## Recommended ownership split

Java owns compiler/check service, real diagnostic extraction, Java-specific tools, Java assets/catalog adapter, Java tests and Java target audit runner. The shared-core owner owns the extensible diagnostics DTO/provider seam, editor panels/squiggles, persistent workspace/tree state, common language display and highlighting. Coordinate the core contract first; Java consumes it and must not duplicate editor caches, terminal managers, diagnostic widgets or other products' logic.

Read before implementation: Java `.trellis/spec/backend/mobile-jdk.md`, frontend `tools-tab.md`, `editor-terminal.md`, `retained-editor.md`, `project-scopes.md`, both layer indexes/quality guidelines and shared guides. The actual core package's corresponding specs must be injected into the coordinated core task separately.
