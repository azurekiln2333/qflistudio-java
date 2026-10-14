import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'java_tools.dart';

/// Java-specific tools page, mounted through `StudioProfile.toolsPageBuilder`.
///
/// Pure Dart and fully offline: every tool is a local conversion, so none of
/// them needs the network. The arithmetic lives in `lib/java_tools.dart`, which
/// keeps this file about presentation only.
///
/// The page title is 工具 to match the shared shell's tool tab.
class JavaToolsPage extends StatelessWidget {
  const JavaToolsPage({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 5,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('工具'),
        bottom: const TabBar(
          isScrollable: true,
          tabs: [
            Tab(icon: Icon(Icons.numbers), text: '整数与进制'),
            Tab(icon: Icon(Icons.abc), text: '字符/Unicode'),
            Tab(icon: Icon(Icons.text_fields), text: '字符串转义'),
            Tab(icon: Icon(Icons.data_object), text: 'JSON 转 Java'),
            Tab(icon: Icon(Icons.schedule), text: '时间戳'),
          ],
        ),
      ),
      body: const TabBarView(
        children: [
          _IntegerTool(),
          _UnicodeTool(),
          _StringEscapeTool(),
          _JsonToJavaTool(),
          _TimestampTool(),
        ],
      ),
    ),
  );
}

Future<void> _copy(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('已复制')));
}

/// A labelled result row with its own copy button.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
          IconButton(
            tooltip: '复制$label',
            visualDensity: VisualDensity.compact,
            onPressed: () => _copy(context, value),
            icon: const Icon(Icons.copy_all_outlined, size: 18),
          ),
        ],
      ),
    );
  }
}

/// One labelled text field used by the tools.
class _ToolField extends StatelessWidget {
  const _ToolField({
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
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    ),
  );
}

/// Shows an inline error, or nothing when there is none.
class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

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

class _IntegerTool extends StatefulWidget {
  const _IntegerTool();

  @override
  State<_IntegerTool> createState() => _IntegerToolState();
}

class _IntegerToolState extends State<_IntegerTool>
    with AutomaticKeepAliveClientMixin {
  final _input = TextEditingController(text: '255');
  final _operand = TextEditingController(text: '0x0F');
  JavaPrimitive _type = JavaPrimitive.int_;
  JavaBitOp? _operation;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _input.dispose();
    _operand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    JavaIntValue? value;
    String? error;
    var overflowed = false;
    if (_input.text.trim().isNotEmpty) {
      try {
        final read = readJavaInt(_input.text, _type);
        value = read.value;
        overflowed = read.overflowed;
        if (_operation != null) {
          final operand = readJavaInt(_operand.text, _type).value;
          value = applyJavaBitOp(value, _operation!, operand);
        }
      } on FormatException catch (exception) {
        error = exception.message;
      } on ArgumentError {
        error = '位运算需要一个操作数';
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
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
        _ToolField(
          controller: _input,
          label: '整数',
          hint: '十进制、0x、0b 或 0 开头八进制',
          onChanged: (_) => setState(() {}),
        ),
        if (overflowed)
          _ErrorText('超出 ${_type.label} 范围，已按 ${_type.bits} 位截断'),
        _ErrorText(error),
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
          _ToolField(
            controller: _operand,
            label: '操作数',
            onChanged: (_) => setState(() {}),
          ),
        const Divider(height: 24),
        if (value != null) ...[
          _ResultRow(label: 'Java 值', value: value.decimal),
          _ResultRow(label: '十六进制', value: value.hexadecimal),
          _ResultRow(label: '二进制', value: value.binary),
          _ResultRow(label: '八进制', value: value.octal),
          if (value.charView != null)
            _ResultRow(label: 'char', value: value.charView!),
          _ResultRow(label: '补码位数', value: '${value.type.bits} 位'),
        ] else
          const Text('输入一个整数以查看各进制与补码表示'),
      ],
    );
  }
}

class _UnicodeTool extends StatefulWidget {
  const _UnicodeTool();

  @override
  State<_UnicodeTool> createState() => _UnicodeToolState();
}

