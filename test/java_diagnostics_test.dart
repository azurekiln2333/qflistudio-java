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

  CodeAnalysisRequest request(
    String activePath, {
    String language = 'java',
    int revision = 3,
    List<CodeDocumentSnapshot>? documents,
  }) => CodeAnalysisRequest(
    projectPath: project.path,
    activeFilePath: activePath,
    language: language,
    revision: revision,
    documents:
        documents ??
        [
          CodeDocumentSnapshot(
            path: activePath,
            text: File(activePath).readAsStringSync(),
            revision: revision,
          ),
        ],
  );

  test('unsupported active files never start javac or claim clean', () async {
    final readme = write('README.md', '# Project');
    final runner = _ControlledRunner(unavailable: true);
    final provider = analyzer(runner: runner);
    for (final language in ['markdown', 'java']) {
      final result = await provider.analyze(
        request(readme.path, language: language),
      );
      expect(result.unavailableReason, contains('.java'));
      expect(result.diagnostics, isEmpty);
    }
    write('Main.java', 'public class Main {}');
    final result = await provider.analyze(request(readme.path));
    expect(result.unavailableReason, contains('.java'));
    expect(result.diagnostics, isEmpty);
    expect(runner.calls, 0);
    expectClean();
  });

  test(
    'wrong language and invalid active captures fail before javac',
    () async {
      final file = write('Main.java', 'public class Main {}');
      final runner = _ControlledRunner(unavailable: true);
      final provider = analyzer(runner: runner);
      final valid = CodeDocumentSnapshot(
        path: file.path,
        text: 'class Main {}',
        revision: 3,
      );
      for (final invalid in [
        request(file.path, language: 'kotlin'),
        request(file.path, documents: []),
        request(file.path, revision: 4, documents: [valid]),
        request(file.path, revision: -1, documents: [valid]),
        request(file.path, documents: [valid, valid]),
        request(
          file.path,
          documents: [
            CodeDocumentSnapshot(
              path: 'Main.java',
              text: 'class Main {}',
              revision: 3,
            ),
          ],
        ),
        request(
          file.path,
          documents: [
            CodeDocumentSnapshot(
              path: p.join(project.path, 'nested', '..', 'Main.java'),
              text: 'class Main {}',
              revision: 3,
            ),
          ],
        ),
        request(
          file.path,
          documents: [
            CodeDocumentSnapshot(
              path: file.path,
              text: String.fromCharCode(0xd800),
              revision: 3,
            ),
          ],
        ),
        request(
          file.path,
          documents: [
            valid,
            CodeDocumentSnapshot(
              path: p.join(project.path, 'README.md'),
              text: 'other',
              revision: -1,
            ),
          ],
        ),
        request(
          file.path,
          documents: [
            valid,
            CodeDocumentSnapshot(
              path: p.join(project.parent.path, 'Foreign.md'),
              text: 'foreign non-Java capture',
              revision: 0,
            ),
          ],
        ),
        request(
          p.join(project.parent.path, 'Foreign.java'),
          documents: [valid],
        ),
      ]) {
        final result = await provider.analyze(invalid);
        expect(result.unavailableReason, isNotEmpty);
        expect(result.diagnostics, isEmpty);
      }
      expect(runner.calls, 0);
      expectClean();
    },
  );

  test(
    'linked active files and missing paths under linked parents are rejected',
    () async {
      final foreign = Directory(p.join(temporary.path, 'foreign'))
        ..createSync();
      File(
        p.join(foreign.path, 'Main.java'),
      ).writeAsStringSync('class Main {}');
      final link = Link(p.join(project.path, 'linked'));
      await link.create(foreign.path);
      try {
        final runner = _ControlledRunner(unavailable: true);
        for (final name in ['Main.java', 'New.java']) {
          final path = p.join(link.path, name);
          final result = await analyzer(runner: runner).analyze(
            request(
              path,
              documents: [
                CodeDocumentSnapshot(
                  path: path,
                  text: 'class Main {}',
                  revision: 3,
                ),
              ],
            ),
          );
          expect(result.unavailableReason, isNotEmpty);
          expect(result.diagnostics, isEmpty);
        }
        expect(runner.calls, 0);
        expect(temporary.listSync().map((file) => p.basename(file.path)), [
          'foreign',
        ]);
      } finally {
        await link.delete();
      }
    },
  );

  for (final useCaseAlias in [false, true]) {
    test(
      'a new editor request cancels the prior project check (case alias=$useCaseAlias)',
      () async {
        final file = write('Main.java', 'public class Main {}');
        final runner = _SupersedingRunner();
        final provider = analyzer(runner: runner);
        final first = provider.analyze(request(file.path));
        try {
          await runner.started.future.timeout(const Duration(seconds: 2));
          final secondRoot = useCaseAlias
              ? project.path.toUpperCase()
              : project.path;
          final second = await provider.analyze(
            CodeAnalysisRequest(
              projectPath: secondRoot,
              activeFilePath: file.path,
              language: 'java',
              revision: 4,
              documents: [
                CodeDocumentSnapshot(
                  path: file.path,
                  text: 'public class Main { int edited = 4; }',
                  revision: 4,
                ),
              ],
            ),
          );
          final superseded = await first.timeout(const Duration(seconds: 2));
          expect(superseded.unavailableReason, contains('取消'));
          expect(second.unavailableReason, contains('missing JDK'));
          expect(runner.calls, 2);
          expect(runner.cancellations, 1);
          expect(file.readAsStringSync(), 'public class Main {}');
          expectClean();
        } finally {
          runner.finish();
          await first;
        }
      },
      skip: useCaseAlias && !Platform.isWindows,
    );
  }

  test(
    'a raw project without Java sources is unavailable before tools',
    () async {
      write('README.md', '# Project');
      final runner = _ControlledRunner(unavailable: true);
      final result = await analyzer(
        runner: runner,
      ).analyzeProject(projectPath: project.path);
      expect(result.status, JavaAnalysisStatus.unavailable);
      expect(result.message, contains('没有可检查'));
      expect(result.diagnostics, isEmpty);
      expect(runner.calls, 0);
      expectClean();
    },
  );

  test(
    'real public adapter checks Java while ignoring other owned file types',
    () async {
      final file = write('Main.java', 'public class Main { int n = 1; }');
      final readme = write('README.md', '# Saved');
      const text =
          'public class Main {\r\n String s = "😀中文"; int n = 2;\r\n static { if (true) throw new AssertionError("must not execute"); }\r\n}';
      final result = await analyzer().analyze(
        request(
          file.path,
          documents: [
            CodeDocumentSnapshot(path: file.path, text: text, revision: 3),
            CodeDocumentSnapshot(
              path: readme.path,
              text: 'not valid Java }',
              revision: 9,
            ),
          ],
        ),
      );
      expect(result.unavailableReason, isNull);
      expect(result.diagnostics, isEmpty);
      expect(file.readAsStringSync(), 'public class Main { int n = 1; }');
      expect(readme.readAsStringSync(), '# Saved');
      expect(project.listSync().map((file) => p.basename(file.path)).toSet(), {
        'Main.java',
        'README.md',
      });
      expectClean();
    },
  );

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
    'Windows identity aliases cannot duplicate captures or lose a dirty overlay',
    () async {
      final file = write('Main.java', 'public class Main { int n = 1; }');
      final alias = file.path.toUpperCase();
      const text = 'public class Main { int n = "dirty"; }';
      final captured = CodeDocumentSnapshot(
        path: alias,
        text: text,
        revision: 3,
      );
      final runner = _ControlledRunner(unavailable: true);
      final duplicate = await analyzer(runner: runner).analyze(
        request(
          file.path,
          documents: [
            captured,
            CodeDocumentSnapshot(path: file.path, text: text, revision: 3),
          ],
        ),
      );
      expect(duplicate.unavailableReason, isNotEmpty);
      expect(runner.calls, 0);
      final result = await analyzer().analyze(
        request(file.path, documents: [captured]),
      );
      expect(result.unavailableReason, isNull);
      final error = result.diagnostics.singleWhere(
        (diagnostic) => diagnostic.code == 'compiler.err.prob.found.req',
      );
      expect(p.equals(error.filePath, file.path), isTrue);
      expect(text.substring(error.startOffset, error.endOffset), '"dirty"');
      expect(file.readAsStringSync(), 'public class Main { int n = 1; }');
      expectClean();
    },
    skip: !Platform.isWindows,
  );

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

  test(
    'early transport failure waits for actual exit before cleanup',
    () async {
      final source = write('Main.java', 'class Main {}');
      final runner = _FailingStreamRunner();
      var completed = false;
      final analysis = analyzer(runner: runner)
          .analyzeProject(projectPath: project.path)
          .then((result) {
            completed = true;
            return result;
          });
      try {
        final snapshot = await runner.started.future;
        runner.stderr.addError(const FileSystemException('native poll failed'));
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        expect(Directory(snapshot).existsSync(), isTrue);
        runner.exit.complete(137);
        await runner.stderr.close();
        final result = await analysis;
        expect(result.status, JavaAnalysisStatus.failed);
        expect(result.message, contains('native poll failed'));
        expect(result.diagnostics, isEmpty);
        expect(source.readAsStringSync(), 'class Main {}');
        expectClean();
      } finally {
        if (!runner.exit.isCompleted) runner.exit.complete(137);
        await runner.stderr.close();
        await analysis;
      }
    },
  );

  test(
    'stdout failure retains the snapshot until stderr reaches EOF after exit',
    () async {
      final source = write('Main.java', 'class Main {}');
      final runner = _SeparateDrainFailureRunner();
      var completed = false;
      final analysis = analyzer(runner: runner)
          .analyzeProject(projectPath: project.path)
          .then((result) {
            completed = true;
            return result;
          });
      try {
        final snapshot = await runner.started.future;
        runner.stdout.addError(
          const FileSystemException('stdout transport failed'),
        );
        await runner.stdout.close();
        runner.exit.complete(137);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(completed, isFalse);
        expect(Directory(snapshot).existsSync(), isTrue);

        runner.stderr.add('final stderr before EOF');
        await runner.stderr.close();
        final result = await analysis;
        expect(result.status, JavaAnalysisStatus.failed);
        expect(result.message, contains('stdout transport failed'));
        expect(result.diagnostics, isEmpty);
        expect(source.readAsStringSync(), 'class Main {}');
        expectClean();
      } finally {
        if (!runner.exit.isCompleted) runner.exit.complete(137);
        await Future.wait([runner.stdout.close(), runner.stderr.close()]);
        await analysis;
      }
    },
  );

  test(
    'late-start cancellation retries failure and retains the live snapshot',
    () async {
      final source = write('Main.java', 'class Main {}');
      final runner = _LateCancellationRunner();
      final cancellation = JavaAnalysisCancellation();
      var completed = false;
      final analysis = analyzer(runner: runner)
          .analyzeProject(projectPath: project.path, cancellation: cancellation)
          .then((result) {
            completed = true;
            return result;
          });
      try {
        final snapshot = await runner.started.future;
        cancellation.cancel();
        runner.release.complete();
        await runner.retryStarted.future.timeout(const Duration(seconds: 2));
        expect(runner.cancellations, 2);
        expect(completed, isFalse);
        expect(Directory(snapshot).existsSync(), isTrue);
        runner.exit.complete(137);
        final result = await analysis;
        expect(result.status, JavaAnalysisStatus.cancelled);
        expect(result.diagnostics, isEmpty);
        expect(source.readAsStringSync(), 'class Main {}');
        expectClean();
      } finally {
        if (!runner.release.isCompleted) runner.release.complete();
        if (!runner.exit.isCompleted) runner.exit.complete(137);
        await analysis;
      }
    },
  );

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

