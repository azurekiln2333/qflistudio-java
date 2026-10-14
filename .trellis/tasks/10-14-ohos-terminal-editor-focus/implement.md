# Implementation Plan: OHOS Keyboard Focus Fixes

## Execution Checklist

### Phase 1: Diagnosis (Problem 1 — Keyboard Flash)

- [ ] **Step 1.1**: Add debug logging to `EditorPage._handlePointerDown`
  - Log pointer events when terminal is visible
  - Note: Keep logs under `if (kDebugMode)` to avoid production noise
  
- [ ] **Step 1.2**: Add debug logging to `TerminalPaneState._focusInput` and `unfocusInput`
  - Log when focus is requested/removed
  - Log keyboard show/hide calls
  
- [ ] **Step 1.3**: Test on OHOS emulator, collect logs
  - Open terminal → tap editor → observe keyboard flash
  - Review log sequence to identify race condition
  
- [ ] **Step 1.4**: Check `re_editor` package for OHOS-specific focus handling
  - Search `vendor/re_editor` for Platform checks
  - Search for IME or keyboard-related code

**Validation**: Can explain the exact sequence that causes keyboard flash.

### Phase 2: Fix Problem 1 (Keyboard Flash)

- [ ] **Step 2.1**: Implement explicit terminal unfocus on editor tap
  - File: `qfli_studio_core/lib/editor/editor_page.dart`
  - In `_handlePointerDown`, add:
    ```dart
    if (Platform.isOHOS && _terminalVisible) {
      _terminalKey.currentState?.unfocusInput();
    }
    ```
  - Place before any editor focus logic (if explicit, otherwise let re_editor handle it)
  
- [ ] **Step 2.2**: Test fix on OHOS emulator
  - Terminal open → tap editor → keyboard appears and STAYS
  - Type code, verify input works
  - Tap terminal → keyboard comes back for terminal
  
- [ ] **Step 2.3**: Verify no desktop regression
  - Run on Windows/Mac with terminal open
  - Tap editor, verify hardware keyboard input still works
  - Verify no focus issues

**Validation**: AC1 passes — editor tap shows keyboard that stays visible.

### Phase 3: Diagnosis (Problem 2 — Enter Key)

- [ ] **Step 3.1**: Add debug logging to `_TerminalSession._onKey`
  - File: `qfli_studio_core/lib/editor/terminal_pane.dart`
  - Log every KeyEvent: type, logicalKey, deviceType, result
  - Specifically check if soft keyboard Enter reaches this handler
  
- [ ] **Step 3.2**: Add debug logging to `_submit()`
  - Log when `_submit()` is called
  - Log the call stack (onSubmitted path vs _onKey path)
  
- [ ] **Step 3.3**: Test on OHOS emulator with soft keyboard
  - Type command, press soft keyboard Enter
  - Collect logs: does _onKey fire? what KeyEvent properties? does _submit fire?
  - Check if `LogicalKeyboardKey.enter` matches the soft keyboard event
  
- [ ] **Step 3.4**: Test hardware Enter key (if emulator supports it)
  - Does hardware Enter work?
  - Compare KeyEvent properties: hardware vs soft keyboard
  
- [ ] **Step 3.5**: Verify interception hypothesis
  - Check if `_onKey` returns `KeyEventResult.handled` for soft keyboard Enter
  - Check if TextField `onSubmitted` ever fires for soft keyboard
  - If _onKey intercepts but doesn't call _submit, that's the bug

**Validation**: Know whether `_onKey` is blocking soft keyboard Enter from reaching TextField.onSubmitted.

### Phase 4: Fix Problem 2 (Enter Key)

**Path A: If `_onKey` is intercepting soft keyboard Enter**

- [ ] **Step 4.1A**: Modify `_onKey` to not intercept soft keyboard events
  - File: `qfli_studio_core/lib/editor/terminal_pane.dart`
  - Detect soft keyboard events (check event type, deviceType, or other properties)
  - Return `KeyEventResult.ignored` for soft keyboard Enter
  - Keep hardware keyboard handling: return `handled` and call `_submit()`
  
- [ ] **Step 4.2A**: Test on OHOS emulator
  - Type command, press soft keyboard Enter
  - Verify: command runs via TextField.onSubmitted path
  - Verify: keyboard stays visible after submission
  
- [ ] **Step 4.3A**: If keyboard dismisses after submission
  - Add `TerminalInputBehavior.restoreKeyboard()` in `_submit()` for OHOS
  - Re-test

**Path B: If `_onKey` is NOT the issue, try different TextInputAction**

