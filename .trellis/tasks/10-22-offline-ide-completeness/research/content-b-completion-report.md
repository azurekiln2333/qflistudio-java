# Completion report — Java content batch B (ids 161..220)

Owner: content author B. Umbrella task:
`.trellis/tasks/10-22-offline-ide-completeness` (R3 content expansion).
Date: 2026-10-22. Status: **delivered and verified (host scope)**; device scope
remains open, see *Open gates*.

## Delivered

| Deliverable | Location | Evidence |
| --- | --- | --- |
| 60 new Java 17 topic/tutorial pairs, ids 161..220 | `qfli_studio_core/tool/java_content/java_topics_io_time.dart` (new; `const List<JavaTopic> javaIoTimeTopics`) | real JDK 17 sweep below |
| Durable research, topic map and integration notes | `research/content-b.md` | — |
| Machine-readable invariant report | `research/content-b-verification.json` | `problems: []`, 0 overlaps vs the original 100 |
| Real JDK 17 per-topic sweep | `research/content-b-jdk17-results.tsv` | 60 × `OK`, `javac 17.0.20.1` / `java 17.0.20.1` |
| Reproducible verifier (scratch, not a product file) | `research/verify_io_time_topics.dart` | exit 0 |
| Reproducible JDK 17 runner (scratch, not a product file) | `research/run_j17_io_time.sh` | `pass=60 fail=0` |
| Locale/time-zone determinism matrix (scratch) | `research/run_j17_io_time_locale_matrix.sh` | `variants=4 pass=60 fail=0` |

Only one product file was created. `java_topics.dart`, the generator, the
verifier, the assets, the tests and every other language payload were left
untouched, and no file owned by another author was edited.

## Content summary

60 distinct topics covering sandbox-local I/O, byte buffers, charsets and text
encodings, checksums/digests, pure-JDK symmetric crypto and key derivation,
compression, serialization, regex, `java.time`, numeric edge cases, and one
combined persistence exercise (220). Levels span `beginner`, `intermediate` and
`advanced`; each topic ships a Chinese summary/objective/explain/concepts, at
least three pitfalls and one concrete exercise (prompt/hint/answer) derived from
that program's own data.

No duplication: ids, titles and whitespace-normalised code bodies are all unique
and have **0 overlap** with the original 100 topics.

## Verification performed

```
topics=60 uniqueIds=60 uniqueTitles=60 uniqueBodies=60 uniqueOutputs=60
baseline=100 idOverlap=0 titleOverlap=0 codeOverlap=0
levels=[advanced, beginner, intermediate] minPitfalls=3
allHaveTasks=true hasTbd=false problems=0
```

### Pass 1 — real JDK 17 (primary evidence, WSL `qfli-java-build`)

```
toolchain: javac 17.0.20.1 / openjdk version "17.0.20.1" 2026-08-18
pass=60 fail=0
```

Each program is compiled with `javac --release 17 -encoding UTF-8` and executed
with `java -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8`, then stdout is diffed
byte-exactly (trailing newline normalised) against the authored `output`.

### Pass 2 — locale / time-zone determinism matrix

The same compiled classes are re-run under `en_US/UTC`, `zh_CN/Asia-Shanghai`,
`tr_TR/Pacific-Kiritimati` and `ja_JP/Europe/Berlin`:

```
variants=4 pass=60 fail=0
```

This proves the outputs do not depend on a device's default locale, time zone or
Turkish-style dotless-i casing. All text file I/O additionally passes an
explicit `StandardCharsets.UTF_8`, so a non-UTF-8 default charset cannot change
behaviour.

### Static checks on the product module

```
dart format --output=none --set-exit-if-changed tool/java_content/java_topics_io_time.dart
  -> Formatted 1 file (0 changed)
dart analyze tool/java_content/java_topics_io_time.dart
  -> No issues found!
```

Authoring contract enforced by the verifier: `class Main` line, `main` line,
8-space indented body, ≥ 6 lines, no tabs, no backticks, no
`TODO/FIXME/省略/<code>/placeholder/TBD` markers, non-empty output, ≥ 2
concepts, ≥ 3 pitfalls, ≥ 1 exercise, `Java NNN：` title prefix, ids inside
161..220.

## Offline / OHOS safety

- No network, no DNS, no GUI/AWT, no third-party dependency; only `java.base`
  APIs plus `javax.crypto` (shipped in `java.base`).
- Only `java.base` charsets (`UTF-8`, `UTF-16LE`, `ISO-8859-1`, `US-ASCII`);
  nothing from `jdk.charsets`.
- Crypto uses SunJCE `AES/GCM`, `HmacSHA256` and `PBKDF2WithHmacSHA256`, all
  present in the standard OpenJDK 17 image; no hardware acceleration is assumed
  and no optional native libcrypto module is required.
- No `SecureRandom.getInstanceStrong()` (cannot block on entropy), no threads,
  no stdin, no `System.exit`.
- Every topic (161–220) removes its sandbox temp files and directory in a
  `finally` block. Topic 172 additionally drops the mapping and triggers a GC
  before deleting, because a live `MappedByteBuffer` keeps the file open on
  Windows. Zero leftovers verified on Linux and Windows (2 runs each).

## Open gates

- Device (OHOS) execution of the final bundled payload is still unverified; the
  umbrella task owns the in-app harness gate. Host JDK 17 evidence is not device
  evidence.
- The generator cap (`> 100 topics` throws) and the content test's exact-100
  assertions must be raised by the owner of those files before this module can
  be aggregated with the other batches.
