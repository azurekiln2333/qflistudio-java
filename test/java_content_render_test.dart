import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/main.dart' show javaProfile;
import 'package:qfli_studio_core/content/asset_content_repository.dart';
import 'package:qfli_studio_core/content/local_content_adapter.dart';
import 'package:qfli_studio_core/editor/editor_fonts.dart';
import 'package:qfli_studio_core/i18n/studio_localizations.dart';
import 'package:qfli_studio_core/models/tutorial.dart';
import 'package:qfli_studio_core/pages/local_content_pages.dart';
import 'package:qfli_studio_core/services/demo_run_service.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';
import 'package:qfli_studio_core/theme/app_theme.dart';
import 'package:qfli_studio_core/widgets/code_snippet.dart';

/// REAL-runner render: drives the actual Java example detail route, runs the
/// selected example through the app's real `JavaProgramRunner` (JDK), and
/// captures the page with genuine runtime output inline under the code.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<ExampleCode> javaExamples;

  setUpAll(() async {
    _installAssetHandler();
    await _loadFonts();
    final scratch = Directory.systemTemp.createTempSync('qfli_real_render_');
    DemoRunService.scratchRootOverride = scratch.path;
    addTearDown(() {
      DemoRunService.scratchRootOverride = null;
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    });
    javaExamples = await LocalContentAdapter.loadExamples(
      repository: AssetContentRepository(),
      language: 'java',
    );
  });

  testWidgets('real-runner inline output on java example detail route', (
    tester,
  ) async {
    StudioProfile.current = javaProfile;
    final example = javaExamples.firstWhere((e) => e.id == 'java-example-001');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: StudioLocalizations.supportedLocales,
          localizationsDelegates: const [StudioLocalizations.delegate],
          theme: _renderTheme(),
          home: ExampleDetailPage(example: example),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ExampleDetailPage), findsOneWidget);
    expect(
      find.byTooltip('Run example'),
      findsOneWidget,
      reason: 'run button on example detail',
    );
    await tester.tap(find.byTooltip('Run example'));
    // Real JDK compile/run: wait for completion (Run button back, no spinner).
    await _waitFor(
      tester,
      () => find.byIcon(Icons.play_arrow_outlined).evaluate().isNotEmpty,
      'real run completion',
      attempts: 400,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AlertDialog), findsNothing);
    // The inline run panel is a descendant of the CodeSnippet, which precedes
    // the page's "Expected output" section. Assert the REAL stdout lines are
    // rendered inside the CodeSnippet (the run panel), using the declared
    // output purely as an oracle.
    final codeSnippet = find.byType(CodeSnippet);
    expect(codeSnippet, findsOneWidget);
    for (final line in example.output.split('\n')) {
      if (line.trim().isEmpty) continue;
      expect(
        find.descendant(of: codeSnippet, matching: find.text(line)),
        findsWidgets,
        reason: 'inline run output inside CodeSnippet: $line',
      );
    }
    expect(tester.takeException(), isNull);
    await _capture(tester, captureKey, 'real-run-java-example-route');
  });

  testWidgets('real-runner inline output on java tutorial lesson route', (
    tester,
  ) async {
    StudioProfile.current = javaProfile;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: StudioLocalizations.supportedLocales,
          localizationsDelegates: const [StudioLocalizations.delegate],
          theme: _renderTheme(),
          home: const LocalTutorialsTab(language: 'java'),
        ),
      ),
    );
    await _waitFor(
      tester,
      () => find.byType(ListTile).evaluate().isNotEmpty,
      'tutorial list',
    );
    await tester.tap(find.byType(ListTile).first, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.byTooltip('Run example'),
      findsOneWidget,
      reason: 'lesson detail run button',
    );
    await tester.tap(find.byTooltip('Run example'));
    await _waitFor(
      tester,
      () => find.byIcon(Icons.play_arrow_outlined).evaluate().isNotEmpty,
      'real tutorial run completion',
      attempts: 400,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await _capture(tester, captureKey, 'real-run-java-tutorial-route');
  });
}

ThemeData _renderTheme() => AppTheme.light.copyWith(
  textTheme: AppTheme.light.textTheme.apply(
    fontFamily: 'Noto Sans SC',
    fontFamilyFallback: const ['Noto Sans SC'],
  ),
);

Future<void> _capture(
  WidgetTester tester,
  GlobalKey captureKey,
  String name,
) async {
  final boundary =
      captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final picture = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await picture.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory(
        '../qfli_java/.trellis/tasks/10-09-java-tutorial-rewrite/research/screenshots',
      );
      directory.createSync(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      picture.dispose();
    }
  });
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  String description, {
  int attempts = 120,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (condition()) return;
  }
  fail('Timed out waiting for $description');
}

Future<void> _loadFonts() async {
  final mono = FontLoader(EditorFonts.bundledFamily)
    ..addFont(
      _fontBytes(
        '../qfli_studio_core/assets/fonts/roboto_mono/static/RobotoMono-Regular.ttf',
      ),
    );
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      _fontBytes(
        'D:/ProgramFiles/flutter_ohos/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    );
  final cjk = FontLoader('Noto Sans SC')
    ..addFont(_fontBytes('C:/Windows/Fonts/NotoSansSC-VF.ttf'));
  // The code/output style uses EditorFonts.fallbacks which includes the generic
  // `monospace` family; register the CJK font there too so real program stdout
  // containing Chinese renders (test-harness font only).
  final monoCjk = FontLoader('monospace')
    ..addFont(_fontBytes('C:/Windows/Fonts/NotoSansSC-VF.ttf'));
  try {
    await Future.wait([mono.load(), icons.load(), cjk.load(), monoCjk.load()]);
  } on Exception {
    // Fonts are optional for layout verification.
  }
}

Future<ByteData> _fontBytes(String path) async {
  final file = File(path);
  return ByteData.sublistView(await file.readAsBytes());
}

void _installAssetHandler() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler('flutter/assets', (message) async {
    if (message == null) return null;
    final key = utf8.decode(
      message.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes),
    );
    final relative = key.startsWith('packages/')
        ? key.substring('packages/qfli_studio_core/'.length)
        : key;
    // Core assets live in the sibling package; resolve them from there.
    final file = File(relative).existsSync()
        ? File(relative)
        : File('../qfli_studio_core/$relative');
    if (!file.existsSync()) return null;
    return ByteData.sublistView(Uint8List.fromList(file.readAsBytesSync()));
  });
}
