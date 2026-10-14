# Diagnosis Notes: OHOS Terminal / Editor Keyboard Focus

Date: 2026-10-14
Basis: source inspection of the vendored `flutter_ohos` engine and `vendor/re_editor`,
plus the partial diff left by an interrupted sub-agent.

## State Found On Entry

An interrupted sub-agent had left changes in `qfli_studio_core` that **did not
compile**:

| File | Problem |
| --- | --- |
| `lib/editor/editor_page.dart:444` | `Platform.isOHOS` — undefined getter |
| `lib/editor/terminal_pane.dart:774` | `Platform.isOHOS` — undefined getter |
| `lib/editor/terminal_pane.dart:774` | `PhysicalKeyboardKey.none` — undefined getter |

`flutter analyze` reported exactly these 3 errors in owned code (the other
vendor errors pre-date this work).

### API facts (verified against this SDK)

- The fork exposes `Platform.isOhos` (**lowercase `h`**), not `isOHOS`:
  `flutter_ohos/bin/cache/dart-sdk/lib/io/platform.dart:179`.
- `TargetPlatform.ohos` **does** exist:
  `flutter_ohos/packages/flutter/lib/src/foundation/platform.dart:85`.
- `PhysicalKeyboardKey` has **no `none`** member; only `enter` and
  `numpadEnter` exist in `keyboard_key.g.dart`.

Use `defaultTargetPlatform == TargetPlatform.ohos` for platform checks: it is
what `vendor/re_editor` already uses (`_consts.dart` `kIsOhosMobileLike`) and it
works in widget tests where `dart:io` platform differs from the target.

## Problem 2 — Enter Key: the `_onKey` Interception Hypothesis Is WRONG

The interrupted agent assumed the soft keyboard Enter arrives as a synthesized
`KeyEvent` and that `_onKey` swallows it. **The engine source disproves this.**

`ListenableEditingState.ets:1826` `handleFunctionKey` dispatches on
`functionKey.enterKeyType`:

```
case inputMethod.EnterKeyType.UNSPECIFIED:
  this.TextInputChannel.unspecifiedAction(this.client);
```

`TextInputChannel.ets:215` `unspecifiedAction` sends a **platform message**, not
a key event:

```
this.channel.invokeMethod("TextInputClient.performAction",
    [inputClientId, "TextInputAction.unspecified"]);
```

Flutter then runs `EditableText.performAction` (`editable_text.dart:3603`):

```
case TextInputAction.unspecified:
  _finalizeEditing(action, shouldUnfocus: false);
```

`shouldUnfocus: false` means `onSubmitted` fires **and the keyboard stays**. So:

1. Soft-keyboard Enter never passes through `Focus.onKeyEvent`. `_onKey` cannot
   be intercepting it, and a `physicalKey`/`PhysicalKeyboardKey.none` check is
   the wrong instrument.
2. `textInputAction: TextInputAction.unspecified` + `onSubmitted: (_) => _submit()`
   is the **correct** design. `TerminalInputBehavior.action` and its doc comment
   should stay as they are.
3. The reported symptom ("键盘显示'开始'，回车没反应") is consistent with the IME
   connection having been torn down by Problem 1: once the platform IME is
   detached, `performAction` has no client to fire on, so Return appears dead.
   **Problem 1 is the likely cause of Problem 2**, not `_onKey`.

Conclusion: do not change `_onKey`'s Enter handling. Fix the focus/IME tear-down
and re-test Enter.

## Problem 1 — Keyboard Flash: Focus-Transfer Race

Root cause traced through the sources:

1. The terminal prompt is `Focus(onKeyEvent: _onKey, child: TextField(...))`
   (`terminal_pane.dart:1324`). The TextField owns a live OHOS IME connection
   while focused.
2. Tapping the editor drives `re_editor`'s `_focusNode.requestFocus()`
   (`vendor/re_editor/.../_code_input.dart:331`, `_code_editable.dart`).
3. `_code_input.dart:423` `_openOrCloseInputConnectionIfNeeded` then runs
   `_openInputConnection()` → `TextInput.attach(...)` + `connection.show()`
   (lines 434-460).
4. At the same moment the terminal's FocusNode loses focus, so Flutter closes
   the terminal's own connection (`TextInput.clearClient`/`hide`).
