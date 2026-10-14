# Fix HarmonyOS Terminal and Editor Keyboard Focus Issues

## Goal

Fix two critical HarmonyOS soft keyboard and focus issues that prevent normal terminal and editor interaction:
1. When terminal is open, tapping the editor causes the soft keyboard to pop up and immediately dismiss
2. When terminal has focus, the soft keyboard shows "开始" (Start) action but pressing Enter has no effect

## Background

### Current Behavior (Verified 2026-10-14)

**Problem 1: Editor tap dismisses keyboard when terminal open**
- Open terminal panel (bottom panel visible)
- Tap on editor code area
- Soft keyboard briefly appears then immediately disappears
- **Expected: keyboard should appear and STAY VISIBLE for editor input** (current behavior is a bug)

**Problem 2: Terminal Enter key not working**
- Terminal panel open with focus on terminal input field
- Soft keyboard displays with "开始" (Start/Begin) action in bottom-right
- Pressing the Enter/Return key has no effect — command is not submitted
- Expected: Enter key should submit the command and keep keyboard visible

### Technical Context

From codebase exploration:

**Terminal Input Handling** (`terminal_pane.dart` + `terminal_input.dart`):
- Uses `TerminalInputBehavior.restoreKeyboard()` for OHOS-specific soft keyboard management
- TextField configured with `textInputAction: TerminalInputBehavior.action` (which is `TextInputAction.unspecified`)
- Comment explains `unspecified` is chosen because:
  - `send`/`done` dismiss keyboard (unwanted)
  - `none` is silently dropped by OHOS engine (no command sent)
  - `unspecified` should submit via `onSubmitted` without dismissing keyboard
- Terminal tap gesture uses deferred focus with double-tap cancellation

**Editor Pointer Handling** (`editor_page.dart`):
- `_handlePointerDown/Move/Up` handle pinch-zoom and long-press paste toolbar
- No explicit terminal unfocus on editor tap
- Editor uses `re_editor` package with its own focus node per open file

**Platform Layer** (`EntryAbility.ets`, `JavaBridge.ets`):
- OHOS-side Flutter embedding
- No obvious keyboard/IME override visible in entry ability code

## Requirements

### R1 — Diagnose keyboard dismiss on editor tap

Identify why tapping the editor when terminal is visible causes the soft keyboard to briefly appear then dismiss. Root causes could include:
- Editor's FocusNode requesting focus and immediately stealing it back from terminal
- OHOS IME connection being severed during focus transfer
- Race condition between editor pointer handler and terminal keyboard restoration
- `re_editor` package behavior specific to OHOS

### R2 — Fix keyboard dismiss behavior

Implement a fix that ensures when user taps editor with terminal open, the soft keyboard appears and **stays visible** for editor input. The keyboard should not flash and dismiss.

Possible strategies based on diagnosis:
- **Option A (focus coordination)**: Properly coordinate focus transfer between terminal and editor FocusNodes, ensuring the IME connection stabilizes on editor before any dismiss signal
- **Option B (IME attachment timing)**: Delay or sequence the IME attachment/detachment to prevent race condition between terminal unfocus and editor focus
- **Option C (platform-specific handling)**: OHOS-specific focus/keyboard management that differs from Android behavior

The chosen fix must not regress existing behavior:
- Desktop platform (hardware keyboard) unaffected
- Terminal tap → keyboard up still works
- Editor keyboard input still functional when terminal closed
- Tapping editor when terminal closed → keyboard works normally

### R3 — Diagnose Enter key not working

Identify why `TextInputAction.unspecified` mapped to OHOS `EnterKeyType.UNSPECIFIED` is not invoking `onSubmitted`. Possible causes:
- OHOS Flutter plugin version mismatch with comment's assumptions
- `flutter_ohos` engine's `handleFunctionKey` switch has changed and `UNSPECIFIED` branch is now missing/broken
- TextField configuration missing additional properties for OHOS IME
- Conflicting key event handler consuming the Enter before TextField sees it

### R4 — Fix Enter key submission

Based on diagnosis, implement the correct fix:
- If `UNSPECIFIED` branch is missing: use a different `TextInputAction` that OHOS does handle and doesn't dismiss keyboard
- If IME configuration issue: add required OHOS-specific TextField properties
- If key event conflict: adjust Focus `onKeyEvent` handler priority or filtering
- Update `TerminalInputBehavior` doc comment with new findings

