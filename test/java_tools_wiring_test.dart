import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools_page.dart';
import 'package:qfli_java/main.dart' show javaProfile;
import 'package:qfli_studio_core/pages/quick_tools_page.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';
import 'package:qfli_studio_core/store/project_store.dart';
import 'package:qfli_studio_core/theme/app_theme.dart';

/// Proves the Java profile actually hands its tools page to the shared shell.
///
/// A unit test on `JavaToolsPage` alone would pass even if the page were never
/// wired into `StudioProfile.toolsPageBuilder`, which is the part that makes it
/// reachable from the app's tools tab.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StudioProfile? originalProfile;

  setUp(() => originalProfile = StudioProfile.current);
  tearDown(() => StudioProfile.current = originalProfile);

  testWidgets('the Java profile exposes its tools page to the shell', (
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