5. On OHOS the IME processes the late `hide` after the editor's `show`, so the
   keyboard appears briefly and immediately dismisses.

Two contributory factors found in the existing partial diff. One is retained as
sound; the other was later removed:

- ~~`resizeToAvoidBottomInset: false` on the editor `Scaffold`~~ — **removed**.
  See the correction at the end of this file.
- Explicitly unfocusing the terminal before the editor takes focus, so the
  terminal's teardown is ordered **before** the editor's `attach`/`show` instead
  of racing it. (Retained.)

### re_editor focus timing (as requested)

- Focus is granted by `requestFocus()` inside `_code_input.dart` `ensureInput`
  (line 331) and `_code_editable.dart` `_onCodeFindChanged` (line 358).
- `_code_editable.dart:166` `didChangeDependencies` performs autofocus via
  `FocusScope.of(context).autofocus(widget.focusNode)`.
- The `_focusNode` listener (`_code_input.dart:33`) is what opens the IME
  connection, so the IME attach is **listener-driven and immediate** on the same
  frame that focus changes. That immediacy is why the terminal's teardown must
  be pushed ahead of it rather than hoping for scheduling order.

## Fix Chosen

1. `editor_page.dart` `_handlePointerDown`: on OHOS with the terminal visible,
   call `_terminalKey.currentState?.unfocusInput()` (existing API) **before**
   pointer bookkeeping, so the terminal releases focus/IME first.
2. `editor_page.dart`: the `resizeToAvoidBottomInset: false` line was added here
   and has since been **removed** (see the correction below). The focus-ordering
   change in `_handlePointerDown` is kept.
3. `terminal_pane.dart` `_onKey`: revert the broken `PhysicalKeyboardKey.none`
   branch and its false-premise comment. Enter handling stays as before.
4. `terminal_pane.dart` `_focusInput`: keep `restoreKeyboard`, because after the
   editor ever stole focus the terminal's Flutter focusNode may still report
   focus while the platform IME is detached; `focusAndShowKeyboard` bails out on
   `hasFocus` and would leave the keyboard down with a dead Return key.
5. `terminal_input.dart`: keep `restoreKeyboard`, fix the corrupted doc comment
   (the interrupted agent replaced `→` with `->`), and correct the OHOS claim to
   match the engine source.

Platform check: use `defaultTargetPlatform == TargetPlatform.ohos` guarded by
`!kIsWeb`, matching `re_editor`'s own OHOS detection.

## Correction (2026-10-14, later the same day)

**`resizeToAvoidBottomInset: false` has been REMOVED.** Item 2 above is
superseded.

### Why it was removed

It caused a real regression: with the flag set, the OHOS soft keyboard no longer
pushes the layout up. The `Scaffold` ignores `MediaQuery.viewInsets.bottom`, so
the keyboard floats over the content instead of resizing it.

Evidence: nothing in `editor_page.dart` compensates the inset another way (its
only `MediaQuery` uses are `sizeOf(...).width` at lines 555 and 992; there is no
`viewInsets` read anywhere), so disabling the flag left the layout with **no**
avoidance mechanism at all.

### Why the original justification does not hold

The stated reason for the flag was "a keyboard-driven resize rebuilds the body
and can detach the freshly attached IME on OHOS". That was **reasoning, never
device-verified**. It has now been traded for a confirmed, visible defect, and it
was **masking the real bug** (below).

### What removing the flag revealed

With resize enabled again, the "keyboard pops then immediately closes" symptom
returned at certain terminal panel heights. Root cause: the keyboard-driven body
shrink flips `compactPanel`, and `TerminalPane`'s compact branch unmounted the
prompt `TextField`, destroying its `FocusNode` attachment and closing the IME.

Fixed in `terminal_pane.dart` by keeping one stable body slot in every layout
mode (collapsed to zero height rather than removed). Full analysis, threshold
arithmetic, and the regression test are in `root-cause-keyboard-dismiss.md`.

**So the original IME-teardown concern was real in effect but wrong in
mechanism:** the IME was torn down because the input was unmounted, not because
of the resize itself. `resizeToAvoidBottomInset` stays at its default `true`.
