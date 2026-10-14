# Implementation Notes: OHOS Terminal / Editor Keyboard Focus

Date: 2026-10-14
Task: `.trellis/tasks/10-14-ohos-terminal-editor-focus`
Repos touched: `qfli_studio_core` (all production code). `qfli_java` unchanged.

## Entry State (interrupted sub-agent)

`qfli_studio_core` had uncommitted changes that **did not compile**:

```
error - The getter 'isOHOS' isn't defined for the type 'Platform'
        - lib/editor/editor_page.dart:444:18
error - The getter 'isOHOS' isn't defined for the type 'Platform'
        - lib/editor/terminal_pane.dart:774:20
error - The getter 'none' isn't defined for the type 'PhysicalKeyboardKey'
        - lib/editor/terminal_pane.dart:774:71
```

The fork exposes `Platform.isOhos` (lowercase `h`); `PhysicalKeyboardKey` has no
`none` member. Both were corrected rather than patched around. Full reasoning is
in `notes/diagnosis.md`.

## Files Changed

### `lib/terminal/widgets/terminal_input.dart`

| Change | Why |
| --- | --- |
| Added `isOhosPlatform` (`!kIsWeb && defaultTargetPlatform == TargetPlatform.ohos`) | Single source of truth for OHOS detection; matches `vendor/re_editor`'s own `kIsOhosMobileLike` and works under widget tests |
| Corrected the class doc's OHOS paragraph | The old text was vague; the engine path is now stated exactly (`handleFunctionKey` → `unspecifiedAction` → `TextInputClient.performAction`), and it records that Return arrives as a platform message, **not** a `KeyEvent` |
| Kept `restoreKeyboard` | Needed to re-attach the IME when the prompt is focused on the Flutter side but the platform IME was detached |
| `import 'package:flutter/foundation.dart'` | For `kIsWeb` / `defaultTargetPlatform` |

### `lib/editor/terminal_pane.dart`

| Change | Why |
| --- | --- |
| `_focusInput` uses `restoreKeyboard` | `focusAndShowKeyboard` returns early on `hasFocus`; after the editor ever took focus the prompt can report `hasFocus` while the IME is detached, leaving a dead Return key |
| `_onKey`: removed the broken `PhysicalKeyboardKey.none` branch | Premise disproved by the engine: soft Enter never reaches `Focus.onKeyEvent`. The branch was both uncompilable and unnecessary |
| `_onKey` comment rewritten | Records the verified engine behaviour so nobody re-adds soft-keyboard detection there |

### `lib/editor/editor_page.dart`

| Change | Why |
| --- | --- |
| `_handlePointerDown`: on OHOS with the terminal visible, `unfocusInput()` before pointer bookkeeping | Orders the terminal's IME teardown **before** the editor's `TextInput.attach`/`show`, removing the race that dismisses the keyboard |
| ~~`resizeToAvoidBottomInset: false` on the editor `Scaffold`~~ | **REMOVED.** It made the OHOS keyboard stop pushing the layout up, and its original justification (a resize detaching the IME) was never device-verified. See the Correction section at the end. |
| `import '../terminal/widgets/terminal_input.dart'` | To reach `TerminalInputBehavior.isOhosPlatform` |

### `test/terminal_input_behavior_test.dart` (new)

5 tests:
- `action` remains `TextInputAction.unspecified`
- `isOhosPlatform` is true only for `TargetPlatform.ohos`
- `restoreKeyboard` focuses an unfocused node
- `restoreKeyboard` issues `TextInput.show` when the node is already focused
- `restoreKeyboard` is a no-op when the node cannot request focus

## Answers To The Two Specific Questions

### Q: Does `_onKey` intercept the soft keyboard Enter? — **No. Not possible.**

Verified in `flutter_ohos` engine source:

1. `ListenableEditingState.ets:1826` `handleFunctionKey` — `EnterKeyType.UNSPECIFIED`
   → `TextInputChannel.unspecifiedAction(client)`.
2. `TextInputChannel.ets:215` — sends
   `TextInputClient.performAction([id, "TextInputAction.unspecified"])`.
3. `editable_text.dart:3603` — `TextInputAction.unspecified` →
   `_finalizeEditing(shouldUnfocus: false)` → `onSubmitted`, keyboard stays.

