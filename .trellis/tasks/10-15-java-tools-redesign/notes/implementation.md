# Implementation notes: Java tools page redesign

Commit: `4a74a51` feat(java): lay the tools page out as a grouped card grid

## What changed

Four new/changed files in `qfli_java/lib`, nothing in core:

| File | Role |
| --- | --- |
| `java_tools_page.dart` | The grid: 12 `JavaToolDefinition`s in 5 groups |
| `java_tools_pages.dart` | The 12 tool pages, all on one `JavaToolScaffold` |
| `java_tools_widgets.dart` | Shared card, section heading, result row, copy helper |
| `java_tools_extra.dart` | New logic: Base64, URL, digests, regex, colour, UUID, reference |
| `java_tools.dart` | Unchanged (integer, Unicode, string, JSON, timestamp) |

## Design reference

Read `netrix/lib/ui/home_page.dart`, `netrix/lib/widgets/common.dart` and
`netrix/lib/core/theme.dart` before writing any UI, as the PRD requires. What
was taken from them:

- flat cards with a hairline `outlineVariant` border and no elevation
- 12 px radii, 14-16 px card padding
- section heading = primary-coloured icon + `titleMedium` title + `bodySmall`
  subtitle
- `SliverGridDelegateWithMaxCrossAxisExtent` so the column count adapts without
  a breakpoint table
- `surfaceContainerLow` as the card surface, tinted from the `ColorScheme` so
  light and dark both work with no hard-coded colours

## Decisions worth remembering

**Digests are hand-written.** `crypto` is not in `pubspec.lock` and the PRD
allows no new dependency, so MD5, SHA-1 and SHA-256 are implemented over byte
lists in `java_tools_extra.dart`. They are pinned to the published vectors
(RFC 1321 `abc`, RFC 3174 `abc`, FIPS 180-4 `abc` and the empty string, plus a
62-byte multi-block case and 1 MB of `a` for MD5). Do not "simplify" these
without re-running those vectors.

**A real bug the tests caught.** The first UUID v5 implementation hashed the
namespace through a Latin-1 string round trip, which corrupts bytes above 0x7F.
The RFC 4122 reference value for `www.example.com` in the DNS namespace
(`2ed6657d-e927-568b-95e1-2665a8aea6a2`) failed, which is what surfaced it. The
generators now use raw-byte digest entry points (`JavaDigest.md5Bytes` etc.).

**Two of my own test expectations were wrong, not the code.** The SHA-256 of 62
`a`s and the Base64 of `0xFB 0xFF` were guessed. Both were replaced with values
computed from the standard (`f506898c…` and `+A==` is not reachable through the
text-only `encode`, so the URL-safe test now uses a character whose UTF-8 bytes
exercise the differing alphabet).

**`pumpAndSettle` is avoided in the widget tests.** The page transitions settle
in practice, but the tests use a fixed `pump()` + `pump(400ms)` pair so they can
never hang. All `flutter test` runs used `--timeout 60s`.

## Verification

- `dart analyze lib test` in qfli_java: 0 issues
- `flutter test --timeout 60s` in qfli_java: **96/96 pass**
  (the run before reported one failure in `ohos_jdk_process_test.dart`, a known
  flaky native-process timing test, which passed on rerun and is unrelated)
- `qfli_studio_core` is untouched (`git status` clean)

## Acceptance vs PRD

| Requirement | Status |
| --- | --- |
| All tools laid out on the page, grouped, scrollable | yes, 5 groups |
| Each tool is a card: icon, name, one-line description | yes |
| Tapping opens that tool's own page with copy buttons | yes |
| Visual reference = netrix spacing/radius/colour/type/columns | yes |
| Page title stays 工具 | yes |
| Existing 5 tools kept | yes |
| More offline tools added | yes, 7 more (12 total) |
| Logic separated from UI and unit-tested | yes, `java_tools*.dart` |
| qfli_java only, no core change | yes |
| No network, no new dependency | yes |
| Light/dark and narrow/wide widget tests | yes |
