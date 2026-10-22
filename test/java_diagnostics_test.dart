import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_diagnostics.dart';
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_studio_core/services/code_analysis.dart';
import 'package:qfli_studio_core/services/studio_profile.dart'
    show ProgramRunResult, kProgramNotRunExitCode;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory project;
  late Directory temporary;

  setUp(() {
    project = Directory.systemTemp.createTempSync('java diagnostics project ');
    temporary = Directory.systemTemp.createTempSync('java_diagnostics_tmp_');
  });
  tearDown(() {
    project.deleteSync(recursive: true);
    temporary.deleteSync(recursive: true);
  });

  File write(String relative, String text) {
    final file = File(p.normalize(p.join(project.path, relative)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return file;
  }

  JavaDiagnosticAnalyzer analyzer({JavaProgramRunner? runner}) =>
      JavaDiagnosticAnalyzer(
        runner: runner ?? const JavaProgramRunner(),
        temporaryDirectory: temporary.path,
      );

  void expectClean() => expect(temporary.listSync(), isEmpty);

  test(
    'raw toolchain preserves real output paused across process exit',
    () async {
      final process = (await const JavaProgramRunner().startToolchainProcess(
        workingDirectory: project.path,
        arguments: [
          'java',
          '-Xms16m',
          '-Xmx64m',
          '-XX:+UseSerialGC',
          '-version',
        ],
        isolatedEnvironment: true,
      ))!;
      final bytes = <int>[];
      final completed = Completer<void>();
      final stdout = process.stdout.drain<void>();
      final subscription = process.stderr.listen(
        bytes.addAll,
        onDone: completed.complete,
        onError: completed.completeError,
      );
      subscription.pause();
      try {
        expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
        await Future<void>.delayed(const Duration(milliseconds: 2300));
        subscription.resume();
        await completed.future.timeout(const Duration(seconds: 5));
        await stdout;
        expect(utf8.decode(bytes), contains('version'));
      } finally {
        await subscription.cancel();
        await process.cancel();
      }
    },
  );

  test('Run accepts Java17 and rejects newer host APIs before execution', () async {
    final file = write(
      'Main.java',
      'public class Main { public static void main(String[] a) { System.out.println(java.util.HexFormat.of().toHexDigits((byte)42)); } }',
    );
    final good = (await const JavaProgramRunner().run(
      projectPath: project.path,
      entryFile: file.path,
    ))!;
    final goodOut = good.stdout.toList();
    final goodErr = good.stderr.toList();
    expect(await good.exitCode, 0);
    expect(await goodOut, ['2a']);
    expect(await goodErr, isEmpty);
    file.writeAsStringSync(
      'public class Main { public static void main(String[] a) { Thread.ofVirtual(); } }',
    );
    final newer = (await const JavaProgramRunner().run(
      projectPath: project.path,
      entryFile: file.path,
    ))!;
    expect(await newer.exitCode, kProgramNotRunExitCode);
    expect((await newer.stderr.toList()).join('\n'), contains('ofVirtual'));
    expect(await newer.stdout.toList(), isEmpty);
  });

  test('Run bounds real javac compilation before starting user code', () async {
    final file = write(
      'Main.java',
      'public class Main { public static void main(String[] a) { throw new AssertionError("must not run"); } }',
    );
    final result = (await const JavaProgramRunner(
      compileTimeout: Duration.zero,
    ).run(projectPath: project.path, entryFile: file.path))!;
    expect(await result.exitCode, kProgramNotRunExitCode);
    expect(await result.stdout.toList(), isEmpty);
    expect((await result.stderr.toList()).join('\n'), contains('编译超时'));
    expect(File(p.join(project.path, 'Main.class')).existsSync(), isFalse);
  });

  test(
    'Run output byte limit kills a real compiler rather than truncating a success',
    () async {
      final file = write('Main.java', 'public class Main { BROKEN }');
      final result = (await const JavaProgramRunner(
        compilerOutputLimit: 1,
      ).run(projectPath: project.path, entryFile: file.path))!;
      expect(await result.exitCode, kProgramNotRunExitCode);
      expect((await result.stderr.toList()).join('\n'), contains('输出限制'));
      expect(File(p.join(project.path, 'Main.class')).existsSync(), isFalse);
    },
  );

  test(
    'core analyzer receives every snapshot and preserves exact offsets',
    () async {
      final file = write('Main.java', 'public class Main { int n = 1; }');
      const text = 'public class Main { String s = "😀"; int n = "bad"; }';
      final result = await analyzer().analyze(
        CodeAnalysisRequest(
          projectPath: project.path,
          activeFilePath: file.path,
          language: 'java',
          revision: 3,
          documents: [
            CodeDocumentSnapshot(path: file.path, text: text, revision: 3),
          ],
        ),
      );
      expect(result.unavailableReason, isNull);
      final error = result.diagnostics.singleWhere(
        (d) => d.severity == CodeDiagnosticSeverity.error,
      );
      expect(error.filePath, file.path);
      expect(text.substring(error.startOffset, error.endOffset), '"bad"');
      expect(error.source, 'javac');
      expect(file.readAsStringSync(), 'public class Main { int n = 1; }');
      expectClean();
    },
  );

  test(
    'core adapter reports unavailable tools without claiming clean syntax',
    () async {
      final file = write('Main.java', 'public class Main {}');
      final result =
          await analyzer(runner: _ControlledRunner(unavailable: true)).analyze(
            CodeAnalysisRequest(
              projectPath: project.path,
              activeFilePath: file.path,
              language: 'java',
              revision: 1,
              documents: [
                CodeDocumentSnapshot(
                  path: file.path,
                  text: file.readAsStringSync(),
                  revision: 1,
                ),
              ],
            ),
          );
      expect(result.diagnostics, isEmpty);
      expect(result.unavailableReason, contains('missing JDK'));
      expectClean();
    },
  );

  test('an unreadable local JAR cannot be reported as clean source', () async {
    final file = write('Main.java', 'public class Main {}');
    write('lib/broken.jar', 'this is not a ZIP');
    final result = await analyzer().analyze(
      CodeAnalysisRequest(
        projectPath: project.path,
        activeFilePath: file.path,
        language: 'java',
        revision: 1,
        documents: [
          CodeDocumentSnapshot(
            path: file.path,
            text: file.readAsStringSync(),
            revision: 1,
          ),
        ],
      ),
    );
    expect(
      result.unavailableReason != null ||
          result.diagnostics.any(
            (d) => d.severity == CodeDiagnosticSeverity.error,
          ),
      isTrue,
    );
    expectClean();
  });

  test(
    'real desktop javac is terminated before its scratch files are deleted',
    () async {
      write('Main.java', 'class Main {}');
      final runner = _ObservingRunner();
      final cancellation = JavaAnalysisCancellation();
      final future = analyzer(
        runner: runner,
      ).analyzeProject(projectPath: project.path, cancellation: cancellation);
      final process = await runner.started.future;
      cancellation.cancel();
      final result = await future;
      expect(result.status, JavaAnalysisStatus.cancelled);
      await process.exitCode;
      expectClean();
    },
  );

  test(
    'all dirty source buffers overlay a multi-file package without writes',
    () async {
      final main = write('src/demo/Main.java', '''
package demo;
public class Main {
  static { throwIfRun(); }
  static void throwIfRun() { throw new AssertionError("must never execute"); }
  String value = Helper.message();
}
''');
      final helper = write('src/demo/Helper.java', '''
package demo;
class Helper { static int message() { return 1; } }
''');
      final originalMain = main.readAsBytesSync();
      final originalHelper = helper.readAsBytesSync();
      final first = await analyzer().analyzeProject(projectPath: project.path);
      expect(first.status, JavaAnalysisStatus.complete, reason: first.message);
      expect(
        first.diagnostics.any(
          (d) => d.severity == JavaDiagnosticSeverity.error,
        ),
        isTrue,
      );
      final result = await analyzer().analyzeProject(
        projectPath: project.path,
        unsavedBuffers: {
          main.path: main.readAsStringSync().replaceFirst(
            'Helper.message()',
            'Helper.edited()',
          ),
          helper.path:
              'package demo; class Helper { static String edited() { return "ok"; } }',
        },
      );
      expect(
        result.status,
        JavaAnalysisStatus.complete,
        reason: result.message,
      );
      expect(
        result.diagnostics.where(
          (d) => d.severity == JavaDiagnosticSeverity.error,
        ),
        isEmpty,
      );
      expect(main.readAsBytesSync(), originalMain);
      expect(helper.readAsBytesSync(), originalHelper);
      expect(
        project
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.extension(f.path)),
        everyElement('.java'),
      );
      expectClean();
    },
  );

  test(
    'new unsaved public classes keep their filenames and are not saved',
    () async {
      final path = p.join(project.path, 'src', 'Main.java');
      final result = await analyzer().analyzeProject(
        projectPath: project.path,
        unsavedBuffers: {path: 'public class Main { int n = 1; }'},
      );
      expect(
        result.status,
        JavaAnalysisStatus.complete,
        reason: result.message,
      );
      expect(result.diagnostics, isEmpty);
      expect(File(path).existsSync(), isFalse);
      expectClean();
    },
  );

  test(
    'same-name files map exact javac ranges across CRLF, tabs and emoji',
    () async {
      write('a/Main.java', 'package a; public class Main { int n = "one"; }');
      const edited =
          'package b; public class Main {\r\n\tString text = "😀中文"; int n = "wrong";\r\n}';
      final second = write('b/Main.java', 'package b; public class Main {}');
      final result = await analyzer().analyzeProject(
        projectPath: project.path,
        unsavedBuffers: {second.path: edited},
      );
      expect(
        result.status,
        JavaAnalysisStatus.complete,
        reason: result.message,
      );
      final errors = result.diagnostics
          .where((d) => d.severity == JavaDiagnosticSeverity.error)
          .toList();
      expect(errors.length, 2);
      expect(errors.map((d) => d.path).toSet(), {
        p.join(project.path, 'a', 'Main.java'),
        second.path,
      });
      final error = errors.singleWhere((d) => d.path == second.path);
      expect(error.offset, edited.indexOf('"wrong"'));
      expect(
        edited.substring(error.offset, error.offset + error.length),
        '"wrong"',
      );
      expect(error.line, 2);
      expect(error.column, greaterThan(1));
      expect(error.code, startsWith('compiler.err.'));
      expect(error.message, contains('java.lang.String'));
      expect(second.readAsStringSync(), 'package b; public class Main {}');
      expectClean();
    },
  );

  test(
    'syntax errors and compiler warnings remain separate severities',
    () async {
      final source = write(
        'Main.java',
        'public class Main { void f() { int n = ; } }',
      );
      final broken = await analyzer().analyzeProject(projectPath: project.path);
      expect(
        broken.status,
        JavaAnalysisStatus.complete,
        reason: broken.message,
      );
      expect(
        broken.diagnostics.any(
          (d) =>
              d.severity == JavaDiagnosticSeverity.error &&
              d.code.contains('illegal.start'),
        ),
        isTrue,
      );
      final warning = await analyzer().analyzeProject(
        projectPath: project.path,
        unsavedBuffers: {
          source.path:
              'import java.util.*; public class Main { List raw = new ArrayList(); }',
        },
      );
      expect(
        warning.status,
        JavaAnalysisStatus.complete,
        reason: warning.message,
      );
      expect(
        warning.diagnostics.any(
          (d) =>
              d.severity == JavaDiagnosticSeverity.warning &&
              d.code.contains('raw.class.use'),
        ),
        isTrue,
      );
      expect(
        warning.diagnostics.where(
          (d) => d.severity == JavaDiagnosticSeverity.error,
        ),
        isEmpty,
      );
      expectClean();
    },
  );

  test(
    'release 17 rejects APIs and syntax introduced by newer host JDKs',
    () async {
      write(
        'Main.java',
        'public class Main { Object n = Thread.ofVirtual(); }',
      );
      final result = await analyzer().analyzeProject(projectPath: project.path);
      expect(
        result.status,
        JavaAnalysisStatus.complete,
        reason: result.message,
      );
      expect(
        result.diagnostics.any(
          (d) =>
              d.severity == JavaDiagnosticSeverity.error &&
              d.message.contains('ofVirtual'),
        ),
        isTrue,
      );
      expectClean();
    },
  );

  test(
    'local lib/libs JARs resolve but their annotation processors never run',
    () async {
      final fixture = Directory(p.join(temporary.path, 'jar_fixture'))
        ..createSync();
      final marker = p
          .join(project.path, 'processor-ran.txt')
          .replaceAll('\\', '\\\\');
      final api = File(p.join(fixture.path, 'Api.java'))
        ..writeAsStringSync(
          'package local; public class Api { public static int answer() { return 42; } }',
        );
      final processor = File(p.join(fixture.path, 'DangerProcessor.java'))
        ..writeAsStringSync('''
import java.util.*;
import javax.annotation.processing.*;
import javax.lang.model.*;
import javax.lang.model.element.*;
@SupportedAnnotationTypes("*")
@SupportedSourceVersion(SourceVersion.RELEASE_17)
public class DangerProcessor extends AbstractProcessor {
  public boolean process(Set<? extends TypeElement> a, RoundEnvironment r) {
    try { java.nio.file.Files.writeString(java.nio.file.Path.of("$marker"), "ran"); }
    catch (Exception e) { throw new RuntimeException(e); }
    return false;
  }
}
''');
      final classes = Directory(p.join(fixture.path, 'classes'))..createSync();
      await _runTool(fixture.path, [
        'javac',
        '--release',
        '17',
        '-proc:none',
        '-d',
        classes.path,
        api.path,
        processor.path,
      ]);
      final service = File(
        p.join(
          classes.path,
          'META-INF',
          'services',
          'javax.annotation.processing.Processor',
        ),
      );
      service.parent.createSync(recursive: true);
      service.writeAsStringSync('DangerProcessor\n');
      final jar = File(p.join(project.path, 'lib', 'local processor.jar'));
      jar.parent.createSync();
      await _runTool(fixture.path, [
        'java',
        '-m',
        'jdk.jartool/sun.tools.jar.Main',
        '--create',
        '--file',
        jar.path,
        '-C',
        classes.path,
        '.',
      ]);
      // Add a separate libs dependency too, rather than succeeding with only lib.
      final extra = File(p.join(fixture.path, 'Extra.java'))
        ..writeAsStringSync(
          'package extra; public class Extra { public static int n = 1; }',
        );
      final extraClasses = Directory(p.join(fixture.path, 'extra'))
        ..createSync();
      await _runTool(fixture.path, [
        'javac',
        '--release',
        '17',
        '-proc:none',
        '-d',
        extraClasses.path,
        extra.path,
      ]);
      final extraJar = File(p.join(project.path, 'libs', 'extra.jar'));
      extraJar.parent.createSync();
      await _runTool(fixture.path, [
        'java',
        '-m',
        'jdk.jartool/sun.tools.jar.Main',
        '--create',
        '--file',
        extraJar.path,
        '-C',
        extraClasses.path,
        '.',
      ]);
      write(
        'Main.java',
        'public class Main { int n = local.Api.answer() + extra.Extra.n; }',
      );
      final before = jar.readAsBytesSync();
      final result = await analyzer().analyzeProject(projectPath: project.path);
      expect(
        result.status,
        JavaAnalysisStatus.complete,
        reason: result.message,
      );
      expect(result.diagnostics, isEmpty);
      expect(
        File(p.join(project.path, 'processor-ran.txt')).existsSync(),
        isFalse,
      );
      expect(jar.readAsBytesSync(), before);
      expect(temporary.listSync().map((e) => p.basename(e.path)), [
        'jar_fixture',
      ]);
    },
  );

  test('outside buffers fail before starting a compiler', () async {
    final runner = _ControlledRunner();
    final result = await analyzer(runner: runner).analyzeProject(
      projectPath: project.path,
      unsavedBuffers: {
        p.join(project.parent.path, 'Elsewhere.java'): 'class Elsewhere {}',
      },
    );
    expect(result.status, JavaAnalysisStatus.failed);
    expect(runner.calls, 0);
    expectClean();
  });

  test('source/file/output limits do not become source diagnostics', () async {
    write('Main.java', 'class Main {}');
    var result = await JavaDiagnosticAnalyzer(
      maxSources: 0,
      temporaryDirectory: temporary.path,
    ).analyzeProject(projectPath: project.path);
    expect(result.status, JavaAnalysisStatus.limitExceeded);
    result = await JavaDiagnosticAnalyzer(
      maxSourceBytes: 1,
      temporaryDirectory: temporary.path,
    ).analyzeProject(projectPath: project.path);
    expect(result.status, JavaAnalysisStatus.limitExceeded);
    final runner = _ControlledRunner(output: 'too much output');
    result = await JavaDiagnosticAnalyzer(
      runner: runner,
      maxOutputBytes: 1,
      temporaryDirectory: temporary.path,
    ).analyzeProject(projectPath: project.path);
    expect(result.status, JavaAnalysisStatus.limitExceeded);
    expect(runner.cancellations, 1);
    expectClean();
  });

  test(
    'cancels an active compiler and waits before cleaning its snapshot',
    () async {
      write('Main.java', 'class Main {}');
      final runner = _ControlledRunner();
      final cancellation = JavaAnalysisCancellation();
      final future = analyzer(
        runner: runner,
      ).analyzeProject(projectPath: project.path, cancellation: cancellation);
      await runner.started.future;
      cancellation.cancel();
      final result = await future;
      expect(result.status, JavaAnalysisStatus.cancelled);
      expect(runner.cancellations, 1);
      expect(runner.snapshotExistedAtCancel, isTrue);
      expectClean();
    },
  );

  test('pre-cancelled checks never create snapshots or start tools', () async {
    write('Main.java', 'class Main {}');
    final runner = _ControlledRunner();
    final cancellation = JavaAnalysisCancellation()..cancel();
    final result = await analyzer(
      runner: runner,
    ).analyzeProject(projectPath: project.path, cancellation: cancellation);
    expect(result.status, JavaAnalysisStatus.cancelled);
    expect(runner.calls, 0);
    expectClean();
  });

  test('timeout kills the active compiler and reports a tool status', () async {
    write('Main.java', 'class Main {}');
    final runner = _ControlledRunner();
    final future = JavaDiagnosticAnalyzer(
      runner: runner,
      timeout: const Duration(milliseconds: 250),
      temporaryDirectory: temporary.path,
    ).analyzeProject(projectPath: project.path);
    await runner.started.future;
    final result = await future;
    expect(result.status, JavaAnalysisStatus.timedOut);
    expect(runner.cancellations, 1);
    expectClean();
  });

  test(
    'missing JDK is unavailable rather than an invented syntax error',
    () async {
      write('Main.java', 'class Main {}');
      final result = await analyzer(
        runner: _ControlledRunner(unavailable: true),
      ).analyzeProject(projectPath: project.path);
      expect(result.status, JavaAnalysisStatus.unavailable);
      expect(result.diagnostics, isEmpty);
      expect(result.message, contains('missing JDK'));
      expectClean();
    },
  );
}

