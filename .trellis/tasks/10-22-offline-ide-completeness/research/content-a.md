# Java content batch A — topics 101..160

Author: content author A (exclusive module). Task:
`.trellis/tasks/10-22-offline-ide-completeness` (goal R3: add well over 100
useful Java examples on top of the original 100; Java target 180 new pairs).
Date: 2026-10-22. Status: **delivered and verified (host scope)**; device scope
remains open, see *Open gates*.

## Scope and ownership

| Item | Value |
| --- | --- |
| New file (only file written in the product) | `qfli_studio_core/tool/java_content/java_topics_collections.dart` |
| Exported symbol | `const List<JavaTopic> javaCollectionTopics` |
| Topic ids | 101..160 (60 topics, contiguous, no gaps) |
| Import dependency | `java_topic.dart` only (data-only module, no `dart:io`) |
| Module size | 133,476 bytes, 2,533 lines, 60 `JavaTopic(` entries |
| sha256 | `e3a031ed2a7f82fcbcf1bea6aa9c877e3f6092d37b73695bbe051870636ffbef` |
| Not touched | aggregator `java_topics.dart`, generator, verifier, assets, tests, other language payloads |

Id ranges 161..220 (author B, `java_topics_io_time.dart`) and 221..280 (author C,
`java_topics_language.dart`) belong to the other authors; this module declares
no id outside 101..160, so the aggregator can concatenate the modules without
collision. Cross-checked: no shared id, title, or normalized code body with
`java_topics.dart`, `java_topics_io_time.dart`, or `java_topics_language.dart`.

## Content design

Every record has Chinese `summary`/`objective`/`explain`/`pitfalls` plus one
concrete `JavaTask` exercise with a hint and an answer that compiles as written.
Each `code` is a complete, formatted `Main` class; each `output` is the verbatim
stdout of a real JDK 17 run, so the pairs stay executable lessons rather than
prose. Sources are ASCII-only stdout where it does not weaken the lesson; the
Unicode topics intentionally print CJK and emoji to prove the point.

| Id | Title | Focus |
| --- | --- | --- |
| 101 | String 不可变与字符串驻留 | `toUpperCase` returns new object; literal pool vs `new`; `intern`; constant folding |
| 102 | 字符串比较与排序规则 | `compareTo` returns a difference; `CASE_INSENSITIVE_ORDER`; length comparator |
| 103 | char 与 Unicode 码点 | UTF-16 surrogate pair; `length` 2 for one emoji; `codePointCount` |
| 104 | 按码点遍历与反转 | `codePoints` stream; `Character.toChars`; dangling high surrogate |
| 105 | Unicode 规范化与等价比较 | NFC vs NFD; `equals` false on same glyph; `Normalizer` |
| 106 | 大小写转换与 Locale | Turkish dotless i; `Locale.ROOT` for protocol keys |
| 107 | String.format 格式化输出 | width, zero pad, hex, grouping; `Locale.ROOT` |
| 108 | strip、isBlank 与 repeat | Unicode whitespace vs `trim`; `lines` count |
| 109 | split 与 join 的边界行为 | trailing empty dropped; negative limit; `StringJoiner` |
| 110 | replace 与正则替换 | literal vs regex; `.` metachar trap |
| 111 | 双指针判断回文串 | O(1) space, skip punctuation, case-insensitive |
| 112 | Pattern 与 Matcher 分组提取 | compiled pattern, `find` loop, capture groups, evaluation order |
| 113 | 正则命名分组解析日志行 | `(?<name>…)`, `matches` vs `find`, group count |
| 114 | KMP 子串查找 | prefix function, linear scan, overlapping matches |
| 115 | 编辑距离（Levenshtein） | DP recurrence, rolling array, insert/delete/replace |
| 116 | 最长公共子序列 | 2-D table, backtracking, subsequence vs substring |
| 117 | 最长回文子串（中心扩展） | odd/even centers, start offset formula |
| 118 | Rabin-Karp 滚动哈希查找 | rolling window, modulus, verification on hash hit |
| 119 | 变位词分组 | sorted-character key, `computeIfAbsent`, stable grouping |
| 120 | LinkedHashSet 去重保序 | insertion order, `add` return value, TreeSet compare |
| 121 | subList 是视图而不是拷贝 | writes through; structural change invalidates view |
| 122 | 用 Deque 接口使用 LinkedList | O(1) ends vs O(n) `get`; ArrayDeque stack |
| 123 | Arrays.asList 与 List.of 的限制 | fixed-size set-only vs immutable; wrap in ArrayList |
| 124 | Collections 工具类常用方法 | sort/binarySearch insertion point/swap/max |
| 125 | 用 List.copyOf 做防御性拷贝 | constructor snapshot; immutable getter |
| 126 | EnumMap 按枚举索引 | ordinal array, declaration-order iteration |
| 127 | LinkedHashMap 实现 LRU 缓存 | accessOrder + `removeEldestEntry`; `serialVersionUID` |
| 128 | TreeMap 区间查询 | headMap/tailMap/subMap bounds; floor/ceiling |
| 129 | PriorityQueue 求 Top-K | bounded min-heap, O(n log k), k=0 guard |
| 130 | 用 ArrayDeque 做括号匹配 | stack, mismatch position, unclosed count |
| 131 | 单调队列求滑动窗口最大值 | index deque, expire from head, monotonic tail |
| 132 | 迭代器删除与并发修改异常 | fail-fast counter; `iterator.remove`; `removeIf` |
| 133 | removeIf、replaceAll 与 compute | default methods; `merge`; null-returning compute |
| 134 | Comparator 多级排序与空值 | `thenComparing`, `nullsLast`, explicit type witness |
| 135 | groupingBy 的嵌套下游收集器 | two-level grouping, TreeMap factories, summing |
| 136 | partitioningBy 二分分组 | true/false keys always present; averaging |
| 137 | Collectors.toMap 的冲突合并 | duplicate-key exception; merge fn; map factory |
| 138 | Collectors.teeing 一次遍历双聚合 | two downstreams + merger; Optional safety |
| 139 | IntStream 数值流 | range vs rangeClosed; summaryStatistics; boxed |
| 140 | iterate 与 generate 生成流 | infinite streams + limit; 3-arg iterate |
| 141 | takeWhile 与 dropWhile | prefix semantics vs filter; ordered streams |
| 142 | 流的惰性与 peek 调试 | nothing runs without terminal op; short-circuit trace |
| 143 | anyMatch、allMatch 与 noneMatch | short-circuit; empty-stream truth values |
| 144 | reduce 的三种形态 | Optional vs identity vs combiner |
| 145 | flatMap 展开嵌套结构 | `List::stream`, `Optional::stream`, chars |
| 146 | distinct 与 sorted 去重排序 | equals/hashCode dependency; comparator chains |
| 147 | mapMulti 一对一与一对多 | downstream consumer; explicit type witness |
| 148 | 用 IntStream.range 带下标遍历 | index mapping; range boundary; parallel caveat |
| 149 | Collector 与 joining 定制输出 | three joining overloads; mapping; trimming |
| 150 | Stream.toList 与不可变结果 | immutable vs Collectors.toList; copy |
| 151 | Optional 链式取值与 orElse 的代价 | eager `orElse` vs lazy `orElseGet` |
| 152 | Optional 安全读取 Map | `ofNullable`, `filter`, digit check, `parseInt` |
| 153 | OptionalInt 与 OptionalDouble | numeric optionals are not `Optional` |
| 154 | Optional.or 与 orElseThrow 链 | lazy fallback chain; informative exception |
| 155 | 对象数组排序与二分查找 | Comparator chain; `binarySearch` on sorted array |
| 156 | 计数排序 | count array, prefix sums, stability, range limits |
| 157 | 并查集与路径压缩 | parent/rank, union returns false, component count |
| 158 | 前缀和与区间求和 | n+1 array, half-open range formula |
| 159 | 滑动窗口求最长无重复子串 | last-seen map, monotone left pointer |
| 160 | 倒排索引综合练习 | tokenize, TreeSet postings, intersection query |

