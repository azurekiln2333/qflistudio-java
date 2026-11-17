# Implementation plan

- [x] Complete SDK, input recovery and authentication research.
- [x] Present final review and activate after approval.
- [x] Delegate workflow, input preparation, artifact packaging and documentation.
- [x] Validate workflow syntax, shell scripts and existing staging contracts.
- [x] Run an independent Trellis check and resolve confirmed findings.
- [x] Commit only task files and push an isolated GitHub branch.
- [x] Observe matrix runs, repair failures and rerun affected jobs.
- [x] Inspect artifact inventories and deliver actual download links.
- [x] Update the native build spec and record session progress.

Android ARM64 and x86_64 passed in run `43924543964`. Their artifact IDs are
`14255917408` and `14256047392`. OHOS retry `43942616850` at `d136c72` still
requires repair and verification. See `results.md` for the recorded status.

## Validation

Use actionlint/YAML validation, bash -n, representative stage.ps1 checks,
git diff --check and the observed GitHub matrix/artifact results. Run the
controlled Chinese linter on any Chinese documentation added by this task.

## Risks

Cold builds can reveal missing downloads, SDK differences, runner capacity or
account-level Actions restrictions. Keep logs and report actual results.

All four cloud jobs and independent artifact checks passed. See results.md for
run links, downloads, source revisions, storage findings and scope limits.
