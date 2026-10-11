# Android OpenJDK 17

This builds the native, headless OpenJDK 17.0.20 toolchain for Android ARM64 and x86_64
(API 28 or newer). Compilation uses HotSpot and the OpenJDK Java modules.

## Build

Use Linux or WSL on x86_64 with an ext4 work directory. Required packages on
Ubuntu 24.04 are `clang-18`, `llvm-18`, `lld-18`, `build-essential`, `autoconf`,
`file`, `curl`, `zip`, `unzip`, and `zlib1g-dev`, plus a complete JDK 17.
Android NDK 27 supplies the target sysroot and compiler-rt. Both its Linux and
Windows archives contain those target files; the compiler runs on Linux.

```bash
bash native/openjdk/android/build.sh \
  --ndk-dir /mnt/d/ProgramData/Android/Sdk/ndk/27.0.12077973 \
  --boot-jdk /usr/lib/jvm/java-17-openjdk-amd64 \
  --abi x86_64 \
  --work-dir /root/qfli-android-openjdk \
  --cache-dir /mnt/d/MyNewProjects/qfli_java/build
```

`--configure-only` prepares and verifies all inputs, applies patches, and runs
OpenJDK configure. `--jobs` defaults to 8. The application ID defaults to
`com.azurekiln.qfli.jvmx`; changing `--app-id` requires a new work directory
because the Termux path patches embed that application prefix.

The default ABI is arm64-v8a. Use a separate work directory for each ABI.
Inputs are fixed to the source archive SHA-256, the Termux commit
`d0f94da1e578a0c9550a84d408bc8ed0003882ec`, the Git blob hashes in
`termux-patches.lock`, and the package hashes in `dependencies.lock` or
`dependencies-x86_64.lock`. The retained upstream [spawn source](spawn/README.md)
is rebuilt because the pinned binary package has 4 KiB LOAD alignment.
`headless-fontmanager.patch` selects the headless AWT library when applying
Termux's fontmanager link fix. The common `app-layout.patch` lets the launcher
and VM resolve the provisioned JDK data through `QFLI_JAVA_HOME`.

The output is `WORK_DIR/source/build/linux-CPU-server-release/images/jdk`,
where CPU is aarch64 or x86_64. Native links use 16 KiB page alignment;
staging rejects any incompatible launcher, helper or shared library.
The script adds the Android compatibility libraries and NDK C++ runtime to its
`lib` directory. The image retains OpenJDK's modules, command-line tools,
licenses, and source archive. It has no X11 GUI backend.

## Verification State

On 2026-09-30, the equivalent native build recipe completed `make images` in
the isolated `qfli-java-build` WSL distribution. ELF inspection confirmed ARM64
and `/system/bin/linker64`, and the image contains `java`, `javac`, `jar`,
`javap`, and `jshell`.

The image is integrated into the Android package. An ARM64 debug APK was built
and its archive inspected for the launchers, JVM, dependencies, and JDK data.
Android ARM64 physical-device execution remains unverified. The desktop runner
continues to use the host JDK.

On 2026-10-01, the APK was installed on the Pixel_10 x86_64 emulator with
ARM64 translation (`libndk_translation.so`) and 16 KB pages. The normal app
opened, but `tools/jdk_smoke.dart` failed before the Java version check with
`missing DT_SYMTAB`. The installed launcher matched the staged SHA-256 and
contained `DT_SYMTAB`. Invoking the emulator's ARM64 linker directly instead
reported `program alignment (4096) cannot be smaller than system page size
(16384)`. Both the launcher and `libjvm.so` have 4 KB ELF LOAD alignment.
The JDK needs 16 KB compatible native binaries before this emulator can pass
the smoke checks. App page-size compatibility mode did not make the spawned
launcher work. The normal app was restored after testing.

Android apps targeting API 29 or newer cannot execute binaries extracted into
their writable data directory. The app installs launchers through the
native-library packaging path with library extraction enabled, provisions
modules and configuration in `files/usr`, and sets the Java home and library
search path. The Android image cannot be used as a HarmonyOS runtime.

On 2026-10-02, the x86_64 image passed all eight application-native checks on
emulator-5560 (API 37, 16 KiB pages): real Java/javac versions, multiple sources,
stdin, UTF-8, compiler diagnostics, exit status and cancellation. All 46 native
files in the image matched x86_64 and had 16 KiB LOAD alignment and congruence;
all DT_NEEDED dependencies were bundled or Android system libraries. The only
incompatible input was the old spawn package, repaired by rebuilding the retained
upstream source with the recipe's toolchain. No ARM device or API 28 emulator is
available here; their execution remains unverified.

Stage the dereferenced image with `stage.ps1 -Platform android -Abi ABI`
before building for the corresponding Flutter target (android-arm64 or
android-x64). The app selects data from the installed launcher's ELF machine,
using APIs available at the minimum Android version.
See the [shared staging instructions](../README.md).

### ARM64 Package Recovery On 2026-10-02

The earlier ARM64 package was stale: its launchers, JVM and other upstream
libraries still used 4 KiB LOAD alignment. A fresh pinned OpenJDK 17.0.20 build
completed in a separate ext4 work directory with the current recipe, including
the rebuilt upstream spawn library. All 71 non-debug ELF files in the exported
image passed ARM64, 16 KiB LOAD alignment/congruence and API 28 public-system or
bundled dependency checks. A broader check of the retained x64 image passed all
72 non-debug ELF files, including tools that are not staged into the app.

The owning ARM64 package now contains 44 native files with hashes matching the
new image. The ordinary dual-ABI APK contains those 44 ARM64 and the retained
45 x64 JDK files, plus three Flutter framework libraries. All 92 APK native
files passed their ABI, dependency and 16 KiB LOAD checks; both JDK data archives
matched staged assets. APK ZIP alignment also passed. All 215 inspected x64 and
HarmonyOS generated inputs remained unchanged during ARM64 staging.

APK hash checks must reproduce the owning Gradle transformation: preserve
`libqfli_*.so` exactly and apply NDK 27 `llvm-strip --strip-unneeded` to other
JDK libraries. Compare APK hashes with those transformed staged inputs; comparing
all files directly with the unstripped image incorrectly reports mismatches.
Generated images and package assets remain outside Git. Native ARM64 device and
API 28 execution remain unverified; x64 emulation is separate runtime evidence.
