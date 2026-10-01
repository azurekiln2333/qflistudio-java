# Native OpenJDK

The app uses native OpenJDK 17.0.20 for mobile Java compilation and execution.
These recipes build headless images; desktop builds use the host's installed
JDK. Generated images and package assets are ignored by Git.

| Target | ABI | VM | Execution in the app |
| --- | --- | --- | --- |
| Android API 28+ | ARM64, x86_64 | HotSpot server | Installed native launchers |
| HarmonyOS | ARM64, x86_64 | Zero | A native child loads the packaged JVM |

Build recipes and pinned input details:

- [Android](android/README.md)
- [HarmonyOS](ohos/README.md)

## Stage An Image

Use PowerShell 7. An image mirror must contain actual files rather than symlinks;
Windows access through WSL UNC paths does not reliably follow the image's legal
notice symlinks. Export from WSL with GNU tar and dereference both symbolic and
hard links, then extract into a new directory under `build/staged-images`:

```bash
tar -chzf /mnt/d/MyNewProjects/qfli_java/build/jdk-image.tar.gz \
  --hard-dereference --exclude='*.debuginfo' --exclude=lib/src.zip \
  -C /path/to/images/jdk .
```

```powershell
New-Item -ItemType Directory -Force build/staged-images/my-jdk
tar -xf build/jdk-image.tar.gz -C build/staged-images/my-jdk
./native/openjdk/stage.ps1 -Platform android -Abi arm64-v8a -Image build/staged-images/my-jdk
```

For HarmonyOS, use `-Platform ohos` and stage each desired ABI with its own
image. The script validates ELF architecture and creates:

- `native/build/PLATFORM/jniLibs/ABI/*.so`: installed native libraries and tools.
- `native/build/PLATFORM/assets/jdk-ABI.zip`: modules, configuration, legal notices.
- `native/build/PLATFORM/assets/jdk-ABI.json`: versioned layout and content ID.

Android Gradle includes these locations directly. HarmonyOS staging also copies
libraries to `ohos/entry/libs/ABI` and assets to the module's rawfile resources.
The app extracts changed JDK data once, checks libraries, and probes real Java
and javac version output before marking the runtime available.

The source archive and patches are pinned in the build recipes. Keep the
image's legal notices in distributed packages; staging includes them. Source
archives are available through the recorded upstream URL and checksum, with
all local changes in this directory.

## Verify

```text
flutter test
dart analyze lib tools/jdk_smoke.dart
flutter build apk --debug --target-platform android-arm64
flutter build hap --debug --target-platform ohos-x64
flutter build hap --debug --target-platform ohos-arm64
```

The standalone mobile smoke entry uses the same runner as the editor and
checks real versions, multiple sources, `input.txt`, UTF-8 output, compilation
diagnostics, exit code 7, and cancellation:

```text
flutter run -t tools/jdk_smoke.dart -d DEVICE_ID
```

Success is one `QFLI_JDK_SMOKE` JSON log with `"ok":true`. Build the normal
`lib/main.dart` entry again after using a smoke package.

## Verification On 2026-09-30

All three native images completed `make images`. Android ARM64 APK and
HarmonyOS ARM64/x86_64 signed debug HAPs were built. The HarmonyOS x86_64 phone
simulator on OpenHarmony 6.1.1.125 (API 24) passed all eight in-app smoke checks.
Sixteen Flutter tests passed, including the desktop JDK runner and the native
process transport. Android and HarmonyOS ARM64 physical execution is pending
device availability.

## Android Emulator Verification On 2026-10-01

The normal Android ARM64 app opened on the Pixel_10 x86_64 emulator using
ARM64 translation and 16 KB pages. The in-app smoke test failed before its
first check: the JDK launcher has 4 KB ELF LOAD alignment, and the emulator's
ARM64 linker rejects it on a 16 KB system. The installed ELF matched the
staged file and contained the symbol table reported missing by the native
bridge. This is a failed Android runtime check; 16 KB compatibility must be
fixed before repeating it. See the [Android verification details](android/README.md).
The normal app was restored after testing.

## Android x86_64 Verification On 2026-10-02

The new 16 KiB aligned x86_64 image passed all eight in-app JDK checks on
emulator-5560, API 37. The retained upstream spawn implementation is rebuilt
with 16 KiB alignment; the pinned old binary package alone is incompatible.
The complete image's 46 native files passed architecture, LOAD alignment and
dependency checks. Nineteen Flutter tests passed on Windows, including actual
host-JDK execution. Android ARM execution still needs a matching device.
