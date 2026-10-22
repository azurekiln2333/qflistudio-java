# Java debugger UI handoff

Date: 2026-10-22. Worker: java_debug_ui. No commits, core edits, emulator,
signing, daemon or device operations. Root retains device-window ownership.

## Delivered behavior

- `lib/java_debugger_page.dart` connects the actual `JavaDebugger` backend to
  an accessible tool page. It chooses the last browsed registered local project
  when available, permits an explicit local project path and Java entry, and
  preserves program arguments as one exact argument per line.
- Users can add/remove class/line breakpoints before or during execution,
  observe actual binding status, launch, pause/resume, step into/over/out, stop,
  select a real stack frame and inspect its actual local variables. The page
  displays the backend's actual VM name/version and stdout/stderr/exit status.
- Startup failures and unsupported JDI/JDWP remain visible failures. Stop is
  available during compilation/attach. Late attach/pause events cannot reopen
  controls during stopping. Inspection responses are rejected after resume,
  another inspection, stop or page disposal. Leaving the page stops the owned
  session and snapshot. Output retains a bounded 64 Ki UTF-16 tail without
  splitting a surrogate pair.
- This route explicitly compiles **saved project files** into an isolated
  snapshot. Core exposes no tool-route accessor to dirty editor buffers; no
  unsaved-buffer debugging claim is made. The backend's existing unsaved-buffer
  interface remains available for a future common editor hook owned by C.

## Integration and ownership

- `lib/java_tools_page.dart`: ninth direct Java card `Java 调试器`; optional
  `ProjectStore` on both `JavaToolsGrid` and standalone `JavaToolsPage`.
  Registry construction binds the store without relying on a card's position.
- `lib/main.dart`: passes the real shell store to both tools builders; existing
  diagnostics wiring by root is preserved.
- `test/java_tools_page_test.dart` and `test/java_tools_wiring_test.dart`: exact
  cardinalities now 9 Java / 18 standalone / 19 including terminal. Direct route
  test proves the debugger receives the shell's actual store. Existing narrow,
  wide, light, dark and unique-card tests remain.
- `test/java_debugger_page_test.dart`: nine deterministic UI/lifecycle tests.
- `test/java_debugger_page_jvm_test.dart`: genuine process-backed page test.
  Actual UI adds `Main:4`, starts JDI, sees a bound breakpoint, stack and
  `int answer = 40`, steps using the UI to `42`, continues, and asserts real
  `answer=42` stdout / exit0 / actual VM text. Source bytes and project inventory
  remain unchanged and debugger temporary directory is empty afterward.
- No edits to `java_debugger.dart`, `java_runner.dart`, developer-tool parsers,
  developer-tool pages, pubspec or common-core files.

## Verification

`flutter test --no-pub test/java_debugger_page_test.dart
test/java_debugger_page_jvm_test.dart test/java_tools_page_test.dart
test/java_tools_wiring_test.dart test/java_developer_tool_pages_test.dart
--reporter expanded --concurrency 1 --timeout 90s`: **62/62 passed**.

After the final bounded-output/VM assertion/registry refinements,
`flutter test --no-pub test/java_debugger_page_test.dart
test/java_debugger_page_jvm_test.dart test/java_tools_wiring_test.dart
--reporter expanded --concurrency 1 --timeout 90s`: **18/18 passed**.

`dart analyze` on all seven changed/new Dart source/test paths: no issues.
`git diff --check` on the same paths: passed (only Windows line-ending notices).

These are current host UI/backend checks. OHOS debugger/runtime execution and
normal installed-app UI verification remain root-owned open gates; no host or
widget pass substitutes for them. Root owns final full-suite checks, spec
updates and scoped commit/push.
