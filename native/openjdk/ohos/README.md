# HarmonyOS OpenJDK 17

This recipe builds headless native OpenJDK 17.0.20 for HarmonyOS ARM64 and
x86_64. It uses the SDK's OHOS target headers, libraries, libc++, and
compiler-rt with Linux-hosted Clang 18. ALSA and libffi are compiled for OHOS;
Android binaries are not reused.

## Build

Use Linux or WSL on x86_64 and an ext4 work directory. Install Clang/LLVM/LLD
18, `build-essential`, `autoconf`, `file`, `curl`, `zip`, `unzip`, and a complete
host JDK 17. Supply an OHOS native SDK with Clang 15.0.4 target resource files.
Its target sysroot and LLVM library resources can be copied from the local
DevEco SDK into a Linux path without spaces. The host compiler remains Linux
Clang 18.

The `--header-dir` input provides only the `cups`, `fontconfig`, and `X11`
header directories used by headless OpenJDK configure. It can point to the
Android recipe's extracted dependency headers after `--configure-only`; the
recipe does not import Android libc headers or binary libraries.

```bash
bash native/openjdk/ohos/build.sh \
  --sdk-dir /root/qfli-ohos-sdk \
  --boot-jdk /usr/lib/jvm/java-17-openjdk-amd64 \
  --header-dir /path/to/dependencies/include \
  --work-dir /root/qfli-ohos-arm64-jdk \
  --cache-dir /mnt/d/MyNewProjects/qfli_java/build \
  --arch aarch64
```

Use `--arch x86_64` for the simulator. `--configure-only` prepares sources,
builds dependencies, and verifies configure without compiling OpenJDK.
The output is `WORK_DIR/source/build/ohos-ARCH-zero-release/images/jdk`.

Inputs are pinned to the OpenJDK source SHA-256, ALSA 1.2.16.1 and libffi 3.4.8
release SHA-256 values, and three Termux symbol/map patches from the Android
lock file. Local patches address OHOS libc differences, native library paths,
launcher initialization, and child exit handling. Dependency patches produce
unversioned `.so` names accepted by the HAP native library packager. Choose a
new work directory when source inputs change.

## Runtime

HarmonyOS rejects executable anonymous mappings needed by the server JIT on
the tested phone simulator. Zero executes bytecode with OpenJDK's native C++
interpreter. `zero-memory.patch` makes its interpreter entry record storage
non-executable. This trades JIT performance for native JVM compatibility.

The tested app sandbox rejects symlinks and ELF execution from the packaged
native library directory. The NAPI bridge forks a child and loads installed
JDK libraries with `dlopen`, then calls `JLI_Launch`. Java data remains in
`files/usr`, while `QFLI_NATIVE_LIBRARY_DIR` points to installed native code.
Each command owns a fresh VM; `System.exit` and cancellation affect its child.
The child skips inherited host exit handlers, and dies when the parent exits.
Standard streams use temporary spool files read incrementally by Dart. The
bridge reaps the child and returns its real exit status.

This path uses POSIX process and library APIs. HarmonyOS's ArkTS native child
process API is documented as restricted to tablets and PC/2-in-1 devices, so
it does not cover the tested phone simulator. Physical phones must still be
tested for their OS process and library policies. Java `ProcessBuilder` is
subject to the same OS restrictions on executing external binaries.

See [staging and smoke checks](../README.md). On 2026-09-30 the x86_64 phone
simulator passed all in-app smoke checks. ARM64 image and HAP builds passed;
ARM64 execution has not been verified on a physical device.
