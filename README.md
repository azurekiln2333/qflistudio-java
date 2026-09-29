# qfli_java

This Flutter app is an independent Git repository. Check out `qfli_studio_core` next to it before resolving dependencies.

```text
checkout-parent/
  qfli_studio_core/
  qfli_java/
```

Run `flutter pub get` here, then `flutter run` for the target device. The shared editor patch is provided by `../qfli_studio_core/vendor/re_editor`.

On Windows, Linux, and macOS, the Run action invokes a JDK's `javac` and `java` tools. Set `QFLI_JAVA_HOME` (or `JAVA_HOME`) to the JDK root, or put both tools from the same JDK on `PATH`. The editor compiles all project `.java` files, includes JARs under `lib/` and `libs/`, then runs the selected entry class. Compilation errors appear in the terminal. Put `input.txt` at the project root to supply standard input. The compiler output is temporary and removed after execution.

The Android and HarmonyOS packages do not yet include a native OpenJDK toolchain. Their local Run action reports that no Java toolchain is installed. Desktop JDK integration is not a mobile OpenJDK port.
