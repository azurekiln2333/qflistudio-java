# Inline tools and shared offline tools

## Boundary

Core `FunctionsTab` owns the tab Scaffold/AppBar and terminal callback.
`ToolsGrid` composes terminal, optional product sections and common cards.
Java contributes its four dedicated tools through the existing profile
extension point. Core owns language-neutral logic and shared presentation.
Preserve card geometry, routes and offline behavior. No dependency or network
change belongs to this task.

## Delivery 1: inline tools

Completed and committed as core `1281298` and Java `6966df6`:

- Add optional `StudioProfile.toolsTabBuilder(store, onOpenTerminal)` and pass
  it through `HomePage` to `FunctionsTab`. Explicit widget builders take
  precedence; inline builders require a store, while legacy construction does not.
- Extract the content-only `JavaToolsGrid` and retain `JavaToolsPage` as a
  standalone wrapper. Reuse the shell terminal callback and card presentation.
- Keep existing product behavior during this first delivery. The shared grid
  composition below is the final default presentation.

## Delivery 2: shared offline tools

Core now owns the reusable logic, pages, widgets and common group. Java keeps
integer types/bit operations, Java literals/text blocks, JSON-to-Java generation
and reference tables. Products without inline customization retain their
existing product-page callback as a card alongside terminal and common tools.
No sibling product source changes are needed.

### Shared composition contract

- `lib/tools/offline_tools.dart` contains pure Dart `OfflineBase64`,
  `OfflineUrlCodec`, `OfflineDigest`, `OfflineRegexMatch`,
  `OfflineRegexResult`, `OfflineRegex`, `OfflineColorInfo`, `OfflineUuid`,
  `OfflineTimestamp` and `UnicodeInfo`. Unicode uses `unicodeEscape`;
  shared logic has no Java or Flutter dependency.
- `lib/widgets/tool_widgets.dart` owns `ToolsTheme`, `ToolsSectionHeading`,
  `ToolCard`, `ResultRow`, `Copy`, `ToolScaffold`, `ToolField`,
  `ToolError` and `ToolResultCard`. Core and Java use these directly.
- `lib/pages/offline_tool_pages.dart` contains `UnicodeToolPage`,
  `TimestampToolPage`, `Base64ToolPage`, `UrlToolPage`, `HashToolPage`,
  `RegexToolPage`, `ColorToolPage` and `UuidToolPage`. The ninth shared
  card, `JSON 格式化`, opens the existing `JsonToolPage` and
  `JsonDocumentService`; copying JSON also uses that page.
- `lib/pages/tools_grid.dart` defines `ToolDefinition` with metadata and
  exactly one of `WidgetBuilder builder` / `VoidCallback onTap`, plus
  `ToolSection(title, icon, tools)`. `commonTools` is an unmodifiable list in
  display order: Unicode, Base64, URL, regex, JSON, digests, timestamps, UUID, color.
- `ToolsGrid(sections: ..., onOpenTerminal: ...)` renders the optional
  `快捷入口` terminal section first, nonempty product sections next and
  `通用` last. It always appends nine common tools and a shared offline note.
  One `CustomScrollView` owns scrolling; no Scaffold/AppBar is nested.
- Default `FunctionsTab` uses `ToolsGrid`. When `onOpenContentTool` exists,
  one `专用` card retains the product's callback/title/icon/description.
  Existing product full pages, including tabs and PopScope, remain behind
  that callback. The default also exposes terminal and all common tools.
- `toolsTabBuilder` remains the single inline customization callback.
  Custom builders return `ToolsGrid` with product definitions and the
  supplied terminal callback; they must not append commonTools themselves.
  Java contributes one `Java` section with four cards, yielding 13 cards
  standalone or 14 with terminal. Generic Java page/widget copies are removed.
- All cards share height 132, maximum cross-axis extent 320 and spacing 12.
  Colors follow Material light/dark schemes. Detail routes remain intact.
- Preserve form URL encoding (spaces become `+`), Dart RegExp semantics,
  known digest/UUID results and conversion error behavior. No qflistudio
  online feature or sibling product source is modified.

## Validation

Run `dart analyze lib test` and `flutter test --timeout 60s` in core and Java.
Cover actual tab wiring, builder precedence/no-store compatibility, terminal and
existing product callbacks, all common routes, Java-specific interactions,
unique card composition and narrow/wide light/dark hit targets.

After `scrollUntilVisible`, pump the final layout before hit testing cached
sliver children. Await bounded route settlement before checking that the source
page is offstage. Core home/editor fixtures also require real-I/O and lazy-tree
waits; update obsolete tab/path/backup assertions without changing product
behavior. Record historical and final evidence separately in `notes/validation.md`.
Widget tests make no device-build claim.

## Working state

Preserve the preexisting signing configuration and marker files. Core is outside
the writable Java workspace: prepare core changes locally and apply them through
an approved command. Do not overwrite other workers' changes. Commit each
repository separately after review; do not push.
