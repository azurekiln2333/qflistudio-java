import 'dart:convert';

import 'package:flutter/material.dart';

import 'java_tools.dart';
import 'java_tools_extra.dart';
import 'java_tools_widgets.dart';

/// Scaffold shared by every Java tool detail page.
///
/// Keeps the app bar, the intro line and the responsive content column in one
/// place so each tool only supplies its own fields and results.
class JavaToolScaffold extends StatelessWidget {
  const JavaToolScaffold({
    super.key,
    required this.title,
    required this.description,
    required this.children,
  });

  final String title;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = JavaToolsTheme.horizontalPadding(
            constraints.maxWidth,
          );
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 40),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: JavaToolsTheme.contentMaxWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    ...children,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Text field styled like the rest of the page.
class JavaToolField extends StatelessWidget {
  const JavaToolField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.maxLines = 1,
    this.onChanged,
    this.monospace = true,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final bool monospace;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: controller,
      maxLines: maxLines,
      onChanged: onChanged,
      style: monospace ? const TextStyle(fontFamily: 'monospace') : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
      ),
    ),
  );
}

/// Inline error line; renders nothing when there is no message.
class JavaToolError extends StatelessWidget {
  const JavaToolError(this.message, {super.key});

  final String? message;

  @override
  Widget build(BuildContext context) => message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            message!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
}

/// A titled group of result rows inside an outlined surface.
class JavaToolResultCard extends StatelessWidget {
  const JavaToolResultCard({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(JavaToolsTheme.cardRadius),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(title!, style: theme.textTheme.titleSmall),
            ),
          ],
          ...children,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Integer and radix
// ---------------------------------------------------------------------------

class JavaIntegerToolPage extends StatefulWidget {
  const JavaIntegerToolPage({super.key});

  static const String title = '整数与进制';
  static const String description = '在十/十六/二/八进制间互转，按 Java 基本类型显示补码、溢出与位运算。';

  @override
  State<JavaIntegerToolPage> createState() => _JavaIntegerToolPageState();
}

class _JavaIntegerToolPageState extends State<JavaIntegerToolPage> {
  final _input = TextEditingController(text: '255');
  final _operand = TextEditingController(text: '0x0F');
  JavaPrimitive _type = JavaPrimitive.int_;
  JavaBitOp? _operation;

  @override
  void dispose() {
    _input.dispose();
    _operand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    JavaIntValue? value;
    String? error;
    var overflowed = false;
    if (_input.text.trim().isNotEmpty) {
      try {
        final read = readJavaInt(_input.text, _type);
        value = read.value;
        overflowed = read.overflowed;
        if (_operation != null) {
          value = applyJavaBitOp(
            value,
            _operation!,
            readJavaInt(_operand.text, _type).value,
          );
        }
      } on FormatException catch (exception) {
        error = exception.message;
      }
    }
    return JavaToolScaffold(
      title: JavaIntegerToolPage.title,
      description: JavaIntegerToolPage.description,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final type in JavaPrimitive.values)
              ChoiceChip(
                label: Text(type.label),
                selected: _type == type,
                onSelected: (_) => setState(() => _type = type),
              ),
          ],
        ),
        JavaToolField(
          controller: _input,
          label: '整数',
          hint: '十进制、0x、0b 或 0 开头八进制，可用下划线',
          onChanged: (_) => setState(() {}),
        ),
        if (overflowed) _OverflowNote(type: _type),
        JavaToolError(error),
        const SizedBox(height: 8),
        Text('位运算（可选）', style: Theme.of(context).textTheme.titleSmall),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final op in JavaBitOp.values)
              ChoiceChip(
                label: Text(op.symbol),
                selected: _operation == op,
                onSelected: (selected) =>
                    setState(() => _operation = selected ? op : null),
              ),
          ],
        ),
        if (_operation != null)
          JavaToolField(
            controller: _operand,
            label: '操作数',
            onChanged: (_) => setState(() {}),
          ),
        const SizedBox(height: 16),
        if (value != null)
          JavaToolResultCard(
            title: '${value.type.label} 表示',
            children: [
              JavaResultRow(label: 'Java 值', value: value.decimal),
              JavaResultRow(label: '十六进制', value: value.hexadecimal),
              JavaResultRow(label: '二进制', value: value.binary),
              JavaResultRow(label: '八进制', value: value.octal),
              if (value.charView != null)
                JavaResultRow(label: 'char', value: value.charView!),
              JavaResultRow(label: '补码位数', value: '${value.type.bits} 位'),
            ],
          )
        else
          const Text('输入一个整数以查看各进制与补码表示'),
      ],
    );
  }
}

