# Java tools page redesign

Parent: `10-15-studio-polish` (read its hard constraints first).

## Problem

`qfli_java/lib/java_tools_page.dart` (commit 76e3390) puts the tools inside one feature card / tab set. The tools page looks empty and the visual design is poor.

## Requirements

- All tools are laid out **directly on the tools page**, scrollable, grouped (e.g. 数值与编码 / 文本 / 数据 / 时间与标识 / 速查).
- Each tool is a card: icon, name, one-line description. Tapping opens that tool's own page.
- Visual reference: `D:/MyNewProjects/netrix` (read its home/tools page and card widgets first; copy spacing, radius, color usage, type hierarchy, section headers, adaptive column count). Material 3 `ColorScheme`, good in light and dark, adaptive from phone portrait to tablet.
- Page title stays 「工具」.
- Keep the existing 5 tools (integer/radix, Unicode, Java string escape + text block, JSON → POJO/record, timestamp). Add more offline tools so the page is full, for example: Base64, URL encode/decode, hash (MD5/SHA-1/SHA-256, pure Dart or an existing dependency only), regex tester (note: Dart RegExp semantics), color converter, UUID generator, Java keyword / primitive type quick reference.
- Logic separated from UI (`lib/java_tools.dart`), unit-tested.
- Java owns its product-specific tools; core may change to embed the grid directly
  in the tools tab and host shared offline tools. No network, no new dependency
  unless already in the lockfile.

## Correction (2026-10-15)

The original "do not modify core" constraint was incorrect: it left the grid
behind the shell's intermediate Functions entry. `10-15-inline-tools-tab`
supersedes it. Embed the existing grid in the tab without redesigning it, with a
matching terminal card and no nested Scaffold/AppBar. The queued follow-up moves
language-neutral tools into core for use by every product.

## Acceptance

- Tools page shows all tool cards without opening anything; no single wrapper card.
- Every card opens a working tool page with copy buttons.
- `flutter test` in qfli_java passes; `dart analyze` clean.
- Light/dark and narrow/wide widget tests for the grid.
