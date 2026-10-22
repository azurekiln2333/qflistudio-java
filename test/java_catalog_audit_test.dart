import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_catalog_audit.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';

import '../../qfli_studio_core/tool/verify_java_content.dart' as host;

void main() {
  group('exhaustive shipped Java inventory', () {
    test('includes every mirror with a genuine SHA256 source identity', () {
      final fixture = _Fixture();
      final inventory = fixture.inventory();
      expect(inventory.issues, isEmpty);
      expect(inventory.snippets, hasLength(4));
      expect(inventory.executionGroups, hasLength(1));
      expect(inventory.counts, {
        'tutorials': 1,
        'examples': 1,
        'legacyLessons': 1,
        'legacyExamples': 1,
      });
      expect(
        inventory.snippets.map((item) => item.location).toSet(),
        hasLength(4),
      );
      expect(
        inventory.snippets.first.sourceSha256,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('retains duplicate IDs instead of overwriting their payload', () {
      final fixture = _Fixture();
      fixture.examples.add({
        ...fixture.examples.first,
        'code': 'second source',
      });
      final inventory = fixture.inventory();
      expect(inventory.ok, isFalse);
      expect(inventory.issues.join('\n'), contains('duplicate examples id'));
      expect(inventory.snippets, hasLength(5));
      expect(inventory.executionGroups, hasLength(2));
    });

    test(
      'enumerates extra tutorial lessons and reports exact inventory drift',
      () {
        final fixture = _Fixture();
        fixture.lessons.add({
          ...fixture.lessons.first,
          'id': 'extra-lesson',
          'code': 'extra code',
        });
        final inventory = fixture.inventory();
        expect(inventory.issues.join('\n'), contains('exactly one lesson'));
        expect(inventory.issues.join('\n'), contains('unexpected lesson id'));
        expect(inventory.snippets, hasLength(5));
        expect(inventory.executionGroups, hasLength(2));
      },
    );

    test('detects missing legacy examples and surplus unpaired examples', () {
      final fixture = _Fixture();
      fixture.legacyExamples.clear();
      fixture.examples.add({
        ...fixture.examples.first,
        'id': 'java-example-002',
      });
      final issues = fixture.inventory().issues.join('\n');
      expect(
        issues,
        contains('missing runnable legacyExamples id: java-example-001'),
      );
      expect(issues, contains('extra examples id: java-example-002'));
      expect(issues, contains('sourceLessonId must be java-tutorial-002'));
    });

    test('fixture/output differences cannot reuse a passing mirror result', () {
      final fixture = _Fixture();
      fixture.examples.first['inputFixtures'] = {'stdin': '42\n'};
      fixture.legacyExamples.first['output'] = 'different expected output';
      final inventory = fixture.inventory();
      expect(inventory.issues.join('\n'), contains('mirror mismatch'));
      expect(inventory.executionGroups, hasLength(3));
    });

    test(
      'compares every mirror with independently authored source and stdin',
      () {
        final fixture = _Fixture();
        const topic = JavaAuditTopic(
          id: 1,
          code: 'abc',
          output: 'answer',
          input: '42\n',
        );
        expect(
          fixture.inventory(authored: [topic]).issues.join('\n'),
          contains('authored code/output/inputFixtures mismatch'),
        );
        for (final record in [
          fixture.lessons.first,
          fixture.examples.first,
          fixture.legacyLessons.first,
          fixture.legacyExamples.first,
        ]) {
          record['inputFixtures'] = {'stdin': '42\n'};
        }
        expect(fixture.inventory(authored: [topic]).issues, isEmpty);
      },
    );

    test(
      'damaged language tags, unsupported fixtures and absent outputs fail',
      () {
        final fixture = _Fixture();
        fixture.tutorials.first['language'] = 'python';
        fixture.examples.first['inputFixtures'] = {
          'ignored.txt': 'must not disappear',
        };
        fixture.legacyLessons.first.remove('output');
        final issues = fixture.inventory().issues.join('\n');
        expect(issues, contains('language/type must both be java'));
        expect(issues, contains('unsupported input fixture ignored.txt'));
        expect(issues, contains('.output: expected string'));
      },
    );

    test(
      'malformed/empty documents cannot pass by having no runnable snippets',
      () {
        final inventory = JavaCatalogInventory.fromSources(
          tutorialsSource: '{',
          examplesSource: '{}',
          legacySource: '[]',
          expectedTopicCount: 1,
        );
        expect(inventory.ok, isFalse);
        expect(
          inventory.issues.join('\n'),
          contains('missing runnable tutorials id'),
        );
      },
    );

    test(
      'only one final line ending is normalized; whitespace stays significant',
      () {
        expect(normalizeJavaCatalogOutput('a\r\n'), 'a');
        expect(normalizeJavaCatalogOutput('a \n'), 'a ');
        expect(normalizeJavaCatalogOutput('a\n\n'), 'a\n');
        expect(normalizeJavaCatalogOutput('a\t'), 'a\t');
      },
    );
  });

  group('actual runner result collection', () {
    test('drains both streams after the exit future resolves', () async {
      final output = StreamController<String>();
      final error = StreamController<String>();
      final result = collectJavaAuditResult(
        ProgramRunResult(
          title: 'drain',
          stdout: output.stream,
          stderr: error.stream,
          exitCode: Future.value(0),
        ),
      );
      output.add('first');
      await Future<void>.delayed(Duration.zero);
      output.add('last');
      error.add('compiler warning');
      await output.close();
      await error.close();
      final observed = await result;
      expect(observed['ok'], isTrue);
      expect(observed['stdout'], 'first\nlast');
      expect(observed['stderr'], 'compiler warning');
    });

    test('runtime deadline cancels the real result handle', () async {
      final output = StreamController<String>();
      final error = StreamController<String>();
      final exit = Completer<int>();
      var canceled = false;
      final observed = await collectJavaAuditResult(
        ProgramRunResult(
          title: 'hang',
          stdout: output.stream,
          stderr: error.stream,
          exitCode: exit.future,
          cancel: () async {
            canceled = true;
            exit.complete(137);
            await output.close();
            await error.close();
          },
        ),
        timeout: const Duration(milliseconds: 20),
      );
      expect(canceled, isTrue);
      expect(observed['ok'], isFalse);
      expect(observed['timedOut'], isTrue);
      expect(observed['exitCode'], 137);
    });

    test(
      'output cap cancels rather than silently truncating a success',
      () async {
        final exit = Completer<int>();
        var canceled = false;
        final observed = await collectJavaAuditResult(
          ProgramRunResult(
            title: 'spam',
            stdout: Stream.value('more than four bytes'),
            stderr: const Stream.empty(),
            exitCode: exit.future,
            cancel: () async {
              canceled = true;
              exit.complete(137);
            },
          ),
          outputLimitBytes: 4,
        );
        expect(canceled, isTrue);
        expect(observed['ok'], isFalse);
        expect(observed['outputLimitExceeded'], isTrue);
      },
    );
  });

  group('catalog execution and evidence', () {
    late Directory temporary;
    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('java-audit-test-');
    });
    tearDown(() async {
      await temporary.delete(recursive: true);
    });

    test(
      'executes once and records all four identities without claiming a device pass',
      () async {
        final runner = _Runner();
        final file = File(p.join(temporary.path, 'report.json'));
        final report = await runJavaCatalogInventory(
          inventory: _Fixture().inventory(),
          runner: runner,
          workspace: Directory(p.join(temporary.path, 'projects')),
          reportFile: file,
          runtimeEvidence: {
            'isOhosDeviceEvidence': true,
            'isJava17Runtime': true,
          },
        );
        expect(runner.sources, ['abc']);
        expect(runner.inputs, ['']);
        expect(report['ok'], isTrue);
        expect(report['deviceGatePassed'], isFalse);
        expect(report['verifiedSnippetCount'], 4);
        expect(report['snippetResults'] as List, hasLength(4));
        expect(
          (jsonDecode(await file.readAsString()) as Map)['executionComplete'],
          isTrue,
        );
      },
    );

    test(
      'actually executes a divergent tutorial payload and keeps the gate failed',
      () async {
        final fixture = _Fixture();
        fixture.lessons.first['code'] = 'independent tutorial';
        final runner = _Runner();
        final report = await runJavaCatalogInventory(
          inventory: fixture.inventory(),
          runner: runner,
          workspace: Directory(p.join(temporary.path, 'projects')),
          reportFile: File(p.join(temporary.path, 'report.json')),
        );
        expect(runner.sources.toSet(), {'abc', 'independent tutorial'});
        expect(report['ok'], isFalse);
        expect(report['deviceGatePassed'], isFalse);
        expect(report['snippetResults'] as List, hasLength(4));
      },
    );

    test(
      'preserves stdin exactly and detects extra blank output lines',
      () async {
        final fixture = _Fixture();
        for (final item in [
          fixture.lessons.first,
          fixture.examples.first,
          fixture.legacyLessons.first,
          fixture.legacyExamples.first,
        ]) {
          item['inputFixtures'] = {'stdin': '中文\n42\n'};
        }
        final runner = _Runner(output: ['answer', '']);
        final report = await runJavaCatalogInventory(
          inventory: fixture.inventory(),
          runner: runner,
          workspace: Directory(p.join(temporary.path, 'projects')),
          reportFile: File(p.join(temporary.path, 'report.json')),
        );
        expect(runner.inputs, ['中文\n42\n']);
        expect(report['ok'], isFalse);
        expect(
          (report['executions'] as List).single['status'],
          'output_mismatch',
        );
      },
    );

    test(
      'launch timeout aborts the sweep and explicitly inventories unrun payloads',
      () async {
        final fixture = _Fixture();
        fixture.examples.first['code'] = 'second payload';
        final launch = Completer<ProgramRunResult?>();
        final runner = _PendingRunner(launch.future);
        final report = await runJavaCatalogInventory(
          inventory: fixture.inventory(),
          runner: runner,
          workspace: Directory(p.join(temporary.path, 'projects')),
          reportFile: File(p.join(temporary.path, 'report.json')),
          launchTimeout: const Duration(milliseconds: 20),
        );
        expect(runner.calls, 1);
        expect(report['executionComplete'], isFalse);
        expect(report['ok'], isFalse);
        expect((report['executions'] as List).map((item) => item['status']), [
          'launch_timeout',
          'not_run_after_launch_timeout',
        ]);
        launch.complete(null);
        await _awaitLateCleanup(report);
      },
    );

    test(
      'late launch is canceled before its retained snapshot is removed',
      () async {
        final launch = Completer<ProgramRunResult?>();
        final workspace = Directory(p.join(temporary.path, 'projects'));
        final report = await runJavaCatalogInventory(
          inventory: _Fixture().inventory(),
          runner: _PendingRunner(launch.future),
          workspace: workspace,
          reportFile: File(p.join(temporary.path, 'report.json')),
          launchTimeout: const Duration(milliseconds: 20),
        );
        final execution = (report['executions'] as List).single as Map;
        final retained = Directory(execution['retainedProjectPath'] as String);
        expect(await retained.exists(), isTrue);
        var canceled = false;
        launch.complete(
          ProgramRunResult(
            title: 'late launch',
            stdout: const Stream.empty(),
            stderr: const Stream.empty(),
            exitCode: Future.value(137),
            cancel: () async {
              expect(await retained.exists(), isTrue);
              canceled = true;
            },
          ),
        );
        await _awaitLateCleanup(report);
        expect(canceled, isTrue);
        expect(await retained.exists(), isFalse);
      },
    );

    test(
      'unproven process exit retains its snapshot and aborts later payloads',
      () async {
        final fixture = _Fixture();
        fixture.examples.first['code'] = 'another payload';
        final exit = Completer<int>();
        final runner = _PendingRunner(
          Future.value(
            ProgramRunResult(
              title: 'cannot cancel',
              stdout: const Stream.empty(),
              stderr: const Stream.empty(),
              exitCode: exit.future,
              cancel: () async =>
                  throw StateError('cancel transport unavailable'),
            ),
          ),
        );
        final report = await runJavaCatalogInventory(
          inventory: fixture.inventory(),
          runner: runner,
          workspace: Directory(p.join(temporary.path, 'projects')),
          reportFile: File(p.join(temporary.path, 'report.json')),
          runTimeout: const Duration(milliseconds: 20),
        );
        expect(runner.calls, 1);
        final executions = report['executions'] as List;
        expect(executions.last['status'], 'not_run_after_unreaped_process');
        expect(
          await Directory(
            executions.first['retainedProjectPath'] as String,
          ).exists(),
          isTrue,
        );
        expect(executions.first['observation']['processExited'], isFalse);
        expect(report['executionComplete'], isFalse);
        expect(report['ok'], isFalse);
        exit.complete(137);
      },
    );
  });

  group('bounded real host child processes', () {
    late Directory temporary;
    late String dart;
    setUp(() async {
      temporary = await Directory.systemTemp.createTemp(
        'java-audit-host-test-',
      );
      final configFile = File(
        p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
      );
      final config = jsonDecode(await configFile.readAsString()) as Map;
      final flutter = (config['packages'] as List).cast<Map>().singleWhere(
        (entry) => entry['name'] == 'flutter',
      );
      final flutterPackage = Directory.fromUri(
        configFile.uri.resolve(flutter['rootUri'] as String),
      );
      final flutterRoot = flutterPackage.parent.parent;
      dart = p.join(
        flutterRoot.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
    });
    tearDown(() async {
      await temporary.delete(recursive: true);
    });

    Future<Map<String, Object?>> runScript(
      String source, {
      String input = '',
      Duration timeout = const Duration(seconds: 10),
    }) async {
      final script = File(p.join(temporary.path, 'child.dart'));
      await script.writeAsString(source);
      return host.runJavaAuditHostProcess(
        dart,
        [script.path],
        cwd: temporary.path,
        input: input,
        timeout: timeout,
      );
    }

    test(
      'feeds Unicode stdin and closes EOF without losing output bytes',
      () async {
        final result = await runScript('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  stdout.write(await stdin.transform(utf8.decoder).join());
}
''', input: '中文\n42\n');
        expect(result['ok'], isTrue, reason: result.toString());
        expect(result['stdout'], '中文\n42\n');
        expect(result['exitCode'], 0);
      },
    );

    test(
      'kills a child that never exits and records its actual exit',
      () async {
        final result = await runScript('''
import 'dart:async';
void main() { Timer.periodic(const Duration(seconds: 1), (_) {}); }
''', timeout: const Duration(milliseconds: 100));
        expect(result['ok'], isFalse);
        expect(result['timedOut'], isTrue);
        expect(result['exitCode'], isA<int>());
        expect(result['exitCode'], isNot(0));
      },
    );

    test('a real excessive-output child fails the bounded verifier', () async {
      final result = await runScript('''
import 'dart:io';
void main() { stdout.write('x' * (2 * 1024 * 1024)); }
''');
      expect(result['ok'], isFalse);
      expect(result['outputLimitExceeded'], isTrue);
      expect((result['stdout'] as String).length, 1024 * 1024);
    });

    test(
      'malformed UTF8 bytes cannot be replaced into a passing output',
      () async {
        final result = await runScript('''
import 'dart:io';
void main() { stdout.add([0xff]); }
''');
        expect(result['exitCode'], 0);
        expect(result['ok'], isFalse);
        expect(result['stdoutEncodingError'], isA<String>());
        expect(result['processExited'], isTrue);
      },
    );
  });
}

Future<void> _awaitLateCleanup(Map<String, Object?> report) async {
  final cleanup =
      ((report['executions'] as List).first as Map)['lateLaunchCleanup'] as Map;
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (cleanup['cleanupComplete'] != true &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(cleanup['cleanupComplete'], isTrue);
  expect(cleanup['error'], isNull);
}

class _Fixture {
  _Fixture() {
    lessons = [
      {'id': 'java-tutorial-001-lesson', 'code': 'abc', 'output': 'answer'},
    ];
    tutorials = [
      {
        'id': 'java-tutorial-001',
        'language': 'java',
        'type': 'java',
        'lessons': lessons,
      },
    ];
    examples = [
      {
        'id': 'java-example-001',
        'language': 'java',
        'type': 'java',
        'code': 'abc',
        'expectedOutput': 'answer',
        'inputFixtures': <String, String>{},
        'sourceLessonId': 'java-tutorial-001',
      },
    ];
    legacyLessons = [
      {'id': 'java-tutorial-001', 'code': 'abc', 'output': 'answer'},
    ];
    legacyExamples = [
      {
        'id': 'java-example-001',
        'code': 'abc',
        'output': 'answer',
        'sourceLessonId': 'java-tutorial-001',
      },
    ];
  }
  late final List<Map<String, Object?>> lessons;
  late final List<Map<String, Object?>> tutorials;
  late final List<Map<String, Object?>> examples;
  late final List<Map<String, Object?>> legacyLessons;
  late final List<Map<String, Object?>> legacyExamples;

  JavaCatalogInventory inventory({List<JavaAuditTopic>? authored}) =>
      JavaCatalogInventory.fromSources(
        tutorialsSource: jsonEncode({'entries': tutorials}),
        examplesSource: jsonEncode({'entries': examples}),
        legacySource: jsonEncode({
          'language': 'java',
          'type': 'java',
          'chapters': [
            {'id': 'chapter-1', 'lessons': legacyLessons},
          ],
          'examples': legacyExamples,
        }),
        expectedTopicCount: 1,
        authoredTopics: authored,
      );
}

class _Runner implements ProgramRunner {
  _Runner({this.output = const ['answer']});
  final List<String> output;
  final sources = <String>[];
  final inputs = <String>[];
  @override
  Future<ProgramRunResult?> run({
    required String projectPath,
    required String entryFile,
  }) async {
    sources.add(await File(entryFile).readAsString());
    inputs.add(await File(p.join(projectPath, 'input.txt')).readAsString());
    return ProgramRunResult(
      title: 'test runner',
      stdout: Stream.fromIterable(output),
      stderr: const Stream.empty(),
      exitCode: Future.value(0),
    );
  }
}

class _PendingRunner implements ProgramRunner {
  _PendingRunner(this.pending);
  final Future<ProgramRunResult?> pending;
  var calls = 0;
  @override
  Future<ProgramRunResult?> run({
    required String projectPath,
    required String entryFile,
  }) {
    calls++;
    return pending;
  }
}
