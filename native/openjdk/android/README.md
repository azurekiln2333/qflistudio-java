# Android OpenJDK 17

This builds the native, headless OpenJDK 17.0.20 toolchain for Android ARM64
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
  --work-dir /root/qfli-android-openjdk \
  --cache-dir /mnt/d/MyNewProjects/qfli_java/build
```

`--configure-only` prepares and verifies all inputs, applies patches, and runs
OpenJDK configure. `--jobs` defaults to 8. The application ID defaults to
`com.azurekiln.qfli.jvmx`; changing `--app-id` requires a new work directory
because the Termux path patches embed that application prefix.

Inputs are fixed to the source archive SHA-256, the Termux commit
`d0f94da1e578a0c9550a84d408bc8ed0003882ec`, the Git blob hashes in
`termux-patches.lock`, and the package hashes in `dependencies.lock`.
`headless-fontmanager.patch` selects the headless AWT library when applying
Termux's fontmanager link fix. The common `app-layout.patch` lets the launcher
and VM resolve the provisioned JDK data through `QFLI_JAVA_HOME`.

The output is `WORK_DIR/source/build/linux-aarch64-server-release/images/jdk`.
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
No Android device is currently connected, so native execution on Android has
not been verified. The desktop runner continues to use the host JDK.

Android apps targeting API 29 or newer cannot execute binaries extracted into
their writable data directory. The app installs launchers through the
native-library packaging path with library extraction enabled, provisions
modules and configuration in `files/usr`, and sets the Java home and library
search path. The Android image cannot be used as a HarmonyOS runtime.

Stage the dereferenced image with `stage.ps1 -Platform android -Abi arm64-v8a`
before running `flutter build apk --debug --target-platform android-arm64`.
See the [shared staging instructions](../README.md).
