# Scenario applicability on this device/layout

## Scenario 5 (code box fully scrolled out of view) — NOT APPLICABLE in portrait

Measured geometry, `ExampleDetailPage` on 1272x2860 portrait (real uitest bounds):

| Element | Bounds (px) | Size |
| --- | --- | --- |
| Outer `Scroll` viewport | `[0,364]` → `[1272,2860]` | 1272 × 2496 |
| Summary text | `[56,406]` → `[1216,546]` | 140 tall |
| Code box (`TextInput`) | `[56,602]` → `[1216,2040]` | 1160 × 1438 |
| Expected-output label | `[56,2096]` → `[1216,2166]` | — |
| Expected output (`TextInput`) | `[56,2187]` → `[1216,2327]` | 140 tall |

The whole page content ends at y≈2327, inside the 2860 viewport. The code box
starts at y=602, so hiding it completely above the viewport top would require
≈602 px of scroll that the content does not provide. **The code box cannot be
fully scrolled out of view in this portrait layout**, so:

- Scenario 5 is recorded as **NOT APPLICABLE (portrait layout)**.
- The detail/clear/re-enter samples include the expected output on screen.
- Selecting the expected output and idling was not separately measured on device.

The "release focus when fully hidden" logic itself is covered by the local widget
regression in core (`code_snippet_idle_frames_test.dart`), which is a separate
and clearly-labelled kind of evidence — it is not a device measurement.
