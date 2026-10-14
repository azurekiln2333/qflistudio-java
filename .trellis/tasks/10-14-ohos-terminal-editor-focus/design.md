# Technical Design: OHOS Keyboard Focus Fixes

## Architecture

### Current Focus Management

```
EditorPage
├─ Multiple OpenFile instances
│  └─ Each has FocusNode (for CodeEditor/re_editor)
└─ TerminalPane (via GlobalKey<TerminalPaneState>)
   └─ _TerminalSession instances
      └─ Each has FocusNode (for TextField input)
```

**Focus ownership**: Flutter's FocusManager handles focus tree. Only one FocusNode can have primary focus at a time.

**IME connection**: On OHOS (and Android), when a FocusNode gains focus and is attached to an editable widget, the platform IME (Input Method Editor) connects. When focus is lost, IME disconnects and keyboard typically dismisses.

### Problem 1: Keyboard Flash on Editor Tap

**Hypothesis**: Race condition during focus transfer
1. User taps editor
2. Editor's FocusNode requests focus (via `re_editor` internal logic or explicit `requestFocus()`)
3. Terminal's FocusNode loses focus
4. Terminal's `restoreKeyboard()` (or similar cleanup) is called
5. OHOS IME briefly connects to editor, showing keyboard
6. Some code path immediately dismisses it (unfocus? IME detach? conflicting show/hide?)

**Diagnosis approach**:
- Add logging around focus changes in both terminal and editor
- Check if `re_editor` package has OHOS-specific focus behavior
- Examine `terminal_pane.dart` for any focus listener that might react to lost focus
- Look for global FocusNode listeners in `EditorPage`

### Problem 2: Enter Key Not Submitting

**Primary Hypothesis**: `Focus.onKeyEvent` handler (`_onKey`) is intercepting soft keyboard Enter events

Current code path:
```dart
Focus(
  onKeyEvent: _onKey,  // Intercepts ALL key events
  child: TextField(...)
)
```

The `_onKey` handler calls `TerminalInputBehavior.handleHardwareKey()` which returns `KeyEventResult.handled` for Enter keys. This prevents the event from reaching TextField's `onSubmitted`.

**Critical issue**: Soft keyboard Enter events may have different characteristics than hardware keyboard events:
- Different `KeyEvent` subtype
- Different `logicalKey` value
- Different `deviceType`

If `_onKey` returns `handled` for soft keyboard Enter without actually calling `_submit()`, the command never runs.

**Secondary Hypothesis**: OHOS `TextInputAction.unspecified` not triggering `onSubmitted`

The existing comment assumes `unspecified` works, but OHOS engine may have changed or the action doesn't map correctly.

**Diagnosis approach**:
1. **CRITICAL**: Add logging in `_onKey` to see if soft keyboard Enter reaches it and what its properties are
2. Log TextField `onSubmitted` calls to see if it ever fires
3. Check if hardware keyboard Enter works (validates hardware path)
4. Test if soft keyboard Enter is being intercepted but not matched by `LogicalKeyboardKey.enter`
5. Try removing `KeyEventResult.handled` for soft keyboard events
6. Try different `TextInputAction` values as fallback

## Data Flow

### Focus Transfer Flow (Terminal → Editor)

```
1. User taps editor area
   ↓
2. EditorPage._handlePointerDown(event)
   ↓
3. CodeEditor/re_editor internal tap handler
   ↓
4. openFile.focusNode.requestFocus()  [inferred, not explicit in current code]
   ↓
5. FocusManager transfers focus
   ├─ terminal session focusNode loses focus
   │  └─ (no explicit listener found in current code)
   └─ editor openFile focusNode gains focus
      └─ IME connects to editor
         └─ (Bug) Keyboard appears then dismisses
```

### Terminal Enter Key Flow

```
1. User presses Enter on soft keyboard
   ↓
2. OHOS IME sends key event to Flutter
   ↓
3a. Hardware key path:
    Focus.onKeyEvent → _onKey(FocusNode, KeyEvent)
    ├─ If Enter: TerminalInputBehavior.handleHardwareKey
    │  └─ _submit() → return KeyEventResult.handled
    └─ TextField never sees it (handled)
   
3b. Soft keyboard path (expected):
    TextField.onSubmitted callback (via IME performAction)
    └─ _submit()

(Bug) Neither 3a nor 3b is firing for soft keyboard Enter
```

