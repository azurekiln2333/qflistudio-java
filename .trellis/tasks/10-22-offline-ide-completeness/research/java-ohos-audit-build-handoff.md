# OHOS x86_64 audit build handoff

2026-10-22. Build worker owns `tools/build_ohos_audit.ps1` and temporary
`ohos/entry/build-profile.json5` changes during its exclusive build window.
No emulator, device, hdc daemon, installed bundle, or signing material was
changed by this worker. The root retains device ownership.

## Repeatable build

```powershell
./tools/build_ohos_audit.ps1 `
  -Target tools/java_catalog_ohos_smoke.dart `
  -LogPath build/java-catalog-ohos-x64-build.log `
  -ReportPath .trellis/tasks/10-22-offline-ide-completeness/research/java-catalog-ohos-x64-build.json
```

Use `-Target tools/java_debug_smoke.dart` for the debugger probe and
`-Target lib/main.dart` to restore the normal app. Choose separate log/report
paths to retain each build's evidence. No device command is included.

The wrapper acquires an exclusive repository build lock and temporarily changes
only the entry profile's three existing selections: native ABI to x86_64,
excluded native ABI to ARM64, and ignored JDK data to ARM64. It sets
`JAVA_TOOL_OPTIONS=-Xms16m -Xmx256m -XX:+UseSerialGC` only in its process.
Both profile bytes and prior environment state are restored in `finally`.
An ignored `build/ohos-audit-profile-*.original` backup remains for recovery
after an abrupt process termination. The JSON report records its location.

## Initial catalog build (before the mobile temporary-directory fix)

The standard output filenames are reused by subsequent targets. The values
below identify this initial build only; consult each later target's JSON report
and verify its hash before installing. The fixed catalog report is
`java-catalog-ohos-x64-tmpfix-build.json`, and the diagnostics/debugger
acceptance report is `java-runtime-acceptance-ohos-x64-build.json`.

- Flutter build exit code: 0; final wrapper exit code: 0.
- Build start: 2026-10-22T06:05:12.7944856Z.
- Output: `ohos/entry/build/default/outputs/default/entry-default-signed.hap`.
- Flutter copy: `build/ohos/hap/entry-default-signed.hap`.
- Size: 194288469 bytes.
- SHA256: `810fff3e1a38f910e71f53883ed22c62c795b45524ca4adf16a4e90a34666670`.
- 43 packaged native libraries have verified ELF64, little-endian x86_64 headers.
- All 40 staged JDK native library names are present in the HAP.
- Packaged `jdk-x86_64.json` and `.zip` exactly match staged SHA256 values.
- No ARM64 native library or ARM64 JDK JSON/ZIP is included.
- Original/restored entry-profile SHA256:
  `a18ba4389f4f0ff53b8d883dbb4d4da74f8147597a73eec8651fc9b454a3bbf6`.
- Profile and environment restoration both report `true`.

The package has not been installed or executed by this worker. Packaging proves
neither current-device signing acceptance nor runtime/content correctness.
Root must retain actual install/launch/results and restore normal main after
all probes. Physical ARM64 runtime validation remains a separate gate.

## Signing state and handoff requirements

`ohos/build-profile.json5` already selects `debugKey` for product `default`.
Its configured local certificate, provisioning profile, and PKCS12 store under
`C:/Users/lichengyu/.ohos/config/` all exist. No new credentials were required
to complete signing, and the script does not alter or print private signing
values. Existing release material under `D:/Keystore/` also exists but was not
selected or changed.

Other product roots should preserve their own bundle's signing configuration;
this Java profile is not a shared profile for other applications. Their actual
signed HAP installation result must establish acceptance for their bundle and
the live device. A build-produced signed filename alone is not that evidence.

## Checks

PowerShell parser accepted the script without errors. `git diff --check`
passed for the owned script and temporary profile. An initial successful build
exposed current .NET's treatment of `SetEnvironmentVariable(name, $null)` as an
empty variable. The wrapper now restores an originally absent variable using
the PowerShell environment provider; the second real build confirms exact
absence restoration. The production entry profile has no diff.
