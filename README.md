# qfli_java

This Flutter app is an independent Git repository. Check out `qfli_studio_core` next to it before resolving dependencies.

```text
checkout-parent/
  qfli_studio_core/
  qfli_java/
```

Run `flutter pub get` here, then `flutter run` for the target device. The shared editor patch is provided by `../qfli_studio_core/vendor/re_editor`.

On Windows, Linux, and macOS, the Run action invokes a JDK's `javac` and `java` tools. Set `QFLI_JAVA_HOME` (or `JAVA_HOME`) to the JDK root, or put both tools from the same JDK on `PATH`. The editor compiles all project `.java` files, includes JARs under `lib/` and `libs/`, then runs the selected entry class. Compilation errors appear in the terminal. Put `input.txt` at the project root to supply standard input. The compiler output is temporary and removed after execution.

Android ARM64 and HarmonyOS ARM64/x86_64 packages can bundle native OpenJDK 17.0.20. Build and stage the platform image before packaging the app; see [native JDK builds](native/openjdk/README.md). Android uses HotSpot server, and HarmonyOS uses the native Zero interpreter because executable anonymous memory is restricted. Availability is reported only after real JVM and compiler version probes succeed.

On 2026-09-30, the HarmonyOS x86_64 phone simulator passed the in-app compilation and execution smoke checks, including standard input, UTF-8, compiler diagnostics, exit codes, and cancellation. Android ARM64 and HarmonyOS ARM64 packages build successfully; physical-device execution remains unverified.
