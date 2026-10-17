# Offline-first studio polish

Umbrella for three child tasks, executed in order:

1. `10-15-java-tools-redesign` (qfli_java only)
2. `10-15-local-stats-audit` (qfli_studio_core)
3. `10-15-open-performance` (qfli_studio_core)

## Hard constraints (all children)

- **Subprojects (qfli_c/dart/go/java/json/lua/note/python/rust/sql/web) must not add any networked feature or dependency.** Networked features require ICP filing, which subprojects do not have.
- **qflistudio (main project, `isOffline: false`) has ICP filing and keeps every online feature working.** Never delete or break login, community, cloud, online terminal, ICP display, or any server-backed code in core. Offline products hide entries by `StudioProfile.offlineOnly` (defaults to `isOffline`) through conditional rendering only.
- Changes in core must keep every qfli subproject and qflistudio building and working.
- New stats/audit data is stored locally only; never uploaded.
- Commits: Conventional Commits matching history (`type(scope): ...`), trailer `Co-Authored-By: Claude <noreply@anthropic.com>`, `git add <files>`, no push, never commit `qfli_java/ohos/build-profile.json5` (signing passwords).
- Verification per task: `dart analyze` on touched packages and the related tests (not the full core suite; 7 known failures in core `widget_test.dart`/`content_code_import_test.dart` pre-exist).

## Out of scope

- Pushing to any remote.
- Changing signing config.
