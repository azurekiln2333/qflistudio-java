import 'package:flutter/material.dart';
import 'package:qfli_studio_core/pages/tools_grid.dart';

import 'java_tools_pages.dart';

/// Java-specific tools contributed to the shared tools grid.
final List<ToolDefinition> javaTools = [
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
];

/// Standalone page wrapper for the Java and shared tools grid.
class JavaToolsPage extends StatelessWidget {
  const JavaToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('工具')),
      body: const JavaToolsGrid(),
    );
  }
}

/// Adds Java-specific cards to core's shared offline tools and terminal card.
class JavaToolsGrid extends StatelessWidget {
  const JavaToolsGrid({super.key, this.onOpenTerminal});

  final VoidCallback? onOpenTerminal;

  @override
  Widget build(BuildContext context) => ToolsGrid(
    onOpenTerminal: onOpenTerminal,
    sections: [ToolSection(title: 'Java', icon: Icons.code, tools: javaTools)],
  );
}