class _UnicodeToolState extends State<_UnicodeTool>
    with AutomaticKeepAliveClientMixin {
  final _input = TextEditingController(text: '中');

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _ToolField(
          controller: _input,
          label: '字符',
          onChanged: (_) => setState(() {}),
        ),
        _ErrorText(error),
        const Divider(height: 24),
        if (info != null) ...[
          _ResultRow(label: '码点', value: info.hex),
          _ResultRow(label: '十进制', value: '${info.codePoint}'),
          _ResultRow(label: 'Java 转义', value: info.javaEscape),
          _ResultRow(label: 'UTF-8', value: info.utf8BytesHex),
          _ResultRow(label: 'UTF-16', value: info.utf16UnitsHex),
          _ResultRow(label: 'UTF-16 单元数', value: '${info.utf16Units.length}'),
        ] else
          const Text('输入一个字符以查看它的码点与编码'),
      ],
    );
  }
}

class _StringEscapeTool extends StatefulWidget {
  const _StringEscapeTool();

  @override
  State<_StringEscapeTool> createState() => _StringEscapeToolState();
}

class _StringEscapeToolState extends State<_StringEscapeTool>
    with AutomaticKeepAliveClientMixin {
  final _plain = TextEditingController();
  final _literal = TextEditingController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _plain.dispose();
    _literal.dispose();
    super.dispose();
  }

  void _toLiteral() {
    setState(() {
      _literal.text = '"${JavaString.toLiteral(_plain.text)}"';
    });
  }

  void _toPlain() {
    setState(() {
      _plain.text = JavaString.fromLiteral(_literal.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final block = JavaString.toTextBlock(_plain.text);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _ToolField(
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
                label: const Text('转为 Java 字面量'),
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
        const SizedBox(height: 8),
        const Text('Java 字面量'),
        const SizedBox(height: 4),
        _ResultRow(label: '字面量', value: _literal.text),
        _ResultRow(label: 'text block', value: block),
      ],
    );
  }
}

class _JsonToJavaTool extends StatefulWidget {
  const _JsonToJavaTool();

  @override
  State<_JsonToJavaTool> createState() => _JsonToJavaToolState();
}

class _JsonToJavaToolState extends State<_JsonToJavaTool>
    with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController(text: 'User');
  final _json = TextEditingController(
    text: '{\n  "id": 1,\n  "name": "Ada",\n  "tags": ["a", "b"]\n}',
  );
  var _asRecord = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _name.dispose();
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    String? error;
    String? source;
    try {
      final decoded = jsonDecode(_json.text);
      source = JavaClassGenerator.generate(
        decoded,
        _name.text.trim().isEmpty ? 'Generated' : _name.text,
        asRecord: _asRecord,
      );
    } on FormatException catch (exception) {
      error = 'JSON 无效：${exception.message}';
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _ToolField(controller: _name, label: '类名', onChanged: (_) => setState(() {})),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('生成 record'),
          value: _asRecord,
          onChanged: (value) => setState(() => _asRecord = value),
        ),
        _ToolField(
          controller: _json,
          label: 'JSON',
          maxLines: 8,
          onChanged: (_) => setState(() {}),
        ),
        _ErrorText(error),
        const Divider(height: 24),
        if (source != null)
          _ResultRow(label: 'Java 源码', value: source)
        else
          const Text('输入 JSON 对象以生成 Java 类'),
      ],
    );
  }
}

class _TimestampTool extends StatefulWidget {
  const _TimestampTool();

  @override
  State<_TimestampTool> createState() => _TimestampToolState();
}

class _TimestampToolState extends State<_TimestampTool>
    with AutomaticKeepAliveClientMixin {
  final _epoch = TextEditingController(
    text: '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
  );
  final _local = TextEditingController();
  var _seconds = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _epoch.dispose();
    _local.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    String? error;
    String? localText;
    String? epochText;
    final raw = _epoch.text.trim();
    if (raw.isNotEmpty) {
      final value = int.tryParse(raw);
      if (value == null) {
        error = '时间戳必须是整数';
      } else {
        final instant = DateTime.fromMillisecondsSinceEpoch(
          _seconds ? value * 1000 : value,
        );
        localText = JavaTimestamp.toLocal(instant, milliseconds: !_seconds);
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
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
        _ToolField(
          controller: _epoch,
          label: '时间戳',
          onChanged: (_) => setState(() {}),
        ),
        _ToolField(
          controller: _local,
          label: '本地日期时间',
          hint: 'yyyy-MM-dd HH:mm:ss 或 yyyy-MM-dd',
          onChanged: (_) => setState(() {}),
        ),
        _ErrorText(error),
        const Divider(height: 24),
        if (localText != null) _ResultRow(label: '本地时间', value: localText),
        if (epochText != null) _ResultRow(label: '时间戳', value: epochText),
      ],
    );
  }
}
