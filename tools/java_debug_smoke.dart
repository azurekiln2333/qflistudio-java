/// In-app runtime gate: `flutter run -t tools/java_debug_smoke.dart -d TARGET`.
/// Rebuild/install the normal lib/main.dart app after the probe.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_debugger.dart';
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_java/mobile_jdk.dart';

final _report = ValueNotifier<String>(
  'Running actual local Java debugger probe…',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Java debugger runtime probe')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ValueListenableBuilder<String>(
            valueListenable: _report,
            builder: (_, value, _) => SelectableText(value),
          ),
        ),
      ),
    ),
  );
  unawaited(() async {
    final result = await runJavaDebugSmoke();
    final text = jsonEncode(result);
    debugPrint('QFLI_JAVA_DEBUG_SMOKE $text');
    _report.value = const JsonEncoder.withIndent('  ').convert(result);
  }());
}

/// The same service and transport as production, with real assertions.
Future<Map<String, Object?>> runJavaDebugSmoke({
  String? temporaryDirectory,
}) async {
  Directory? project;
  final sessions = <JavaDebugSession>[];
  final observations = <_Observation>[];
  final checks = <String, bool>{};
  final result = <String, Object?>{
    'platform': Platform.operatingSystem,
    'os': Platform.operatingSystemVersion,
    'checks': checks,
    'ok': false,
  };
  void require(String name, bool value) {
    checks[name] = value;
    if (!value) throw StateError('Debug smoke failed: $name');
  }

  try {
    if (MobileJdk.isMobile) await MobileJdk.prepare();
    final root =
        temporaryDirectory ??
        (MobileJdk.current == null
            ? Directory.systemTemp.path
            : p.join(MobileJdk.current!.home, 'tmp'));
    project = await Directory(root).createTemp('qfli_java_debug_probe_');
    final entry = File(p.join(project.path, 'Main.java'));
    await entry.writeAsString(_program);
    final version = (await const JavaProgramRunner().startToolchainProcess(
      workingDirectory: project.path,
      arguments: [
        'java',
        '-Xms16m',
        '-Xmx256m',
        '-XX:+UseSerialGC',
        '-XshowSettings:properties',
        '-version',
      ],
      isolatedEnvironment: true,
    ))!;
    final stdout = version.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderr = version.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      require(
        'runtimeProbe',
        await version.exitCode.timeout(const Duration(seconds: 30)) == 0,
      );
    } finally {
      await version.cancel();
    }
    final properties = '${await stdout}\n${await stderr}';
    result['javaVersion'] = RegExp(
      r'^\s*java.version\s*=\s*(.+)$',
      multiLine: true,
    ).firstMatch(properties)?.group(1)?.trim();
    result['abi'] = RegExp(
      r'^\s*os.arch\s*=\s*(.+)$',
      multiLine: true,
    ).firstMatch(properties)?.group(1)?.trim();
    final debugger = JavaDebugger(
      temporaryDirectory: root,
      startupTimeout: const Duration(seconds: 90),
    );
    final session = debugger.launch(
      projectPath: project.path,
      entryFile: entry.path,
      breakpoints: [
        const JavaBreakpoint(id: 'start', className: 'Main', line: 9),
      ],
    );
    sessions.add(session);
    final observed = _Observation(session);
    observations.add(observed);
    await session.ready;
    result['vm'] = {
      'name': session.vmInfo?.name,
      'version': session.vmInfo?.version,
      'canPopFrames': session.vmInfo?.canPopFrames,
      'canForceEarlyReturn': session.vmInfo?.canForceEarlyReturn,
    };
    var pause = await observed.pause();
    require(
      'breakpoint',
      pause.location?.line == 9 && pause.message == 'breakpoint',
    );
    require(
      'localsBefore',
      (await session.variables()).any(
        (v) => v.name == 'counter' && v.value == '1',
      ),
    );
    require('stackMain', (await session.stackTrace()).first.method == 'main');
    await session.removeBreakpoint('start');
    await session.setBreakpoint(
      const JavaBreakpoint(id: 'end', className: 'Main', line: 11),
    );
    await session.stepOver();
    pause = await observed.pause();
    require(
      'stepOver',
      pause.location?.line == 10 &&
          (await session.variables()).any(
            (v) => v.name == 'counter' && v.value == '3',
          ),
    );
    await session.stepInto();
    pause = await observed.pause();
    require(
      'stepInto',
      pause.location?.line == 4 &&
          (await session.variables()).any(
            (v) => v.name == 'value' && v.value == '3',
          ),
    );
    require(
      'stackCaller',
      (await session.stackTrace()).map((f) => f.method).join(',') ==
          'twice,main',
    );
    await session.stepOver();
    pause = await observed.pause();
    require(
      'localsAfterStep',
      pause.location?.line == 5 &&
          (await session.variables()).any(
            (v) => v.name == 'doubled' && v.value == '6',
          ),
    );
    await session.stepOut();
    pause = await observed.pause();
    require('stepOut', (await session.stackTrace()).first.method == 'main');
    if (pause.location?.line != 11) {
      await session.resume();
      pause = await observed.pause();
    }
    require(
      'dynamicBreakpoint',
      pause.location?.line == 11 &&
          (await session.variables()).any(
            (v) => v.name == 'answer' && v.value == '6',
          ),
    );
    await session.removeBreakpoint('end');
    await session.resume();
    require('resumeExit', await session.done == 0);
    require('actualStdout', observed.stdout.toString().trim() == 'answer=6');
    require('noDebuggerErrors', observed.errors.isEmpty);
    require('originalSource', await entry.readAsString() == _program);
    await entry.writeAsString(
      'public class Main {\n public static void main(String[] a) {\n int value = 1;\n System.out.println(value);\n }\n}',
    );
    final stopped = debugger.launch(
      projectPath: project.path,
      entryFile: entry.path,
      breakpoints: [
        const JavaBreakpoint(id: 'stop', className: 'Main', line: 4),
      ],
    );
    sessions.add(stopped);
    final stopObservation = _Observation(stopped);
    observations.add(stopObservation);
    await stopped.ready;
    require(
      'repeatLaunch',
      (await stopObservation.pause()).location?.line == 4,
    );
    await stopped.terminate();
    require(
      'terminateSuspended',
      await stopped.done == 0 && stopObservation.stdout.isEmpty,
    );
    result['ok'] = true;
  } catch (error, stack) {
    result['error'] = '$error';
    result['stack'] = '$stack';
  } finally {
    for (final session in sessions) {
      await session.stop();
    }
    for (final observed in observations) {
      await observed.close();
    }
    if (project != null) await project.delete(recursive: true);
  }
  return result;
}