The message is a `performAction` platform message, not a `KeyEvent`, so
`Focus.onKeyEvent` is never in the path. `_onKey` is therefore innocent, and the
interrupted agent's `physicalKey` heuristic had nothing to detect.

**Consequence:** the reported dead Return key is best explained by Problem 1 — if
the platform IME is detached, `performAction` has no live client to fire on. Fix
Problem 1 first, then re-test Enter. `_onKey` and `TextInputAction.unspecified`
were left as the (correct) existing design.

### Q: Confirm the focus timing via `re_editor` source (Problem 1) — **it is a focus-transfer race.**

1. Editor tap → `re_editor` `_code_input.dart:331` `_focusNode.requestFocus()`
   (also `_code_editable.dart:166` autofocus via
   `FocusScope.of(context).autofocus(...)`).
2. `_code_input.dart:419` `_onFocusChanged` → `_openOrCloseInputConnectionIfNeeded`
   → `_openInputConnection()` (`:434`) → `TextInput.attach(...)` + `connection.show()`.
   This is **listener-driven and immediate** on the frame focus changes.
3. The terminal prompt's FocusNode loses focus → Flutter closes the terminal's
   own connection (`clearClient`/`hide`).
4. On OHOS the late `hide` is processed after the editor's `show`, so the
   keyboard appears and immediately dismisses.

The fix makes step 3's teardown run **before** step 2's attach by unfocusing the
terminal synchronously in `_handlePointerDown`.

(An earlier attempt also disabled `resizeToAvoidBottomInset` to stop a body
resize from detaching the IME in between. That was reverted; see the Correction
section at the end.)

## Verification

| Check | Result |
| --- | --- |
| `flutter analyze` (core), owned files | **0 issues** (was 3 errors) |
| `dart analyze lib tools test` (java repo) | clean |
| `flutter test test/terminal_input_behavior_test.dart` | 5/5 pass |
| `flutter test test/terminal_pane_test.dart test/editor_run_test.dart` | 41/41 pass |
| `flutter test test/sandbox_terminal_test.dart test/terminal_manager_delegate_test.dart` | 26/26 pass |
| `flutter test` (java repo) | 34/34 pass |
| `flutter build hap --ohos-arm64` | Dart/ArkTS/asset stages succeed; fails only at `SignHap` |

### Pre-existing failures — NOT caused by this change

`test/widget_test.dart` fails 6 tests on the **clean tree** as well. Verified by
`git stash`-ing all three changed files and re-running: the same 6 failures
reproduce. They concern project creation / filesystem backup, not keyboard focus.

### Blocked manual verification

- No OHOS device or emulator is attached (`hdc list targets` empty). AC1/AC2
  could not be exercised on hardware.
- `flutter build hap` still fails at `SignHap`: `ohos/build-profile.json5`
  references `...Gu8zVby71b0t4gfRa-...p12`, which no longer exists after DevEco
  regenerated `~/.ohos/config` material under a new name on 2026-10-13. This is
  the same pre-existing blocker recorded in task `10-13-spring-boot-ohos`. Every
  ohos build in this project is blocked until signing is restored.

## Not Done (deliberately)

- No change to `_onKey`'s Enter handling — it is correct.
- No new `TextInputAction` experiment — the engine source proves `unspecified`
  works; changing it would have been a guess.
- No debug logging added, so Phase 6.1 cleanup was unnecessary.

## Correction: `resizeToAvoidBottomInset` removed (2026-10-14)

The `resizeToAvoidBottomInset: false` line on the editor `Scaffold` was **added**
by this task and has since been **removed**. The original table entry above is
struck through and superseded by this section.

### What was wrong

With the flag set, the OHOS soft keyboard stopped pushing the layout up: the
`Scaffold` no longer subtracts `MediaQuery.viewInsets.bottom`, so the keyboard
floated over the content. `editor_page.dart` has no alternative inset handling
(its only `MediaQuery` uses are `sizeOf(...).width` at lines 555 and 992; there
is no `viewInsets` read), so the layout had no avoidance path at all.

### Why the stated reason did not justify it

