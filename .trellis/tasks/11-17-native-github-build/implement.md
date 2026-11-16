# Implementation plan

- [x] Complete SDK, input recovery and authentication research.
- [x] Present final review and activate after approval.
- [x] Delegate workflow, input preparation, artifact packaging and documentation.
- [x] Validate workflow syntax, shell scripts and existing staging contracts.
- [x] Run an independent Trellis check and resolve confirmed findings.
- [ ] Commit only task files and push an isolated GitHub branch.
- [ ] Observe matrix runs, repair failures and rerun affected jobs.
- [ ] Inspect artifact inventories and deliver actual download links.
- [ ] Update the native build spec and record session progress.

## Validation

Use actionlint/YAML validation, bash -n, representative stage.ps1 checks,
git diff --check and the observed GitHub matrix/artifact results. Run the
controlled Chinese linter on any Chinese documentation added by this task.

## Risks

Cold builds can reveal missing downloads, SDK differences, runner capacity or
account-level Actions restrictions. Keep logs and report actual results.
