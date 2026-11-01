import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_diagnostics.dart';
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_studio_core/editor/editor_analysis_controller.dart';
import 'package:qfli_studio_core/editor/editor_controller.dart';
import 'package:qfli_studio_core/editor/editor_problems_bar.dart';
import 'package:qfli_studio_core/models/project.dart';
import 'package:qfli_studio_core/services/studio_profile.dart'
    show ProgramRunResult;

void main() {
  for (final hasJava in [false, true]) {
    testWidgets(
      'README active with Java sources=$hasJava never renders a clean Problems status',
      (tester) async {
        final root = Directory.systemTemp.createTempSync(
          'java_readme_analysis_',
        );
        final editor = EditorController(
          project: Project.create(
            name: 'Java',
            path: root.path,
            type: 'java',
            language: 'Java',
          ),
        );
        final runner = _NeverCompileRunner();
        EditorAnalysisController? analysis;
        try {
          if (hasJava) {
            final java = File(p.join(root.path, 'Main.java'))
              ..writeAsStringSync('public class Main {}');
            expect(
              await tester.runAsync(() => editor.openPath(java.path)),
              isNull,
            );
          }
          final readme = File(p.join(root.path, 'README.md'))
            ..writeAsStringSync('# Java project');
          expect(
            await tester.runAsync(() => editor.openPath(readme.path)),
            isNull,
          );
          analysis = EditorAnalysisController(
            editor: editor,
            analyzer: JavaDiagnosticAnalyzer(runner: runner),
            debounce: Duration.zero,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: EditorProblemsBar(
                  analysis: analysis,
                  onOpenProblems: () {},
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          );
          expect(analysis.pending, isTrue);
          expect(find.text('正在检查…'), findsOneWidget);
          // pumpWidget flushes microtasks without advancing the fake clock.
          // Advance beyond the zero-duration debounce before expecting its
          // asynchronous provider result and the status bar to settle.
          await tester.pump(const Duration(milliseconds: 1));
          expect(analysis.pending, isFalse);
          expect(analysis.checked, isFalse);
          expect(analysis.problems, isEmpty);
          expect(analysis.unavailableReason, contains('.java'));
          expect(find.text('本地检查未发现问题'), findsNothing);
          expect(find.text(analysis.unavailableReason!), findsOneWidget);
          expect(runner.calls, 0);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          analysis?.dispose();
          editor.dispose();
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}

class _NeverCompileRunner extends JavaProgramRunner {
  int calls = 0;

  @override
  Future<ProgramRunResult?> runToolchainCommand({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
  }) async {
    calls++;
    throw StateError(
      'Unsupported active document must be rejected before javac',
    );
  }
}
