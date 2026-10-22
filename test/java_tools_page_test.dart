import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools_page.dart';
import 'package:qfli_java/java_debugger_page.dart';
import 'package:qfli_java/java_tools_pages.dart';
import 'package:qfli_java/java_developer_tool_pages.dart';
import 'package:qfli_studio_core/pages/content_tools_pages.dart';
import 'package:qfli_studio_core/pages/offline_tool_pages.dart';
import 'package:qfli_studio_core/pages/tools_grid.dart';
import 'package:qfli_studio_core/widgets/tool_widgets.dart';

/// Widget tests for the redesigned tools page.
///
/// The conversions are covered by the pure-logic suites; these check the page
/// structure: every tool is laid out on the page itself, each card opens its
/// own page, and the grid adapts to the window without overflowing.
void main() {
  // Wait for the route transition and the frame that hides its previous page.
  // A short fake-clock timeout keeps a persistent animation from hanging tests.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
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

  Future<Finder> revealCard(WidgetTester tester, String title) async {
    final card = find.widgetWithText(ToolCard, title);
    await tester.scrollUntilVisible(
      card,
      260,
      scrollable: find.descendant(
        of: find.byType(JavaToolsGrid),
        matching: find.byType(Scrollable),
      ),
    );
    // The final ensureVisible jump needs a layout frame before hit testing.
    await tester.pump();
    expect(card.hitTestable(), findsOneWidget);
    expect(find.text(title).hitTestable(), findsOneWidget);
    return card;
  }

  testWidgets('the page shows every tool card without opening anything', (
    tester,
  ) async {
    // A tall window so the whole page lays out at once and every card is built.
    await mount(tester, size: const Size(1100, 2400));

    expect(find.text('工具'), findsOneWidget);
    for (final tool in [...javaTools, ...commonTools]) {
      expect(
        find.text(tool.title),
        findsOneWidget,
        reason: 'card for ${tool.title} is on the page',
      );
    }
    expect(javaTools.map((tool) => tool.title), [
      JavaIntegerToolPage.title,
      JavaStringToolPage.title,
      JavaJsonToolPage.title,
      JavaReferenceToolPage.title,
      JavaDescriptorToolPage.title,
      JavaStackTraceToolPage.title,
      JavaClassFileToolPage.title,
      JavaJarToolPage.title,
      JavaDebuggerPage.title,
    ]);
    expect(commonTools, hasLength(9));
    final titles = [...javaTools, ...commonTools].map((tool) => tool.title);
    expect(titles.toSet(), hasLength(18), reason: 'no duplicated tool cards');
    expect(find.text('Java'), findsOneWidget);
    expect(find.text('通用'), findsOneWidget);
  });

  testWidgets('there is no single wrapper card around the whole page', (
    tester,
  ) async {
    // The regression this guards: the old page put everything inside one card
    // behind a tab set. Cards are per-tool, so a window tall enough to build
    // the whole page must show exactly one card per tool.
    await mount(tester, size: const Size(1100, 2400));
    expect(
      find.byType(ToolCard),
      findsNWidgets(javaTools.length + commonTools.length),
    );
  });

  testWidgets('tapping a card opens that tool page', (tester) async {
    await mount(tester);
    expect(find.byType(Base64ToolPage), findsNothing);
    await tester.tap(await revealCard(tester, Base64ToolPage.title));
    await settle(tester);

    expect(find.byType(Base64ToolPage), findsOneWidget);
    expect(find.byType(JavaToolsPage), findsNothing);
    // Its own content is live.
    expect(find.text('URL-safe 字母表（无填充）'), findsOneWidget);
  });

  testWidgets('a tool page offers copy buttons', (tester) async {
    await mount(tester);
    expect(find.byType(HashToolPage), findsNothing);
    await tester.tap(await revealCard(tester, HashToolPage.title));
    await settle(tester);

    expect(find.byType(HashToolPage), findsOneWidget);
    expect(find.byTooltip('复制MD5'), findsOneWidget);
    expect(find.byTooltip('复制SHA-1'), findsOneWidget);
    expect(find.byTooltip('复制SHA-256'), findsOneWidget);
  });

  for (final route in <(String, Type)>[
    (UnicodeToolPage.title, UnicodeToolPage),
    (TimestampToolPage.title, TimestampToolPage),
    (UrlToolPage.title, UrlToolPage),
    (RegexToolPage.title, RegexToolPage),
    (ColorToolPage.title, ColorToolPage),
    (UuidToolPage.title, UuidToolPage),
    ('JSON 格式化', JsonToolPage),
  ]) {
    testWidgets('the shared ${route.$1} card opens its core page', (
      tester,
    ) async {
      await mount(tester);
      expect(find.byType(route.$2), findsNothing);
      await tester.tap(await revealCard(tester, route.$1));
      await settle(tester);

      expect(find.byType(route.$2), findsOneWidget);
      expect(find.byType(JavaToolsPage), findsNothing);
      expect(find.byType(JavaJsonToolPage), findsNothing);
    });
  }

  testWidgets('the Java integer card still converts input', (tester) async {
    await mount(tester, size: const Size(1100, 2400));
    expect(find.byType(JavaIntegerToolPage), findsNothing);
    await tester.tap(await revealCard(tester, JavaIntegerToolPage.title));
    await settle(tester);

    expect(find.byType(JavaIntegerToolPage), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '0x10');
    await tester.pump();
    expect(find.text('16'), findsOneWidget);
    expect(find.text('Java 值'), findsOneWidget);
  });

  testWidgets('the Java string card still generates a literal', (tester) async {
    await mount(tester, size: const Size(1100, 2400));
    expect(find.byType(JavaStringToolPage), findsNothing);
    await tester.tap(await revealCard(tester, JavaStringToolPage.title));
    await settle(tester);

    expect(find.byType(JavaStringToolPage), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'A\nB');
    await tester.tap(find.text('转为字面量'));
    await tester.pump();
    expect(find.text(r'"A\nB"'), findsOneWidget);
    expect(find.text('text block'), findsOneWidget);
  });

  testWidgets('the Java JSON card still generates records', (tester) async {
    await mount(tester, size: const Size(1100, 2400));
    expect(find.byType(JavaJsonToolPage), findsNothing);
    await tester.tap(await revealCard(tester, JavaJsonToolPage.title));
    await settle(tester);

    expect(find.byType(JavaJsonToolPage), findsOneWidget);
    expect(find.byType(JsonToolPage), findsNothing);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('record User(') == true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('the Java reference card still shows language tables', (
    tester,
  ) async {
    await mount(tester, size: const Size(1100, 2400));
    expect(find.byType(JavaReferenceToolPage), findsNothing);
    await tester.tap(await revealCard(tester, JavaReferenceToolPage.title));
    await settle(tester);

    expect(find.byType(JavaReferenceToolPage), findsOneWidget);
    expect(find.text('基本类型'), findsOneWidget);
    expect(find.text('字符串转义'), findsOneWidget);
  });

  testWidgets('a narrow window lays the cards out in one column', (
    tester,
  ) async {
    await mount(tester, size: const Size(360, 900));
    final first = tester.getRect(find.byType(ToolCard).first);
    final second = tester.getRect(find.byType(ToolCard).at(1));
    // Same column: the second card starts at the same x and sits below.
    expect(second.left, closeTo(first.left, 0.5));
    expect(second.top, greaterThan(first.top));
    expect(first.right, lessThanOrEqualTo(360));
  });

  testWidgets('a wide window lays the cards out in several columns', (
    tester,
  ) async {
    await mount(tester, size: const Size(1100, 900));
    final first = tester.getRect(find.byType(ToolCard).first);
    final second = tester.getRect(find.byType(ToolCard).at(1));
    // Same row: the second card shares the first card's top and sits to its
    // right.
    expect(second.top, closeTo(first.top, 0.5));
    expect(second.left, greaterThan(first.left));
  });

  testWidgets('the page renders in dark mode', (tester) async {
    await mount(tester, size: const Size(1100, 2400), mode: ThemeMode.dark);
    expect(
      find.byType(ToolCard),
      findsNWidgets(javaTools.length + commonTools.length),
    );
    // The scaffold adopted the dark scheme.
    final context = tester.element(find.byType(JavaToolsPage));
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  testWidgets('the page scrolls to reach the last group', (tester) async {
    await mount(tester, size: const Size(420, 700));
    final scrollable = find.byType(CustomScrollView);
    expect(scrollable, findsOneWidget);
    await tester.scrollUntilVisible(
      find.widgetWithText(ToolCard, commonTools.last.title),
      300,
      scrollable: find.descendant(
        of: scrollable,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pump();
    expect(
      find.widgetWithText(ToolCard, commonTools.last.title).hitTestable(),
      findsOneWidget,
    );
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
