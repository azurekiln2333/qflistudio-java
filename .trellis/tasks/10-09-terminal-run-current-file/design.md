# Design

## Boundaries

The shared editor owns terminal layout and Run gestures. The Java shell owns Java runner display titles. Keep ProgramRunner and ProgramRunResult interfaces unchanged: stdout/stderr remain line streams and exitCode retains its numeric semantics.

## Terminal presentation

- Retain the existing session model, bounded transcript, process ownership and online event handling.
- Render transcript entries and the active prompt in one scrollable list on one terminal background. Keep only compact header controls outside the transcript. Use the existing monospace family and current theme colors.
- Hide the shell prompt while an attached program is running/preparing; after completion place the next prompt immediately after output. No fake shell, output or duplicate input area.
- Echo run titles as a normal command-like line. Java titles identify the source/main class without the backend implementation suffix.
- Suppress code-0 completion markers at the local command, online result and attached-stream presentation boundaries. Preserve errors and show a compact nonzero status. Keep useful online authentication/reset errors intact.
- Reuse ideas from core `lib/terminal/widgets/terminal_output.dart`: prompt as final scrollback row and consistent canvas. Do not transplant its separate ShellBackend session model into TerminalPane.

## Run routing

Capture the active OpenFile at gesture time. Use one internal Run method with an optional explicit entry. A regular tap passes no explicit entry and continues using RunnerService.findEntry. A long press validates the captured file and uses its normalized project-contained path. Share the existing save loop and runtime routing, and retain busy/mounted checks across awaits.

Use one material gesture owner for tap and long press so long press suppresses tap naturally. Preserve button semantics, disabled state and a discoverable long-press hint. Do not alter ProjectConfig.entryFile.

## Compatibility and risks

The core is shared by other language apps. Do not hard-code Main.java or Java-specific filtering into generic runtime routing; consult the existing profile/file support rules for explicit selection. Preserve online and HTML/SQL routing where applicable. Keep program-not-started numeric status so online fallback still works.

The working tree is already dirty. Capture affected file baselines before implementation and do not commit unrelated changes. Removing successful-completion lines is an intentional presentation change, not a process-exit change. Do not claim device runtime validation from a desktop/widget check.
