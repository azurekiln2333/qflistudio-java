# Restore Enter submit in the app terminal input

## Goal

Pressing Enter in the app terminal must send the command again. It currently
does nothing, so no command can be entered.

## Background (verified)

- Commit `b75f656` changed the input field in
  `lib/terminal/widgets/terminal_output.dart` from
  `textInputAction: TextInputAction.send` to `TextInputAction.none` with the
  stated intent of keeping the soft keyboard open after Return.
- `TextInputAction.none` also removes Return as a submit action, so Flutter
  never calls `onSubmitted`. The command is not sent and the field keeps the
  text.
- The keyboard-stay-open goal is already served independently: `_submit` ends
  with `editor.focusNode.requestFocus()` (`terminax_terminal_page.dart`), and
  the same commit added a `TextInput.show` invocation in the tap handler. The
  `none` action is therefore unnecessary as well as harmful.

## Requirements

- R1 Return (hardware and soft keyboard) submits the current input line.
- R2 The soft keyboard stays available after submitting, so consecutive
  commands do not require re-tapping the field.
- R3 No other input behaviour changes: no auto-correct, no suggestions,
  single-line field, collapsed decoration.

## Acceptance Criteria

- [ ] AC1 The input field uses a submit-capable `textInputAction`.
- [ ] AC2 A focused test proves typing a command and pressing Enter reaches
      the backend (not merely that the field holds text).
- [ ] AC3 `test/terminal_pane_test.dart` and the other terminal suites stay
      green; `dart analyze` is clean.

## Out of scope

- Changing the sandbox backend or the shortcut bar.
- Reworking focus management beyond what R2 requires.