The justification recorded in the table — "a keyboard-driven resize rebuilds the
body via `LayoutBuilder`, which on OHOS can detach the just-attached IME" — was
inference, never confirmed on a device. It was traded for a visible, confirmed
defect.

### Current state

- `resizeToAvoidBottomInset` is **not** set on this `Scaffold`; HEAD behaviour is
  restored (the property is absent, so it defaults to `true`).
- The focus-ordering fix in `_handlePointerDown` (`unfocusInput()` before pointer
  bookkeeping) is **kept** — it is independent of this flag.

### What removing the flag exposed, and the real fix

With resize enabled again the "keyboard pops then immediately closes" symptom
returned at middle terminal-panel heights. That exposed a genuine layout bug:
the keyboard-driven body shrink flips `compactPanel`, and `TerminalPane`'s
compact branch replaced the subtree containing the prompt `TextField`, unmounting
its `FocusNode` and closing the IME.

Fixed in `lib/editor/terminal_pane.dart`: `build` now keeps one stable body slot
in every mode and collapses it to zero height instead of removing it, so the
transcript's element path (and the prompt's `FocusNode`) survives the switch.
`Offstage`/`Visibility(maintainState)` were rejected because they hand the
`ListView` unbounded height.

Guarded by the new `test/terminal_compact_focus_test.dart`. Full analysis:
`root-cause-keyboard-dismiss.md`.

### Required re-test on an OHOS device

1. The keyboard lays the page out again (expected: yes).
2. The keyboard no longer closes immediately at any terminal panel height
   (expected: yes, now that the input is not unmounted).

If a flash still occurs, it is a second, independent path and must be
diagnosed separately — do not re-disable `resizeToAvoidBottomInset`.

## Editor/terminal touch routing + compact guard (2026-10-14, later session)

Requested interaction scheme, implemented in `editor_page.dart` and
`terminal_pane.dart`:

1. **Editor touch while the terminal is expanded collapses it.**
   `_handlePointerDown` sets `_terminalCollapsed = true` without touching
   `_terminalHeight`, so re-expanding restores the dragged height. It is a
   `Listener(onPointerDown)` side effect on the handler that already existed, so
   it cannot steal gestures from the editor's taps/selection/scroll/IME, and it
   is skipped while `_draggingTerminal`, so drag-resize still works.
2. **Terminal touch expands and focuses.** `TerminalPane` wraps its root
   `Column` in `Listener(onPointerDown:)` → `onActivated`. `EditorPage` expands
   (clearing `_terminalDragHeight` so the preserved height applies) and focuses
   the prompt in an `addPostFrameCallback`, since the prompt row only exists once
   the expanded layout has built. `requestInputFocus()` is the public entry
   point; `focusInputForTest` was renamed to `focusInput` now that production
   code uses it.
3. **Compact guard.** `compactPanel = compactByHeight && !_terminalInputHasFocus`,
   fed by `onInputFocusChanged` from a listener on the session `focusNode`.

**Which of the two options was chosen, and why.** The requested choice was
between "focus-aware compact check that ignores `viewInsets`" and "skip compact
entirely while the terminal input has focus". The second was chosen. It states
the invariant directly — *a focused input must never be laid out at zero height* —
so it holds for every inset and viewport and survives future edits to the height
arithmetic. The first only holds while its own inset accounting stays in sync
with the `Scaffold`'s, which is the exact coupling that caused the original bug.
The guard was verified to be load-bearing: removing it makes
`test/editor_terminal_touch_test.dart` fail.

**Two safety conditions the guard required** (both found by running the tests,
not by inspection):

- `effectivePreferred.clamp(minExpandedHeight, maxPanelHeight)` threw
  `ArgumentError: Invalid argument(s): 120.0` once the guard kept a panel
  non-compact while `maxPanelHeight < 120`. The floor is now
  `min(maxPanelHeight, minExpandedHeight)`.
- The body-level `Offstage` (`bodyHeight < 198`) and the panel's height
  animation both had to become focus-aware. Without that, the very state the
  guard creates hides the panel outright or animates through an overshoot that
  overflows the body `Column`. The editor now gives up height instead.

### Test-result caveat worth remembering

