import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:qfli_java/main.dart' as app;
import 'package:qfli_studio_core/app.dart';
import 'package:qfli_studio_core/pages/home_page.dart';
import 'package:qfli_studio_core/services/app_paths.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';
import 'package:qfli_studio_core/splash_screen.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qflistudio/platform');
  final messenger = binding.defaultBinaryMessenger;
  late Directory directory;
  late PathProviderPlatform originalPaths;
  StudioProfile? originalProfile;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('qfli_startup_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryPaths(directory.path);
    await AppPaths.storageDirectory();
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  setUp(() {
    binding.resetFirstFrameSent();
    originalProfile = StudioProfile.current;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    StudioProfile.current = originalProfile;
  });

  Future<void> waitForBootstrap(WidgetTester tester) async {
    final root = tester.widget<QfliApp>(find.byType(QfliApp));
    for (var attempt = 0; !root.ready!.value && attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(root.ready!.value, isTrue);
  }

  for (final available in [true, false]) {
    testWidgets(
      'OHOS waits for home layout with progress channel ${available ? "available" : "missing"}',
      (tester) async {
        final progress = <double>[];
        if (available) {
          messenger.setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'startupProgress');
            progress.add((call.arguments as Map)['progress'] as double);
            return null;
          });
        }

        await app.main();
        expect(binding.sendFramesToEngine, isFalse);
        await tester.pump();
        expect(find.byType(SplashScreen), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 160));
        await waitForBootstrap(tester);
        await tester.pump();

        expect(find.byType(HomePage), findsOneWidget);
        expect(binding.sendFramesToEngine, isFalse);
        if (available) {
          expect(progress.first, 0.05);
          expect(progress, contains(0.25));
          expect(progress.last, 1.0);
          expect(progress, orderedEquals([...progress]..sort()));
        }

        await tester.pump(const Duration(milliseconds: 1100));
        await tester.pump();
        expect(binding.sendFramesToEngine, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({TargetPlatform.ohos}),
    );
  }

  testWidgets(
    'Android renders the Flutter loading screen immediately',
    (tester) async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        fail('Android startup should use its Flutter loading screen');
      });

      await app.main();
      expect(binding.sendFramesToEngine, isTrue);
      await tester.pump();
      expect(find.byType(SplashScreen), findsOneWidget);
      await waitForBootstrap(tester);
      await tester.pump();
      expect(find.byType(HomePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
