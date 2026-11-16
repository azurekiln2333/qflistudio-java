# Native GitHub builds

## Goal

Build existing mobile OpenJDK runtimes on GitHub. Let the developer reuse small
downloadable outputs without retaining a local native compilation environment.

## Background

- Local main is 9632d0f and has unrelated OHOS edits.
- Local main and GitHub main diverged. Cloud verification needs a new branch.
- Existing recipes cover Android and OHOS, both ARM64 and x86_64.
- The registered WSL distribution occupies approximately 78.99 GiB by file length.
- Nine pinned Termux dependency URLs return 404. All 19 dependency packages
  exist locally and match their recorded hashes, totaling 16.12 MiB.

## Requirements

- R1: Report repository status and the main sources of local disk usage.
- R2: Add target-selectable GitHub Actions for the existing four native targets.
- R3: Publish per-target images, staged app inputs, checksums, provenance and logs.
- R4: Recover pinned inputs without silently changing runtime dependencies.
- R5: Commit task-owned changes and push an isolated build branch. Preserve
  unrelated edits and both existing main branches.
- R6: Execute the workflow and report observed results and artifact URLs.
- R7: Explain future local cleanup. Leave the WSL distribution intact in this task.
- R8: Match the main qflistudio project GPL-3.0 license text and make the
  declaration explicit across localized README files. Commit and push this update.

## Acceptance criteria

- A1 (R1, R7): Distinguish sources, build environment, intermediates and reusable inputs.
- A2 (R2, R5): The new workflow has an observable GitHub Actions run.
- A3 (R3, R6): Successful targets expose downloadable archives and SHA-256 checksums.
  Failed targets expose useful logs and a concrete failure explanation.
- A4 (R3): Staging preserves legal notices and existing ELF architecture checks.
  Android also passes its existing 16 KiB alignment checks.
- A5 (R4): All retained dependency archives are verified against existing lock files.
- A6 (R6): Provide the actual run link, artifact names, and restore instructions.
- A7 (R8): The license text matches the main project, each README names GPL v3.0,
  and the user receives the conventional commit subject and pushed revision.

## Out of scope

- Flutter APK/HAP builds, signing, application releases and mobile device tests.
- Reconciling main branches or changing unrelated application code.
- Deleting build folders, unregistering WSL, or compacting VHDX.

## Planning status

The user approved task creation and continued planning on 2026-11-17.
GitHub API access confirmed the signed-in account can push to the public repository.
The official OpenHarmony 6.0 SDK download and checksum are identified; the cloud
run will verify its extracted native resources. No product decision remains open.

The user added the GPL-3.0 alignment and commit/push request during execution.
