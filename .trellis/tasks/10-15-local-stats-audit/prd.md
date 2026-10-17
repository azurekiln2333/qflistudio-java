# Local stats and audit pages

Parent: `10-15-studio-polish` (read its hard constraints first).

## Step 0: survey (report before building)

Check existing `qfli_studio_core/lib/pages/audit_page.dart`, `activity_stats_page.dart`, `checkin_calendar_page.dart`, `points_page.dart`: are they reachable, which depend on the server, what can be reused. Server-backed pages stay as they are for qflistudio.

## Statistics (local, all products)

Collect and show, at minimum:

- Files edited, projects edited, files created / deleted / renamed, saves.
- Project opens; runs / compiles with success vs failure; terminal commands.
- Accumulated editing time and app usage time.
- Lines added / removed (estimated from save diffs).
- Distribution by language / extension; top N projects.
- Daily activity heatmap, current and longest streak, 7 / 30 day trends.
- Anything else reasonable that can be derived locally.

Storage: JSON under the app documents directory, writes throttled and async (never block the UI thread). Clear and export (to a local file).

## Audit log (local, all products)

- Records create / delete / rename / save / run / import / export / restore with time, project, path.
- Filter by type and time, search, export, clear. Capped size with oldest-first eviction.

## Placement and hooks

- Entries on the 「我的」 page, visible for offline and online products.
- Hooks attached at existing operation points (ProjectStore, editor save, runner, terminal), kept in one service, not scattered.
- For qflistudio, local stats must not replace or break the server-backed pages; show both if both exist.

## Acceptance

- Unit tests for the stats/audit services (aggregation, eviction, persistence, throttling).
- Widget tests: entries visible on 「我的」 with `offlineOnly` true and false.
- No network calls added.
