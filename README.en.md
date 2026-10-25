# QFLIJVMX (qfli_java)

[简体中文](README.md) · [繁體中文](README.zh-TW.md)

QFLIJVMX is an offline Java editor.
It compiles source with `javac`.
It runs programs with `java`.
The shared `qfli_studio_core` package supplies the interface.

## Features

- A file tree and syntax highlighting.
- Empty and Java project templates.
- Compilation of every project `.java` file.
- Local JAR dependencies under `lib/` and `libs/`.
- Standard input from `input.txt` at the project root.
- Compiler diagnostics and program output in the terminal.
- Compiler checks of unsaved buffers, with diagnostic locations in the editor.
  Analysis does not write source files or run user programs.
- A separate local JDI debugger page with breakpoints, stepping, stack frames and locals.
  That page reads saved files only.
- Built-in terminal commands for `javac` and `java` through the same JDK.
- Nine Java tool cards and nine shared tool cards directly on the tools page.
- 280 Java topics from the shared content package.
- These features need no internet connection.
  JDI uses a local loopback connection.
  The native OHOS entry rejects remote routes.

## Repository layout

This app is an independent repository.
Check out the shared core beside it.

```text
checkout-parent/
  qfli_studio_core/
  qfli_java/
```

`pubspec.yaml` references the core through a path dependency.
The editor override is `../qfli_studio_core/vendor/re_editor`.

## Setup

The project requires Dart `^3.11.5`.
Use a Flutter SDK that satisfies that constraint.
Run these commands in this repository.

```bash
flutter pub get
flutter run -d DEVICE_ID
```

Replace `DEVICE_ID` with the target device identifier.

## Desktop JDK

Windows, Linux and macOS use the host JDK.
The app searches in this order:

1. `QFLI_JAVA_HOME`
2. `JAVA_HOME`
3. Directories on `PATH`

Set either environment variable to the JDK root.
Its `bin/` directory must contain both `javac` and `java`.
Alternatively, add that `bin/` directory to `PATH`.
Compilation uses `--release 17`.
JDK 17 is recommended.
A pass on a newer host JDK does not establish a target-device pass.

## Multiple sources, JARs and input

The compiler collects project `.java` files recursively.
It skips directories whose names begin with a dot and the `build` directory.
The app collects JARs recursively under `lib/` and `libs/`.
It determines the entry class from the selected file.
It reads the package name from source.
The compiler writes its output to a temporary directory.
The app removes that directory after the run.
The default compile timeout is 60 seconds.
The default compiler-output limit is 512 KiB.

Write standard input to `input.txt` at the project root.
The app does not download dependencies.

## Mobile native JDK

Android and HarmonyOS packages can bundle OpenJDK 17.0.20.
Android uses HotSpot server.
HarmonyOS uses the Zero interpreter.
The image ABI must match the target device.
The app reports the JDK as available only after real version probes pass.

Build the platform image first.
Stage it as described in the build recipe.
Then package the app.

- [Native JDK overview](native/openjdk/README.md)
- [Android build recipe](native/openjdk/android/README.md)
- [HarmonyOS build recipe](native/openjdk/ohos/README.md)

## Checks and tests

Run these commands in this repository.

```bash
flutter analyze
flutter test
```

Host tests do not establish device behavior.
Run catalog acceptance from the shared-core repository.

```bash
dart run tool/verify_java_content.dart "JDK17_HOME"
```

Replace `JDK17_HOME` with the root of a real JDK 17 installation.
Acceptance covers 280 topic primary programs across 1120 catalog snippet entries.

Use the temporary entry points to check a target device.

```bash
flutter run -t tools/java_catalog_ohos_smoke.dart -d DEVICE_ID
flutter run -t tools/jdk_smoke.dart -d DEVICE_ID
flutter run -t tools/java_runtime_acceptance.dart -d DEVICE_ID
```

These entries check the catalog, JDK, diagnostics and debugging.
Restore the normal entry after acceptance.

```bash
flutter run -t lib/main.dart -d DEVICE_ID
```

## Verification scope

These results cover the source at the recorded dates.
Validate later revisions again on their target platforms.

| Date | Target | Result |
| --- | --- | --- |
| 2026-10-22 | WSL, OpenJDK 17.0.20.1 | 280/280 primary programs passed. |
| 2026-10-22 | App test host | 235 tests passed. Static analysis reported no issues. |
| 2026-10-22 | HarmonyOS 7.0.0.107, API 26, x86_64 | 280/280 primary programs passed. All 26 diagnostics checks and 16 debugger checks passed. |
| 2026-09-30 | OpenHarmony 6.1.1.125, API 24, x86_64 | All eight in-app JDK checks passed. |
| 2026-10-02 | Android, API 37, x86_64, 16 KiB pages | All eight in-app JDK checks passed. |

## Pending work and limits

- Device acceptance of the shared-editor debugger in this app remains pending.
- Complete acceptance of the exercise answers remains pending.
- Android and HarmonyOS ARM64 physical-device execution is unverified.
  Successful packaging does not establish a device pass.
- Android API 28 execution is unverified.
- Java execution is unavailable on iOS and Web.
- The Spring Boot preparation script and local JAR assembly code are available.
  The UI template is not connected.

## License

See [LICENSE](LICENSE).
