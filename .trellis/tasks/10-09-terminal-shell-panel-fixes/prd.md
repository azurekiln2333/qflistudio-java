# Repair terminal commands and resizable panel interactions

## Goal

Restore basic shell commands and improve terminal focus, scrollbar, tab spacing, and drag-to-collapse behavior through Pi.

## Background

- The Java editor consumes `../qfli_studio_core` (`pubspec.yaml:14`). The embedded terminal is implemented in the shared core, not in the Java runner.
- The previous terminal task improved continuous scrollback and active-file Run, but the user still observes broken basic commands, difficult focus/scrolling, cramped tabs, and ineffective panel resizing.
- The user explicitly authorizes changes to the shared core and asks the coordinator to direct Pi. Task creation and planning were approved on 2026-10-09.
- Both repositories have substantial uncommitted work. This task must preserve the current baseline and previous terminal/Run behavior.

## Requirements

- R1: Common commands (`ls`/`dir`, `pwd`, `cd`, `clear`/`cls`, `cat`, `echo`, `mkdir`, `touch`, and `rm`) work against the real accessible project filesystem, including ordinary options such as `ls -la` and `mkdir -p`. Retain each session's current directory. These built-ins must work when the platform cannot execute a shell; unsupported options/syntax and filesystem failures produce clear errors. Evidence: core `lib/editor/terminal_pane.dart:154` currently dispatches directly to a new `cmd`/`sh` process at `:174` with a fixed directory.
- R2: Tapping the terminal canvas gives focus to that session's input while preserving text selection, scrolling, and header controls.
- R3: Show a usable vertical scrollbar on the right of the output area, associated with the active session's scrollback. Reading earlier output must remain stable while new output streams, and switching sessions retains their positions.
- R4: Give terminal tabs discernible boundaries, sufficient spacing, clear selection, and accessible close controls, including narrow phone widths.
- R5: Drag an accessible upper resize area to continuously change panel height within the available viewport. Dragging below a sensible threshold collapses to a header; upward dragging or expansion reopens it and retains its preferred expanded size and session. Evidence: core `lib/editor/terminal_pane.dart:738` provides only an 8 px strip, omitted while collapsed (`:685`); `lib/editor/editor_page.dart:1462` enforces a 150 px minimum while `:1444` animates every drag delta.
- R6: Preserve continuous output/prompt layout, session isolation, command history, cancellation, online execution, and tap/long-press Run behavior. Pi performs the implementation under explicit file ownership.

## Acceptance Criteria

- AC1 (R1): `ls`/`ls -la` list actual project files; `cd` followed by `pwd` and another listing uses the changed directory; quoted paths with spaces and Unicode work; `clear` empties the visible transcript without destroying cwd, history, or session identity. File read/create/remove commands act on real temporary fixtures, and failures do not pretend success.
- AC2 (R2): Tapping unused terminal canvas focuses the active input. Scrolling, selection, tabs, menus, and resize gestures keep their intended behavior.
- AC3 (R3): Long output can be navigated through the right scrollbar; the thumb does not cover text or the caret. Switching tabs retains each session's scroll state, and streaming does not drag a user back to the bottom while reading history.
- AC4 (R4): Multiple tabs remain distinct and usable at narrow and wide widths, in light and dark themes, without clipped labels or close targets.
- AC5 (R5): The panel tracks dragging, respects the available viewport, collapses at the threshold, and can reopen by dragging upward or using the expand control without losing output or running work.
- AC6 (R6): Focused runtime and widget checks and the Java regression suite pass; real-widget renders verify the visual and short-viewport cases. Compound commands remain intact for the external-shell path; where a shell cannot execute, they produce an honest error without partially executing file operations.

## Out of Scope

Changing primary navigation, Java toolchain installation, replacing the app's standalone full-screen terminal, fake sample files/output, or a new full PTY emulator. Broader shell support must stay within the operating system's actual permissions.

