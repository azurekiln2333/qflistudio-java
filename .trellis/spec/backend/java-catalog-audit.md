# Java catalog and OHOS audit

## 1. Scope / Trigger

Applies to Java content authoring/generation in shared core and Java's packaged
audit harness. Java owns only Java-specific sources/tests and serialized Java
aggregate replacement; coordinate the shared index with the core integrator.

## 2. Signatures

Core: `dart run tool/verify_java_content.dart <jdkHome>
[--wsl-distribution <name>] [--report <path>] [--expected-topics <count>]`.
The release inventory independently expects 280 topics. An explicit historical
override must never silently become the current acceptance count.

Java: `tools/java_catalog_ohos_smoke.dart` executes bundled inventory through
`JavaProgramRunner`; `QFLI_JAVA_EXPECTED_TOPICS` is only for declared historical
baselines. `tools/build_ohos_audit.ps1 -Target <entry> -LogPath <path>
-ReportPath <path>` builds x86_64 audit or normal-main HAPs without installing.

## 3. Contracts

- Preserve original IDs001-100; release expansion adds101-280. All tutorials,
  examples and two legacy mirrors must represent280 distinct payloads and1120
  snippet assertions. Compare source/output/fixtures, not just titles/counts.
- Serialize aggregate writes; canonical before/after hashes must show every
  unrelated language record and metadata field unchanged. Never broad-stage
  shared assets or another owner's changes.
- Require real Java17 and javac17 probes. Use `--release17`, bounded process
  execution/output and strict UTF-8. Verify expected output and actual exit for
  every distinct payload, then attribute all mirrored snippets to that result.
  Output normalization only converts CRLF to LF and removes one final LF;
  spaces, additional newlines and all other characters remain significant.
- The host audit fixes locale/timezone. In-app audit exercises the real runner
  and device defaults; host success is never OHOS evidence. Record runtime,
  ABI, toolchain/assets/source hashes and each execution in retained JSON.
- Create audit cwd before version probes. Serialize progress report writes.
  Cancel and prove process exit before deleting workspaces; retain and abort
  if termination cannot be established. Never turn an incomplete run green.
- Emulator builder temporarily selects x86_64 and excludes ARM64 data, limits
  only its process packaging JVM, and restores original profile bytes and
  environment in finally. Inspect actual packaged ELF ABI and JDK data hashes.
  Production configuration remains ARM64. Do not confuse a signed filename
  with successful installation or runtime behavior.

## 4. Validation & Error Matrix

| Condition | Required result |
| --- | --- |
| Missing/extra/mismatched mirror or fixture | Inventory failure |
| JDK25 host with release17 compilation | No Java17 runtime acceptance |
| Compiler/run nonzero, timeout or malformed UTF-8 | Payload failure |
| Stream/termination unproven | Retained workspace, incomplete/failing audit |
| OHOS report before final item | `executionComplete:false`, gate false |
| Desktop audit passes | Host evidence only |
| x86_64 passes | No physical ARM64 claim |
| HAP succeeds but install fails | Packaging evidence only |

## 5. Good/Base/Bad Cases

Good:280 payloads compile/run in the installed OHOS runner and1120 mirror
assertions match their exact source/output identities. Base: an explicitly
requested old100 audit is labelled historical. Bad: expected count is derived
from a truncated input, or a transient launcher failure is retried and omitted
from evidence. Keep failed and later successful reports separately.

## 6. Tests Required

Run Java catalog inventory/cancellation/late-launch tests, core Java content and
render suites, then final exhaustive host and in-app runs. Preserve unrelated
record digests around generation. Require actual install/launch and final
report pull. Restore normal main and explicitly release the exclusive device
window to the queued product; leave other apps/daemon/data unchanged.

## 7. Wrong vs Correct

Wrong: `expected = topics.length`, then claim every example passed from examples
alone. Correct: independently assert280 and inventory all1120 mirrors before
execution. Wrong: infer packaged JDK works from ELF assets. Correct: retain
actual in-app compiler/runtime probes and per-item output/exit results.