The fix must:
- Submit terminal command on Enter press
- Keep soft keyboard visible after submission (no dismiss)
- Work on both OHOS x86_64 emulator and ARM64 device if testable
- Not regress desktop/Android Enter key behavior

## Out of Scope

- Other terminal keyboard issues (symbol input, history navigation, paste)
- Editor keyboard issues unrelated to terminal interaction
- Terminal scrolling or output rendering
- Changing Flutter/OHOS plugin versions (work within current constraints)
- Cross-platform keyboard behavior unification (each platform has valid differences)

## Acceptance Criteria

### AC1 — Editor tap with terminal open

- [ ] Terminal panel open and expanded
- [ ] Tap on editor code area (anywhere in the code editing region)
- [ ] **Result**: Soft keyboard appears
- [ ] **Result**: Soft keyboard REMAINS VISIBLE (does not dismiss immediately)
- [ ] **Result**: User can type code using the soft keyboard
- [ ] **Result**: Editor cursor is positioned where user tapped

### AC2 — Terminal Enter key submits command

- [ ] Terminal panel open with input focused
- [ ] Type a simple command (e.g. `echo test`)
- [ ] Soft keyboard visible, showing any action label OHOS provides
- [ ] Press the Enter/Return key (hardware or soft keyboard)
- [ ] **Result**: Command is submitted and output appears in transcript
- [ ] **Result**: Soft keyboard remains visible after submission
- [ ] **Result**: Terminal input is cleared and ready for next command

### AC3 — No regression on other platforms/scenarios

- [ ] Desktop (Windows/macOS): hardware Enter still works
- [ ] Android (if applicable): soft keyboard Enter still works
- [ ] Terminal closed: editor keyboard input unaffected
- [ ] Terminal gestures (tap, resize, scroll) unaffected

### AC4 — Code and spec updated

- [ ] If `TerminalInputBehavior` changes, update its doc comment with OHOS findings
- [ ] If root cause was non-obvious, capture in `.trellis/spec/` (e.g. `frontend/mobile-keyboard.md` or `frontend/ohos-focus.md`)

## Constraints

- **OHOS-only issues**: Fixes may be OHOS-specific (Platform.isOHOS checks are acceptable)
- **Read-only engine**: Cannot modify `flutter_ohos` plugin source; must work with current plugin as-is
- **Two-repo structure**: `qfli_studio_core` owns terminal/editor; changes there must not break other products using that core
- **Testing limitations**: May only have x86_64 emulator; ARM64 device verification deferred if unavailable

## Technical Notes

### Relevant Files

- `qfli_studio_core/lib/editor/editor_page.dart` — editor pointer handlers, terminal key management
- `qfli_studio_core/lib/editor/terminal_pane.dart` — terminal panel, session focus, tap gesture
- `qfli_studio_core/lib/terminal/widgets/terminal_input.dart` — `TerminalInputBehavior` and soft keyboard logic
- `qfli_studio_core/lib/editor/open_file.dart` — per-file FocusNode
- `ohos/entry/src/main/ets/entryability/EntryAbility.ets` — OHOS Flutter embedding

### Focus Chain

```
EditorPage (has _terminalKey: GlobalKey<TerminalPaneState>)
  ├─ CodeEditor (per OpenFile, has focusNode)
  └─ TerminalPane
       └─ _TerminalSession (has focusNode for TextField)
```

When terminal visible and user taps editor:
1. Editor Listener.onPointerDown fires → `_handlePointerDown`
2. Editor's CodeEditor/re_editor requests focus (implicit or explicit?)
3. Terminal's focusNode loses focus
4. (Bug) Keyboard pops and immediately dismisses

### OHOS TextInputAction Behavior

Per `terminal_input.dart` comment (written before this bug):
- `send`/`done`/etc. → `shouldUnfocus: true` → keyboard dismissed (unwanted)
- `none` → `EnterKeyType.NONE` → OHOS engine has no branch → Enter dropped
- `unspecified` → `EnterKeyType.UNSPECIFIED` → engine should call `performAction` → `onSubmitted`

**But current observation**: Enter not working, so either:
- Comment's assumption is wrong / outdated
- OHOS engine behavior changed
- Configuration is incomplete
