# Native GitHub build results

Status recorded on 2026-11-17. All four native cloud build jobs passed. Android
artifacts passed independent local verification. Both OHOS artifacts passed
independent verification on GitHub.

## Delivery

Changes were committed and pushed to `ci/native-build-20261117` in
`azurekiln2333/qflistudio-java`. The branch starts from `github/main` and preserves
the original worktree's unrelated application edits.

- `d5e4026`: `ci(native): build and publish mobile JDK artifacts on GitHub`
- `036e77e`: `docs(license): declare GPL-3.0 across project readmes`

The root `LICENSE` already contains GNU GPL version 3. Its normalized text
matches `D:/MyNewProjects/qflistudio/LICENSE`; only line endings differ.
All three root README files now explicitly declare GNU General Public License
v3.0 and preserve third-party license notices. No file in the main studio
project was changed by this task.

## Verified Android outputs

Both Android targets completed native compilation and staging in
[run 43924543964](https://github.com/azurekiln2333/qflistudio-java/actions/runs/43924543964).
That first run is marked failed overall because its OHOS jobs failed. Both
Android jobs and their independently verified artifacts succeeded. Later fixes
affect OHOS, diagnostics and documentation, so Android was not rebuilt.

| Target | Result | Download |
| --- | --- | --- |
| Android ARM64 (`arm64-v8a`) | Passed | [Artifact 14255917408](https://github.com/azurekiln2333/qflistudio-java/actions/runs/43924543964/artifacts/14255917408) |
| Android x86_64 | Passed | [Artifact 14256047392](https://github.com/azurekiln2333/qflistudio-java/actions/runs/43924543964/artifacts/14256047392) |

The workflow retains artifacts for 14 days. Sign in to GitHub with repository
read access, open the run, and use its Artifacts section. Download and retain
the required outputs before they expire.

Each successful `native-PLATFORM-ABI-COMMIT` artifact contains:

| File | Contents |
| --- | --- |
| `openjdk-PLATFORM-ABI-image.tar.gz` | Dereferenced target JDK runtime image, including legal notices |
| `openjdk-PLATFORM-ABI-staged.tar.gz` | Repository-relative native libraries, JDK data ZIP and layout JSON |
| `SHA256SUMS` | SHA-256 checksums for delivered archives and provenance |
| `provenance.json` | Source commit, platform, ABI and build inputs |

Separate `native-logs-PLATFORM-ABI-COMMIT` artifacts contain diagnostics.
Extract a staged archive at the repository root after verifying its checksum.
It restores `native/build/PLATFORM/jniLibs/ABI` and the matching `assets` files.
OHOS bundles also restore the HAP library and rawfile copies.
See [download and restore instructions](https://github.com/azurekiln2333/qflistudio-java/blob/main/native/openjdk/ci/README.md).

These artifacts are JDK inputs for application packaging. They contain no APK
or HAP. Compilation and staging do not establish mobile device execution.

## OHOS cloud outputs

Both OHOS targets completed native compilation and staging in
[run 43945972223](https://github.com/azurekiln2333/qflistudio-java/actions/runs/43945972223)
at revision `6759444`.

| Target | Result | Download |
| --- | --- | --- |
| OHOS ARM64 (`arm64-v8a`) | Passed | [Artifact 14265448559](https://github.com/azurekiln2333/qflistudio-java/actions/runs/43945972223/artifacts/14265448559) |
| OHOS x86_64 | Passed | [Artifact 14265627524](https://github.com/azurekiln2333/qflistudio-java/actions/runs/43945972223/artifacts/14265627524) |

The ARM64 outer ZIP is 238,519,584 bytes. The x86_64 ZIP is 239,312,946 bytes.
Both expire on 2026-11-30 UTC under the configured 14-day retention policy.

The successful retries corrected the SDK libc++ header selection and guarded
an unused Xrender include in headless builds. The latter preserves X11 JNI
stubs. Both architectures passed real-source preprocessing before the final run.

Local downloads could not establish TLS with the assigned Azure Blob storage
endpoint. The separate [verification run 43949447383](https://github.com/azurekiln2333/qflistudio-java/actions/runs/43949447383)
downloaded and verified these exact artifacts on GitHub without rebuilding.
Both target notices report verification passed, with 66 image ELF files,
40 staged native files, and 235 legal files per architecture. Checks covered
API size/digest, ZIP CRC, internal SHA-256, all ELF architectures, image/staged
content equality, complete native library inventories, data/layout consistency,
legal notices, OHOS mirrors, source run, SDK and source commit provenance.

The independent workflow was committed as `796d5d0`:
`ci(native): verify published OHOS artifacts without rebuilding`.

## Local storage

The initial file-length audit found about 88 GiB under the original repository.
The registered WSL disk `build/wsl/qfli-java-build/ext4.vhdx` accounts for about
79 GiB. Other large items include `build/app` (2.6 GiB), `build/ohos` (1.0 GiB),
Flutter caches and exported JDK images. Existing staged runtimes in `native/build`
total about 290 MiB. These figures are file lengths, not allocated disk usage.

Cloud builds avoid new local OpenJDK compilation trees. They do not remove or
shrink existing local files. Local app packaging still needs the staged runtime
inputs and application SDKs. The original WSL distribution and application build
files were preserved. The task-owned SDK archive and verified Android download
copies were removed after validation, recovering about 1.14 GiB by file length.
Review and back up the registered distribution before separately removing or
compacting it; do not delete the entire `build` directory.

## Acceptance

- All four native targets built successfully on GitHub.
- Runtime artifacts and their download links were independently verified.
- GPL declarations match the main studio project and were committed/pushed.
- Native CI and SDK/headless build findings are recorded in the project spec.
- The original application changes and WSL environment remain intact.
- The work was merged into `main` at `a0e8899`.
- Both temporary branches were removed after ancestry checks found zero unique commits.
- Device runtime tests and full APK/HAP packaging remain outside this task.
