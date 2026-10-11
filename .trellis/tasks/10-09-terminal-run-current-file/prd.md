# Continuous terminal and active-file Run

## Goal

Make the editor terminal a professional, continuous transcript and let users run the active Java source with a long press while a normal tap keeps running the configured project entry.

## Background

- The Java app consumes `../qfli_studio_core` through `pubspec.yaml:14`. Shared editor Run behavior lives in `lib/editor/editor_page.dart:714`; terminal presentation lives in `lib/editor/terminal_pane.dart:673` in the core repository.
- The terminal currently separates its output ListView from a fixed input row with a divider. `attachOutput` appends `runEnded(code)` for every outcome (`terminal_pane.dart:642`).
- Java returns localized run titles ending in `(JDK)` (full-width punctuation) from both execution paths (`qfli_java/lib/java_runner.dart:159`, `:185`).
- Both repositories have pre-existing uncommitted changes, including the affected core files. Preserve that work and review this task as a delta from the captured baseline.

## Requirements

- R1: Put commands, stdout, stderr and the next prompt in one top-aligned scrollback. The prompt follows the last line; it is never pinned to a separate bottom section.
- R2: Use a restrained terminal canvas, consistent monospace text, compact session controls and conventional short terminal labels. Suppress successful completion/exit-code-zero lines and verbose preparation chatter. Remove Java runner implementation labels from the transcript; preserve real output and useful failure information.
- R3: A tap on Run uses the existing project-entry resolver. A long press runs the file selected when the gesture fires, without updating project configuration or falling back to Main.java.
- R4: Reuse the normal save/compile/run path and project root for both gestures. Keep dependencies, package handling, cancellation and stderr diagnostics intact. Reject an absent, deleted, unsupported or out-of-project active file with a clear short error.
- R5: Keep existing terminal sessions, command history/submission, online execution and error visibility functional. Preserve user-authored stdout, including Chinese text.

## Acceptance criteria

- AC1 (R3, R4): With Main2.java active and Main.java as the entry, tap runs Main once; long press runs Main2 once; a later tap still runs Main. Dirty sources are saved before execution.
- AC2 (R1): Empty/short output begins at the top. The prompt directly follows the transcript. Long output, repeated runs, keyboard/view-height changes and session switches remain usable and scrollable.
- AC3 (R2, R5): Success prints neither a Chinese completion sentence nor exit code 0; the transcript contains no `(jdk)`/`(JDK)` suffix or separate run card. Application output is preserved.
- AC4 (R2, R4): A nonzero exit stays visible with a concise English terminal status. Compilation diagnostics and the program-not-started result remain distinguishable.
- AC5 (R5): Command submission/history and cancellation still work; switching sessions does not redirect an in-flight stream into another session.

## Out of scope

New PTY/shell backend, live Java stdin transport, runtime installation changes, startup/splash work, main navigation, replacing the full-screen terminal page, or changing the configured default entry.
