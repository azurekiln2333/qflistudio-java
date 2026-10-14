import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools_page.dart';

/// Widget-level checks for the Java tools page.
///
/// The conversions themselves are covered by `java_tools_test.dart`; this file
/// only proves the page is wired up: the title, the five tools and the copy
/// buttons the requirement asks for.
void main() {
  testWidgets('the page is titled 工具 and offers all five tools', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: JavaToolsPage()));
    await tester.pump();

    expect(find.text('工具'), findsOneWidget);
    for (final label in ['整数与进制', '字符/Unicode', '字符串转义', 'JSON 转 Java', '时间戳']) {
      expect(find.text(label), findsWidgets, reason: 'tab $label exists');
    }
  });

  testWidgets('the integer tool shows the converted bases by default', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: JavaToolsPage()));
    await tester.pump();

    // The default input is 255, so every representation is on screen.
    expect(find.text('255'), findsWidgets);
    expect(find.text('0x000000FF'), findsOneWidget);
    expect(find.text('0377'), findsOneWidget);
  });

  testWidgets('every result row has a copy button', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: JavaToolsPage()));
    await tester.pump();

    // The integer tool is the initial tab; its rows are labelled.
    for (final label in ['十六进制', '二进制', '八进制']) {
      expect(
        find.byTooltip('复制$label'),
        findsOneWidget,
        reason: 'a copy button for $label',
      );
    }
  });

  testWidgets('switching to the Unicode tool shows the code point', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: JavaToolsPage()));
    await tester.pump();

    await tester.tap(find.text('字符/Unicode'));
    await tester.pumpAndSettle();

    // The default character is 中.
    expect(find.text('U+4E2D'), findsOneWidget);
    expect(find.text('E4 B8 AD'), findsOneWidget);
  });
}
