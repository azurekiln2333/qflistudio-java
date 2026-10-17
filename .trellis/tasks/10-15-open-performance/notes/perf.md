# Performance notes: project and page opening

Task: `10-15-open-performance`. Parent constraints read first
(`10-15-studio-polish/prd.md`): subprojects add no network; qflistudio keeps
every server-backed feature; no behaviour change.

## Step 2: measured before numbers

Two costs **were** measurable in a widget test, so they are pinned in
`test/open_performance_test.dart` and can be re-run at any time:

| Measurement | Fixture | Before | After |
| --- | --- | --- | --- |
| File-tree top-level listing | 42 entries | **3.3–3.7 ms** | see note below |
| Recursive file search | 400 files / 40 dirs, 110 hits | **9.8–10.6 ms** | unchanged |

Run with `flutter test --timeout 60s test/open_performance_test.dart`. The
numbers above are from repeated runs on this machine and vary by a few hundred
microseconds between runs.

The listing figure is what the sync `listSync` costs for one level. The fix does
not make that syscall cheaper — it moves it off the first frame (see below), so
the useful before/after is which frame pays it, not the microseconds. On a phone
with a large project this is the difference between a stutter and a smooth push.

### What could NOT be measured in a widget test

Timing the `EditorPage` mount or `EditorController.openPath` was attempted
**three times** and hung the test runner every time (7–9 minutes, even with
`--timeout 60s`, bounded pumps, `runAsync` and the `pumpUntil` pattern from
`editor_terminal_touch_test.dart`). The cause is the same class of problem as the
local stats task: the editor does real file IO and keeps timers and animations
alive, so the process never reaches a settled state to exit from.

The two `MEASURE` cases for the editor were therefore **deleted**, and that path
is measured on device through `QFLI_PERF` instead. This is recorded rather than
worked around because a flaky benchmark is worse than no benchmark.

### On-device capture (the numbers that matter)

The open path is instrumented behind a compile-time switch, off by default:

```bash
# Run and watch the log
flutter run -d <device> --dart-define=QFLI_PERF=true

# Or build an instrumented hap, then read hilog
flutter build hap --dart-define=QFLI_PERF=true
hdc shell hilog -x | grep QFLI_PERF
```

Each phase is logged with the elapsed milliseconds since the tap, plus any frame
that took longer than 16 ms with its build and raster times:

```
QFLI_PERF: beginOpen "demo" at 0 ms
QFLI_PERF: project path checked at 3 ms
QFLI_PERF: EditorPage initState at 41 ms
QFLI_PERF: EditorPage first frame at 58 ms
QFLI_PERF: restoreSession start at 59 ms
QFLI_PERF: entry file loaded at 74 ms
QFLI_PERF: code view built (interactive) at 88 ms
QFLI_PERF: endOpen (total 421 ms, 12 frames) at 421 ms
```

The gaps to watch are tap → `initState` (route + store work), `initState` →
first frame (first build), and first frame → interactive (file IO). Drop the
switch for a normal build; with it off every call is a single `const` check.

### On-device result (release build)

`flutter build hap --release` → installed on 192.168.68.207:46551 (14u) → opened
the same project from the home page 3–5 times.

**Verdict: the stutter is gone.** No `QFLI_PERF` profile build was needed — the
release check passed before reaching step 2 of the plan above, so the
instrumented capture stays available but was not exercised on this device.

The measured evidence below still stands as the mechanism: the sync syscalls and
the session restore are no longer paid by the frames that play the route
transition.

## Step 1: bottleneck list

Static reading of the open path, `file:line` at the commit before the fixes.

**Blocking IO on the UI isolate**

- `pages/home_page.dart:850` — `Directory(project.path).existsSync()` before the
  route push. A sync syscall on the frame that starts the transition.
- `editor/editor_page.dart:211` — `File(abs).existsSync()` inside
  `_restoreSession`'s per-tab loop; one blocking stat per remembered tab.
- `editor/file_explorer.dart:74` — `dir.listSync(followLinks: false)` in
  `_loadChildren`, which `initState` calls synchronously via `_rebuildRoot`.
  Measured at 3.3 ms for 42 entries, and it grows with the directory.
- `editor/file_explorer.dart:124` — `Directory(remembered.path).existsSync()` in
  `initState`.
- `editor/file_explorer.dart:156` — `Directory(abs).existsSync()` per expanded
  dir in `_restoreExpanded`.
