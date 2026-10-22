import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_debugger.dart';
import 'package:qfli_java/java_debugger_page.dart';

class _ObservedDebugger extends JavaDebugger {
  _ObservedDebugger({required super.temporaryDirectory});
  JavaDebugSession? session;

  @override
  JavaDebugSession launch({
    required String projectPath,
    required String entryFile,
    Map<String, String> unsavedBuffers = const {},
    List<JavaBreakpoint> breakpoints = const [],
    List<String> arguments = const [],
  }) => session = super.launch(
    projectPath: projectPath,
    entryFile: entryFile,
    unsavedBuffers: unsavedBuffers,
    breakpoints: breakpoints,
    arguments: arguments,
  );
}

void main() {
  testWidgets(
    'page controls a genuine Unicode-package JVM breakpoint, local, step and output',
    (tester) async {
      final project = Directory.systemTemp.createTempSync('java debug page ');
      final temporary = Directory.systemTemp.createTempSync(
        'java_debug_page_tmp_',
      );
      final entry = File(p.join(project.path, 'Main.java'))
        ..writeAsStringSync('''
package 示例;
public class Main {
  public static void main(String[] args) {
    int answer = 40;
    answer += 2;
    System.out.println("answer=" + answer);
  }
}
''');
      final before = entry.readAsBytesSync();
      final debugger = _ObservedDebugger(temporaryDirectory: temporary.path);
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      Finder button(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      );
      Future<void> waitFor(Finder result) async {
        final elapsed = Stopwatch()..start();
        while (result.evaluate().isEmpty &&
            elapsed.elapsed < const Duration(seconds: 55)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
        expect(result, findsOneWidget);
      }

      Future<void> tap(String label) async {
        // Start backend work in the real async zone: javac/JDI use actual files,
        // processes and socket events, rather than the widget test's fake clock.
        await tester.runAsync(() => tester.tap(button(label)));
        await tester.pump();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(home: JavaDebuggerPage(debugger: debugger)),
        );
        await tester.enterText(
          find.widgetWithText(TextField, '项目绝对路径'),
          project.path,
        );
        await tester.enterText(
          find.widgetWithText(TextField, '断点类名'),
          '示例.Main',
        );
        await tester.enterText(find.widgetWithText(TextField, '断点行号'), '5');
        await tap('添加断点');
        await tap('启动调试');
        await waitFor(find.text('int answer = 40'));
        final vm = debugger.session!.vmInfo!;
        expect(find.text('${vm.name} ${vm.version}'), findsOneWidget);
        expect(find.text('已暂停'), findsOneWidget);
        expect(find.text('已绑定可执行位置'), findsOneWidget);
        expect(find.text('示例.Main.main'), findsOneWidget);
        await tap('单步越过');
        await waitFor(find.text('int answer = 42'));
        await tap('继续');
        await waitFor(find.text('已结束'));
        final output = tester.widget<SelectableText>(
          find.byKey(const ValueKey('java-debug-output')),
        );
        expect(output.data, contains('answer=42'));
        expect(output.data, contains('[进程结束：0]'));
        expect(entry.readAsBytesSync(), before);
        expect(project.listSync().map((file) => p.basename(file.path)), [
          'Main.java',
        ]);
        expect(temporary.listSync(), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await debugger.session?.stop();
          await project.delete(recursive: true);
          await temporary.delete(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
