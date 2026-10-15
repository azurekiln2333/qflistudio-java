import 'package:flutter/material.dart';

import 'java_tools_pages.dart';
import 'java_tools_widgets.dart';

/// One tool in the grid: its card metadata and the page it opens.
class JavaToolDefinition {
  const JavaToolDefinition({
    required this.icon,
    required this.title,
    required this.description,
    required this.group,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final String description;
  final JavaToolGroup group;
  final WidgetBuilder builder;
}

/// The groups the tools are laid out under.
enum JavaToolGroup {
  numbers('数值与编码', Icons.calculate_outlined),
  text('文本', Icons.text_fields),
  data('数据', Icons.data_object),
  time('时间与标识', Icons.schedule_outlined),
  reference('速查', Icons.menu_book_outlined);

  const JavaToolGroup(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Every Java tool, in the order the page lays them out.
///
/// A plain list rather than a registry: this app has exactly one tools page, so
/// the data is local and the widget stays declarative.
final List<JavaToolDefinition> javaTools = [
  JavaToolDefinition(
    icon: Icons.numbers,
    title: JavaIntegerToolPage.title,
    description: '十/十六/二/八进制互转、补码与位运算',
    group: JavaToolGroup.numbers,
    builder: (_) => const JavaIntegerToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.abc,
    title: JavaUnicodeToolPage.title,
    description: '码点、\\uXXXX、UTF-8 / UTF-16 字节',
    group: JavaToolGroup.numbers,
    builder: (_) => const JavaUnicodeToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.password_outlined,
    title: JavaBase64ToolPage.title,
    description: '标准与 URL-safe 字母表编解码',
    group: JavaToolGroup.numbers,
    builder: (_) => const JavaBase64ToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.link,
    title: JavaUrlToolPage.title,
    description: '百分号编解码，空格转 +',
    group: JavaToolGroup.numbers,
    builder: (_) => const JavaUrlToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.text_fields,
    title: JavaStringToolPage.title,
    description: '文本 <-> Java 字面量，含 text block',
    group: JavaToolGroup.text,
    builder: (_) => const JavaStringToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.find_replace_outlined,
    title: JavaRegexToolPage.title,
    description: '正则匹配、分组与替换试验',
    group: JavaToolGroup.text,
    builder: (_) => const JavaRegexToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.data_object,
    title: JavaJsonToolPage.title,
    description: 'JSON 生成 POJO 或 record，嵌套递归',
    group: JavaToolGroup.data,
    builder: (_) => const JavaJsonToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.tag,
    title: JavaHashToolPage.title,
    description: 'MD5 / SHA-1 / SHA-256 摘要',
    group: JavaToolGroup.data,
    builder: (_) => const JavaHashToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.schedule,
    title: JavaTimestampToolPage.title,
    description: '秒/毫秒时间戳 <-> 本地日期时间',
    group: JavaToolGroup.time,
    builder: (_) => const JavaTimestampToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.fingerprint,
    title: JavaUuidToolPage.title,
    description: '随机 v4 与确定性 v3 / v5',
    group: JavaToolGroup.time,
    builder: (_) => const JavaUuidToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.palette_outlined,
    title: JavaColorToolPage.title,
    description: '#AARRGGBB / RGB / HSL 互转',
    group: JavaToolGroup.time,
    builder: (_) => const JavaColorToolPage(),
  ),
  JavaToolDefinition(
    icon: Icons.menu_book_outlined,
    title: JavaReferenceToolPage.title,
    description: '基本类型、关键字与转义速查',
    group: JavaToolGroup.reference,
    builder: (_) => const JavaReferenceToolPage(),
  ),
];

/// Standalone page wrapper for the Java tools grid.
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

/// Grouped, scrollable tool cards embedded in the shell's tools tab.
///
/// The shell supplies its terminal route so it uses the same card styling as
/// the other tools, without nesting a page scaffold inside the tab.
class JavaToolsGrid extends StatelessWidget {
  const JavaToolsGrid({super.key, this.onOpenTerminal});

  final VoidCallback? onOpenTerminal;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = JavaToolsTheme.horizontalPadding(
          constraints.maxWidth,
        );
        return CustomScrollView(
          key: const PageStorageKey<String>('java-tools-scroll'),
          slivers: [
            for (final group in JavaToolGroup.values)
              if (javaTools.any((tool) => tool.group == group)) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(horizontal, 20, horizontal, 8),
                  sliver: SliverToBoxAdapter(
                    child: JavaToolsSectionHeading(
                      icon: group.icon,
                      title: group.label,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 8),
                  sliver: _grid(group),
                ),
              ],
            SliverPadding(
              padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 32),
              sliver: const SliverToBoxAdapter(child: _OfflineNote()),
            ),
          ],
        );
      },
    );
  }

  /// One grid per group, so the column width stays constant across the page.
  Widget _grid(JavaToolGroup group) {
    final tools = javaTools.where((tool) => tool.group == group).toList();
    final includeTerminal =
        group == JavaToolGroup.numbers && onOpenTerminal != null;
    final terminalCount = includeTerminal ? 1 : 0;
    return SliverGrid(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (includeTerminal && index == 0) {
          return JavaToolCard(
            icon: Icons.terminal,
            title: '终端',
            description: '在本机沙盒中运行命令',
            onTap: onOpenTerminal!,
          );
        }
        final tool = tools[index - terminalCount];
        return JavaToolCard(
          icon: tool.icon,
          title: tool.title,
          description: tool.description,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: tool.builder)),
        );
      }, childCount: tools.length + terminalCount),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: JavaToolsTheme.cardMaxWidth,
        mainAxisExtent: JavaToolsTheme.cardHeight,
        crossAxisSpacing: JavaToolsTheme.cardSpacing,
        mainAxisSpacing: JavaToolsTheme.cardSpacing,
      ),
    );
  }
}

/// Reassures the user that nothing here leaves the device.
class _OfflineNote extends StatelessWidget {
  const _OfflineNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          Icons.offline_bolt_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '全部工具均在本机离线计算，不会上传任何内容。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