class _FailingStreamRunner extends JavaProgramRunner {
  final started = Completer<String>();
  final exit = Completer<int>();
  final stderr = StreamController<String>();

  @override
  Future<ProgramRunResult?> runToolchainCommand({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
  }) async {
    started.complete(workingDirectory);
    return ProgramRunResult(
      title: 'failing transport',
      stdout: const Stream.empty(),
      stderr: stderr.stream,
      exitCode: exit.future,
      cancel: () async {
        if (!exit.isCompleted) exit.complete(137);
        await exit.future;
      },
    );
  }
}

class _SeparateDrainFailureRunner extends JavaProgramRunner {
  final started = Completer<String>();
  final exit = Completer<int>();
  final stdout = StreamController<String>();
  final stderr = StreamController<String>();

  @override
  Future<ProgramRunResult?> runToolchainCommand({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
  }) async {
    started.complete(workingDirectory);
    return ProgramRunResult(
      title: 'transport with independently drained pipes',
      stdout: stdout.stream,
      stderr: stderr.stream,
      exitCode: exit.future,
      cancel: () async {
        if (!exit.isCompleted) exit.complete(137);
        await exit.future;
      },
    );
  }
}

class _LateCancellationRunner extends JavaProgramRunner {
  final started = Completer<String>();
  final release = Completer<void>();
  final exit = Completer<int>();
  final retryStarted = Completer<void>();
  int cancellations = 0;

