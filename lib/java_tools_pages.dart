import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qfli_studio_core/widgets/tool_widgets.dart';

import 'java_tools.dart';
import 'java_tools_extra.dart';

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
    return ToolScaffold(
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
        ToolField(
          controller: _input,
          label: '整数',
          hint: '十进制、0x、0b 或 0 开头八进制，可用下划线',
          onChanged: (_) => setState(() {}),
        ),
        if (overflowed) _OverflowNote(type: _type),
        ToolError(error),
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
          ToolField(
            controller: _operand,
            label: '操作数',
            onChanged: (_) => setState(() {}),
          ),
        const SizedBox(height: 16),
        if (value != null)
          ToolResultCard(
            title: '${value.type.label} 表示',
            children: [
              ResultRow(label: 'Java 值', value: value.decimal),
              ResultRow(label: '十六进制', value: value.hexadecimal),
              ResultRow(label: '二进制', value: value.binary),
              ResultRow(label: '八进制', value: value.octal),
              if (value.charView != null)
                ResultRow(label: 'char', value: value.charView!),
              ResultRow(label: '补码位数', value: '${value.type.bits} 位'),
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

class JavaStringToolPage extends StatefulWidget {
  const JavaStringToolPage({super.key});

  static const String title = '字符串转义';
  static const String description = '普通文本 <-> Java 字面量互转，并生成保留换行的 text block。';

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
    return ToolScaffold(
      title: JavaStringToolPage.title,
      description: JavaStringToolPage.description,
      children: [
        ToolField(
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
        ToolResultCard(
          title: '结果',
          children: [
            ResultRow(label: 'Java 字面量', value: _literal.text),
            ResultRow(label: 'text block', value: block),
          ],
        ),
      ],
    );
  }
}

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
    return ToolScaffold(
      title: JavaJsonToolPage.title,
      description: JavaJsonToolPage.description,
      children: [
        ToolField(
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
        ToolField(
          controller: _json,
          label: 'JSON',
          maxLines: 8,
          onChanged: (_) => setState(() {}),
        ),
        ToolError(error),
        const SizedBox(height: 16),
        if (source != null)
          ToolResultCard(
            title: 'Java 源码',
            children: [ResultRow(label: '源码', value: source)],
          )
        else
          const Text('输入 JSON 对象以生成 Java 类'),
      ],
    );
  }
}

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
    return ToolScaffold(
      title: JavaReferenceToolPage.title,
      description: JavaReferenceToolPage.description,
      children: [
        ToolResultCard(
          title: '基本类型',
          children: [
            for (final entry in JavaReference.primitives)
              ResultRow(
                label: entry.name,
                value: entry.detail,
                monospace: false,
                allowCopy: false,
              ),
          ],
        ),
        const SizedBox(height: 12),
        ToolResultCard(
          title: '字符串转义',
          children: [
            for (final entry in JavaReference.escapes)
              ResultRow(
                label: entry.name,
                value: entry.detail,
                allowCopy: false,
              ),
          ],
        ),
        const SizedBox(height: 12),
        ToolResultCard(
          title: '关键字（${JavaReference.keywords.length}）',
          children: [
            for (final entry in JavaReference.keywords)
              ResultRow(
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
