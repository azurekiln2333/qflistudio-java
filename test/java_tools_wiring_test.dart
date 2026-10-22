import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools_page.dart';
import 'package:qfli_java/java_debugger_page.dart';
import 'package:qfli_studio_core/pages/offline_tool_pages.dart';
import 'package:qfli_studio_core/pages/tools_grid.dart';
import 'package:qfli_studio_core/widgets/tool_widgets.dart';
import 'package:qfli_java/main.dart' show javaProfile;
import 'package:qfli_studio_core/pages/quick_tools_page.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';
import 'package:qfli_studio_core/store/project_store.dart';
import 'package:qfli_studio_core/theme/app_theme.dart';

/// Exercises the real shell tab with the Java profile, including its terminal
/// callback, and keeps the standalone tools page route compatible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StudioProfile? originalProfile;

  setUp(() => originalProfile = StudioProfile.current);
  tearDown(() => StudioProfile.current = originalProfile);

  Future<void> mountTab(
    WidgetTester tester, {
    Size size = const Size(420, 700),
    ThemeMode mode = ThemeMode.light,
    required VoidCallback onOpenTerminal,
  }) async {
    StudioProfile.current = javaProfile;
    expect(javaProfile.toolsTabBuilder, isNotNull);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = ProjectStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        locale: const Locale('zh', 'CN'),
        home: FunctionsTab(
          store: store,
          onOpenTerminal: onOpenTerminal,
          onOpenContentTool: () {},
          toolsTabBuilder: javaProfile.toolsTabBuilder,
        ),
      ),
    );
    await tester.pump();
  }

  Finder gridScrollable() => find.descendant(
    of: find.byType(JavaToolsGrid),
    matching: find.byType(Scrollable),
  );

  Future<Finder> revealCard(WidgetTester tester, String title) async {
    final card = find.widgetWithText(ToolCard, title);
    await tester.scrollUntilVisible(card, 260, scrollable: gridScrollable());
    // scrollUntilVisible ends with a zero-duration ensureVisible/jumpTo. Lay
    // out that final scroll position before checking the card's hit target.
    await tester.pump();
    expect(
      card.hitTestable(),
      findsOneWidget,
      reason: '$title has a reachable tap target directly on the tools tab',
    );
    expect(find.text(title).hitTestable(), findsOneWidget);
    return card;
  }

  for (final size in const [Size(360, 700), Size(1100, 800)]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('the tools tab exposes every card at $size in ${mode.name}', (
        tester,
      ) async {
        var terminalOpens = 0;
        await mountTab(
          tester,
          size: size,
          mode: mode,
          onOpenTerminal: () => terminalOpens++,
        );

        expect(find.byType(JavaToolsGrid), findsOneWidget);
        expect(find.byType(ToolsGrid), findsOneWidget);
        expect(javaTools, hasLength(9));
        expect(commonTools, hasLength(9));
        expect(find.byType(JavaToolsPage), findsNothing);
        expect(find.byType(Scaffold), findsOneWidget);
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.text('功能'), findsNothing);
        expect(find.text('内置终端'), findsNothing);
        expect(
          Theme.of(tester.element(find.byType(JavaToolsGrid))).brightness,
          mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
        );

        final cards = find.byType(ToolCard);
        expect(tester.widget<ToolCard>(cards.first).title, '终端');
        expect(
          tester.widget<ToolCard>(cards.at(1)).title,
          javaTools.first.title,
        );
        expect(tester.getSize(cards.first), tester.getSize(cards.at(1)));
        await tester.tap(find.text('终端'));
        await tester.pump();
        expect(terminalOpens, 1);

        for (final tool in [...javaTools, ...commonTools]) {
          await revealCard(tester, tool.title);
        }
        expect(find.text('功能'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the tools tab contains one terminal and eighteen unique tools', (
    tester,
  ) async {
    await mountTab(tester, size: const Size(1100, 2400), onOpenTerminal: () {});

    final titles = tester
        .widgetList<ToolCard>(find.byType(ToolCard))
        .map((card) => card.title)
        .toList();
    expect(titles, [
      '终端',
      ...javaTools.map((tool) => tool.title),
      ...commonTools.map((tool) => tool.title),
    ]);
    expect(titles, hasLength(19));
    expect(titles.toSet(), hasLength(19));
  });

  testWidgets('a tool card on the tab opens its own page', (tester) async {
    await mountTab(tester, onOpenTerminal: () {});
    expect(find.byType(Base64ToolPage), findsNothing);
    final card = await revealCard(tester, Base64ToolPage.title);
    await tester.tap(card);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );

    expect(find.byType(Base64ToolPage), findsOneWidget);
    expect(find.byType(FunctionsTab), findsNothing);
    expect(find.text('URL-safe 字母表（无填充）'), findsOneWidget);
  });

  testWidgets('debugger card opens directly with the shell project store', (
    tester,
  ) async {
    await mountTab(tester, onOpenTerminal: () {});
    final grid = tester.widget<JavaToolsGrid>(find.byType(JavaToolsGrid));
    final card = await revealCard(tester, JavaDebuggerPage.title);
    await tester.tap(card);
    await tester.pumpAndSettle();
    final page = tester.widget<JavaDebuggerPage>(find.byType(JavaDebuggerPage));
    expect(page.store, same(grid.store));
    expect(page.store, isNotNull);
    expect(find.text('启动调试'), findsOneWidget);
  });

  testWidgets('the standalone tools page remains available to the shell', (
    tester,
  ) async {
    StudioProfile.current = javaProfile;
    expect(javaProfile.toolsPageBuilder, isNotNull);

    final store = ProjectStore();
    addTearDown(store.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh', 'CN'),
        home: ContentToolsPage(store: store),
      ),
    );
    await tester.pump();

    // The shell's content tools page renders whatever the profile supplies.
    expect(find.byType(JavaToolsPage), findsOneWidget);
    expect(find.text('工具'), findsWidgets);
  });
}
