# Tools tab and shared offline tools

## 1. Scope / Trigger

Apply this contract when adding a product tool, changing `FunctionsTab` or
`StudioProfile.toolsTabBuilder`, or moving a conversion between Java and core.
Core owns the tab Scaffold/AppBar, terminal route, shared card presentation and
nine language-neutral tools. Java owns integer/bit operations, Java string and
text block conversion, JSON-to-Java generation and Java reference tables.

Source owners are core `services/studio_profile.dart`, `pages/home_page.dart`,
`pages/quick_tools_page.dart`, `pages/tools_grid.dart`,
`pages/offline_tool_pages.dart`, `widgets/tool_widgets.dart` and
`tools/offline_tools.dart`; Java integrates through `lib/main.dart`,
`lib/java_tools_page.dart` and `lib/java_tools_pages.dart`. Shared pure logic
imports only Dart libraries. Core never imports a product package. No new
network calls or dependencies belong to this integration.

## 2. Signatures

Paths below are relative to core `lib/` unless a Java path is stated.

```dart
// services/studio_profile.dart
final Widget Function(ProjectStore store, VoidCallback onOpenTerminal)?
    toolsTabBuilder;
final Widget Function(ProjectStore store)? toolsPageBuilder;

// pages/quick_tools_page.dart
const FunctionsTab({
  super.key,
  this.store,
  required this.onOpenTerminal,
  this.onOpenContentTool,
  this.toolsTabBuilder,
}); // store: ProjectStore?; callbacks: VoidCallback

// pages/tools_grid.dart
const ToolDefinition({
  required IconData icon,
  required String title,
  required String description,
  WidgetBuilder? builder,
  VoidCallback? onTap,
}); // assert((builder == null) != (onTap == null))
const ToolSection({
  required String title,
  required IconData icon,
  required List<ToolDefinition> tools,
});
const ToolsGrid({
  super.key,
  List<ToolSection> sections = const [],
  VoidCallback? onOpenTerminal,
});
final List<ToolDefinition> commonTools; // List.unmodifiable, nine entries
```

`widgets/tool_widgets.dart` exports `ToolsTheme`, `ToolsSectionHeading`,
`ToolCard`, `ResultRow`, `Copy`, `ToolScaffold`, `ToolField`, `ToolError` and
`ToolResultCard`. `Copy.copy(BuildContext context, String text)` returns
`Future<void>`; `ToolError(String? message)` renders nothing for null.
Detail pages supply their fields/results to `ToolScaffold`.

`tools/offline_tools.dart` exports `OfflineBase64` (standard and URL-safe UTF-8
encode/decode), `OfflineUrlCodec.encode/decode(String)`,
`OfflineDigest.md5/sha1/sha256(String)` and raw-byte variants,
`OfflineRegex.test(String pattern, String input, {bool multiLine = false,
bool dotAll = false, bool caseSensitive = true})`,
`OfflineRegex.replaceAll(String pattern, String input, String replacement)`,
`OfflineRegexMatch`, `OfflineRegexResult`, `OfflineColorInfo.parse(String)`,
`OfflineUuid.v4([Random? random])`, `OfflineUuid.v3/v5(String name,
String namespace)`, `UnicodeInfo(int codePoint)` and
`OfflineTimestamp.toLocal(DateTime, {required bool milliseconds})` /
`OfflineTimestamp.parseLocal(String) -> DateTime?`.
`UnicodeInfo.unicodeEscape` is language-neutral; do not restore `javaEscape`.

Java exposes `JavaToolsGrid({super.key, ProjectStore? store,
VoidCallback? onOpenTerminal})` and `JavaToolsPage({super.key, ProjectStore? store})`.
The first delegates to `ToolsGrid`; the second is
the standalone Scaffold wrapper.

## 3. Contracts

- Builder precedence is the explicit `FunctionsTab.toolsTabBuilder`, then
  `StudioProfile.current?.toolsTabBuilder`. An inline builder requires a
  non-null store. `HomePage` supplies both the store and current builder.
- An inline builder owns the entire scroll body. Return `ToolsGrid` with only
  product definitions and the supplied terminal callback; the shell does not
  append common cards around arbitrary custom content. Do not return a full
  page or add a second Scaffold/AppBar.