Levels: 11 beginner, 29 intermediate, 20 advanced — all three levels present.

## Verification evidence

Real toolchain: WSL distro `qfli-java-build`,
`/usr/lib/jvm/java-17-openjdk-amd64` — `javac 17.0.20.1`,
`java 17.0.20.1 (17.0.20.1+1-1-24.04-Ubuntu)`. Every program compiled with
`javac --release 17 -encoding UTF-8` and ran with
`-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8`; stdout compared byte-exactly
against the `output` field parsed back out of the emitted Dart module (so Dart
escaping is part of the checked surface). Class files report major version 61,
i.e. Java 17 bytecode.

| Evidence | Location |
| --- | --- |
| Per-topic results (id, level, status, class major, source sha16, line counts) | `research/content-a-jdk17-results.tsv` — 60 `OK` |
| Machine-readable verification payload (source/stdout sha256 per topic, module sha256, versions) | `research/content-a-verification.json` |
| `dart analyze tool/java_content/java_topics_collections.dart` | `No issues found!` |
| `javac -Xlint:all` sweep | 60/60 clean, zero warnings |
| Duplicate/collision gate (ids, titles, normalized code vs all four modules) | pass |
| Format gate (≥6 lines, `public class Main`, `static void main`, no tabs, no placeholder markers) | pass |

Reproduction commands (scratch scripts live outside the repo in
`D:/tmp_java_content_a`, deliberately not product files):

```bash
wsl -d qfli-java-build -- bash -lc 'cd /mnt/d/.../<id> && \
  /usr/lib/jvm/java-17-openjdk-amd64/bin/javac --release 17 -encoding UTF-8 -d classes Main.java && \
  /usr/lib/jvm/java-17-openjdk-amd64/bin/java -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -classpath classes Main'
python D:/tmp_java_content_a/verify_dart.py   # parses the emitted module, recompiles all 60
python D:/tmp_java_content_a/quality.py       # format/uniqueness gates
python D:/tmp_java_content_a/crosscheck.py    # collisions against sibling modules
python D:/tmp_java_content_a/lint.py          # -Xlint:all sweep
```

## Integration notes for the aggregator owner

- `java_topics_collections.dart` is data-only and imports `java_topic.dart`
  only. Concatenate as
  `[...javaTopics, ...javaCollectionTopics, ...javaIoTimeTopics, ...javaLanguageTopics]`
  and sort by `id` if a strict 001..280 order is required.
- Nothing in the module uses `dart:io`, network, files, time, randomness, or
  threads, so the emitted examples remain deterministic offline.
- No `$` or backslash appears in any Java source or expected output, so the
  Dart literals carry no interpolation/escape hazards.

## Open gates (not claimed here)

- The module is not yet wired into the aggregator/generator/tests; catalog
  parity, the 280-topic integrity test, and asset emission belong to the
  integration owner and were intentionally not edited by this author.
- OHOS device execution is unverified: `hdc list targets` was empty on
  2026-10-22. Host JDK 17 success is not device evidence.
