# Inline tools and shared offline tools

## Boundary

The missing behavior lives in core `FunctionsTab`, which currently owns the
terminal and the extra Functions route. Java owns the existing grouped cards.
Keep their geometry, colors, routes and offline behavior while embedding the grid
in the shell. Reuse the shell's terminal callback. No network or dependency changes.

## Delivery 1: inline tools

- Add optional `StudioProfile.toolsTabBuilder(store, onOpenTerminal)` and pass it
  through `HomePage` to `FunctionsTab`.
- When present it owns the tab body; otherwise preserve existing product behavior.
- Extract `JavaToolsGrid` without a Scaffold/AppBar; keep `JavaToolsPage` as its
  standalone wrapper. Put the terminal first using the existing card widget.
- Validate and commit core and Java separately before delivery 2.

## Delivery 2: queued shared tools

Move language-neutral logic, pages and card presentation into core; Java keeps
integer types/bit operations, Java literal/text block conversion, JSON-to-Java and
Java reference. Shared logic must remain independent of Flutter and Java.
Core owns a common group (Base64, URL, digests, UUID, timestamps, regex, color,
Unicode and JSON formatting). Java consumes it instead of retaining copies.
Compose terminal, optional product content and common cards in the shared tools
tab, retaining existing custom product tools. Keep qflistudio's online features.
Prefer core-only composition to changes in other products. Specify the concrete
composition API after inspecting existing custom pages; record that decision here.

## Validation

Run `dart analyze lib test` and `flutter test --timeout 60s` in core and Java.
Cover narrow/wide and light/dark cards, inline terminal callback, no intermediate
Functions route for Java, shared tools for products with and without custom
pages, and unchanged access to existing product tools. If another product must
change, run its Flutter suite too. No device/build claim from widget tests.

## Working state

Preserve preexisting signing config and marker files. Core is outside the writable
workspace: prepare any additional core changes locally, then use an approved
command to apply them. Do not overwrite changes introduced by another session.
