# Execution

- [x] Inspect and retain existing core inline implementation.
- [x] Extract JavaToolsGrid, wire toolsTabBuilder and add terminal card.
- [x] Validate both repos and review delivery 1 (initial core failures recorded; test harness corrections documented later).
- [x] Commit delivery 1 separately in core and Java, excluding signing config.
- [x] Extract language-neutral logic, pages and shared card widgets into core.
- [x] Compose common group with existing product tools and terminal.
- [x] Replace Java duplicates with core consumption, retain Java-specific tools.
- [x] Run analyze and full test suites in core and Java; review final behavior.
- [x] Update tool integration spec, record validation, commit delivery 2 per repo.
- [x] Record session and finish the resumed task. Do not push.

All Flutter tests use `--timeout 60s`. Commits follow Conventional Commits with
`Co-Authored-By: Claude <noreply@anthropic.com>` as requested in the resumed work.
