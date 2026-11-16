# Native builds on GitHub

The native workflow builds the mobile OpenJDK runtimes on GitHub. Download its
staged inputs to build the app locally without keeping an OpenJDK compiler
environment. The workflow produces native JDK inputs; APK and HAP packaging
remains a separate application build.

| Platform | ABI | VM |
| --- | --- | --- |
| Android API 28+ | `arm64-v8a` | HotSpot server |
| Android API 28+ | `x86_64` | HotSpot server |
| OHOS | `arm64-v8a` | Zero |
| OHOS | `x86_64` | Zero |

The jobs use Ubuntu 24.04, Clang/LLVM/LLD 18, a host JDK 17, and the existing
[Android](../android/README.md) and [OHOS](../ohos/README.md) recipes. Each target
has an independent job. A failed target does not cancel the other targets.

## Run and download

The [Native OpenJDK workflow](../../../.github/workflows/native-build.yml) runs
when native recipe or workflow changes are pushed to `main` or a
`ci/native-build-*` branch. The initial trial uses an isolated branch.
Manual runs accept `platform` (`all`, `android`, `ohos`) and `abi` (`all`,
`arm64-v8a`, `x86_64`). The GitHub **Run workflow** button becomes
available when the workflow file is on the default branch. After the workflow
has run once, GitHub also supports dispatching another ref through its API or CLI.

Open the repository's **Actions** tab, select the native build run, and open its
**Artifacts** section. Sign in to a GitHub account with repository read access
to download artifacts. Outputs are retained for 14 days. Save successful
downloads locally if they are needed beyond that period.

Check each target job's result. An artifact containing logs is diagnostic output;
it does not establish that the target produced a usable runtime.

The successful output artifact is named `native-PLATFORM-ABI-COMMIT`.
`COMMIT` is the full source commit hash. Its outer download is a ZIP containing:

| File | Purpose |
| --- | --- |
| `openjdk-PLATFORM-ABI-image.tar.gz` | Portable target JDK image with `bin`, `lib`, `conf`, `legal` and `release` |
| `openjdk-PLATFORM-ABI-staged.tar.gz` | Repository-relative application packaging inputs |
| `SHA256SUMS` | Checksums for the delivered files |
| `provenance.json` | Source commit, target and build input information |

The image archive contains real files rather than symbolic or hard links.
It excludes debug symbols and `lib/src.zip`, while preserving legal notices.
Logs are uploaded separately as `native-logs-PLATFORM-ABI-COMMIT` on success
or failure. SDKs, object files and full source build trees are not uploaded.

The separate [Verify OHOS artifacts workflow](../../../.github/workflows/verify-native-artifacts.yml)
downloads existing OHOS outputs and validates their API digest, internal checksums,
ELF architecture, staged files, legal notices and provenance. It does not compile
the JDK. Its optional `source_run` input selects a native build run; an empty value
selects the latest successful native run on the current branch. Both OHOS outputs
must exist. This is useful when the local network cannot reach an artifact's
storage endpoint. Results appear in the job summary and notice annotations.

## Restored application layout

Each staged bundle uses repository-relative paths. Extract it at the repository
root to restore the inputs expected by the application build. For example,
unzip an Android ARM64 artifact into `build/native-download/android-arm64`.
Compare these SHA-256 results with its `SHA256SUMS` entries before extraction:

```powershell
Get-Content build/native-download/android-arm64/SHA256SUMS
Get-FileHash -Algorithm SHA256 build/native-download/android-arm64/*.tar.gz
tar -xzf build/native-download/android-arm64/openjdk-android-arm64-v8a-staged.tar.gz
```

Run the commands from the repository root. Use matching platform/ABI filenames
for the other targets. Restore the target's generated inputs as one unit:

```text
native/build/PLATFORM/jniLibs/ABI/*.so
native/build/PLATFORM/assets/jdk-ABI.zip
native/build/PLATFORM/assets/jdk-ABI.json
```

Keep all three parts together for the same target. The `.so` files contain native
libraries and launchers. The ZIP contains Java modules, configuration and legal
notices. The JSON records the content ID and native library layout.

OHOS bundles also restore these copies used by HAP packaging:

```text
ohos/entry/libs/ABI/*.so
ohos/entry/src/main/resources/rawfile/jdk-ABI.zip
ohos/entry/src/main/resources/rawfile/jdk-ABI.json
```

Android staging checks ELF architecture and 16 KiB LOAD alignment. OHOS staging
checks the launcher architecture. A successful cloud build is compilation and
packaging evidence. Run the [mobile smoke checks](../README.md#verify) on a matching
device or emulator before claiming runtime compatibility. These target JDKs do
not run directly on Windows or on the Ubuntu build host.

## Fixed inputs

The recipes retain their OpenJDK source hashes, Termux patch hashes and dependency
lock files. Nine of the 19 locked Termux package URLs returned 404 during the
2026-11-17 audit. All 19 original packages were recovered from the local cache
and matched their recorded SHA-256 values, totaling 16.12 MiB.

The `native-build-inputs-v1` release retains these inputs for clean builds.
The retained packages keep their original bytes and notices. The accompanying
source bundle preserves source archives and the pinned Termux recipes and build
helpers. The workflow verifies the input archive before extraction; the recipes
also verify individual dependency hashes.

Android uses NDK `27.0.12077973`. OHOS uses the official OpenHarmony 6.0 SDK
archive `ohos-sdk-windows_linux-public.tar.gz`, with SHA-256
`a315834ac133625efc912bd078f3e2b2550868d04aef1b5aa4f9679c8b3c9d8e`.
The SDK comes from Huawei Cloud's OpenHarmony `6.0-Release` distribution.
Only its Linux native component is extracted. The build requires Clang 15.0.4
target resources and the selected OHOS sysroot. CUPS, fontconfig and X11 headers
come from Ubuntu development packages; OHOS binaries are compiled for OHOS.

## Local disk space

The 2026-11-17 audit found about 79 GiB in
`build/wsl/qfli-java-build/ext4.vhdx`. This file belongs to a registered WSL
distribution. Other large directories contained application intermediates,
Flutter caches and exported JDK images. The four existing staged runtimes in
`native/build` totaled about 290 MiB. These figures describe file lengths rather
than allocated filesystem space.

Cloud compilation prevents new local OpenJDK build trees, but it does not shrink
or remove the existing virtual disk. Keep the downloaded staged inputs for
local application packaging. Keep the application SDKs and Flutter tools needed
for APK/HAP builds. Full JDK image downloads are optional if only the staged
inputs are needed.

This workflow does not delete local files. After validating cloud outputs,
review and back up the WSL distribution before separately removing or compacting
it. Do not delete the entire local `build` directory while it contains a
registered distribution's virtual disk.