The compact threshold is `bodyHeight < 260`. On a tall viewport (e.g. 900px) a
real-scale keyboard (~35–45%) never crosses it, so a keyboard test there passes
vacuously — it does not prove the guard does anything. The test therefore mounts
at `900x560` with `viewInsets.bottom = 280`, computed to be `compactByHeight ==
true` while still leaving the editor usable. Verify the arithmetic before
choosing a size for a test like this.

### New test

`test/editor_terminal_touch_test.dart` (4 tests, all passing):

1. touching the editor collapses the terminal and keeps the height preference;
2. touching the terminal expands it and focuses the prompt;
3. a keyboard-driven shrink keeps the focused prompt expanded, mounted and
   focused (same `EditableText` element) and non-zero-height;
4. the editor still takes focus when the terminal is open.

### Verification (this session)

- `dart analyze lib` and `flutter analyze` over owned code: 0 issues.
- Terminal suites together: **77/77 pass**
  (`editor_terminal_touch_test`, `terminal_compact_focus_test`,
  `terminal_pane_test`, `editor_run_test`, `terminal_input_behavior_test`,
  `sandbox_terminal_test`, `terminal_manager_delegate_test`).
- `qfli_java` suite: **34/34 pass**.
- `qfli_studio_core` full suite: 7 failures, all pre-existing
  (`widget_test.dart` x6, `content_code_import_test.dart` tearDownAll) —
  reproduced on the clean tree before this change.
- Not committed to git, per instruction.
- Device verification still outstanding: no OHOS device attached.

## Tab bar: width, hit testing, and single-tab close (2026-10-14, third session)

The 40 px header height from the previous session was confirmed good by the user
and is unchanged. Three follow-up defects were reported and fixed.

**1. Tabs too wide.** The label was the full `Terminal <id>`, so a single pill
measured ~148 px. The label is now the id alone (`1`, `R1` for remote), the pill
is capped at `maxTabWidth = 96` via `ConstrainedBox`, and the label ellipsises
inside a `Flexible`. Padding moved to `tabHorizontalPadding = 8`. Measured: one
pill 147.5 px → 50.8 px. The old `canRequestFocus`/34 px literals are gone.

**2. Header focus/hit handling.** Root cause turned out to be narrower than the
report suggested: the editor's collapse-on-touch `Listener` wraps **only
`CodeEditor`** (`editor_page.dart:2103`), not the terminal, so it never saw
tab-bar touches. The real defect was that a tap on a tab left the terminal with
no focused input, leaving a detached node focused:

```
D after tab pill tap: term=false primary=Focus label=null
```

Fix: `_selectSession` restores prompt focus, guarded by `promptHadFocus` and
run after the scroll restore. The header additionally gained
`GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {})` so its blank
area absorbs touches.

**Mistake worth remembering.** I first wrapped the *whole* header in
`Focus(canRequestFocus: false, descendantsAreFocusable: false)`. That silently
disabled the tabs' own keyboard activation and broke `terminal_pane_test.dart`
"session tabs support keyboard selection and accessible close". Guard individual
buttons, never a container that also holds interactive tabs.

**3. Single tab could not be closed.** `_closeSession` returned early on
`sessions.length == 1`, and `closable` required `sessions.length > 1`. A lone
local session is now closable and is replaced in place by a fresh session (same
id, cleared transcript and caret), so the pane is never empty. Remote sessions
remain non-closable.

### Tests

- New `test/terminal_tab_bar_test.dart` — 11 tests.
- `test/editor_terminal_touch_test.dart` — grew to 7 (header touch does not
  collapse; header-button tap keeps terminal focus; switching tabs keeps caret).
- `test/terminal_pane_test.dart` — 25 tests updated for the new labels/sizes
  instead of `Terminal <id>` and 32 px close buttons.
- Load-bearing checks performed by reverting each fix: the short label and the
  tab-switch focus hand-off both fail when reverted. The header-absorption
  assertions could **not** be made to fail, because a coloured `Container`
  already absorbs those hits — recorded honestly rather than claimed.

### Verification (this session)

- `dart analyze lib` and `flutter analyze` over owned code: 0 issues.
- Terminal suites: **91/91 pass.**
- `qfli_java` suite: **34/34 pass.**
- Not committed to git.