## Design Decisions

### Decision 1: Fix Approach for Keyboard Flash

**Options**:

A. **Explicit terminal unfocus on editor tap**
   - Pro: Clean separation of concerns
   - Pro: Terminal keyboard definitely won't try to restore
   - Con: Adds OHOS-specific code to EditorPage
   - Implementation: `_handlePointerDown` calls `_terminalKey.currentState?.unfocusInput()` before editor focuses

B. **Guard terminal's `restoreKeyboard()` against editor focus**
   - Pro: Fix stays within terminal component
   - Pro: No EditorPage changes
   - Con: Requires heuristic to detect "editor stole focus"
   - Implementation: Track last unfocus timestamp, skip `restoreKeyboard()` if < 100ms ago

C. **Investigate and fix `re_editor` OHOS behavior**
   - Pro: Addresses root cause if it's in re_editor
   - Con: Depends on external package maintainer
   - Con: May require forking re_editor

**Chosen**: **Option A (explicit terminal unfocus)**

**Rationale**: 
- Clean, predictable behavior
- EditorPage already has `_terminalKey` for other terminal interactions
- OHOS-specific guard (`if (Platform.isOHOS)`) is acceptable per constraints
- Testable and reversible

### Decision 2: Fix Approach for Enter Key

**Options**:

A. **Fix `_onKey` to not intercept soft keyboard Enter**
   - Detect soft keyboard events and return `KeyEventResult.ignored`
   - Let TextField's `onSubmitted` handle soft keyboard Enter
   - Keep hardware Enter handling in `_onKey`
   - Pro: Addresses root cause if interception is the issue
   - Con: Need reliable way to distinguish hardware vs soft keyboard

B. **Use a different TextInputAction**
   - Try `send`, `newline`, or `done`
   - Pro: May work with current OHOS engine if `onSubmitted` path is working
   - Con: Each action has trade-offs (label, dismiss behavior)

C. **Hybrid: Fix interception + use working action**
   - Let soft keyboard events pass through to TextField
   - Use a `TextInputAction` that OHOS handles correctly
   - Add keyboard restoration in `onSubmitted` if needed
   - Pro: Most robust
   - Con: More changes

**Chosen**: **Option A first (fix `_onKey` interception), fallback to C if needed**

**Rationale**:
- Diagnosis will reveal if `_onKey` is intercepting soft keyboard events
- If yes, stop intercepting them (return `ignored` for soft keyboard)
- Hardware keyboard path stays unchanged
- If `onSubmitted` still doesn't fire, then try different `TextInputAction`

## Compatibility

### Platform Matrix

| Platform | Focus Fix | Enter Fix | Regression Risk |
|----------|-----------|-----------|-----------------|
| OHOS x86_64 emulator | Test primary fix | Test primary fix | N/A (new fixes) |
| OHOS ARM64 device | If available | If available | N/A |
| Android | No-op (Platform.isOHOS guard) | Unchanged code | Low (no code change) |
| Desktop (Win/Mac) | No-op | Hardware Enter path unchanged | Low |

### Testing Strategy

**Problem 1 (Keyboard flash)**:
1. Open terminal, run a command
2. While terminal visible, tap editor text area
3. Observe: keyboard should appear and stay
4. Type some code, verify input works
5. Tap terminal again, verify terminal keyboard comes back

**Problem 2 (Enter key)**:
1. Terminal focused, type `echo hello`
2. Soft keyboard visible
3. Tap Enter key on soft keyboard
4. Observe: command runs, output appears, keyboard stays visible
5. Type another command, verify repeated Enter works
6. (Desktop) Hardware Enter still works

## Rollback Plan

If fixes cause regressions:

**Keyboard flash fix**: Remove the `unfocusInput()` call from EditorPage. Revert to original behavior (flash persists but no new breakage).

**Enter key fix**: Revert `TextInputAction` change. Document limitation that OHOS terminal Enter requires hardware keyboard until engine is fixed.

## Migration Notes

None — these are bug fixes, not feature changes. No user migration or API changes.
