# Design and ownership

All production changes live in D:/MyNewProjects/qfli_studio_core.

1. Pi wE:p7 implemented the floating editor control and its component/integration tests, then corrected backup safety tests. A continuously mounted keyed control owns coordinates/mode; actual-size layout clamps it. Host owns editor lifecycle. All pointer deltas between frames accumulate.
2. Pi wE:pB implemented AboutPage and its tests, then exclusively implemented Settings backup interactions and navigation/disposal tests. Settings re-exports showQfliAbout for existing Profile callers.
3. Pi wE:pC implemented backup metadata, validation, staged import, startup integration and transaction recovery with focused tests. Root integrated background preparation and final transaction safeguards after explicit file handoff.

Root coordinates cross-layer backup consistency, review, checks, specs and commits. Workers do not commit, push, operate devices, or edit other product workspaces. They are not alone; preserve peer edits and do not stage unrelated files.

Root additionally owns app_private_roots.dart, app_backup_codec.dart, app_restore_gate.dart, restore_complete_page.dart, app.dart and their tests. Backup Pi owns splash_screen.dart startup integration. Restore uses a second cold-start gate because Java native runtime prepares before shared bootstrap. Root discovery deduplicates mobile roots and refuses desktop Documents; ZIP compression streams in an isolate. Preserve link objects without following targets, reject link ancestors and invalid normalized paths before extraction, and keep transaction journal separate from payload.

After each implementation handoff, all three Pi received separate follow-up scopes. Native check workers also reviewed the floating control, startup gates and transaction recovery. Root serializes Flutter tests in each package after production handoffs and owns final scoped commits.

Import resolves plugins and active profile on the main isolate, then validates and stages in a worker isolate. It retains one decompressed member at a time. An explicit empty root is a valid replacement. Restore checks transaction-root completeness before recovery, protects original journal.json through a control/originals split, atomically updates journals and infers interrupted moves from disk. A registry rewrite failure propagates to rollback. Rebase only known private path fields and use the transaction's resolved root mapping.