- `ToolsGrid` renders an optional `快捷入口` section containing `终端`, then
  nonempty product sections in input order, then the `通用` group and offline
  note. It always adds the nine common tools. Do not include `commonTools` in a
  product section or copy their implementations into Java.
- Common display order is Unicode, Base64, URL, regex, JSON formatting, digests,
  timestamp, UUID and color. The `JSON 格式化` card opens core's existing
  `JsonToolPage`/`JsonDocumentService`; `JSON 转 Java 类` opens
  `JavaJsonToolPage`. They are separate capabilities.
- Without an inline builder, `FunctionsTab` uses `ToolsGrid` itself. It preserves
  the existing product tool callback as one card in `专用` when
  `onOpenContentTool` exists; its product title/icon/description and full page
  route stay intact. The terminal and common group are also present. Legacy
  callers may omit the store. This changes presentation, while retaining access
  to the existing product page and its tabs/PopScope.
- A definition has exactly one action. `onTap` calls the supplied callback;
  `builder` opens `MaterialPageRoute<void>`. Common tool routes use only core.
  The terminal reuses the shell callback/terminal manager and does not create a
  second command backend.
- Java supplies one `Java` section with exactly nine definitions: integer/bit,
  strings, JSON-to-Java, reference, JVM descriptors, stack traces, class
  inspection, JAR/manifest inspection and the actual local debugger. Its standalone
  grid contains 18 cards; the tab contains 19 including terminal, with no
  intermediate `功能` card. No duplicate generic pages/widgets remain in Java.
- Every card uses `ToolCard`/`ToolsTheme`: height 132, maximum cross-axis extent
  320, spacing/radius 12 and inner padding 16. Titles have one line; descriptions
  have at most two. Layout follows available width and Material color scheme.
  The one `CustomScrollView` uses `PageStorageKey<String>('tools-scroll')`.
- Form URL encoding maps spaces to `+` and literal plus to `%2B`. Regex uses
  Dart `RegExp` semantics, including its replacement-string behavior.
  UUID v3/v5 hashes binary namespace bytes plus UTF-8 name bytes. Timestamp
  parsing preserves Dart `DateTime` normalization; it is not strict calendar
  validation. Shared UI and pure helpers work offline. Existing qflistudio
  network features remain independent.

## 4. Validation & Error Matrix

| Condition | Contract |
| --- | --- |
| Inline builder with null store | Debug assertion: `FunctionsTab requires a ProjectStore when toolsTabBuilder is provided.` Release callers must also satisfy the non-null-store precondition. |
| No inline builder and null store | Valid legacy construction; terminal, optional product entry and common group render. |
| Both/neither definition actions supplied | Constructor assertion fails. Supply exactly one `builder` or `onTap`. |
| Empty product section / absent terminal callback | Empty section is skipped / terminal section is omitted; nine common tools remain. |
| Duplicate product/common definition | No automatic deduplication. Avoid it in product configuration and assert unique card titles in integration tests. |
| Malformed Base64 or decoded non-UTF-8 bytes | Pure decoder throws `FormatException`; page shows `解码失败` with its message. URL-safe decode restores missing padding. |
| URL percent triplet with invalid hex, e.g. `%GG` | Decoder throws `FormatException`; page shows a `无法解码` result. Incomplete escapes such as `%` remain literal, matching current codec behavior. |
| Invalid regex pattern | `OfflineRegex.test` returns `ok == false` and an error string instead of throwing. Replacement API uses normal Dart exceptions. |
| More than 200 regex matches | Return first 200 matches with `truncated == true`. Match payload contains index/value/positional and named groups. |
| Color has invalid hex or unsupported length | `OfflineColorInfo.parse` throws `FormatException`; page renders an inline error. Supported hex lengths are 3, 6 and 8. |
| Unicode input has more than one rune | Page shows the rune-count error. Empty input shows the input prompt. Supplementary characters report two UTF-16 units. |
| Timestamp is not an integer / date text has an unsupported format | Page shows an inline error. `parseLocal` returns null for unsupported formats; supported fields follow `DateTime` normalization. |
| UUID namespace is not 32 hex digits after removing hyphens | v3/v5 use the RFC DNS namespace fallback, preserving the existing behavior. |
| JSON formatting input is malformed | Existing JSON analysis reports invalid input; formatting does not replace it with invented content. |
| Clipboard future completes after page disposal | `Copy.copy` checks `context.mounted` before showing its snackbar. |

