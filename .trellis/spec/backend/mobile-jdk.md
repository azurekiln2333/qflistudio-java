# Mobile JDK Contract

## 1. Scope

Use this contract when modifying OpenJDK recipes, mobile installation, runtime
availability, process transport, or the Java Run action. Ownership is in
`lib/mobile_jdk.dart`, `lib/java_runner.dart`, the platform JDK bridges, and
`native/openjdk`. The shared editor consumes `ProgramRunResult`.

## 2. Signatures

The Flutter channel is `qfli_jvmx/jdk`:

| Method | Arguments | Result |
| --- | --- | --- |
| `prepare` | none | layout map |
| `start` (OHOS) | `home`, `libraries`, `cwd`, `input`, `output`, `error`, `args` | child PID |
| `poll` (OHOS) | `pid` | null while running; integer exit code after reaping |
| `cancel` (OHOS) | `pid` | null after requesting SIGKILL; caller awaits exit |

`startJava(home, libraries, cwd, input, output, error, args): number` creates
the native child. `pollJava(pid): number | null` and `cancelJava(pid): void`
accept only children owned by this bridge; cancel is idempotent after reaping.

## 3. Contracts

All layout fields (`home`, `java`, `javac`, `libraryDirectory`) are nonempty
absolute strings. Manifests have `version: 1`, a content `id`, and `libraries`
with `path` and `library`. Installation uses `files/usr-install` then replaces
`files/usr`; `.qfli-jdk-id` caches only extracted data. Version probes still run
on each fresh app process, and successful preparation is cached per Dart isolate.

Android supports arm64-v8a and x86_64 and selects its data ABI from the installed
launcher's ELF64 machine (183 or 62). Read the header using DataInputStream APIs
available at minSdk 28. Android executes installed `libqfli_java.so` and `libqfli_javac.so`, with native
library extraction enabled. It creates data-directory links to installed code.
OHOS uses a forked native child and `dlopen`/`JLI_Launch`, without ELF exec or
symlinks. `args` includes `java` as argv[0]. Javac is the module entry
`jdk.compiler/com.sun.tools.javac.Main`.

Required environment: `JAVA_HOME`, `QFLI_JAVA_HOME`, `TMPDIR`, library paths.
OHOS additionally uses `QFLI_NATIVE_LIBRARY_DIR` for the flat installed native
library location. Zero entry record memory is non-executable; JLI skips host
re-exec in this mode; JVM exit bypasses inherited host exit handlers.

`MobileJvmLaunch` creates the app-owned `home/tmp` directory before each mobile
launch and when returning a cached prepared layout. `TMPDIR` alone does not set
the packaged OHOS JVM's `java.io.tmpdir`; prepend an explicit
`-Djava.io.tmpdir=<home/tmp>` before caller options. Android's javac launcher
requires `-J-Djava.io.tmpdir=<home/tmp>`. The OHOS module compiler, analyzer and
JDI helper all pass through the same native JVM launch path. A later explicit
caller property retains the launcher's last-value-wins behavior. Desktop/WSL
toolchains do not inherit a cached mobile layout or this default.

## 4. Validation And Errors

| Condition | Behavior |
| --- | --- |
| Wrong ELF ABI during staging | staging fails |
| Any Android launcher/helper/SO LOAD has alignment below 16384 or incongruent offset/address modulo 16384 | staging fails |
| Unsupported manifest version, missing modules/library | `JDK_PREPARE_FAILED` |
| Null/relative layout path | Dart `FormatException` |
| Version command fails or has no expected version text | preparation fails; unavailable |
| Native stream, fork, wait, cancel failure | `JDK_PROCESS_FAILED` |
| javac fails | diagnostics, `kProgramNotRunExitCode`, no JVM run |
| Java exits with N | return N |
| Native child killed by signal S | return 128 + S |

## 5. Cases

- Good: multiple Java sources and a package, input.txt, Chinese stdout, code 0.
- Base: empty stdin is EOF, temp compiler output is removed on completion.
- Bad: malformed source produces javac diagnostics and never starts main.
- Bad: an ELF-only build passes packaging but execution is denied on device.
- Bad: the JVM is aligned but the pinned libandroid-spawn.so package is not.
  Rebuild the retained upstream spawn source with both 16 KiB linker flags;
  package its BSD license in legal/qfli-android-spawn. All dependencies must pass.

## 6. Required Verification

`flutter test` covers desktop compilation and the OHOS transport's fragmented
UTF-8, final stream drainage, stdin path, cancellation, and exit status.
`test/mobile_jvm_launch_test.dart` covers actual temporary-directory creation,
cached-layout recovery, Java/javac option ordering, desktop isolation and real
`Files.createTempFile`/`createTempDirectory` behavior. The OHOS transport test
also checks the property for normal, module-compiler and JDI helper launches.
`tools/jdk_smoke.dart` must run inside the app for each available target ABI.
Require `QFLI_JDK_SMOKE` with all eight checks and `ok:true`. ARM64 packaging
success on Windows is not physical-device runtime evidence. Rebuild and install
the normal app after the smoke entry. Keep generated runtime assets out of Git.

## 7. Wrong And Correct

Wrong: infer availability from bundled filenames or a zero exit code alone.
Correct: verify actual Java and javac version text before setting availability.

Wrong: treat the launcher's 16 KiB alignment as evidence for the whole image.
Correct: inspect every packaged native input, dependency closure, and real
in-app execution on a device using that page size. The 2026-10-02 x86_64
image passed all eight smoke checks on the API 37, 16 KiB emulator.

The 2026-10-02 ARM64 recovery rebuilt the stale 4 KiB package using the current
recipe. All 71 exported non-debug ELF files and all 44 staged ARM64 native files
passed. Treat ABI packages independently: a new recipe or x64 pass does not
refresh a previously staged ARM64 package. Keep the other ABI and OHOS inputs
unchanged and compare their hashes before and after staging.

For APK provenance checks, reproduce the actual Gradle strip step with the
configured NDK: `libqfli_*.so` retains its staged hash; other native JDK libraries
are compared with `llvm-strip --strip-unneeded` output. Verify architecture,
all LOAD alignments/congruence and dependency closure on the APK's resulting
files, then compare both ABI manifests and ZIP assets directly with staged
assets. A direct raw-image hash comparison is insufficient after stripping.
All 89 JDK native files in the owning dual-ABI APK passed these checks. ARM64
and API 28 device execution still require a matching available environment.

Wrong: reuse Android binaries on OHOS or request executable anonymous memory
for Zero's entry records.
Correct: cross compile for OHOS libc and mark Zero entry storage non-executable.

Wrong: execute HAP library files or create ArkTS symlinks on the tested phone.
Correct: load installed libraries in a native child with explicit data/code paths.
