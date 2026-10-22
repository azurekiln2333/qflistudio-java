/// Temporary device entry. Pull the durable report, then restore lib/main.dart.
/// OHOS bundle: com.azurekiln.qfli.java (never the historical jvmx bundle).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_diagnostics.dart';
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_java/mobile_jdk.dart';
import 'package:qfli_studio_core/services/app_paths.dart';
import 'package:qfli_studio_core/tools/offline_tools.dart';

import 'java_debug_smoke.dart' show runJavaDebugSmoke;

const javaRuntimeAcceptanceReportName = 'qfli-java-runtime-acceptance.json';
final _status = ValueNotifier<String>('Java runtime acceptance is running…');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: ValueListenableBuilder<String>(
          valueListenable: _status,
          builder: (_, value, _) => Text(value),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_entry()));
}

Future<void> _entry() async {
  try {
    final storage = await AppPaths.storageDirectory().timeout(
      const Duration(seconds: 20),
    );
    if (storage == null) throw StateError('No writable AppPaths storage');
    final report = await runJavaRuntimeAcceptance(
      storage: Directory(storage),
      onProgress: (stage) {
        _status.value = 'Java runtime acceptance: $stage';
        debugPrint('QFLI_JAVA_RUNTIME_STAGE $stage');
      },
    );
    final summary = {
      'ok': report['ok'],
      'deviceGatePassed': report['deviceGatePassed'],
      'diagnosticsDeviceGatePassed': report['diagnosticsDeviceGatePassed'],
      'debuggerDeviceGatePassed': report['debuggerDeviceGatePassed'],
      'operatingSystem': Platform.operatingSystem,
      'report': report['reportFile'],
      'reportSha256': OfflineDigest.sha256(
        await File(report['reportFile']! as String).readAsString(),
      ),
    };
    _status.value = const JsonEncoder.withIndent('  ').convert(summary);
    debugPrint('QFLI_JAVA_RUNTIME_ACCEPTANCE ${jsonEncode(summary)}');
  } catch (error, stack) {
    _status.value = 'Java runtime acceptance failed: $error';
    debugPrint(
      'QFLI_JAVA_RUNTIME_ACCEPTANCE ${jsonEncode({'ok': false, 'deviceGatePassed': false, 'operatingSystem': Platform.operatingSystem, 'error': '$error', 'stack': '$stack'})}',
    );
  }
}

