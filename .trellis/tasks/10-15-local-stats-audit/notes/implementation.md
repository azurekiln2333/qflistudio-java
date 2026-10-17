# Implementation notes: local stats and audit

Commit: `336c327` feat(pages): add local-only stats and audit pages
Survey: see `notes/survey.md` (Step 0, written before any code).

## What changed (core only)

| File | Role |
| --- | --- |
| `lib/services/local_store_backend.dart` | `LocalStoreBackend` + file and in-memory implementations |
| `lib/services/local_stats_service.dart` | Counters, streaks, trends, distribution, persistence |
| `lib/services/local_audit_service.dart` | Capped append-only event log with filtering |
| `lib/pages/local_stats_audit_pages.dart` | `LocalStatsPage` and `LocalAuditPage` |
| `pages/profile_page.dart` | New 本机记录 section, rendered for all products |
| `pages/home_page.dart` | Project create/open/delete hooks |
| `editor/editor_page.dart` | Save hook with a line-delta estimate; run outcome hook |
| `editor/terminal_pane.dart` | Terminal command hook |

`audit_page.dart`, `activity_stats_page.dart`, `checkin_calendar_page.dart` and
`points_page.dart` are **untouched** — verified with `git status` on those paths.

## A hang worth remembering

The first version of the page test ran for nine minutes and never exited, even
with `--timeout 60s`. It was not a slow test: the process could not finish.

Two causes, both fixed:

1. **The throttle `Timer`.** `_scheduleWrite` armed a 400 ms timer on every
   record. A widget test never advances real time, so the timer stayed pending
   and the harness refused to exit.
2. **Real file IO.** The services wrote through `dart:io` inside the test, and
   `AppPaths._findStorageDirectory` creates its own 2 s timer, which the stack
   trace for the failure named directly.

The fixes:

- a `LocalStoreBackend` seam, with `LocalMemoryBackend` for tests, so no test
  touches the disk;
- an injectable `flushDelay`; `Duration.zero` writes on the next microtask
  instead of arming a timer;
- writes are only scheduled once `load()` has resolved a storage location, so a
  singleton that is never loaded (as in the terminal and editor tests) arms
  nothing;
- `dispose()` cancels the timer and is safe to call with none pending.

Symptoms to recognise next time: a test that passes every assertion but never
prints `All tests passed`, and a failure dump containing `Pending timers:`.

## Verification

- `dart analyze lib test` in core: 0 issues
- core tests, all with `--timeout 60s`:
  - `local_stats_audit_test.dart` — 28/28, ~3 s
  - `local_stats_audit_pages_test.dart` — 10/10, ~5 s
  - the broader related set (stats/audit + navigation + terminal + editor,
    10 files) — **120/120, ~14 s**
- qfli_java unaffected by the core change: `flutter test` **96/96**
- No network call added: neither service imports `ApiClient` or `AuthStore`
  (checked by grep; the only mentions are doc comments saying so).

## Acceptance vs PRD

| Requirement | Status |
| --- | --- |
| Files/projects edited, created/deleted/renamed, saves | yes |
| Project opens, runs success/failure, terminal commands | yes |
| Accumulated editing and usage time | yes |
| Lines added/removed, estimated from save diffs | yes, per-path previous count |
| Language/extension distribution, top N projects | yes |
| Daily heatmap, current/longest streak, 7/30 day trends | yes |
| JSON under app documents, throttled and async | yes, via the backend seam |
| Clear and export | yes, both from the app bar (export shows the JSON) |
| Audit records create/delete/rename/save/run/import/export/restore | yes |
| Audit filter by type and time, search, export, clear | yes |
| Capped size, oldest-first eviction | yes, 500 |
| Entries on 「我的」 for offline and online | yes, `本机记录` for both |
| Hooks at existing operation points, one service | yes, alongside `TaskActivityService` |
| qflistudio's server pages not replaced or broken | yes, untouched and still rendered |
| Unit tests for aggregation, eviction, persistence, throttling | yes |
| Widget tests for both offline modes | yes |
| No network calls added | yes |

## Notes

- `import`/`export`/`restore` are in the `LocalAuditKind` enum and the filter,
  but only `restore`/`export` currently have no call site: the recovery pages
  predate this task and adding hooks there was outside its scope. Recorded here
  rather than silently claimed as wired.
- Line deltas are labelled as estimates in the UI because the first save of a
  file has no previous count to diff against.