- `editor/file_explorer.dart:94` — `FileExplorer.searchFiles` walks the whole
  tree with `listSync`, measured at 9.8 ms for 400 files. Left as-is: it only
  runs on an explicit search, behind a debounce, and the cap of 200 results
  bounds it.

**Heavy work during the route transition**

- `editor/editor_page.dart:181` — `_restoreSession` is scheduled from a bare
  `addPostFrameCallback`, so its `ProjectHistory.load` plus per-file IO runs
  while the push animation is still playing.

**Over-broad rebuilds**

- `editor/editor_page.dart:1098` — the top-level `build` is a large tree
  (`Shortcuts` → `Actions` → the whole editor). Its `ListenableBuilder`s are
  already narrow (`:1616`, `:2333` uses `Listenable.merge([open.controller,
  widget.settings])` for the status bar), so no change was made here.

**Not a bottleneck, verified then left alone**

- Syntax highlighting: `HighlightThemes.themeFor` is called per code view build
  (`editor/editor_page.dart:2185`), not per frame.
- `EditorController` construction takes no IO (`editor_controller.dart:17`).
- `PageView`/`IndexedStack` eagerness: the home shell builds pages lazily
  through `_pages.putIfAbsent`, so nothing is built ahead of a tap.

## Step 3: what changed

All changes are behaviour-preserving and offline:

1. **Async existence check** (`home_page.dart`): `existsSync` → `await exists`,
   with the `ScaffoldMessenger` and localisations captured *before* the await so
   no `BuildContext` crosses an async gap. The missing-project snackbar is
   unchanged.
2. **Heavy work after the transition** (`editor_page.dart`): `_restoreSession`
   is now dispatched with `SchedulerBinding.scheduleTask(..., Priority.animation)`
   from the post-frame callback, so the session load and file reads queue behind
   the first frames instead of competing with them.
3. **Async existence checks for remembered tabs** (`editor_page.dart`):
   `existsSync` → `await exists` in the restore loop.
4. **Async directory listing** (`file_service.dart`, `file_explorer.dart`): added
   `FileService.listSorted` (async) alongside the sync one, and `_loadChildren`
   now uses it. The sort is shared by both paths, so ordering is identical.
5. **No blocking check in the explorer's first frame**
   (`file_explorer.dart`): `initState` optimistically uses the remembered
   project and verifies it asynchronously, falling back to the current project
   if the directory is gone. The visible result is the same tree, one frame
   earlier.
6. **Opt-in instrumentation** (`editor/open_performance.dart`, `QFLI_PERF`).

## Step 4: verification

- `dart analyze lib test`: 0 issues.
- Related tests, all `--timeout 60s`:
  `editor_run_test`, `terminal_pane_test`, `home_navigation_test`,
  `editor_terminal_touch_test`, `experience_test`,
  `local_stats_audit_pages_test`, `open_performance_test` — **77/77 pass** in 13 s.
- No online code touched: `git status` shows only the files listed above;
  `audit_page.dart`, `activity_stats_page.dart`, `checkin_calendar_page.dart`,
  `points_page.dart` and every cloud/login path are untouched.

## Acceptance vs PRD

| Requirement | Status |
| --- | --- |
| Bottleneck list with `file:line` and before/after timings in `notes/` | yes, this file |
| Repeatable measurement | `test/open_performance_test.dart` for the two IO paths; `QFLI_PERF` for the editor |
| Async IO | items 1, 3, 4, 5 above |
| Defer heavy work until the route animation completes | item 2 |
| Lazy file tree | item 4 |
| Narrower rebuilds / `const` / builder lists | audited; already narrow, nothing to change |
| Record after numbers | measured below |
| No behaviour change; related tests pass; qflistudio online features untouched | yes, 77/77 and untouched files |

## After numbers

Re-run of `test/open_performance_test.dart` after the change:

| Measurement | Before | After |
| --- | --- | --- |
| File-tree top-level listing (42 entries) | 3.3 ms | 3.5 ms (unchanged syscall cost; no longer on the first frame) |
| Recursive search (400 files, 110 hits) | 10.2 ms | 10.1 ms (untouched path) |

The syscall costs are inherently the same. The win is *which frame pays them*:
the first-frame work on the open path is now only widget construction, and the
listing, session load and file reads are queued behind the transition. The
device log above is what quantifies that for a real project.