/// Uses the actual services; host runs never satisfy the OHOS device gate.
/// A debugger deadline bounds the report, not cancellation of the reused smoke
/// function, which has no external Stop hook. Such a timeout is an explicit
/// failure with unconfirmed cleanup and a retained work directory.
Future<Map<String, Object?>> runJavaRuntimeAcceptance({
  required Directory storage,
  JavaProgramRunner runner = const JavaProgramRunner(),
  Duration analysisTimeout = const Duration(seconds: 120),
  Duration debuggerTimeout = const Duration(minutes: 8),
  void Function(String stage)? onProgress,
}) async {
  await storage.create(recursive: true);
  final reportFile = File(
    p.join(storage.path, javaRuntimeAcceptanceReportName),
  );
  final work = await storage.createTemp('qfli_java_runtime_acceptance_');
  final report = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'java-runtime-acceptance',
    'expectedBundleName': 'com.azurekiln.qfli.java',
    'expectedOhosPullPath':
        '/data/app/el2/100/base/com.azurekiln.qfli.java/files/$javaRuntimeAcceptanceReportName',
    'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'operatingSystem': Platform.operatingSystem,
    'operatingSystemVersion': Platform.operatingSystemVersion,
    'dartVersion': Platform.version,
    'reportFile': reportFile.path,
    'workDirectory': work.path,
    'status': 'running',
    'ok': false,
    'deviceGatePassed': false,
    'diagnosticsDeviceGatePassed': false,
    'debuggerDeviceGatePassed': false,
  };
  Future<void> persist(String stage) async {
    report['stage'] = stage;
    report['updatedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    await reportFile
        .writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true,
        )
        .timeout(const Duration(seconds: 10));
    onProgress?.call(stage);
  }

  var cleanupSafe = true;
  try {
    await persist('runtime');
    final runtime = <String, Object?>{'ok': false};
    report['runtime'] = runtime;
    try {
      if (MobileJdk.isMobile) {
        await MobileJdk.prepare().timeout(const Duration(seconds: 90));
      }
      runtime['jdkHome'] = MobileJdk.current?.home;
      final properties = await _probe(runner, work, [
        'java',
        '-Xms16m',
        '-Xmx128m',
        '-XX:+UseSerialGC',
        '-XshowSettings:properties',
        '-version',
      ]);
      runtime['javaProbe'] = properties;
      final compiler = await _probe(runner, work, [
        'javac',
        '-J-Xms16m',
        '-J-Xmx128m',
        '-J-XX:+UseSerialGC',
        '-version',
      ]);
      runtime['javacProbe'] = compiler;
      if (properties['cleanupConfirmed'] != true ||
          compiler['cleanupConfirmed'] != true) {
        cleanupSafe = false;
      }
      final text = '${properties['stdout']}\n${properties['stderr']}';
      String? property(String name) => RegExp(
        '^\\s*${RegExp.escape(name)}\\s*=\\s*(.+)\$',
        multiLine: true,
      ).firstMatch(text)?.group(1)?.trim();
      final javaVersion = property('java.version');
      final compilerText = '${compiler['stdout']}\n${compiler['stderr']}';
      final compilerMajor = RegExp(
        r'javac (\d+)',
      ).firstMatch(compilerText)?.group(1);
      runtime.addAll({
        'javaVersion': javaVersion,
        'javaVmName': property('java.vm.name'),
        'javaRuntimeVersion': property('java.runtime.version'),
        'osArch': property('os.arch'),
        'isJava17Runtime': javaVersion?.split('.').first == '17',
        'isJavac17Compiler': compilerMajor == '17',
      });
      runtime['ok'] =
          properties['ok'] == true &&
          compiler['ok'] == true &&
          runtime['isJava17Runtime'] == true &&
          runtime['isJavac17Compiler'] == true &&
          runtime['osArch'] != null &&
          runtime['javaVmName'] != null;
    } catch (error, stack) {
      runtime.addAll({'error': '$error', 'stack': '$stack'});
    }

    await persist('diagnostics');
    final diagnostics = await _diagnostics(runner, work, analysisTimeout, (
      partial,
    ) async {
      report['diagnostics'] = partial;
      await persist('diagnostics');
    });
    report['diagnostics'] = diagnostics;
    if (diagnostics['cleanupConfirmed'] != true) cleanupSafe = false;

    await persist('debugger');
    try {
      final debuggerDirectory = await Directory(
        p.join(work.path, 'debugger'),
      ).create();
      report['debugger'] = await runJavaDebugSmoke(
        temporaryDirectory: debuggerDirectory.path,
      ).timeout(debuggerTimeout);
    } catch (error, stack) {
      cleanupSafe = false;
      report['debugger'] = {
        'ok': false,
        'timedOut': error is TimeoutException,
        'error': '$error',
        'stack': '$stack',
        'cleanupConfirmed': false,
        'note':
            'The reused smoke has no external cancellation hook; stop the app before removing retained work.',
      };
    }
    final debugger = report['debugger']! as Map<String, Object?>;
    if (debugger['ok'] != true) {
      // These are failure details, never substitutes for real debugger checks.
      await persist('debugger-failure-probes');
      final probes = <String, Object?>{};
      for (final (name, arguments) in [
        (
          'jdiModule',
          [
            'java',
            '-Xms16m',
            '-Xmx128m',
            '-XX:+UseSerialGC',
            '--add-modules',
            'jdk.jdi',
            '-version',
          ],
        ),
        (
          'jdwpAgent',
          [
            'java',
            '-Xms16m',
            '-Xmx128m',
            '-XX:+UseSerialGC',
            '-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:0',
            '-version',
          ],
        ),
      ]) {
        try {
          probes[name] = await _probe(runner, work, arguments);
          if ((probes[name]! as Map)['cleanupConfirmed'] != true) {
            cleanupSafe = false;
          }
        } catch (error, stack) {
          probes[name] = {'ok': false, 'error': '$error', 'stack': '$stack'};
        }
      }
      report['debuggerFailureProbes'] = probes;
    }
    final isOhos = Platform.operatingSystem == 'ohos';
    final actual17 = runtime['ok'] == true;
    report['diagnosticsDeviceGatePassed'] =
        isOhos && actual17 && diagnostics['ok'] == true;
    report['debuggerDeviceGatePassed'] =
        isOhos && actual17 && debugger['ok'] == true;
    report['ok'] =
        actual17 && diagnostics['ok'] == true && debugger['ok'] == true;
  } catch (error, stack) {
    report.addAll({'error': '$error', 'stack': '$stack', 'ok': false});
  } finally {
    if (cleanupSafe) {
      try {
        await work.delete(recursive: true).timeout(const Duration(seconds: 10));
        report['cleanupConfirmed'] = true;
      } catch (error) {
        report.addAll({'cleanupConfirmed': false, 'cleanupError': '$error'});
      }
    } else {
      report['cleanupConfirmed'] = false;
    }
    if (report['cleanupConfirmed'] != true) report['ok'] = false;
    report['deviceGatePassed'] =
        Platform.operatingSystem == 'ohos' && report['ok'] == true;
    report['status'] = 'complete';
    report['finishedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    await persist('complete');
  }
  return report;
}

