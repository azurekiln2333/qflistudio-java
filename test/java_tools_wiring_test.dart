import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools_page.dart';
import 'package:qfli_java/java_tools_pages.dart';
import 'package:qfli_java/java_tools_widgets.dart';
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
    final card = find.widgetWithText(JavaToolCard, title);
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
        expect(find.byType(JavaToolsPage), findsNothing);
        expect(find.byType(Scaffold), findsOneWidget);
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.text('功能'), findsNothing);
        expect(find.text('内置终端'), findsNothing);
        expect(
          Theme.of(tester.element(find.byType(JavaToolsGrid))).brightness,
          mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
        );

        final cards = find.byType(JavaToolCard);
        expect(tester.widget<JavaToolCard>(cards.first).title, '终端');
        expect(
          tester.widget<JavaToolCard>(cards.at(1)).title,
          javaTools.first.title,
        );
        expect(tester.getSize(cards.first), tester.getSize(cards.at(1)));
        await tester.tap(find.text('终端'));
        await tester.pump();
        expect(terminalOpens, 1);

        for (final tool in javaTools) {
          await revealCard(tester, tool.title);
        }
        expect(find.text('功能'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('a tool card on the tab opens its own page', (tester) async {
    await mountTab(tester, onOpenTerminal: () {});
    final card = await revealCard(tester, JavaBase64ToolPage.title);
    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(JavaBase64ToolPage), findsOneWidget);
    expect(find.text('URL-safe 字母表（无填充）'), findsOneWidget);
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
