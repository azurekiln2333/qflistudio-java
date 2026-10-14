import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools_page.dart';
import 'package:qfli_java/java_tools_pages.dart';
import 'package:qfli_java/java_tools_widgets.dart';

/// Widget tests for the redesigned tools page.
///
/// The conversions are covered by the pure-logic suites; these check the page
/// structure: every tool is laid out on the page itself, each card opens its
/// own page, and the grid adapts to the window without overflowing.
void main() {
  // `pumpAndSettle` is avoided throughout: page transitions settle quickly, but
  // a fixed pair of pumps is deterministic and cannot hang.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(420, 900),
    ThemeMode mode = ThemeMode.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        themeMode: mode,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: const Color(0xFF0B63CE),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF0B63CE),
        ),
        home: const JavaToolsPage(),
      ),
    );
    await settle(tester);
  }

  testWidgets('the page shows every tool card without opening anything', (
    tester,
  ) async {
    // A tall window so the whole page lays out at once and every card is built.
    await mount(tester, size: const Size(1100, 2400));

    expect(find.text('工具'), findsOneWidget);
    for (final tool in javaTools) {
      expect(
        find.text(tool.title),
        findsOneWidget,
        reason: 'card for ${tool.title} is on the page',
      );
    }
    // Every group heading is present too.
    for (final group in JavaToolGroup.values) {
      if (javaTools.any((tool) => tool.group == group)) {
        expect(find.text(group.label), findsOneWidget);
      }
    }
  });

  testWidgets('there is no single wrapper card around the whole page', (
    tester,
  ) async {
    // The regression this guards: the old page put everything inside one card
    // behind a tab set. Cards are per-tool, so a window tall enough to build
    // the whole page must show exactly one card per tool.
    await mount(tester, size: const Size(1100, 2400));
    expect(find.byType(JavaToolCard), findsNWidgets(javaTools.length));
  });

  testWidgets('tapping a card opens that tool page', (tester) async {
    await mount(tester);
    await tester.tap(find.text(JavaBase64ToolPage.title));
    await settle(tester);

    expect(find.byType(JavaBase64ToolPage), findsOneWidget);
    // Its own content is live.
    expect(find.text('URL-safe 字母表（无填充）'), findsOneWidget);
  });

  testWidgets('a tool page offers copy buttons', (tester) async {
    await mount(tester);
    await tester.tap(find.text(JavaHashToolPage.title));
    await settle(tester);

    expect(find.byType(JavaHashToolPage), findsOneWidget);
    expect(find.byTooltip('复制MD5'), findsOneWidget);
    expect(find.byTooltip('复制SHA-1'), findsOneWidget);
    expect(find.byTooltip('复制SHA-256'), findsOneWidget);
  });

  testWidgets('a narrow window lays the cards out in one column', (
    tester,
  ) async {
    await mount(tester, size: const Size(360, 900));
    final first = tester.getRect(find.byType(JavaToolCard).first);
    final second = tester.getRect(find.byType(JavaToolCard).at(1));
    // Same column: the second card starts at the same x and sits below.
    expect(second.left, closeTo(first.left, 0.5));
    expect(second.top, greaterThan(first.top));
    expect(first.right, lessThanOrEqualTo(360));
  });

  testWidgets('a wide window lays the cards out in several columns', (
    tester,
  ) async {
    await mount(tester, size: const Size(1100, 900));
    final first = tester.getRect(find.byType(JavaToolCard).first);
    final second = tester.getRect(find.byType(JavaToolCard).at(1));
    // Same row: the second card shares the first card's top and sits to its
    // right.
    expect(second.top, closeTo(first.top, 0.5));
    expect(second.left, greaterThan(first.left));
  });

  testWidgets('the page renders in dark mode', (tester) async {
    await mount(tester, size: const Size(1100, 2400), mode: ThemeMode.dark);
    expect(find.byType(JavaToolCard), findsNWidgets(javaTools.length));
    // The scaffold adopted the dark scheme.
    final context = tester.element(find.byType(JavaToolsPage));
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  testWidgets('the page scrolls to reach the last group', (tester) async {
    await mount(tester, size: const Size(420, 700));
    final scrollable = find.byType(CustomScrollView);
    expect(scrollable, findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(JavaToolGroup.reference.label),
      300,
      scrollable: find.descendant(
        of: scrollable,
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text(JavaReferenceToolPage.title), findsOneWidget);
  });

  testWidgets('no overflow is reported in either orientation', (tester) async {
    for (final size in const [Size(360, 640), Size(1200, 800)]) {
      await mount(tester, size: size);
      expect(
        tester.takeException(),
        isNull,
        reason: 'no layout overflow at $size',
      );
    }
  });
}
