# Stage 2 — ohos Probe: Preparation And Blocker

Date: 2026-10-13

## Status: probe built and packaged; device run blocked on a pre-existing signing issue

## What Was Done

| Step | Outcome |
| --- | --- |
| 2.1 `tools/spring_boot_probe.dart` | Written; uses `MobileJdk.prepare()` + `OhosJdkProcess.start()` directly |
| 2.2 Asset staging | `lib/spring_boot_bundle.dart` materialises the bundled JARs from Flutter assets; `assets/spring_boot/3.5.16/` declared in `pubspec.yaml` |
| 2.3 Compile path | Probe compiles its sources through the same mobile `javac` module entry the product uses |
| 2.4 Launch + timing | Timestamps JVM launch, first output, and `PROBE_READY`; parses the port |
| 2.5 HTTP | Issues a real `HttpClient` GET to `127.0.0.1:<port>` and requires `PROBE_OK` |
| 2.6 Stop | Cancels and reaps the child |
| 2.7 JSON output | One `QFLI_SPRING_BOOT_PROBE` line with `ok`, `firstOutputMs`, `serverReadyMs`, `port`, `checks` |
| 2.8 Device run | **Blocked** — see below |
| `dart analyze lib tools test` | clean |
| `flutter analyze` | clean |
| `flutter test test/spring_boot_bundle_test.dart` | 4/4 pass |
| `flutter build hap --target-platform ohos-arm64 -t tools/spring_boot_probe.dart` | Dart/ArkTS/asset stages **succeeded**; only `SignHap` failed |

## Verified: The Probe Actually Builds And Packages

The build reached `entry:default@SignHap` and produced
`ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`
(239.5 MB, dominated by the two 47 MB JDK zips).

The packaged output contains the full Spring Boot set:

```
flutter_assets/assets/spring_boot/3.5.16/  ->  28 JARs, 17.46 MB, + manifest.json
```

So the Dart code, the ArkTS bridge, and the asset packaging are all correct. The
only thing that did not happen is signing, which is unrelated to this task.

## Blocker: Stale OHOS Signing Material (pre-existing)

```
hvigor ERROR: Failed :entry:default@SignHap
00303107 Configuration Error
Invalid storeFile value. Make sure it is not null or empty. The file must be
included in 'C:\Users\lichengyu\.ohos\config\default_ohos_Gu8zVby71b0t4gfRa-4NpIdkL2QGfz2fVEJ7JnRdkBg=.p12'
```

`ohos/build-profile.json5` references signing files that no longer exist:

| Referenced by build-profile.json5 | Present? |
| --- | --- |
| `...Gu8zVby71b0t4gfRa-4NpIdkL2QGfz2fVEJ7JnRdkBg=.p12` | **no** |
| `...Gu8zVby71b0t4gfRa-4NpIdkL2QGfz2fVEJ7JnRdkBg=.p7b` | **no** |
| `...Gu8zVby71b0t4gfRa-4NpIdkL2QGfz2fVEJ7JnRdkBg=.cer` | **no** |

`C:\Users\lichengyu\.ohos\config` now holds a **new** set generated today at
01:33:

```
default_ohos_udwsx4szjsVYdfsIlGUHNWjABzLiV5jMmp6fUlekYQM=.cer  (01:33:18)
default_ohos_udwsx4szjsVYdfsIlGUHNWjABzLiV5jMmp6fUlekYQM=.csr  (01:33:15)
default_ohos_udwsx4szjsVYdfsIlGUHNWjABzLiV5jMmp6fUlekYQM=.p12  (01:33:15)
default_ohos_udwsx4szjsVYdfsIlGUHNWjABzLiV5jMmp6fUlekYQM=.p7b  (01:33:23)
```

`build-profile.json5` has not been modified since commit `e45b4f0`, so the
referenced material existed then and was regenerated afterwards. Its p12
password is not stored in the repository and must not be guessed.

**This blocks every ohos build in this project, not only the probe.**

## Resolution Required (user)

Pick one:

- **A (recommended):** In DevEco Studio, open this project, go to
  File → Project Structure → Signing Configs, tick "Automatically generate
  signature", and sign in. DevEco writes the new paths and passwords into
  `ohos/build-profile.json5`.
- **B:** Update `ohos/build-profile.json5` by hand to point at the new
  `...udwsx4szjsVYdfsIlGUHNWjABzLiV5jMmp6fUlekYQM=` material, including its p12
  `storePassword` and `keyPassword`.

Until one is done, `entry-default-unsigned.hap` can be produced but not
installed, so the Stage 2 gate cannot be evaluated.

## Stage 2 Gate Status: OPEN

No measurement exists yet. The desktop baseline was 1.87 s with JIT; the ohos
Zero interpreter has no JIT and this number must not be extrapolated. Do not
proceed to Stage 3 on the strength of the desktop result.
