# Render product tools inline on the tools tab

Parent: `10-15-studio-polish`. Supersedes the "do not modify core" rule in
`10-15-java-tools-redesign`.

## Problem

The tools tab (bottom navigation, page 2) renders only two entries: a
「内置终端」 tile and a 「功能」 tile that pushes `ContentToolsPage` →
`StudioProfile.toolsPageBuilder` (in qfli_java, the `JavaToolsPage` card grid).
So the user has to tap through a second-level page to reach any tool, even
though the grid itself is already the intended design.

Root cause: `StudioProfile` can only hand core a **full page** widget
(`toolsPageBuilder`), never content, so core has to keep the intermediate
navigation. `10-15-java-tools-redesign` accepted that as a constraint ("do not
modify core") and consequently never fixed the second-level hop.

## Requirements

1. **Core**: `StudioProfile` gains an optional product-rendered tools section
   (`toolsTabBuilder`). When set, `FunctionsTab` renders it as the tab content
   and does **not** render the 「功能」 entry. When unset (every other product,
   including qflistudio), `FunctionsTab` is byte-for-byte unchanged.
2. **Core**: the 终端 entry stays reachable in both cases. It becomes a card in
   the product's own grid, not a separate styled tile, when the product provides
   the inline builder.
3. **qfli_java**: the tools tab shows the existing grouped card grid verbatim —
   same layout, same cards, same groups as `java_tools_page.dart` today — with
   the 终端 card added to the first group, renamed from 「内置终端」 to 「终端」
   and styled exactly like every other tool card (same size, icon treatment,
   title and one-line description).
4. **qfli_java**: no nested `Scaffold`/`AppBar`; the grid must be embeddable
   inside the shell's `FunctionsTab` scaffold. Tapping a card still opens that
   tool's own page (that level is required and stays).
5. No network, no new dependency. qflistudio's networked features untouched.

## Acceptance

- qfli_java tools tab finds every tool card and the 终端 card directly, and
  finds no 「功能」 entry.
- A product without `toolsTabBuilder` renders the unchanged `FunctionsTab`
  (terminal tile + optional 功能 tile).
- `flutter test --timeout 60s` in both repos; `dart analyze` clean in both.
- `.trellis/tasks/10-15-java-tools-redesign/prd.md` no longer forbids core
  changes and records this correction.
- Two commits, one per repo, `ohos/build-profile.json5` untouched, no push.
