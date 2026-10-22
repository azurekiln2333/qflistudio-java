import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_runner.dart';

void main() {
  test(
    'real Run preserves a Chinese Unicode package name',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'java-unicode-package-',
      );
      try {
        final entry = File(p.join(project.path, 'Main.java'));
        const source = '''
package 示例.中文包;
public class Main {
  public static void main(String[] args) {
    System.out.println("中文😀");
  }
}
''';
        await entry.writeAsString(source);
        final result = await const JavaProgramRunner().run(
          projectPath: project.path,
          entryFile: entry.path,
        );
        expect(result, isNotNull);
        final output = result!.stdout.toList();
        final error = result.stderr.toList();
        final exitCode = await result.exitCode;
        final actualOutput = await output;
        final actualError = await error;
        expect(exitCode, 0, reason: actualError.join('\n'));
        expect(actualOutput, ['中文😀']);
        expect(actualError, isEmpty);
        expect(result.title, 'java 示例.中文包.Main');
        expect(await entry.readAsString(), source);
      } finally {
        await project.delete(recursive: true);
      }
    },
  );
}