Future<Map<String, Object?>> _probe(
  JavaProgramRunner runner,
  Directory directory,
  List<String> arguments,
) async {
  JavaToolchainProcess? process;
  final result = <String, Object?>{
    'ok': false,
    'arguments': arguments,
    'cleanupConfirmed': true,
  };
  var bytes = 0;
  final subscriptions = <StreamSubscription<List<int>>>[];
  final output = <int>[];
  final error = <int>[];
  var exceeded = false;
  Future<void> collect(Stream<List<int>> stream, List<int> target) {
    final done = Completer<void>();
    subscriptions.add(
      stream.listen(
        (chunk) {
          final remaining = (64 * 1024 - bytes).clamp(0, chunk.length);
          target.addAll(chunk.take(remaining));
          bytes += chunk.length;
          if (bytes > 64 * 1024 && !exceeded) {
            exceeded = true;
            unawaited(process!.cancel().catchError((Object _) {}));
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object failure, StackTrace stack) {
          if (!done.isCompleted) done.completeError(failure, stack);
        },
      ),
    );
    return done.future;
  }

  try {
    final starting = runner.startToolchainProcess(
      workingDirectory: directory.path,
      arguments: arguments,
      isolatedEnvironment: true,
    );
    try {
      process = await starting.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      result['cleanupConfirmed'] = false;
      // A native start may finish after the deadline. Reap that owned process
      // if it arrives; never report its cleanup as already confirmed.
      unawaited(
        starting
            .then((late) async {
              if (late == null) return;
              final stdout = late.stdout.drain<void>();
              final stderr = late.stderr.drain<void>();
              await late.cancel().timeout(const Duration(seconds: 10));
              await Future.wait([
                stdout,
                stderr,
              ]).timeout(const Duration(seconds: 5));
            })
            .catchError((Object _) {}),
      );
      rethrow;
    }
    if (process == null) throw StateError('Toolchain probe was not handled');
    final stdout = collect(process.stdout, output);
    final stderr = collect(process.stderr, error);
    final values = await Future.wait<Object?>([
      process.exitCode,
      stdout,
      stderr,
    ]).timeout(const Duration(seconds: 30));
    result.addAll({
      'ok': values.first == 0 && !exceeded,
      'exitCode': values.first,
      'outputLimitExceeded': exceeded,
    });
  } catch (failure, stack) {
    result.addAll({
      'error': '$failure',
      'stack': '$stack',
      'timedOut': failure is TimeoutException,
    });
  } finally {
    try {
      await process?.cancel().timeout(const Duration(seconds: 10));
    } catch (failure) {
      result.addAll({
        'ok': false,
        'cleanupConfirmed': false,
        'cleanupError': '$failure',
      });
    }
    for (final subscription in subscriptions) {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 5));
      } catch (failure) {
        result.addAll({
          'ok': false,
          'cleanupConfirmed': false,
          'streamCleanupError': '$failure',
        });
      }
    }
    result['stdout'] = utf8.decode(output, allowMalformed: true);
    result['stderr'] = utf8.decode(error, allowMalformed: true);
  }
  return result;
}