  @override
  Future<ProgramRunResult?> runToolchainCommand({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
  }) async {
    started.complete(workingDirectory);
    await release.future;
    return ProgramRunResult(
      title: 'late compiler',
      stdout: const Stream.empty(),
      stderr: const Stream.empty(),
      exitCode: exit.future,
      cancel: () async {
        cancellations++;
        if (cancellations == 1) {
          throw const FileSystemException('first native cancel failed');
        }
        retryStarted.complete();
        await exit.future;
      },
    );
  }
}

class _SupersedingRunner extends JavaProgramRunner {
  final started = Completer<void>();
  final _exit = Completer<int>();
  int calls = 0;
  int cancellations = 0;

  void finish() {
    if (!_exit.isCompleted) _exit.complete(-1);
  }

  @override
  Future<ProgramRunResult?> runToolchainCommand({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
  }) async {
    calls++;
    if (calls > 1) {
      return ProgramRunResult(
        title: 'unavailable',
        stdout: const Stream.empty(),
        stderr: Stream.value('missing JDK'),
        exitCode: Future.value(kProgramNotRunExitCode),
      );
    }
    started.complete();
    return ProgramRunResult(
      title: 'superseded javac',
      stdout: const Stream.empty(),
      stderr: const Stream.empty(),
      exitCode: _exit.future,
      cancel: () async {
        cancellations++;
        finish();
        await _exit.future;
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
