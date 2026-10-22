import 'package:flutter/material.dart';
import 'package:qfli_studio_core/pages/tools_grid.dart';
import 'package:qfli_studio_core/store/project_store.dart';

import 'java_debugger_page.dart';
import 'java_developer_tool_pages.dart';
import 'java_tools_pages.dart';

/// Java-specific tools contributed to the shared tools grid.
///
/// The first four are text converters and reference tables. Additional cards
/// inspect JVM artefacts or launch a local debugger. Each opens its own page.
final List<ToolDefinition> javaTools = _javaTools();

List<ToolDefinition> _javaTools([ProjectStore? store]) => [
  ToolDefinition(
    icon: Icons.numbers,
    title: JavaIntegerToolPage.title,
    description: '十/十六/二/八进制互转、补码与位运算',
    builder: (_) => const JavaIntegerToolPage(),
  ),
  ToolDefinition(
    icon: Icons.text_fields,
    title: JavaStringToolPage.title,
    description: '文本 <-> Java 字面量，含 text block',
    builder: (_) => const JavaStringToolPage(),
  ),
  ToolDefinition(
    icon: Icons.data_object,
    title: JavaJsonToolPage.title,
    description: 'JSON 生成 POJO 或 record，嵌套递归',
    builder: (_) => const JavaJsonToolPage(),
  ),
  ToolDefinition(
    icon: Icons.menu_book_outlined,
    title: JavaReferenceToolPage.title,
    description: '基本类型、关键字与转义速查',
    builder: (_) => const JavaReferenceToolPage(),
  ),
  ToolDefinition(
    icon: Icons.code_off,
    title: JavaDescriptorToolPage.title,
    description: '解码或生成字段/方法描述符',
    builder: (_) => const JavaDescriptorToolPage(),
  ),
  ToolDefinition(
    icon: Icons.bug_report_outlined,
    title: JavaStackTraceToolPage.title,
    description: '解析异常链，只保留应用帧',
    builder: (_) => const JavaStackTraceToolPage(),
  ),
  ToolDefinition(
    icon: Icons.inventory_2_outlined,
    title: JavaClassFileToolPage.title,
    description: '读本地 .class：版本、常量池与成员',
    builder: (_) => const JavaClassFileToolPage(),
  ),
  ToolDefinition(
    icon: Icons.folder_zip_outlined,
    title: JavaJarToolPage.title,
    description: '读本地 JAR：MANIFEST 与条目结构',
    builder: (_) => const JavaJarToolPage(),
  ),
  _debuggerTool(store),
];

ToolDefinition _debuggerTool([ProjectStore? store]) => ToolDefinition(
  icon: Icons.pest_control_outlined,
  title: JavaDebuggerPage.title,
  description: '真实断点、单步、调用栈和局部变量',
  builder: (_) => JavaDebuggerPage(store: store),
);

/// Standalone page wrapper for the Java and shared tools grid.
class JavaToolsPage extends StatelessWidget {
  const JavaToolsPage({super.key, this.store});

  final ProjectStore? store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('工具')),
      body: JavaToolsGrid(store: store),
    );
  }
}

/// Adds Java-specific cards to core's shared offline tools and terminal card.
class JavaToolsGrid extends StatelessWidget {
  const JavaToolsGrid({super.key, this.store, this.onOpenTerminal});

  final ProjectStore? store;
  final VoidCallback? onOpenTerminal;

  @override
  Widget build(BuildContext context) => ToolsGrid(
    onOpenTerminal: onOpenTerminal,
    sections: [
      ToolSection(title: 'Java', icon: Icons.code, tools: _javaTools(store)),
    ],
  );
}