Future<void> _runTool(String directory, List<String> arguments) async {
  final result = (await const JavaProgramRunner().runToolchainCommand(
    workingDirectory: directory,
    arguments: arguments,
    isolatedEnvironment: true,
  ))!;
  final stdout = result.stdout.toList();
  final stderr = result.stderr.toList();
  final code = await result.exitCode;
  expect(code, 0, reason: '${await stdout}\n${await stderr}');
}

class _ControlledRunner extends JavaProgramRunner {
  _ControlledRunner({this.unavailable = false, this.output});
  final bool unavailable;
  final String? output;
  final started = Completer<void>();
  int calls = 0;
  int cancellations = 0;
  bool snapshotExistedAtCancel = false;

  @override
  Future<ProgramRunResult?> runToolchainCommand({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
  }) async {
    expect(isolatedEnvironment, isTrue);
    calls++;
    if (unavailable) {
      return ProgramRunResult(
        title: 'unavailable',
        stdout: const Stream.empty(),
        stderr: Stream.value('missing JDK'),
        exitCode: Future.value(kProgramNotRunExitCode),
      );
    }
    final exit = Completer<int>();
    started.complete();
    if (output != null) exit.complete(0);
    return ProgramRunResult(
      title: 'controlled javac',
      stdout: output == null ? const Stream.empty() : Stream.value(output!),
      stderr: const Stream.empty(),
      exitCode: exit.future,
      cancel: () async {
        cancellations++;
        snapshotExistedAtCancel = Directory(workingDirectory).existsSync();
        if (!exit.isCompleted) exit.complete(-1);
        await exit.future;
      },
    );
  }
}

class _ObservingRunner extends JavaProgramRunner {
  final started = Completer<ProgramRunResult>();

  @override
  Future<ProgramRunResult?> runToolchainCommand({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
  }) async {
    final result = await super.runToolchainCommand(
      workingDirectory: workingDirectory,
      arguments: arguments,
      isolatedEnvironment: isolatedEnvironment,
    );
    if (!started.isCompleted && result != null) started.complete(result);
    return result;
  }
}
