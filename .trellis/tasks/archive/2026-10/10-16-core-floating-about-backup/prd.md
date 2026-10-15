# Shared core usability and application backup

Implement directly per the user's explicit request; three Pi workers in the same Java Herdr workspace.

## Requirements
- Global retained-editor restore control supports dragging and an explicit collapse into a small circle; tapping the circle expands it. Preserve coordinates and mode across editor/route/modal transitions during the app lifetime. Clamp to screen, safe areas and keyboard. Preserve existing editor state, animations, session selector, modal hiding and default FAB clearance.
- About opens a normal secondary page from both existing entry points. Preserve active StudioProfile identity, version, description and open-source licenses. Support Back, narrow screens and large text.
- Settings exports/imports the entire application's durable private data, including projects (binary files too), settings, indexes and applicable private store files. Replace project JSON actions. Export a ZIP with .qfliz suffix and root app_info.json containing current application identity and archive format version. Restore validates format, identity compatibility and paths before touching live data; protect against traversal/symlinks and partial destructive restores. All products inherit the implementation from core.

## Acceptance
- Focused widget tests cover dragging, collapse/expand, hide/show retention, bounded layout and About navigation/identity.
- Backup tests cover binary round trip, metadata, full durable roots, invalid archives and safe restore failure behavior.
- Core analysis and full test suite pass; Java integration tests pass.
- Scoped conventional core commits; preserve unrelated work and other product workspaces.
