# Terminal command and panel design

## Boundaries and ownership

The shared core owns the command runtime and editor terminal. Pi implements the scoped changes; the main coordinator owns planning, cross-agent coordination, review, and task/spec records. `ProgramRunner`, Java/JDK installation, Run entry selection, primary navigation, and the standalone terminal page layout stay outside the implementation target. Reusing the shell layer is allowed and must preserve its existing consumers.

Pi's product ownership is `../qfli_studio_core/lib/editor/terminal_pane.dart`, terminal sizing/collapse hunks in `lib/editor/editor_page.dart`, and the necessary files under `lib/terminal/shell/`. Its validation ownership is `test/terminal_pane_test.dart`, the focused shell-command test file, and terminal sizing cases alongside the existing editor tests. Existing unrelated edits in these files are part of the baseline. No other agent may concurrently modify these owned hunks.

## Command execution

Use one `ShellBackend` per local pane session, created with the real project directory. The backend is the source of current-directory state, execution state, output, and cancellation. Remove the pane's parallel `cmd /c` or `sh -c` command engine rather than maintaining two command implementations. Keep the pane's attached-program and online paths intact.

Add portable filesystem built-ins at the shared shell layer using `dart:io` and a small reusable argument parser if existing helpers do not suffice. Keep filesystem I/O in the IO implementation/helper selected through the existing conditional import; `BaseShellBackend` and the web stub must remain usable without importing `dart:io`. Supported ordinary commands are `ls`/`dir`, `pwd`, `cd`, `clear`/`cls`, `cat`, `echo`, `mkdir`, `touch`, and `rm`; include conventional `ls -a`, `ls -l`, combined `ls -la`, `mkdir -p`, `rm -f`/`-r` and combined forms, and explicit supported-option handling. Paths resolve against the session directory, with quoted names, spaces, relative paths, home expansion, and `--` handled deliberately. List and read real files, never a seeded virtual filesystem. Failed filesystem operations retain the old cwd and produce actionable stderr.

Do not interpret unquoted shell operators as path operands. Preserve the entire command for the existing external-shell path when syntax needs a real shell (pipes, redirection, chaining, expansion). If no executable shell is available, report that limitation clearly without partially executing the command. A platform availability hint is not proof of device execution permission. Portable built-ins work independently of that permission. This change does not promise persistent shell environment variables or full PTY behavior.

`clear`/`cls` is a control operation consumed by the pane: clear current transcript and pending partial output, preserve cwd/history/session/process identity, and retain a usable prompt. Clear from the menu and command submission shares one reset helper. Output chunks and completion stay associated with the session captured at dispatch; preserve output ordering, the 500-line bound, error/exit status, UTF-8, and cancellation. Echo each submitted command only once in the pane. Derive local-shell busy state from the backend while keeping attached-run/online/preparation ownership explicit; protect the entire asynchronous built-in execution, not just external process startup. Do not suppress user text with regex filters.

## Focus and scrolling

Own a `FocusNode` and scroll controller per session and dispose them with that session. An intentional canvas tap focuses the active prompt and reveals it, including when the prompt is currently outside the lazy list viewport. Delay the focus request until the input is mounted. A tap must be distinguished from long press, double-click selection, text dragging, scrollbar interaction, or multi-pointer movement. Header controls are outside the canvas focus target. Busy/preparing sessions must not focus an unavailable input.

Wrap the output list in an explicit right-side scrollbar using the same session controller; reserve a right gutter so text/caret and the thumb do not overlap. Do not create competing automatic desktop scrollbars. Show the thumb when there is scrollable content and make it draggable on appropriate platforms.

Preserve each session's scroll offset. Stream output follows the bottom only when the user was already following it; scrolling back must remain stable as new lines arrive. Explicit command submission or a deliberate focus-to-input action can reveal the latest prompt. Check lazy-list disposal, frame callbacks, keyboard resize, and session switches together.

## Tabs and panel geometry

Keep a horizontally scrollable tab strip with visible per-tab outlines, clearer selected styling, space between tabs, and outer padding. Keep at least the existing 36 px close targets and keyboard/button/selected semantics. The user's new request supersedes the old spec's borderless flat-label preference. Validate multiple tabs at phone width, not only an empty single-tab desktop view.

The editor owns the panel's displayed height and collapsed state. The pane can request collapse/expand but must not independently disagree with the parent. Preserve standalone usage if making the collapsed state controlled. Keep expanded preferred height separate from transient viewport clamps and the collapsed header height.

Provide an enlarged, discoverable resize region (roughly 18–24 logical pixels or equivalent header hit area) and a resize cursor on desktop. The same stable gesture owner remains present when collapsed. Calculate drag movement from the current displayed height, not a stale preferred height; disable height animation during active dragging so the panel follows the pointer. Clamp to the current available viewport while retaining a usable editor area. Crossing the lower threshold collapses to a header; upward dragging or the existing expand action reopens it. Use a small threshold/hysteresis where necessary to prevent flicker, and share the height constants rather than duplicating them in parent/child code.

Collapse and viewport compaction preserve sessions, cwd, output, scroll positions, and running work. Avoid forcing the keyboard open from a resize gesture. Keep AI-panel geometry independent from terminal-only sizing changes.

## Compatibility and rollback

The core is shared by multiple language apps and contains extensive uncommitted changes. Recheck owned-file hashes at handoff, coordinate any concurrent edit, and review the task delta against `research/baseline/`, not merely Git HEAD. Roll back only this task's hunks. Do not reset or replace either worktree, format entire projects, or commit unrelated baseline work.

Use real widget renders and behavior checks; desktop tests and target-platform overrides do not establish Android/OHOS device execution. Report exactly which runtime/device was exercised.
