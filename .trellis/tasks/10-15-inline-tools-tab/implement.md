# Execution

- [ ] Inspect and retain existing core inline implementation.
- [ ] Extract JavaToolsGrid, wire toolsTabBuilder and add terminal card.
- [ ] Validate both repos and review delivery 1.
- [ ] Commit delivery 1 separately in core and Java, excluding signing config.
- [ ] Extract language-neutral logic, pages and shared card widgets into core.
- [ ] Compose common group with existing product tools and terminal.
- [ ] Replace Java duplicates with core consumption, retain Java-specific tools.
- [ ] Run analyze and full test suites in core and Java; review final behavior.
- [ ] Update tool integration spec, record validation, commit delivery 2 per repo.
- [ ] Record session and finish the resumed task. Do not push.

All Flutter tests use `--timeout 60s`. Commits follow Conventional Commits with
`Co-Authored-By: Claude <noreply@anthropic.com>` as requested in the resumed work.
