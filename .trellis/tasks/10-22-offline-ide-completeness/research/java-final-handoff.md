# Java final handoff — 2026-10-22

## Delivered and verified

- Curriculum100 ->280 paired tutorials/examples, including180 new substantive
  Java17 programs. Original IDs retained. All four mirrors inventoried:1120
  snippets,280 distinct payloads. Canonical before/after digests prove1540
  non-Java entries per aggregate and unrelated metadata unchanged.
- Nine direct Java tools: integer/bit, strings, JSON-to-Java, reference,
  descriptors, stack traces, class inspection, JAR/manifest inspection and real
  local debugger. Actual OHOS normal-main tools/debugger route was opened and
  captured; no intermediate product-tools menu.
- Frozen core CodeAnalyzer adapter compiles isolated dirty buffers using actual
  javac17/JSR199 offsets, preserves CRLF/UTF16 and local JARs, disables annotation
  processors, never runs user code or writes user sources, and separates clean
  from unavailable. Common UI/scheduling remains C-owned.
- Real local JDI/JDWP service and saved-source debugger page expose breakpoints,
  pause/resume, step-in/over/out, frames, locals, output and stop. The page says
  to save editor buffers first; it does not pretend to access dirty editor text.
- Fixed actual OHOS default `/tmp` failure at the mobile JVM launch boundary.
  All mobile JVMs now create/use app-owned home/tmp; Android javac forwards
  `-J-Djava.io.tmpdir`. Caller property overrides and desktop paths are preserved.
- Hardened process bounds/cancellation/drainage and binary/ZIP/descriptor/stack
  parsers. Review/test records describe concrete regressions and retained limits.

## Actual evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Final Java analysis | Clean | java-final-analysis.log |
| Final serial full app suite |235/235 PASS | java-final-full-test.log |
| Core Java content/render |23/23 PASS | java-final-core-content-tests.log |
| Full actual host Java17+javac17 |280/280 programs,1120 assertions PASS | java-final-host17-rerun.json |
| Actual OHOS catalog |280/280 programs,1120 assertions PASS; device gate true | java-ohos-x64-catalog-final.json |
| Actual OHOS type/syntax/clean diagnostics | Exact dirty-buffer UTF16, no writes/execution, cleanup PASS | java-ohos-x64-runtime-acceptance.json |
| Actual OHOS JDI lifecycle |16 checks PASS, cleanup confirmed | java-ohos-x64-runtime-acceptance.json |
| Normal main restore | Signed install/start and real Home/tools/debugger route PASS | java-main-ohos-x64-build.json; java-main-ohos.jpeg; java-tools-ohos.jpeg; java-debugger-ohos.jpeg |

Host: WSL qfli-java-build OpenJDK17.0.20.1. Target: Mate90Pro emulator,
127.0.0.1:5555, HarmonyOS7.0.0.107(SP8DEVC00E999R4P11), API26 x86_64,
OpenJDK17.0.20-internal Zero. This proves actual OHOS x86_64 behavior and does
not prove physical ARM64 behavior.

Final catalog SHA256:
`a6b40d9524919010b24fdb1946385083b20457b448d07b3300ccf2c7ea007ee0`.
Final runtime report SHA256:
`07789411f3921a86860f2f2c1da7275fd5ccc6559c902555c5190e1b7f82c7ba`.
Normal main signed HAP SHA256:
`71c5c823e7bc29673d0295f0272c7be7f06f73b2d091666105f92c3de8f9c387`.

Retained failed attempts are not overwritten: initial host279/280 had a WSL
launch resource failure, and initial OHOS266/280 had14 missing-/tmp failures.
Both full reports remain beside the final passing reports.

## Device/signing handoff

Global qfli-core-release-sync seq119 explicitly releases Java window100 to Web
request91. Normal main is installed; Java was cleanly force-stopped afterward.
The emulator remains live. No further Java device/daemon/emulator operation is
authorized by that window. Web receives next exclusive use; root must negotiate
a new window before touching the device again.

Pura90 cannot boot because its6.1.1 system image is absent. Do not restart it.
The usable instance is Mate90Pro7/API26. Existing per-bundle Java debugKey
certificate/profile/store worked with ordinary signed `hdc install -r`, followed
by `aa start -a EntryAbility -b com.azurekiln.qfli.java`. No unsigned bypass,
new credential, enrollment change or sibling signing identity was used. Other
apps must use their own bundle-matched signing configuration and verify actual
install. No private signing material belongs in reports or messages.

## Scope still open

- All original R1-R13 requirements remain represented in PRD/ledger. This Java
  evidence cannot close other products' runtime/content/module/header gates.
- Physical ARM64 execution is unavailable and remains open.
- C owns common editor/workspace/tree/highlighting/filter/Problems behavior;
  consume its source/test/device handoffs rather than claim independent Java
  ownership. Core C integration ef345913 and Java content9a1c8b9 are pushed.
- Shared URI reading allocates its native byte response before Java can apply
  its cap; bounded native URI transfer belongs to the common platform owner.
- Actual Windows JDK25 could not launch a supplementary-plane package name
  through either direct arguments or UTF8 argfiles. BMP Chinese Run/debug is
  tested; no universal Windows supplementary-identifier support is claimed.
- Standalone features use no remote services/package resolution. The debugger
  uses process-local loopback communication only.

Do not archive the umbrella task or mark the original goal complete from this
handoff. Product commits/pushes are recorded in the task ledger after execution.

## Commits and remote verification

- Core Java content:9a1c8b9e33bfa938d2b8ad2fc58164c631d1cc75, pushed and exact
  github/main verified before releasing the shared index.
- Java process/mobile fix:142a9f0db39dfe61f5088a7562839d30d09074de.
- Java tools/diagnostics/debugger:a377d1ba33f57ced75d2b54912517b4a25f723ae.
- Java exhaustive harness/evidence:f461881c2604d81b36b602f354361f584d4077b6.

All three Java work commits were non-force pushed together; exact github/main
ls-remote matched f461881c2604d81b36b602f354361f584d4077b6. A subsequent docs
handoff commit records these results. Java working tree was clean after the
work commits. No common workspace/explorer or other products' files were staged.