## 5. Good / Base / Bad Cases

- Good: Java profile returns `JavaToolsGrid(onOpenTerminal: onOpenTerminal)`.
  The tab shows terminal, nine Java cards and nine common cards directly;
  tapping the shared JSON card opens `JsonToolPage`, while Java generation
  still produces POJO/record source.
- Base: `FunctionsTab(onOpenTerminal: openTerminal)` with no profile and no
  store shows ten cards. Adding `onOpenContentTool` preserves that callback
  through a product card, giving eleven. `const ToolsGrid()` contains nine.
- Good: encoding `a b+c` returns `a+b%2Bc`; decoding restores the original.
  Emoji Unicode input has one rune and a UTF-16 surrogate pair.
- Bad: returning `JavaToolsPage` from the inline builder nests a Scaffold.
  Adding generic definitions to the Java section repeats the automatic group.
  Treating malformed codec input as an empty successful result loses errors.

## 6. Tests Required

- Core `test/studio_profile_test.dart` pins explicit-builder precedence,
  profile fallback, the non-null-store inline requirement and legacy no-store
  construction. `test/home_navigation_test.dart` pins HomePage wiring and
  offline/online navigation.
- Core `test/tools_grid_test.dart` covers all nine direct routes, terminal
  callback, existing product entry callbacks/titles/icons, empty standalone
  construction and product sections between terminal/common groups. Include
  360/1200 widths and both brightness values, card geometry, hit targets, live
  form results/errors and per-result copying.
- Core `test/offline_tools_test.dart` covers standard/URL-safe UTF-8 Base64,
  form URL spaces/plus, known digest vectors, RFC UUID v3/v5 and v4 bits,
  regex groups/errors/truncation/replacement, color formats, Unicode BMP and
  supplementary points, and timestamp conversion behavior.
- Java `test/java_tools_page_test.dart` verifies 18 unique standalone cards,
  all nine common routes, distinct JSON routes, nine direct Java pages,
  narrow/wide columns, dark theme, scrolling and no overflow.
  `test/java_tools_wiring_test.dart` mounts real `FunctionsTab` with
  `javaProfile`: 19 unique ordered cards, terminal callback, one Scaffold and
  AppBar, no `功能`, every card hit-testable in narrow/wide and light/dark.
- `scrollUntilVisible` may find cached sliver content before its final
  `ensureVisible` jump has laid out. Target the whole `ToolCard` and pump
  after scrolling before asserting card/title hit testing. Await a bounded
  `pumpAndSettle` for tool route completion before asserting the source page
  is offstage; Java detail-route tests use a two-second fake-clock timeout.
- Full home/editor tests also need explicit real-I/O waits using `runAsync`,
  initialized temporary AppPaths/TaskActivityService fixtures and bounded
  lazy-tree waits. Frame pumping alone cannot finish real filesystem futures.
  Dispose widgets/controllers before removing fixture directories.
- Run `dart analyze lib test` and `flutter test --timeout 60s` in core and
  Java. Report full-suite failures separately from targeted passes. Widget
  coverage does not demonstrate a device build or installation.

## 7. Wrong vs Correct

Wrong: use the standalone page or manually repeat shared definitions.

```dart
toolsTabBuilder: (store, onOpenTerminal) => const JavaToolsPage()
// Also wrong: ToolSection(..., tools: [...javaTools, ...commonTools])
// ToolsGrid already appends commonTools.
```

Correct: embed the content-only adapter and let core compose shared cards.

```dart
toolsTabBuilder: (store, onOpenTerminal) =>
    JavaToolsGrid(onOpenTerminal: onOpenTerminal)

// Inside JavaToolsGrid:
ToolsGrid(
  onOpenTerminal: onOpenTerminal,
  sections: [ToolSection(title: 'Java', icon: Icons.code, tools: javaTools)],
)
```
