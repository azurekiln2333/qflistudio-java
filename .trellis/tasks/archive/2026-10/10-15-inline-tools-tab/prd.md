# Inline product tools and shared offline tools

Parent: `10-15-studio-polish`. Supersedes the earlier no-core restriction in
`10-15-java-tools-redesign`. Both delivery stages are authorized.

## Problem

Originally the tools tab exposed terminal and a `功能` entry that pushed
`ContentToolsPage` before Java users could reach the actual grouped card grid.
`StudioProfile` supported a full-page `toolsPageBuilder` but no embeddable body.
Java also owned language-neutral codecs, conversions, pages and card widgets,
which prevented other products from sharing those offline capabilities.

## Requirements

1. Core owns the tools tab Scaffold/AppBar and exposes optional
   `StudioProfile.toolsTabBuilder(store, onOpenTerminal)`. An explicit
   `FunctionsTab` builder takes precedence over the profile builder; inline
   builders require a store. Legacy callers may omit it when using the default.
2. Core `ToolsGrid` is one embeddable scroll body. It renders an optional
   `快捷入口` terminal card, product sections, then nine tools in `通用`:
   Unicode, Base64, form URL encoding, regex, JSON formatting, digests,
   timestamps, UUID and color. Use the same Material card style throughout.
3. Products without an inline builder retain their existing product entry and
   callback through the default grid, alongside terminal and shared tools.
   Their full pages, tabs and PopScope continue to work. Existing navigation
   capability is retained; the old two-tile layout is superseded.
4. Java contributes only four dedicated cards in a `Java` section: integer and
   bit operations, Java string/text blocks, JSON-to-POJO/record and reference.
   Its tab directly shows these cards, terminal and all shared tools without
   an intermediate `功能` entry or nested Scaffold/AppBar. Individual tool
   pages continue to open as routes; `JavaToolsPage` remains a standalone wrapper.
5. Shared pure logic, detail pages and card/form widgets live in core. Remove
   Java's duplicate generic implementations. Reuse core's existing
   `JsonToolPage`/`JsonDocumentService` for `JSON 格式化`; keep Java generation
   as a separate tool. Core never imports a product package.
6. Preserve UTF-8 behavior, form encoding where spaces become `+`, Dart
   `RegExp` semantics, digest/UUID behavior and existing conversion contracts.
   Common tools work offline. No new dependency or network behavior is added;
   qflistudio's online features remain available.
7. Complete the two stages in order, validate both repositories and commit
   each repository separately. Preserve the preexisting signing configuration
   and marker files. Do not push.

## Acceptance

- Java standalone grid has 13 unique cards; the actual tools tab has 14 with
  terminal first. Every card can be reached and tapped; no `功能` entry appears.
- Default `FunctionsTab` exposes the nine common tools and terminal, and
  preserves a supplied product entry callback/title/icon. No-store legacy
  construction and builder precedence remain covered.
- All nine shared cards open core pages. Shared JSON formatting and Java
  generation open distinct pages. All four Java-specific pages still work.
- Narrow/wide and light/dark layouts preserve card geometry, scrolling and
  hit targets with one tab Scaffold/AppBar and no overflow.
- Pure shared tests cover codec/error behavior, digest vectors, RFC UUID
  values, regex groups/truncation, color/Unicode and timestamps.
- `dart analyze lib test` and `flutter test --timeout 60s` pass in both
  repositories. Record actual commands and results in `notes/validation.md`.
- Shared composition is implemented in core without sibling-product source
  changes. If a sibling must change, run that product's tests as well.
- Keep `ohos/build-profile.json5` unchanged by this task. Widget tests do not
  imply a device build or installation.