class _OverflowNote extends StatelessWidget {
  const _OverflowNote({required this.type});

  final JavaPrimitive type;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(
      '超出 ${type.label} 范围，已按 ${type.bits} 位截断',
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

// ---------------------------------------------------------------------------
// 2. Unicode
// ---------------------------------------------------------------------------

class JavaUnicodeToolPage extends StatefulWidget {
  const JavaUnicodeToolPage({super.key});

  static const String title = '字符/Unicode';
  static const String description = '查看一个字符的码点、Java \\uXXXX 转义与 UTF-8 / UTF-16 字节。';

  @override
  State<JavaUnicodeToolPage> createState() => _JavaUnicodeToolPageState();
}

class _JavaUnicodeToolPageState extends State<JavaUnicodeToolPage> {
  final _input = TextEditingController(text: '中');

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? error;
    UnicodeInfo? info;
    final text = _input.text;
    if (text.isNotEmpty) {
      final runes = text.runes.toList();
      if (runes.length != 1) {
        error = '请输入恰好一个字符（当前 ${runes.length} 个）';
      } else {
        info = UnicodeInfo(runes.first);
      }
    }
    return JavaToolScaffold(
      title: JavaUnicodeToolPage.title,
      description: JavaUnicodeToolPage.description,
      children: [
        JavaToolField(
          controller: _input,
          label: '字符',
          onChanged: (_) => setState(() {}),
        ),
        JavaToolError(error),
        const SizedBox(height: 16),
        if (info != null)
          JavaToolResultCard(
            title: '编码',
            children: [
              JavaResultRow(label: '码点', value: info.hex),
              JavaResultRow(label: '十进制', value: '${info.codePoint}'),
              JavaResultRow(label: 'Java 转义', value: info.javaEscape),
              JavaResultRow(label: 'UTF-8', value: info.utf8BytesHex),
              JavaResultRow(label: 'UTF-16', value: info.utf16UnitsHex),
              JavaResultRow(
                label: 'UTF-16 单元数',
                value: '${info.utf16Units.length}',
              ),
            ],
          )
        else
          const Text('输入一个字符以查看它的码点与编码'),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3. String escaping
// ---------------------------------------------------------------------------

class JavaStringToolPage extends StatefulWidget {
  const JavaStringToolPage({super.key});

  static const String title = '字符串转义';
  static const String description =
      '普通文本 <-> Java 字面量互转，并生成保留换行的 text block。';

  @override
  State<JavaStringToolPage> createState() => _JavaStringToolPageState();
}

class _JavaStringToolPageState extends State<JavaStringToolPage> {
  final _plain = TextEditingController();
  final _literal = TextEditingController();

  @override
  void dispose() {
    _plain.dispose();
    _literal.dispose();
    super.dispose();
  }

  void _toLiteral() => setState(() {
    _literal.text = '"${JavaString.toLiteral(_plain.text)}"';
  });

  void _toPlain() => setState(() {
    _plain.text = JavaString.fromLiteral(_literal.text);
  });

  @override
  Widget build(BuildContext context) {
    final block = JavaString.toTextBlock(_plain.text);
    return JavaToolScaffold(
      title: JavaStringToolPage.title,
      description: JavaStringToolPage.description,
      children: [
        JavaToolField(
          controller: _plain,
          label: '普通文本',
          maxLines: 4,
          monospace: false,
          onChanged: (_) => setState(() {}),
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _toLiteral,
                icon: const Icon(Icons.arrow_downward, size: 18),
                label: const Text('转为字面量'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _toPlain,
                icon: const Icon(Icons.arrow_upward, size: 18),
                label: const Text('解析回文本'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        JavaToolResultCard(
          title: '结果',
          children: [
            JavaResultRow(label: 'Java 字面量', value: _literal.text),
            JavaResultRow(label: 'text block', value: block),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 4. JSON to Java
// ---------------------------------------------------------------------------

class JavaJsonToolPage extends StatefulWidget {
  const JavaJsonToolPage({super.key});

  static const String title = 'JSON 转 Java 类';
  static const String description = '从 JSON 对象生成 POJO 或 record，嵌套对象与数组递归成类。';

  @override
  State<JavaJsonToolPage> createState() => _JavaJsonToolPageState();
}

class _JavaJsonToolPageState extends State<JavaJsonToolPage> {
  final _name = TextEditingController(text: 'User');
  final _json = TextEditingController(
    text: '{\n  "id": 1,\n  "name": "Ada",\n  "tags": ["a", "b"]\n}',
  );
  var _asRecord = false;

  @override
  void dispose() {
    _name.dispose();
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? error;
    String? source;
    try {
      source = JavaClassGenerator.generate(
        jsonDecode(_json.text),
        _name.text.trim().isEmpty ? 'Generated' : _name.text,
        asRecord: _asRecord,
      );
    } on FormatException catch (exception) {
      error = 'JSON 无效：${exception.message}';
    }
    return JavaToolScaffold(
      title: JavaJsonToolPage.title,
      description: JavaJsonToolPage.description,
      children: [
        JavaToolField(
          controller: _name,
          label: '类名',
          onChanged: (_) => setState(() {}),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('生成 record'),
          value: _asRecord,
          onChanged: (value) => setState(() => _asRecord = value),
        ),
        JavaToolField(
          controller: _json,
          label: 'JSON',
          maxLines: 8,
          onChanged: (_) => setState(() {}),
        ),
        JavaToolError(error),
        const SizedBox(height: 16),
        if (source != null)
          JavaToolResultCard(
            title: 'Java 源码',
            children: [JavaResultRow(label: '源码', value: source)],
          )
        else
          const Text('输入 JSON 对象以生成 Java 类'),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Timestamp
// ---------------------------------------------------------------------------

class JavaTimestampToolPage extends StatefulWidget {
  const JavaTimestampToolPage({super.key});

  static const String title = '时间戳';
  static const String description = '毫秒/秒时间戳与本地日期时间互转。';

  @override
  State<JavaTimestampToolPage> createState() => _JavaTimestampToolPageState();
}

class _JavaTimestampToolPageState extends State<JavaTimestampToolPage> {
  final _epoch = TextEditingController(
    text: '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
  );
  final _local = TextEditingController();
  var _seconds = true;

  @override
  void dispose() {
    _epoch.dispose();
    _local.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? error;
    String? localText;
    String? epochText;
    final raw = _epoch.text.trim();
    if (raw.isNotEmpty) {
      final value = int.tryParse(raw);
      if (value == null) {
        error = '时间戳必须是整数';
      } else {
        localText = JavaTimestamp.toLocal(
          DateTime.fromMillisecondsSinceEpoch(_seconds ? value * 1000 : value),
          milliseconds: !_seconds,
        );
      }
    }
    final localInput = _local.text.trim();
    if (localInput.isNotEmpty) {
      final parsed = JavaTimestamp.parseLocal(localInput);
      if (parsed == null) {
        error = '日期格式应为 yyyy-MM-dd HH:mm:ss';
      } else {
        epochText = _seconds
            ? '${parsed.millisecondsSinceEpoch ~/ 1000}'
            : '${parsed.millisecondsSinceEpoch}';
      }
    }
    return JavaToolScaffold(
      title: JavaTimestampToolPage.title,
      description: JavaTimestampToolPage.description,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('秒')),
            ButtonSegment(value: false, label: Text('毫秒')),
          ],
          selected: {_seconds},
          onSelectionChanged: (selection) =>
              setState(() => _seconds = selection.first),
        ),
        JavaToolField(
          controller: _epoch,
          label: '时间戳',
          onChanged: (_) => setState(() {}),
        ),
        JavaToolField(
          controller: _local,
          label: '本地日期时间',
          hint: 'yyyy-MM-dd HH:mm:ss 或 yyyy-MM-dd',
          onChanged: (_) => setState(() {}),
        ),
        JavaToolError(error),
        const SizedBox(height: 16),
        JavaToolResultCard(
          title: '结果',
          children: [
            if (localText != null)
              JavaResultRow(label: '本地时间', value: localText),
            if (epochText != null)
              JavaResultRow(label: '时间戳', value: epochText),
            if (localText == null && epochText == null)
              const JavaResultRow(label: '提示', value: '输入任一字段即可换算'),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 6. Base64
// ---------------------------------------------------------------------------

class JavaBase64ToolPage extends StatefulWidget {
  const JavaBase64ToolPage({super.key});

  static const String title = 'Base64';
  static const String description =
      '标准与 URL-safe 两种字母表的 Base64 编解码（Java Base64 API 对应）。';

  @override
  State<JavaBase64ToolPage> createState() => _JavaBase64ToolPageState();
}

class _JavaBase64ToolPageState extends State<JavaBase64ToolPage> {
  final _plain = TextEditingController(text: 'hello');
  final _encoded = TextEditingController();
  var _urlSafe = false;

  @override
  void dispose() {
    _plain.dispose();
    _encoded.dispose();
    super.dispose();
  }

  String? _error;

  void _encode() {
    setState(() {
      _error = null;
      _encoded.text = _urlSafe
          ? JavaBase64.encodeUrlSafe(_plain.text)
          : JavaBase64.encode(_plain.text);
    });
  }

  void _decode() {
    setState(() {
      try {
        _plain.text = _urlSafe
            ? JavaBase64.decodeUrlSafe(_encoded.text)
            : JavaBase64.decode(_encoded.text);
        _error = null;
      } on FormatException catch (exception) {
        _error = '解码失败：${exception.message}';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final output = _urlSafe
        ? JavaBase64.encodeUrlSafe(_plain.text)
        : JavaBase64.encode(_plain.text);
    return JavaToolScaffold(
      title: JavaBase64ToolPage.title,
      description: JavaBase64ToolPage.description,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('URL-safe 字母表（无填充）'),
          value: _urlSafe,
          onChanged: (value) => setState(() => _urlSafe = value),
        ),
        JavaToolField(
          controller: _plain,
          label: '原文',
          maxLines: 3,
          monospace: false,
          onChanged: (_) => setState(() {}),
        ),
        JavaToolField(
          controller: _encoded,
          label: 'Base64',
          maxLines: 3,
          onChanged: (_) => setState(() {}),
        ),
        JavaToolError(_error),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _encode,
                icon: const Icon(Icons.arrow_downward, size: 18),
                label: const Text('编码'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _decode,
                icon: const Icon(Icons.arrow_upward, size: 18),
                label: const Text('解码'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        JavaToolResultCard(
          title: '即时结果',
          children: [JavaResultRow(label: 'Base64', value: output)],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 7. URL encoding
// ---------------------------------------------------------------------------

class JavaUrlToolPage extends StatefulWidget {
  const JavaUrlToolPage({super.key});

  static const String title = 'URL 编解码';
  static const String description =
      '浏览器/Java URLEncoder 风格百分号编解码，空格编码为 +。';

  @override
  State<JavaUrlToolPage> createState() => _JavaUrlToolPageState();
}

class _JavaUrlToolPageState extends State<JavaUrlToolPage> {
  final _plain = TextEditingController(text: '中 文 & a=1');
  String? _error;

  @override
  void dispose() {
    _plain.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return JavaToolScaffold(
      title: JavaUrlToolPage.title,
      description: JavaUrlToolPage.description,
      children: [
        JavaToolField(
          controller: _plain,
          label: '文本',
          maxLines: 3,
          monospace: false,
          onChanged: (_) => setState(() => _error = null),
        ),
        JavaToolError(_error),
        const SizedBox(height: 16),
        JavaToolResultCard(
          title: '结果',
          children: [
            JavaResultRow(
              label: '编码',
              value: JavaUrlCodec.encode(_plain.text),
            ),
            JavaResultRow(
              label: '解码',
              value: _decodedOrError(),
            ),
          ],
        ),
      ],
    );
  }

  String _decodedOrError() {
    try {
      return JavaUrlCodec.decode(_plain.text);
    } on FormatException catch (error) {
      return '无法解码：${error.message}';
    }
  }
}

// ---------------------------------------------------------------------------
// 8. Hashes
// ---------------------------------------------------------------------------

class JavaHashToolPage extends StatefulWidget {
  const JavaHashToolPage({super.key});

  static const String title = '哈希摘要';
  static const String description = 'MD5 / SHA-1 / SHA-256 摘要（纯 Dart 实现，用于校验）。';

  @override
  State<JavaHashToolPage> createState() => _JavaHashToolPageState();
}

class _JavaHashToolPageState extends State<JavaHashToolPage> {
  final _input = TextEditingController(text: 'abc');

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final digests = JavaDigest.all(_input.text);
    return JavaToolScaffold(
      title: JavaHashToolPage.title,
      description: JavaHashToolPage.description,
      children: [
        JavaToolField(
          controller: _input,
          label: '输入',
          maxLines: 4,
          monospace: false,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        JavaToolResultCard(
          title: '摘要',
          children: [
            for (final entry in digests.entries)
              JavaResultRow(label: entry.key, value: entry.value),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 9. Regex tester
// ---------------------------------------------------------------------------

class JavaRegexToolPage extends StatefulWidget {
  const JavaRegexToolPage({super.key});

  static const String title = '正则测试';
  static const String description =
      '用 Dart RegExp 试跑正则（与 Java 语法接近但并非完全一致）。';

  @override
  State<JavaRegexToolPage> createState() => _JavaRegexToolPageState();
}

class _JavaRegexToolPageState extends State<JavaRegexToolPage> {
  final _pattern = TextEditingController(text: r'(\d+)-(\d+)');
  final _input = TextEditingController(text: 'a 12-34 b 56-78');
  var _multiLine = false;
  var _dotAll = false;
  var _caseSensitive = true;

  @override
  void dispose() {
    _pattern.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = JavaRegex.test(
      _pattern.text,
      _input.text,
      multiLine: _multiLine,
      dotAll: _dotAll,
      caseSensitive: _caseSensitive,
    );
    return JavaToolScaffold(
      title: JavaRegexToolPage.title,
      description: JavaRegexToolPage.description,
      children: [
        JavaToolField(
          controller: _pattern,
          label: '正则',
          onChanged: (_) => setState(() {}),
        ),
        JavaToolField(
          controller: _input,
          label: '测试文本',
          maxLines: 4,
          monospace: false,
          onChanged: (_) => setState(() {}),
        ),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              label: const Text('多行'),
              selected: _multiLine,
              onSelected: (value) => setState(() => _multiLine = value),
            ),
            FilterChip(
              label: const Text('点匹配换行'),
              selected: _dotAll,
              onSelected: (value) => setState(() => _dotAll = value),
            ),
            FilterChip(
              label: const Text('区分大小写'),
              selected: _caseSensitive,
              onSelected: (value) => setState(() => _caseSensitive = value),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (!result.ok)
          JavaToolResultCard(
            title: '错误',
            children: [JavaResultRow(label: '原因', value: result.error ?? '')],
          )
        else
          JavaToolResultCard(
            title: '匹配 ${result.matches.length} 处'
                '${result.truncated ? '（已截断）' : ''}',
            children: result.matches.isEmpty
                ? const [JavaResultRow(label: '结果', value: '无匹配')]
                : [
                    for (var i = 0; i < result.matches.length; i++)
                      JavaResultRow(
                        label: '#${i + 1} @${result.matches[i].index}',
                        value: _describeMatch(result.matches[i]),
                      ),
                  ],
          ),
      ],
    );
  }

  String _describeMatch(JavaRegexMatch match) {
    final buffer = StringBuffer('「${match.value}」');
    if (match.groups.isNotEmpty) {
      buffer.write('  组：${match.groups.map((g) => g ?? 'null').join(' | ')}');
    }
    if (match.namedGroups.isNotEmpty) {
      buffer.write(
        '  命名组：${match.namedGroups.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
      );
    }
    return buffer.toString();
  }
}

// ---------------------------------------------------------------------------
// 10. Colour converter
// ---------------------------------------------------------------------------

class JavaColorToolPage extends StatefulWidget {
  const JavaColorToolPage({super.key});

  static const String title = '颜色转换';
  static const String description =
      '#RRGGBB / #AARRGGBB <-> Android、Kotlin 与 CSS 记法。';

  @override
  State<JavaColorToolPage> createState() => _JavaColorToolPageState();
}

class _JavaColorToolPageState extends State<JavaColorToolPage> {
  final _input = TextEditingController(text: '#336699');

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    JavaColorInfo? info;
    String? error;
    try {
      info = JavaColorInfo.parse(_input.text);
    } on FormatException catch (exception) {
      error = exception.message;
    }
    return JavaToolScaffold(
      title: JavaColorToolPage.title,
      description: JavaColorToolPage.description,
      children: [
        JavaToolField(
          controller: _input,
          label: '颜色',
          hint: '#RGB、#RRGGBB 或 #AARRGGBB',
          onChanged: (_) => setState(() {}),
        ),
        JavaToolError(error),
        if (info != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Color(info.argb),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '预览',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          JavaToolResultCard(
            title: '表示',
            children: [
              JavaResultRow(label: 'Android', value: info.hexArgb),
              JavaResultRow(label: 'RGB', value: info.hexRgb),
              JavaResultRow(label: 'Kotlin', value: info.kotlinHex),
              JavaResultRow(label: 'CSS', value: info.cssRgb),
              JavaResultRow(label: 'HSL', value: info.cssHsl),
              JavaResultRow(
                label: 'ARGB',
                value: '${info.alpha}, ${info.red}, ${info.green}, ${info.blue}',
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 11. UUID
// ---------------------------------------------------------------------------

class JavaUuidToolPage extends StatefulWidget {
  const JavaUuidToolPage({super.key});

  static const String title = 'UUID 生成';
  static const String description = '随机 v4，以及基于名称的确定性 v3（MD5）/ v5（SHA-1）。';

  @override
  State<JavaUuidToolPage> createState() => _JavaUuidToolPageState();
}

class _JavaUuidToolPageState extends State<JavaUuidToolPage> {
  final _name = TextEditingController(text: 'www.example.com');
  final _namespace = TextEditingController(
    text: '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
  );
  var _v4 = '';

  @override
  void initState() {
    super.initState();
    _v4 = JavaUuid.v4();
  }

  @override
  void dispose() {
    _name.dispose();
    _namespace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return JavaToolScaffold(
      title: JavaUuidToolPage.title,
      description: JavaUuidToolPage.description,
      children: [
        JavaToolResultCard(
          title: '随机 UUID（v4）',
          children: [
            JavaResultRow(label: 'UUID', value: _v4),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: () => setState(() => _v4 = JavaUuid.v4()),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新生成'),
          ),
        ),
        const SizedBox(height: 20),
        Text('基于名称（确定性）', style: Theme.of(context).textTheme.titleSmall),
        JavaToolField(
          controller: _name,
          label: '名称',
          onChanged: (_) => setState(() {}),
        ),
        JavaToolField(
          controller: _namespace,
          label: '命名空间 UUID',
          hint: '留空使用 DNS 命名空间',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        JavaToolResultCard(
          title: '结果',
          children: [
            JavaResultRow(
              label: 'v3 (MD5)',
              value: JavaUuid.v3(_name.text, _namespace.text),
            ),
            JavaResultRow(
              label: 'v5 (SHA-1)',
              value: JavaUuid.v5(_name.text, _namespace.text),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 12. Keyword reference
// ---------------------------------------------------------------------------

class JavaReferenceToolPage extends StatefulWidget {
  const JavaReferenceToolPage({super.key});

  static const String title = '关键字速查';
  static const String description = 'Java 基本类型、关键字与字符串转义速查表。';

  @override
  State<JavaReferenceToolPage> createState() => _JavaReferenceToolPageState();
}

class _JavaReferenceToolPageState extends State<JavaReferenceToolPage> {
  @override
  Widget build(BuildContext context) {
    return JavaToolScaffold(
      title: JavaReferenceToolPage.title,
      description: JavaReferenceToolPage.description,
      children: [
        JavaToolResultCard(
          title: '基本类型',
          children: [
            for (final entry in JavaReference.primitives)
              JavaResultRow(
                label: entry.name,
                value: entry.detail,
                monospace: false,
                allowCopy: false,
              ),
          ],
        ),
        const SizedBox(height: 12),
        JavaToolResultCard(
          title: '字符串转义',
          children: [
            for (final entry in JavaReference.escapes)
              JavaResultRow(label: entry.name, value: entry.detail, allowCopy: false),
          ],
        ),
        const SizedBox(height: 12),
        JavaToolResultCard(
          title: '关键字（${JavaReference.keywords.length}）',
          children: [
            for (final entry in JavaReference.keywords)
              JavaResultRow(
                label: entry.name,
                value: entry.detail,
                monospace: false,
                allowCopy: false,
              ),
          ],
        ),
      ],
    );
  }
}