- [ ] **Step 4.1B**: Update `TerminalInputBehavior.action` constant
  - File: `qfli_studio_core/lib/terminal/widgets/terminal_input.dart`
  - Try `TextInputAction.send` first
  - If that doesn't work, try `TextInputAction.newline`
  - Test and document which one works
  
- [ ] **Step 4.2B**: If action dismisses keyboard, add restoration
  - In `TerminalPaneState._submit()`, after `_run(text)`:
    ```dart
    if (Platform.isOHOS && mounted && session.focusNode.canRequestFocus) {
      TerminalInputBehavior.restoreKeyboard(session.focusNode);
    }
    ```
  
- [ ] **Step 4.3B**: Update `TerminalInputBehavior` doc comment
  - Explain why the new action is used
  - Document OHOS version and tested behavior

**Common final step**:

- [ ] **Step 4.4**: Test on OHOS emulator
  - Type command, press Enter
  - Verify: command runs, output appears, keyboard stays
  - Verify: can submit multiple commands in a row
  - Test both soft keyboard and hardware keyboard (if available)

**Validation**: AC2 passes — soft keyboard Enter submits command, keyboard stays visible.

### Phase 5: Cross-Platform Verification

- [ ] **Step 5.1**: Test on Windows desktop
  - Terminal Enter (hardware): works
  - Editor typing: works
  - No new errors in console
  
- [ ] **Step 5.2**: Test on macOS desktop (if available)
  - Same checks as Windows
  
- [ ] **Step 5.3**: Test on Android (if applicable)
  - Soft keyboard Enter in terminal: works
  - Editor soft keyboard: works
  - No regressions
  
- [ ] **Step 5.4**: Run all terminal/editor tests
  - `flutter test ../qfli_studio_core/test/terminal_pane_test.dart`
  - `flutter test ../qfli_studio_core/test/editor_run_test.dart`
  - Verify no new failures

**Validation**: AC3 passes — no regressions on other platforms.

### Phase 6: Cleanup and Documentation

- [ ] **Step 6.1**: Remove debug logging added in Phase 1 and 3
  - Or gate behind `const bool _debugKeyboard = false;`
  
- [ ] **Step 6.2**: Update spec if root cause was non-obvious
  - File: `.trellis/spec/frontend/ohos-focus.md` (create if needed)
  - Document OHOS focus transfer behavior
  - Document OHOS TextInputAction quirks
  
- [ ] **Step 6.3**: Update any changed comments
  - Ensure `TerminalInputBehavior` class doc is accurate
  - Ensure editor/terminal focus comments match new behavior
  
- [ ] **Step 6.4**: Verify `flutter analyze` passes
  - Run in both repos: `qfli_java` and `qfli_studio_core`

**Validation**: AC4 passes — code clean, documented, analysis passes.

## Validation Commands

**Lint/Analysis**:
```bash
cd D:\MyNewProjects\qfli_java
flutter analyze

cd ..\qfli_studio_core
flutter analyze
```

**Unit Tests**:
```bash
cd ..\qfli_studio_core
flutter test test/terminal_pane_test.dart
flutter test test/editor_run_test.dart
```

**Manual Testing** (OHOS emulator):
1. Launch app on OHOS emulator
2. Open a project
3. Open terminal (bottom panel)
4. **Test AC1**: Tap editor → keyboard appears and stays → type code → verify input
5. **Test AC2**: Focus terminal → type `echo test` → press soft Enter → verify runs → keyboard stays
6. **Test terminal gestures**: resize, scroll, tab switching → no keyboard issues

## Risky Files / Rollback Points

**Risky files** (focus/keyboard critical paths):
- `qfli_studio_core/lib/editor/editor_page.dart` — EditorPage pointer handling
- `qfli_studio_core/lib/editor/terminal_pane.dart` — Terminal focus/keyboard logic
- `qfli_studio_core/lib/terminal/widgets/terminal_input.dart` — TextInputAction config

**Rollback checkpoints**:
1. After Phase 2.1: Can revert editor_page changes if it breaks desktop
2. After Phase 4.2: Can revert terminal_input changes if Enter breaks on other platforms
3. Git commit after each passing AC so partial rollback is possible

## Follow-Up Checks

After `task.py start` and implementation:

- [ ] All four ACs pass on OHOS emulator
- [ ] No regressions on Windows/Mac desktop
- [ ] `flutter analyze` clean in both repos
- [ ] Terminal/editor tests pass
- [ ] Spec updated if root cause warrants it
