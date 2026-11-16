# Native GitHub Build Contract

## 1. Scope and trigger

Use this contract for `.github/workflows/native-build.yml` and
`native/openjdk/ci`. The workflow builds OpenJDK inputs independently of Flutter
and the sibling studio core. It does not build APK/HAP or prove device execution.

## 2. Signatures

Workflow dispatch accepts `platform: all|android|ohos` and
`abi: all|arm64-v8a|x86_64`. Pushes affecting native recipes or the workflow on
`main` and `ci/native-build-*` run all four targets. Each target runs:

```bash
bash native/openjdk/ci/prepare.sh
bash native/openjdk/ci/build.sh
bash native/openjdk/ci/package.sh
bash native/openjdk/ci/collect-logs.sh
```

`package.sh [IMAGE]` accepts a prebuilt image for a packaging check.
Preparation writes `NATIVE_SDK_DIR` through `GITHUB_ENV` for the next step.

## 3. Contracts

- `NATIVE_PLATFORM`, `NATIVE_ABI`, and `RUNNER_TEMP` are required. Scripts derive
  `native-downloads`, `native-work`, `native-artifacts`, and `native-logs` there.
- Ubuntu 24.04 supplies Clang/LLVM/LLD 18 and host OpenJDK 17. Limit jobs to four.
  Android uses NDK 27.0.12077973; OHOS uses the checksum-pinned official SDK.
- Choose one complete OHOS libc++ header tree. Prefer
  `llvm/include/libcxx-ohos/include/c++/v1` when it contains `__config_site`;
  otherwise use `llvm/include/c++/v1` for legacy SDKs. The public SDK's OHOS tree
  matches the target libraries' `std::__n1` ABI. Never use the host `__1` config.
  Do not combine generic and vendor trees: their include_next chains can hide
  size_t definitions. Preprocess `<limits.h>` and `<string>` before dependencies;
  an empty C++ compile does not test this header layout.
- Keep the OHOS headless build's X11 JNI stubs. Its X11SurfaceData.h must guard
  the Xrender include with `!HEADLESS`; removing X11 source files can remove JNI
  entry points. Include any new source patch in the prepared-source stamp.
- `inputs.lock.json` pins retained dependency and corresponding source bundles.
  Extract the dependency archive into the recipe cache, then verify every `.deb`
  against both existing dependency locks. Never silently upgrade missing packages.
- Distribute dependency notices in image/legal before staging. Keep source bundle
  provenance alongside notices. Do not drop notices when dereferencing links.
- Package real files, excluding debug symbols and lib/src.zip. Preserve the
  existing stage.ps1 ABI and Android 16 KiB alignment gates.
- `native-PLATFORM-ABI-COMMIT` contains image/staged tar.gz files, `SHA256SUMS`,
  and `provenance.json`. Staged paths are relative to the repository root.
  OHOS includes its libs/rawfile copies. Retain artifacts for 14 days.
- `native-logs-PLATFORM-ABI-COMMIT` is diagnostic output. It may exist for failed
  builds and must not be described as a successful runtime artifact.
- Keep contents permission read-only. Pin third-party actions by commit SHA.
  Use independent matrix jobs with fail-fast disabled. Cache downloads only.

## 4. Validation and error matrix

| Condition | Required behavior |
| --- | --- |
| Invalid target or missing required environment | Fail before build |
| Bundle, package, source or SDK checksum mismatch | Fail before consuming input |
| SDK lacks Clang 15.0.4 resources or target libc | Fail preparation |
| OHOS libc++ configuration headers are unavailable | Fail C++ preflight |
| Compile, ELF or notice validation fails | No success artifact; retain diagnostics |
| One target fails | Let other matrix jobs finish |
| Build succeeds | Publish checksummed inputs and explicit provenance |
| Local WSL disk is large | Report separately; never delete it from cloud setup |

## 5. Good, base and bad cases

- Good: a cold runner restores fixed bytes, builds a target, stages valid native
  files, and uploads archives that restore the expected app packaging paths.
- Base: dispatch one platform/ABI for a targeted retry.
- Bad: an old exported Android image has 4 KiB alignment; staging rejects it.
- Bad: public Termux mirrors remove pinned versions; preserve verified bytes
  with source/notices instead of editing hashes to accept unrelated inputs.

## 6. Required checks

Run actionlint, bash -n for changed shell files, Python syntax checks and
git diff --check. For input-bundle changes verify package/source hashes,
archive inventory, repeatability and rejection of corrupted cache bytes.
Observe the real GitHub run; inspect target conclusions and artifact inventories.
Do not substitute YAML validation for a cloud compilation result.

## 7. Wrong and correct

Wrong: upload a successful configure log and claim the JDK is built.
Correct: require make images, staging and checksummed artifacts to succeed.

Wrong: infer mobile compatibility from successful Ubuntu cross compilation.
Correct: report compilation/packaging evidence and retain separate device gates
from [Mobile JDK](mobile-jdk.md).

Wrong: infer the pinned SDK layout from a compiler driver's conditional branch.
Correct: inspect actual archive members and test target headers against their
matching library ABI before modifying the include-tree selection.

Wrong: delete build/ to recover space when it contains a registered WSL disk.
Correct: leave cleanup as a separate explicit operation after cloud verification.
