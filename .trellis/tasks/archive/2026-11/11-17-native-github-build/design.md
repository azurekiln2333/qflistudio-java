# Design

## Boundaries and matrix

Use Ubuntu 24.04 x86_64 jobs, Clang/LLVM/LLD 18 and a full host JDK 17.
Reuse existing recipes and staging. Native builds do not require Flutter or
the sibling studio core. Each of Android/OHOS and ARM64/x86_64 gets its own job.
Disable fail-fast, bound jobs and set a timeout.

## Inputs

Retain source and dependency hashes. Use a checksum-verified repository-owned
input archive for disappearing Termux packages. Include source/provenance and
licenses for retained binary dependencies. Pin an official OHOS SDK download
with Clang 15.0.4 target resources. Cache downloads, not full build trees.

## Outputs

Export a dereferenced JDK tar.gz per target, excluding debug symbols and lib/src.zip.
Run stage.ps1, then package repository-relative native/build paths and the copied
OHOS libraries/rawfile assets. Preserve legal notices. Include SHA256SUMS and
build/input provenance. Upload bounded logs on failure and on success.

## Rollout and rollback

Create a separate worktree and branch from github/main. Its native recipes match
local main, so copy only task-owned files without importing unrelated local commits.
Use a branch push trigger for the first run; workflow_dispatch may require a
workflow already registered on the default branch. The feature branch can be
abandoned without changing main. Never infer device execution from cloud compilation.
Local disk cleanup requires a later explicit action after usable cloud outputs exist.

## SDK decision

Use https://repo.huaweicloud.com/openharmony/os/6.0-Release/ohos-sdk-windows_linux-public.tar.gz
with SHA-256 a315834ac133625efc912bd078f3e2b2550868d04aef1b5aa4f9679c8b3c9d8e.
Extract only the Linux native component and check required Clang 15.0.4 resources
and target sysroots before compilation. The first cloud run validates compatibility.
For the three configure-only header directories, install the corresponding Ubuntu
CUPS/fontconfig/X11 development packages; no host binary libraries enter the image.