class _Observation {
  _Observation(JavaDebugSession session) {
    _subscription = session.events.listen((event) {
      if (event.kind == JavaDebugEventKind.output && !event.isErrorOutput) {
        stdout.write(event.message);
      }
      if (event.kind == JavaDebugEventKind.error) errors.add(event.message);
      if (event.kind == JavaDebugEventKind.paused) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(event);
        } else {
          _pauses.add(event);
        }
      }
    });
  }
  final stdout = StringBuffer();
  final errors = <String>[];
  final _waiters = <Completer<JavaDebugEvent>>[];
  final _pauses = <JavaDebugEvent>[];
  late final StreamSubscription<JavaDebugEvent> _subscription;
  Future<JavaDebugEvent> pause() {
    if (_pauses.isNotEmpty) return Future.value(_pauses.removeAt(0));
    final waiter = Completer<JavaDebugEvent>();
    _waiters.add(waiter);
    return waiter.future.timeout(const Duration(seconds: 30));
  }

  Future<void> close() => _subscription.cancel();
}

const _program = '''public class Main {
  // Exact line numbers are asserted against the target's actual line table.
  static int twice(int value) {
    int doubled = value * 2;
    return doubled;
  }
  public static void main(String[] args) {
    int counter = 1;
    counter += 2;
    int answer = twice(counter);
    System.out.println("answer=" + answer);
  }
}
''';