Future<Map<String, Object?>> _diagnostics(
  JavaProgramRunner runner,
  Directory work,
  Duration timeout,
  Future<void> Function(Map<String, Object?> partial) persist,
) async {
  final result = <String, Object?>{'ok': false, 'cleanupConfirmed': true};
  final checks = <String, bool>{};
  final cases = <String, Object?>{};
  result.addAll({
    'offsetUnits': 'UTF-16 code units',
    'checks': checks,
    'cases': cases,
  });
  final project = await Directory(
    p.join(work.path, 'diagnostics-project'),
  ).create();
  final scratch = await Directory(
    p.join(work.path, 'diagnostics-scratch'),
  ).create();
  final main = File(p.join(project.path, 'probe', 'Main.java'));
  final helper = File(p.join(project.path, 'probe', 'Helper.java'));
  final extra = File(p.join(project.path, 'probe', 'Extra.java'));
  final marker = File(p.join(project.path, 'USER_CODE_WAS_EXECUTED'));
  void require(String name, bool passed) {
    checks[name] = passed;
    if (!passed) throw StateError('Diagnostic acceptance failed: $name');
  }

  try {
    await main.parent.create(recursive: true);
    const savedMain =
        'package probe; public class Main { invalid saved buffer }';
    const savedHelper =
        'package probe; public class Helper { invalid saved buffer }';
    await main.writeAsString(savedMain);
    await helper.writeAsString(savedHelper);
    final originals = {
      main.path: await main.readAsBytes(),
      helper.path: await helper.readAsBytes(),
    };
    result['diskSources'] = {
      for (final original in originals.entries)
        original.key: {
          'text': utf8.decode(original.value),
          'sha256Before': _bytesHash(original.value),
        },
    };
    final mainPrefix = [
      'package probe;',
      'public class Main {',
      '  static { mark(); }',
      '  static void mark() { try { java.nio.file.Files.writeString(java.nio.file.Path.of(${jsonEncode(marker.path)}), "EXECUTED"); } catch (java.io.IOException e) { throw new RuntimeException(e); } }',
      '  public static void main(String[] args) { mark(); }',
      '  String unicode = "😀中文";',
      '  String message = Helper.edited();',
      '  int extra = Extra.answer();',
    ].join('\r\n');
    String mainBuffer(String expression) =>
        '$mainPrefix\r\n\tint number = $expression;\r\n}\r\n';
    String helperBuffer(String expression) =>
        'package probe;\r\npublic class Helper {\r\n  static String edited() { String text = "😀中文"; return $expression; }\r\n}\r\n';
    const extraBuffer =
        'package probe;\r\npublic class Extra { static int answer() { return 17; } }\r\n';
    final analyzer = JavaDiagnosticAnalyzer(
      runner: runner,
      timeout: timeout,
      temporaryDirectory: scratch.path,
    );
    for (final (name, expression, helperExpression) in [
      ('typeErrors', '"wrong"', '42'),
      ('syntaxError', '', '"ok"'),
      ('clean', '17', '"ok"'),
    ]) {
      final buffers = {
        main.path: mainBuffer(expression),
        helper.path: helperBuffer(helperExpression),
        extra.path: extraBuffer,
      };
      final cancellation = JavaAnalysisCancellation();
      final check = analyzer.analyzeProject(
        projectPath: project.path,
        unsavedBuffers: buffers,
        cancellation: cancellation,
      );
      JavaAnalysisResult analyzed;
      try {
        analyzed = await check.timeout(timeout + const Duration(seconds: 15));
      } on TimeoutException {
        cancellation.cancel();
        try {
          await check.timeout(const Duration(seconds: 15));
        } on TimeoutException {
          result['cleanupConfirmed'] = false;
        }
        rethrow;
      }
      cases[name] = {
        'status': analyzed.status.name,
        'message': analyzed.message,
        'buffers': {
          for (final entry in buffers.entries)
            entry.key: {
              'text': entry.value,
              'utf16Length': entry.value.length,
              'sha256': OfflineDigest.sha256(entry.value),
            },
        },
        'diagnostics': [
          for (final diagnostic in analyzed.diagnostics)
            {
              'path': diagnostic.path,
              'offset': diagnostic.offset,
              'length': diagnostic.length,
              'line': diagnostic.line,
              'column': diagnostic.column,
              'severity': diagnostic.severity.name,
              'code': diagnostic.code,
              'message': diagnostic.message,
              if (buffers.containsKey(diagnostic.path) &&
                  diagnostic.offset >= 0 &&
                  diagnostic.length >= 0 &&
                  diagnostic.offset + diagnostic.length <=
                      buffers[diagnostic.path]!.length)
                'fragment': buffers[diagnostic.path]!.substring(
                  diagnostic.offset,
                  diagnostic.offset + diagnostic.length,
                ),
            },
        ],
      };
      await persist(result);
      require('$name.complete', analyzed.status == JavaAnalysisStatus.complete);
      require(
        '$name.validUtf16Ranges',
        analyzed.diagnostics.every(
          (d) =>
              buffers.containsKey(d.path) &&
              d.offset >= 0 &&
              d.length >= 0 &&
              d.offset + d.length <= buffers[d.path]!.length,
        ),
      );
      final errors = analyzed.diagnostics
          .where((d) => d.severity == JavaDiagnosticSeverity.error)
          .toList();
      if (name == 'typeErrors') {
        require('typeErrors.count', errors.length == 2);
        for (final (file, token) in [(main, '"wrong"'), (helper, '42')]) {
          final source = buffers[file.path]!;
          final expected = source.indexOf(token);
          require(
            'typeErrors.${p.basename(file.path)}.exactRange',
            errors.any(
              (d) =>
                  d.path == file.path &&
                  d.offset == expected &&
                  d.length == token.length &&
                  source.substring(d.offset, d.offset + d.length) == token,
            ),
          );
        }
      } else if (name == 'syntaxError') {
        final expected =
            buffers[main.path]!.indexOf('int number = ;') +
            'int number = '.length;
        require(
          'syntaxError.exactInsertion',
          errors.length == 1 &&
              errors.single.path == main.path &&
              errors.single.offset == expected &&
              errors.single.length <= 1 &&
              errors.single.code.contains('illegal.start'),
        );
      } else {
        require('clean.noDiagnostics', analyzed.diagnostics.isEmpty);
      }
      require('$name.noUserExecution', !await marker.exists());
      require(
        '$name.noSourceWrites',
        originals.entries.every(
          (entry) => listEquals(File(entry.key).readAsBytesSync(), entry.value),
        ),
      );
      for (final original in originals.entries) {
        ((result['diskSources']! as Map)[original.key] as Map)['sha256After'] =
            _bytesHash(await File(original.key).readAsBytes());
      }
      require('$name.newBufferNotSaved', !await extra.exists());
      require(
        '$name.noProjectOutputs',
        project.listSync(recursive: true).whereType<File>().length ==
            originals.length,
      );
      require('$name.scratchClean', scratch.listSync().isEmpty);
      await persist(result);
    }
    result['ok'] = true;
  } catch (error, stack) {
    result.addAll({
      'error': '$error',
      'stack': '$stack',
      'timedOut': error is TimeoutException,
    });
  }
  return result;
}

String _bytesHash(List<int> bytes) => OfflineDigest.sha256Bytes(
  bytes,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
