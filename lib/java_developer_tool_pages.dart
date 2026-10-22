import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/services/picker_service.dart';
import 'package:qfli_studio_core/widgets/tool_widgets.dart';

import 'java_developer_tools.dart';

/// Bytes plus the display name of a locally picked file.
class JavaFileBytes {
  const JavaFileBytes({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Loads a local file's bytes; injectable so widget tests can supply a real
/// committed fixture instead of driving a native file dialog.
typedef JavaFileBytesLoader = Future<JavaFileBytes?> Function();

/// The largest file the inspection tools read into memory.
///
/// A `.class` file is a few KB and a JAR is normally a few MB; the cap keeps a
/// mistaken pick of a huge archive from stalling the UI isolate.
const int kJavaToolMaxBytes = 32 * 1024 * 1024;

/// Reads a document through the shared picker, then returns its bytes.
///
/// Desktop returns a path, HarmonyOS/Android returns a content URI, so both
/// shapes are handled here instead of in every page.
Future<JavaFileBytes?> pickJavaFileBytes(List<String> extensions) async {
  final picked = await PickerService.pickDocument(extensions: extensions);
  if (picked == null) return null;
  final path = picked.path;
  final uri = picked.uri;
  final name = picked.name ?? (path == null ? '已选文件' : p.basename(path));
  FormatException tooLarge() => FormatException(
    '$name 超过 ${JavaBytesFormat.human(kJavaToolMaxBytes)}，无法在工具中打开',
  );
  final Uint8List bytes;
  if (path != null && path.isNotEmpty) {
    final file = File(path);
    if (await file.length() > kJavaToolMaxBytes) throw tooLarge();
    final builder = BytesBuilder(copy: false);
    // Bound the read even if the file grows between the length probe and open.
    await for (final chunk in file.openRead(0, kJavaToolMaxBytes + 1)) {
      builder.add(chunk);
      if (builder.length > kJavaToolMaxBytes) throw tooLarge();
    }
    bytes = builder.takeBytes();
  } else if (uri != null && uri.isNotEmpty) {
    bytes = await PickerService.readUri(uri);
  } else {
    throw const FileSystemException('系统未返回可读文件');
  }
  if (bytes.length > kJavaToolMaxBytes) {
    throw tooLarge();
  }
  return JavaFileBytes(name: name, bytes: bytes);
}

/// Decodes or writes a JVM descriptor without running `javap`.
class JavaDescriptorToolPage extends StatefulWidget {
  const JavaDescriptorToolPage({super.key});

  static const String title = 'JVM 描述符';
  static const String description =
      '解码或生成字段/方法描述符：Ljava/lang/String;、[I、(IJ)V 与 Java 类型互转。';

  @override
  State<JavaDescriptorToolPage> createState() => _JavaDescriptorToolPageState();
}

class _JavaDescriptorToolPageState extends State<JavaDescriptorToolPage> {
  final _descriptor = TextEditingController(text: '(Ljava/lang/String;I)V');
  final _fieldType = TextEditingController(text: 'java.lang.String[]');
  final _parameters = TextEditingController(text: 'int, java.util.List');
  final _returnType = TextEditingController(text: 'void');

  @override
  void dispose() {
    _descriptor.dispose();
    _fieldType.dispose();
    _parameters.dispose();
    _returnType.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Object? decoded;
    String? error;
    final source = _descriptor.text.trim();
    if (source.isNotEmpty) {
      try {
        decoded = JavaDescriptors.parseAny(source);
      } on FormatException catch (exception) {
        error = exception.message;
      }
    }

    String? fieldDescriptor;
    String? fieldError;
    try {
      fieldDescriptor = JavaDescriptors.descriptorOf(_fieldType.text);
    } on FormatException catch (exception) {
      fieldError = exception.message;
    }

    String? methodDescriptor;
    String? methodError;
    try {
      final parameters = _parameters.text
          .split(RegExp(r'[,\s]+'))
          .where((part) => part.trim().isNotEmpty)
          .map((part) => part.trim())
          .toList();
      methodDescriptor = JavaDescriptors.methodDescriptorOf(
        parameters,
        _returnType.text,
      );
    } on FormatException catch (exception) {
      methodError = exception.message;
    }

    return ToolScaffold(
      title: JavaDescriptorToolPage.title,
      description: JavaDescriptorToolPage.description,
      children: [
        ToolField(
          controller: _descriptor,
          label: '描述符',
          hint: '字段如 Ljava/lang/String;，方法如 (ILjava/lang/String;)V',
          onChanged: (_) => setState(() {}),
        ),
        ToolError(error),
        if (decoded is JavaMethodDescriptor) ...[
          const SizedBox(height: 8),
          ToolResultCard(
            title: '方法描述符',
            children: [
              ResultRow(label: '可读签名', value: decoded.signature),
              ResultRow(
                label: '参数个数',
                value: '${decoded.parameters.length}',
                allowCopy: false,
              ),
              for (var i = 0; i < decoded.parameters.length; i++)
                ResultRow(
                  label: '参数 ${i + 1}',
                  value:
                      '${decoded.parameters[i].javaName}  '
                      '[${decoded.parameters[i].descriptor}]',
                ),
              ResultRow(
                label: '返回类型',
                value:
                    '${decoded.returnType.javaName}  '
                    '[${decoded.returnType.descriptor}]',
              ),
              ResultRow(label: '重建描述符', value: decoded.rebuiltDescriptor),
            ],
          ),
        ] else if (decoded is JavaDescriptorType) ...[
          const SizedBox(height: 8),
          ToolResultCard(
            title: '字段描述符',
            children: [
              ResultRow(label: 'Java 类型', value: decoded.javaName),
              ResultRow(
                label: '数组维度',
                value: '${decoded.dimensions}',
                allowCopy: false,
              ),
              ResultRow(
                label: '基本类型',
                value: decoded.isPrimitive ? '是' : '否',
                allowCopy: false,
              ),
              ResultRow(
                label: '重建描述符',
                value: JavaDescriptors.descriptorOf(decoded.javaName),
              ),
            ],
          ),
        ] else if (source.isEmpty)
          const Text('输入一个字段或方法描述符以查看 Java 类型'),
        const SizedBox(height: 24),
        Text('反向：Java 类型 → 描述符', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ToolField(
          controller: _fieldType,
          label: '字段类型',
          hint: '例如 java.lang.String[] 或 int',
          onChanged: (_) => setState(() {}),
        ),
        ToolError(fieldError),
        if (fieldDescriptor != null)
          ToolResultCard(
            title: '生成的字段描述符',
            children: [ResultRow(label: '描述符', value: fieldDescriptor)],
          ),
        const SizedBox(height: 16),
        ToolField(
          controller: _parameters,
          label: '方法参数类型（逗号分隔）',
          hint: '例如 int, java.lang.String[]',
          onChanged: (_) => setState(() {}),
        ),
        ToolField(
          controller: _returnType,
          label: '返回类型',
          hint: '例如 void 或 java.util.List',
          onChanged: (_) => setState(() {}),
        ),
        ToolError(methodError),
        if (methodDescriptor != null)
          ToolResultCard(
            title: '生成的方法描述符',
            children: [ResultRow(label: '描述符', value: methodDescriptor)],
          ),
      ],
    );
  }
}

/// Parses a pasted stack trace, then re-prints it without runtime noise.
class JavaStackTraceToolPage extends StatefulWidget {
  const JavaStackTraceToolPage({super.key});

  static const String title = '栈异常分析';
  static const String description = '解析异常链与栈帧，只保留应用帧或按类/文件名过滤，便于定位自己的代码。';

  /// A realistic sample so the page shows real output before any typing.
  static const String sampleTrace = '''
Exception in thread "main" java.lang.IllegalStateException: 配置缺少 database.url
\tat app.Config.require(Config.java:42)
\tat app.Repository.connect(Repository.java:18)
\tat app.Main.main(Main.java:9)
Caused by: java.io.FileNotFoundException: config.properties
\tat java.base/java.io.FileInputStream.open0(Native Method)
\tat java.base/java.io.FileInputStream.open(FileInputStream.java:219)
\tat app.Config.load(Config.java:31)
\t... 3 more
''';

  @override
  State<JavaStackTraceToolPage> createState() => _JavaStackTraceToolPageState();
}

class _JavaStackTraceToolPageState extends State<JavaStackTraceToolPage> {
  final _input = TextEditingController(
    text: JavaStackTraceToolPage.sampleTrace,
  );
  final _filter = TextEditingController();
  var _onlyApplicationFrames = true;

  /// The last parsed text and its report.
  ///
  /// Re-parsing on every keystroke would be wasteful for a large pasted log, so
  /// the report is reused until the text actually changes.
  String _parsedText = '';
  JavaStackTraceReport? _parsedReport;

  JavaStackTraceReport get _report {
    if (_parsedReport == null || _parsedText != _input.text) {
      _parsedText = _input.text;
      _parsedReport = JavaStackTrace.parse(_input.text);
    }
    return _parsedReport!;
  }

  @override
  void dispose() {
    _input.dispose();
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;
    final primary = report.primary;
    final rendered = JavaStackTrace.render(
      report,
      onlyApplicationFrames: _onlyApplicationFrames,
      contains: _filter.text,
    );
    final applicationFrames = report.applicationFrameCount();
    final firstApplicationFrame = report.allFrames
        .where(
          (frame) =>
              !frame.isRuntimeFrame(JavaStackTrace.defaultRuntimePrefixes),
        )
        .firstOrNull;

    return ToolScaffold(
      title: JavaStackTraceToolPage.title,
      description: JavaStackTraceToolPage.description,
      children: [
        ToolField(
          controller: _input,
          label: '堆栈文本',
          hint: '从控制台或日志粘贴完整异常栈',
          maxLines: 10,
          onChanged: (_) => setState(() {}),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('只保留应用帧'),
          subtitle: Text(
            '隐藏 ${JavaStackTrace.defaultRuntimePrefixes.take(5).join(' / ')} 等运行时帧',
          ),
          value: _onlyApplicationFrames,
          onChanged: (value) => setState(() => _onlyApplicationFrames = value),
        ),
        ToolField(
          controller: _filter,
          label: '只保留包含（可选）',
          hint: '例如 Service.java 或自己的包名',
          monospace: false,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        if (report.isEmpty)
          const Text('粘贴一段 Java 堆栈以解析异常链和栈帧')
        else ...[
          ToolResultCard(
            title: '概览',
            children: [
              ResultRow(
                label: '异常类型',
                value: primary?.exceptionClass.isEmpty ?? true
                    ? '（未识别）'
                    : primary!.exceptionClass,
              ),
              ResultRow(label: '异常消息', value: primary?.message ?? '（无消息）'),
              ResultRow(
                label: '线程',
                value: report.threadName ?? '（未标注）',
                allowCopy: false,
              ),
              ResultRow(
                label: '栈帧',
                value:
                    '${report.allFrames.length} 帧，其中 $applicationFrames 帧属于应用代码',
                allowCopy: false,
              ),
              ResultRow(
                label: '首个应用帧',
                value: firstApplicationFrame?.display ?? '（全部是运行时帧）',
              ),
              ResultRow(
                label: '异常链',
                value: report.throwables
                    .map((throwable) => throwable.exceptionClass)
                    .join('\n'),
              ),
              if (report.unparsedLines.isNotEmpty)
                ResultRow(
                  label: '其他行',
                  value: '${report.unparsedLines.length} 行未识别（如构建日志）',
                  allowCopy: false,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('过滤后的堆栈', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          ToolResultCard(
            children: [
              ResultRow(
                label: '输出',
                value: rendered.isEmpty ? '（没有可输出的行）' : rendered,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Reads a local `.class` file and explains its structure.
class JavaClassFileToolPage extends StatefulWidget {
  const JavaClassFileToolPage({super.key, this.loader});

  static const String title = 'class 文件检查';
  static const String description =
      '读取本地 .class：目标 Java 版本、修饰符、父类接口、常量池统计与字段方法签名。';

  /// Test seam: replaced with a fixture loader so no native dialog is needed.
  final JavaFileBytesLoader? loader;

  @override
  State<JavaClassFileToolPage> createState() => _JavaClassFileToolPageState();
}

class _JavaClassFileToolPageState extends State<JavaClassFileToolPage> {
  JavaFileBytes? _file;
  JavaClassFile? _parsed;
  String? _error;
  var _busy = false;

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final loader = widget.loader ?? () => pickJavaFileBytes(const ['class']);
      final file = await loader();
      if (!mounted || file == null) return;
      final parsed = JavaClassFile.parse(file.bytes);
      setState(() {
        _file = file;
        _parsed = parsed;
      });
    } on FormatException catch (exception) {
      if (!mounted) return;
      setState(() {
        _file = null;
        _parsed = null;
        _error = exception.message;
      });
    } on FileSystemException catch (exception) {
      if (!mounted) return;
      setState(() {
        _file = null;
        _parsed = null;
        _error = '无法读取文件：${exception.message}';
      });
    } on Object catch (error) {
      // The platform picker can fail with a channel error; show it instead of
      // letting an unhandled async error escape the page.
      if (!mounted) return;
      setState(() {
        _file = null;
        _parsed = null;
        _error = '选择文件失败：$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parsed = _parsed;
    return ToolScaffold(
      title: JavaClassFileToolPage.title,
      description: JavaClassFileToolPage.description,
      children: [
        _FilePickCard(
          buttonLabel: '选择 .class 文件',
          busy: _busy,
          status: _file == null
              ? null
              : '${_file!.name} · ${JavaBytesFormat.human(_file!.bytes.length)}',
          onPressed: _busy ? null : _load,
        ),
        ToolError(_error),
        if (parsed == null)
          const Text('选择一个本地 .class 文件以查看其结构')
        else ...[
          const SizedBox(height: 8),
          ToolResultCard(
            title: '版本与修饰符',
            children: [
              ResultRow(label: '目标版本', value: parsed.versionText),
              ResultRow(
                label: '修饰符',
                value: parsed.modifiers.isEmpty
                    ? '（默认）'
                    : parsed.modifiers.join(' '),
              ),
              ResultRow(label: '声明', value: parsed.declaration),
              ResultRow(
                label: '父类',
                value: parsed.superClass ?? '（无，java.lang.Object 或模块信息）',
              ),
              ResultRow(
                label: '接口',
                value: parsed.interfaces.isEmpty
                    ? '（无）'
                    : parsed.interfaces.join('\n'),
              ),
              ResultRow(
                label: '文件大小',
                value: JavaBytesFormat.human(parsed.byteLength),
                allowCopy: false,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ToolResultCard(
            title: '常量池（${parsed.constantPoolSlots} 个槽位）',
            children: [
              ResultRow(label: '按标签统计', value: parsed.constantPoolSummary),
            ],
          ),
          const SizedBox(height: 12),
          ToolResultCard(
            title: '字段（${parsed.fields.length}）',
            children: parsed.fields.isEmpty
                ? const [ResultRow(label: '字段', value: '（无）')]
                : [
                    for (final field in parsed.fields)
                      ResultRow(label: field.name, value: field.listing),
                  ],
          ),
          const SizedBox(height: 12),
          ToolResultCard(
            title: '方法（${parsed.methods.length}）',
            children: parsed.methods.isEmpty
                ? const [ResultRow(label: '方法', value: '（无）')]
                : [
                    for (final method in parsed.methods)
                      ResultRow(label: method.name, value: method.listing),
                  ],
          ),
          const SizedBox(height: 12),
          ToolResultCard(
            title: '类级属性',
            children: [
              ResultRow(
                label: '属性',
                value: parsed.attributes.isEmpty
                    ? '（无）'
                    : parsed.attributes.join(', '),
                allowCopy: false,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '提示：常量池里的 Utf8/Class/Methodref 计数能快速说明一个类引用了多少符号。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// Reads a local JAR and explains its manifest and entry structure.
class JavaJarToolPage extends StatefulWidget {
  const JavaJarToolPage({super.key, this.loader});

  static const String title = 'JAR 清单检查';
  static const String description =
      '读取本地 JAR：MANIFEST 主属性与命名段、Main-Class、条目/类文件/包统计。';

  /// Test seam: replaced with a fixture loader so no native dialog is needed.
  final JavaFileBytesLoader? loader;

  @override
  State<JavaJarToolPage> createState() => _JavaJarToolPageState();
}

class _JavaJarToolPageState extends State<JavaJarToolPage> {
  JavaFileBytes? _file;
  JavaJarInspection? _inspection;
  String? _error;
  var _busy = false;

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final loader =
          widget.loader ?? () => pickJavaFileBytes(const ['jar', 'zip']);
      final file = await loader();
      if (!mounted || file == null) return;
      final inspection = JavaJarInspection.fromBytes(file.bytes);
      setState(() {
        _file = file;
        _inspection = inspection;
      });
    } on FormatException catch (exception) {
      if (!mounted) return;
      setState(() {
        _file = null;
        _inspection = null;
        _error = exception.message;
      });
    } on FileSystemException catch (exception) {
      if (!mounted) return;
      setState(() {
        _file = null;
        _inspection = null;
        _error = '无法读取文件：${exception.message}';
      });
    } on Object catch (error) {
      // The platform picker can fail with a channel error; show it instead of
      // letting an unhandled async error escape the page.
      if (!mounted) return;
      setState(() {
        _file = null;
        _inspection = null;
        _error = '选择文件失败：$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inspection = _inspection;
    final manifest = inspection?.manifest;
    return ToolScaffold(
      title: JavaJarToolPage.title,
      description: JavaJarToolPage.description,
      children: [
        _FilePickCard(
          buttonLabel: '选择 .jar 文件',
          busy: _busy,
          status: _file == null
              ? null
              : '${_file!.name} · ${JavaBytesFormat.human(_file!.bytes.length)}',
          onPressed: _busy ? null : _load,
        ),
        ToolError(_error),
        if (inspection == null)
          const Text('选择一个本地 .jar 文件以查看清单与条目')
        else ...[
          const SizedBox(height: 8),
          ToolResultCard(
            title: 'MANIFEST 主属性',
            children: manifest == null
                ? [
                    ResultRow(
                      label: '清单',
                      value: inspection.manifestError ?? '（无法读取）',
                      allowCopy: false,
                    ),
                  ]
                : [
                    for (final entry in manifest.mainAttributes.entries)
                      ResultRow(label: entry.key, value: entry.value),
                  ],
          ),
          if (manifest != null && manifest.sections.isNotEmpty) ...[
            const SizedBox(height: 12),
            ToolResultCard(
              title: '命名段（${manifest.sections.length}）',
              children: [
                for (final section in manifest.sections.entries)
                  ResultRow(
                    label: section.key,
                    value: section.value.entries
                        .where((entry) => entry.key != 'Name')
                        .map((entry) => '${entry.key}: ${entry.value}')
                        .join('\n'),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          ToolResultCard(
            title: '归档结构',
            children: [
              ResultRow(
                label: '条目',
                value:
                    '${inspection.entries.length} 个条目，'
                    '${inspection.fileCount} 个文件',
                allowCopy: false,
              ),
              ResultRow(
                label: '类文件',
                value: '${inspection.classCount} 个',
                allowCopy: false,
              ),
              ResultRow(
                label: '包',
                value: inspection.packages.isEmpty
                    ? '（默认包）'
                    : inspection.packages.join('\n'),
              ),
              ResultRow(
                label: '解压后大小',
                value: JavaBytesFormat.human(inspection.totalUncompressedBytes),
                allowCopy: false,
              ),
              ResultRow(
                label: '模块化',
                value: inspection.isModular ? '是（含 module-info.class）' : '否',
                allowCopy: false,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ToolResultCard(
            title: '条目列表',
            children: [
              ResultRow(
                label: '内容',
                value: inspection.entryListing().join('\n'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The shared "pick a local file" control for the byte-inspection pages.
class _FilePickCard extends StatelessWidget {
  const _FilePickCard({
    required this.buttonLabel,
    required this.busy,
    required this.status,
    required this.onPressed,
  });

  final String buttonLabel;
  final bool busy;
  final String? status;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ToolResultCard(
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: onPressed,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open_outlined, size: 18),
                label: Text(busy ? '读取中…' : buttonLabel),
              ),
            ),
          ],
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              status!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '只读取本机文件，不会上传或修改。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
