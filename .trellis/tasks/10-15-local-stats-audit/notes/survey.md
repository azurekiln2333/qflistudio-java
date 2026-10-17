# Step 0 survey: local stats and audit

Task: `10-15-local-stats-audit`. Parent constraints read first
(`10-15-studio-polish/prd.md`): subprojects add no network; qflistudio keeps
every server-backed feature; new stats/audit data is local-only.

## The four existing pages

| Page | Lines | Data source | Reachable from |
| --- | --- | --- | --- |
| `audit_page.dart` | 197 | **Server** — `ApiClient` admin log, paginated | `profile_page.dart:183` (admin only) |
| `activity_stats_page.dart` | 161 | **Server + local queue** — points, experience, check-in streak from `AuthStore.user`, plus `TaskActivityService` pending-sync counts | `profile_page.dart:125` |
| `checkin_calendar_page.dart` | 184 | **Server** — check-in calendar | `profile_page.dart:330` |
| `points_page.dart` | 534 | **Server** — points ledger | `profile_page.dart:118, 328` |

**Reachability finding.** All four are reached *only* through
`profile_page.dart`, and every entry sits inside a `!offlineOnly` guard
(the 签到与积分 section at lines 104-128, 管理 at 169-186, and the
`_statistics` card at 315-332). So an offline product currently has **no**
stats and **no** audit entry at all — which is exactly the gap this task fills.

**Reuse assessment.** None of the four can be reused for offline:

- `audit_page.dart` is a paginated view over a server API; there is no local
  equivalent to point it at, and repurposing it would drag `ApiClient` into
  offline builds where it must never be called.
- `activity_stats_page.dart` reads `AuthStore.user` fields that are only
  populated after login, and its "pending sync" counters are meaningless
  without a server.
- `checkin_calendar_page.dart` and `points_page.dart` are wholly server-domain
  (check-in streaks and a points ledger are server concepts; an offline app has
  no account to hold them).

They stay exactly as they are for qflistudio, untouched, as the parent PRD
requires. The new local pages are separate widgets with separate data.

## Existing local infrastructure

`TaskActivityService` (`lib/services/task_activity_service.dart`, 418 lines) is
the closest thing to a local activity tracker, but it is **not** suitable as the
stats store:

- its state is keyed by **server user id** (`_scope(auth) => auth.user?.id ??
  'local'`) and its snapshots/calendars come from the API;
- it exists to *queue* events for later upload, which an offline product must
  never do;
- it stores counters for a fixed set of reward keys, not the file/line/run
  history this task needs.

It is, however, the right **shape** to copy: a singleton `ChangeNotifier` with a
static `report(...)` entry point and throttled async persistence.

## Hook points (already instrumented)

`TaskActivityService.report` already fires at every operation this task needs to
observe, so no new plumbing is required at the call sites — the new services can
be reported from the same places:

| Operation | Existing hook |
| --- | --- |
| editor save | `editor_page.dart:269, 377, 382, 633` |
| project create | `home_page.dart:821, 1046`, `code_snippet.dart:430, 476` |
| project open | `home_page.dart:850`, `code_snippet.dart:208` |

Two operations have no existing report call and will be added alongside the
existing ones (not instead of them):

- **run / compile outcome** — `editor_page.dart:937` has `exitCode` and
  `kProgramNotRunExitCode`, which is where success vs failure is decided.
- **terminal command** — `terminal_pane.dart:360` (`_run`) is the single entry
  point for a submitted command.

`ProjectStore` mutation points for create/delete/rename/import/export:
`createProject` (205), `createProjectFromExample` (219), `addExisting` (371),
`addCloudProject` (408), `deleteProject` (463). `addCloudProject` is
server-domain and will not be recorded as a local event.

## Design decisions

1. **Two services, no network.** `LocalStatsService` and `LocalAuditService`
   under `lib/services/`, each a `ChangeNotifier` singleton with a static
   `report(...)` entry point, mirroring `TaskActivityService`'s shape. JSON
   under the app documents directory via the existing `AppPaths`, written
   throttled and asynchronously so the UI thread never blocks.
2. **Offline-safe by construction.** They import neither `ApiClient` nor
   `AuthStore`, so they cannot make a request even by accident.
3. **Core-only, conditional rendering.** New pages live in core and are added to
   `profile_page.dart` in a new section that renders for **both** offline and
   online products. The existing server entries keep their `!offlineOnly`
   guards, and qflistudio's four pages are untouched.
4. **Lines added/removed** are estimated from save diffs (previous content vs
   new content line counts), which the editor already has in hand at save time.

## What will be built

- `lib/services/local_stats_service.dart` — counters, streaks, daily heatmap,
  language/extension distribution, top projects, editing and usage time.
- `lib/services/local_audit_service.dart` — capped append-only event log with
  filtering by type and time, search, clear, export.
- `lib/pages/local_stats_page.dart` and `lib/pages/local_audit_page.dart`.
- Entries added to `profile_page.dart` for all products.
