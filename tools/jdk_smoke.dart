import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_java/mobile_jdk.dart';
import 'package:qfli_studio_core/services/app_paths.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.shrink(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => _check());
}

Future<void> _check() async {
  final checks = <String>[];
  Directory? project;
  try {
    final layout = await MobileJdk.prepare();
    checks.add('java-version');
    checks.add('javac-version');
    final storage = await AppPaths.storageDirectory();
    if (storage == null) throw StateError('No writable app storage');
    project = await Directory(storage).createTemp('jdk-smoke-');
    final root = project.path;
    Future<void> write(String name, String content) async {
      final file = File(p.join(root, name));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    Future<({List<String> stdout, List<String> stderr, int code})> run(
      String source,
    ) async {
      await write('src/Main.java', source);
      final result = (await const JavaProgramRunner().run(
        projectPath: root,
        entryFile: p.join(root, 'src/Main.java'),
      ))!;
      final output = result.stdout.toList();
      final error = result.stderr.toList();
      final code = await result.exitCode.timeout(const Duration(seconds: 60));
      return (stdout: await output, stderr: await error, code: code);
    }

    await write(
      'src/Helper.java',
      'package demo; class Helper { static int twice(int n) { return n * 2; } }',
    );
    await write('input.txt', '21\n');
    final first = await run(r'''
package demo;
import java.util.Scanner;
public class Main {
  public static void main(String[] args) {
    System.out.println(Helper.twice(new Scanner(System.in).nextInt()));
    System.out.println("\u4f60\u597d\uff0cJava");
  }
}
''');
    if (first.code != 0 ||
        first.stdout.join('|') != '42|\u4f60\u597d\uff0cJava') {
      throw StateError('Java run failed: $first');
    }
    checks.addAll(['multiple-sources', 'stdin', 'utf8']);
    final bad = await run('package demo; public class Main { BROKEN }');
    if (bad.code != kProgramNotRunExitCode ||
        !bad.stderr.join().contains('Main.java')) {
      throw StateError('javac diagnostics failed: $bad');
    }
    checks.add('compiler-diagnostics');
    final exit = await run(
      'package demo; public class Main { public static void main(String[] args) { System.exit(7); } }',
    );
    if (exit.code != 7) throw StateError('JVM exit code was ${exit.code}');
    checks.add('exit-code');
    await write('src/Main.java', '''
package demo;
public class Main {
  public static void main(String[] args) throws Exception {
    System.out.println("running");
    while (true) Thread.sleep(1000);
  }
}
''');
    final loop = (await const JavaProgramRunner().run(
      projectPath: root,
      entryFile: p.join(root, 'src/Main.java'),
    ))!;
    final error = loop.stderr.toList();
    final line = await loop.stdout.first.timeout(const Duration(seconds: 30));
    if (line != 'running') throw StateError('JVM did not start: $line');
    await loop.cancel!().timeout(const Duration(seconds: 10));
    if (await loop.exitCode == 0) {
      throw StateError('Canceled program returned success');
    }
    await error;
    checks.add('cancel');
    debugPrint(
      'QFLI_JDK_SMOKE ${jsonEncode({'ok': true, 'checks': checks, 'home': layout.home})}',
    );
  } catch (error, stack) {
    debugPrint(
      'QFLI_JDK_SMOKE ${jsonEncode({'ok': false, 'checks': checks, 'error': error.toString(), 'stack': stack.toString()})}',
    );
  } finally {
    if (project != null) await project.delete(recursive: true);
  }
}
