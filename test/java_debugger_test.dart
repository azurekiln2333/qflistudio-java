import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_debugger.dart';

import '../tools/java_debug_smoke.dart' show runJavaDebugSmoke;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory project;
  late Directory temporary;
  final sessions = <JavaDebugSession>[];

  setUp(() {
    project = Directory.systemTemp.createTempSync('java debugger project ');
    temporary = Directory.systemTemp.createTempSync('java_debugger_tmp_');
  });
  tearDown(() async {
    for (final session in sessions) {
      await session.stop();
    }
    sessions.clear();
    project.deleteSync(recursive: true);
    temporary.deleteSync(recursive: true);
  });

  File write(String relative, String text) {
    final file = File(p.normalize(p.join(project.path, relative)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return file;
  }

  JavaDebugSession launch(
    File entry, {
    List<JavaBreakpoint> breakpoints = const [],
    Map<String, String> buffers = const {},
    int maxOutputBytes = 1024 * 1024,
  }) {
    final session =
        JavaDebugger(
          temporaryDirectory: temporary.path,
          maxOutputBytes: maxOutputBytes,
        ).launch(
          projectPath: project.path,
          entryFile: entry.path,
          breakpoints: breakpoints,
          unsavedBuffers: buffers,
        );
    sessions.add(session);
    return session;
  }

  test(
    'actual JDWP breakpoint, locals, stack, step into/over/out and resume',
    () async {
      final entry = write('src/demo/Main.java', _steppingProgram);
      final before = entry.readAsBytesSync();
      final session = launch(
        entry,
        breakpoints: [
          const JavaBreakpoint(id: 'start', className: 'demo.Main', line: 9),
        ],
      );
      final log = _DebugLog(session);
      await session.ready;
      var pause = await log.nextPause();
      expect(pause.message, 'breakpoint');
      expect(pause.location!.line, 9);
      expect(pause.location!.className, 'demo.Main');
      var variables = await session.variables();
      expect(variables.singleWhere((v) => v.name == 'counter').value, '1');
      final frames = await session.stackTrace();
      expect(frames.first.method, 'main');
      expect(frames.first.location.line, 9);
      await session.removeBreakpoint('start');
      await session.setBreakpoint(
        const JavaBreakpoint(id: 'end', className: 'demo.Main', line: 11),
      );
      await session.stepOver();
      pause = await log.nextPause();
      expect(pause.location!.line, 10);
      variables = await session.variables();
      expect(variables.singleWhere((v) => v.name == 'counter').value, '3');
      await session.stepInto();
      pause = await log.nextPause();
      expect(pause.location!.line, 4);
      variables = await session.variables();
      expect(variables.singleWhere((v) => v.name == 'value').value, '3');
      expect((await session.stackTrace()).map((f) => f.method), [
        'twice',
        'main',
      ]);
      await session.stepOver();
      pause = await log.nextPause();
      expect(pause.location!.line, 5);
      expect(
        (await session.variables())
            .singleWhere((v) => v.name == 'doubled')
            .value,
        '6',
      );
      await session.stepOut();
      pause = await log.nextPause();
      expect(pause.location!.className, 'demo.Main');
      expect((await session.stackTrace()).first.method, 'main');
      // Depending on VM line tables, STEP_OUT stops at the call or its next line.
      if (pause.location!.line != 11) {
        await session.resume();
        pause = await log.nextPause();
      }
      expect(pause.location!.line, 11);
      expect(
        (await session.variables())
            .singleWhere((v) => v.name == 'answer')
            .value,
        '6',
      );
      await session.removeBreakpoint('end');
      await session.resume();
      expect(await session.done, 0);
      expect(log.stdout.join(), 'answer=6${Platform.lineTerminator}');
      expect(log.errors, isEmpty);
      expect(
        log.events.any(
          (e) =>
              e.kind == JavaDebugEventKind.breakpoint &&
              e.verified &&
              e.breakpointId == 'start',
        ),
        isTrue,
      );
      expect(
        log.events.any(
          (e) =>
              e.kind == JavaDebugEventKind.breakpoint &&
              e.verified &&
              e.breakpointId == 'end',
        ),
        isTrue,
      );
      expect(entry.readAsBytesSync(), before);
      expect(
        project
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.extension(f.path)),
        everyElement('.java'),
      );
      expect(temporary.listSync(), isEmpty);
      await log.close();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'the in-app smoke uses the same actual desktop service and passes every assertion',
    () async {
      final result = await runJavaDebugSmoke(
        temporaryDirectory: temporary.path,
      );
      expect(
        result['ok'],
        isTrue,
        reason: '${result['error']}\n${result['stack']}',
      );
      expect((result['checks'] as Map).values, everyElement(true));
      expect(result['javaVersion'], isNotEmpty);
      expect(result['abi'], isNotEmpty);
      expect(temporary.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'concurrent sessions isolate targets, commands and cancellation',
    () async {
      final entry = write('src/demo/Main.java', _steppingProgram);
      final first = launch(
        entry,
        breakpoints: [
          const JavaBreakpoint(id: 'first', className: 'demo.Main', line: 9),
        ],
      );
      final second = launch(
        entry,
        breakpoints: [
          const JavaBreakpoint(id: 'second', className: 'demo.Main', line: 9),
        ],
      );
      final firstLog = _DebugLog(first);
      final secondLog = _DebugLog(second);
      await Future.wait([first.ready, second.ready]);
      await Future.wait([firstLog.nextPause(), secondLog.nextPause()]);
      await first.stepOver();
      expect((await firstLog.nextPause()).location!.line, 10);
      expect(
        (await first.variables()).singleWhere((v) => v.name == 'counter').value,
        '3',
      );
      expect(
        (await second.variables())
            .singleWhere((v) => v.name == 'counter')
            .value,
        '1',
      );
      await first.stop();
      expect(
        (await second.variables())
            .singleWhere((v) => v.name == 'counter')
            .value,
        '1',
      );
      await second.removeBreakpoint('second');
      await second.resume();
      expect(await second.done, 0);
      expect(secondLog.stdout.join().trim(), 'answer=6');
      expect(temporary.listSync(), isEmpty);
      await firstLog.close();
      await secondLog.close();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'dirty multifile debug snapshot and actual breakpoint removal',
    () async {
      final entry = write('Main.java', 'invalid saved Java source');
      final helper = write(
        'Helper.java',
        'class Helper { static int value() { return -1; } }',
      );
      const source =
          'public class Main {\n  public static void main(String[] a) {\n    int counter = 0;\n    for (int i = 0; i < 3; i++) {\n      counter += Helper.value();\n    }\n    System.out.println(counter);\n  }\n}\n';
      final session = launch(
        entry,
        breakpoints: [
          const JavaBreakpoint(id: 'loop', className: 'Main', line: 5),
        ],
        buffers: {
          entry.path: source,
          helper.path: 'class Helper { static int value() { return 2; } }',
        },
      );
      final log = _DebugLog(session);
      await session.ready;
      expect((await log.nextPause()).location!.line, 5);
      await session.removeBreakpoint('loop');
      await session.setBreakpoint(
        const JavaBreakpoint(id: 'loop', className: 'Main', line: 5),
      );
      await session.resume();
      expect((await log.nextPause()).location!.line, 5);
      expect(
        (await session.variables())
            .singleWhere((v) => v.name == 'counter')
            .value,
        '2',
      );
      await session.removeBreakpoint('loop');
      await session.resume();
      expect(await session.done, 0);
      expect(log.stdout.join().trim(), '6');
      expect(
        log.events.where((e) => e.kind == JavaDebugEventKind.paused).length,
        2,
      );
      expect(entry.readAsStringSync(), 'invalid saved Java source');
      expect(helper.readAsStringSync(), contains('return -1'));
      expect(temporary.listSync(), isEmpty);
      await log.close();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'user packages resembling JDK namespaces still receive class breakpoints',
    () async {
      final entry = write(
        'src/com/sun/example/Main.java',
        'package com.sun.example;\npublic class Main {\n public static void main(String[] a) {\n int value = 7;\n System.out.println(value);\n }\n}',
      );
      final session = launch(
        entry,
        breakpoints: [
          const JavaBreakpoint(
            id: 'namespace',
            className: 'com.sun.example.Main',
            line: 5,
          ),
        ],
      );
      final log = _DebugLog(session);
      await session.ready;
      expect((await log.nextPause()).location!.line, 5);
      expect(
        (await session.variables()).singleWhere((v) => v.name == 'value').value,
        '7',
      );
      await session.resume();
      expect(await session.done, 0);
      expect(log.stdout.join().trim(), '7');
      await log.close();
    },
  );

  test(
    'variable inspection reads Unicode and references without invoking user methods',
    () async {
      final entry = write(
        'Main.java',
        'public class Main {\n static class Dangerous { public String toString() { throw new AssertionError("toString executed"); } }\n public static void main(String[] a) {\n Dangerous instance = new Dangerous();\n String text = "😀中文"; int[] numbers = {1, 2};\n System.out.println("safe");\n }\n}',
      );
      final session = launch(
        entry,
        breakpoints: [
          const JavaBreakpoint(id: 'inspect', className: 'Main', line: 6),
        ],
      );
      final log = _DebugLog(session);
      await session.ready;
      await log.nextPause();
      final variables = await session.variables();
      expect(variables.singleWhere((v) => v.name == 'text').value, '😀中文');
      expect(
        variables.singleWhere((v) => v.name == 'instance').value,
        startsWith('Main\$Dangerous@'),
      );
      expect(
        variables.singleWhere((v) => v.name == 'numbers').value,
        'int[][length=2]',
      );
      await session.resume();
      expect(await session.done, 0);
      expect(log.stdout.join().trim(), 'safe');
      expect(log.errors, isEmpty);
      await log.close();
    },
  );

  test(
    'actual pause/variables and termination of a running target',
    () async {
      final entry = write(
        'Main.java',
        'public class Main { public static void main(String[] a) throws Exception { int counter = 0; while (true) { counter++; Thread.sleep(20); } } }',
      );
      final session = launch(entry);
      final log = _DebugLog(session);
      await session.ready;
      await session.pause();
      final pause = await log.nextPause();
      expect(pause.message, 'pause');
      expect(await session.stackTrace(), isNotEmpty);
      await session.resume();
      await session.terminate();
      expect(await session.done, 0);
      expect(temporary.listSync(), isEmpty);
      await log.close();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'terminates a genuinely breakpoint-suspended target and can start again',
    () async {
      final entry = write(
        'Main.java',
        'public class Main {\n public static void main(String[] a) {\n int counter = 1;\n System.out.println(counter);\n }\n}',
      );
      for (var i = 0; i < 2; i++) {
        final session = launch(
          entry,
          breakpoints: [
            JavaBreakpoint(id: 'stop$i', className: 'Main', line: 4),
          ],
        );
        final log = _DebugLog(session);
        await session.ready;
        await log.nextPause();
        await session.terminate();
        expect(await session.done, 0);
        expect(log.stdout, isEmpty);
        expect(temporary.listSync(), isEmpty);
        await log.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'invalid state/breakpoint has real errors without a simulated pause',
    () async {
      final entry = write(
        'Main.java',
        'public class Main {\n public static void main(String[] a) throws Exception {\n int counter = 1;\n while (true) { Thread.sleep(20); }\n }\n}',
      );
      final session = launch(
        entry,
        breakpoints: [
          const JavaBreakpoint(id: 'initial', className: 'Main', line: 4),
        ],
      );
      final log = _DebugLog(session);
      await session.ready;
      await log.nextPause();
      await session.setBreakpoint(
        const JavaBreakpoint(id: 'blank', className: 'Main', line: 99),
      );
      expect(
        log.events.any(
          (e) =>
              e.breakpointId == 'blank' &&
              !e.verified &&
              e.message == 'no-executable-code',
        ),
        isTrue,
      );
      await expectLater(session.variables(frame: 31), throwsStateError);
      await session.removeBreakpoint('initial');
      await session.resume();
      await expectLater(session.variables(), throwsStateError);
      await session.stop();
      expect(temporary.listSync(), isEmpty);
      await log.close();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'Stop during preparation and compiler failure clean isolated state',
    () async {
      final entry = write('Main.java', 'public class Main { invalid }');
      final cancelled = launch(entry);
      await cancelled.stop();
      await expectLater(cancelled.ready, throwsStateError);
      expect(temporary.listSync(), isEmpty);
      final broken = launch(entry);
      final log = _DebugLog(broken);
      await expectLater(broken.ready, throwsStateError);
      await broken.done;
      expect(log.errors.join(), contains('javac failed'));
      expect(temporary.listSync(), isEmpty);
      await log.close();
    },
  );

  test(
    'Stop closes inherited pipes and preserves a separate live session',
    () async {
      final entry = write('Main.java', _descendantProgram);
      final peerEntry = write(
        'Peer.java',
        'public class Peer { public static void main(String[] a) throws Exception { Thread.sleep(30000); } }',
      );
      final peer = launch(peerEntry);
      final peerLog = _DebugLog(peer);
      await peer.ready;
      final session = launch(entry);
      final log = _DebugLog(session);
      int? childPid;
      try {
        await session.ready;
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        final child = File(p.join(project.path, 'child.pid'));
        final started = File(p.join(project.path, 'child.started'));
        while (!child.existsSync() || !started.existsSync()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Actual inherited-output descendant did not start');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        childPid = int.parse(child.readAsStringSync());
        await session.stop().timeout(const Duration(seconds: 10));
        await session.done.timeout(const Duration(seconds: 1));
        if (Platform.isWindows) {
          // False proves tree cancellation has already removed the real child.
          expect(Process.killPid(childPid, ProcessSignal.sigkill), isFalse);
        }
        expect(temporary.listSync(), hasLength(1)); // Only the peer snapshot.
        await peer.pause();
        expect((await peerLog.nextPause()).message, 'pause');
        await peer.stop();
        expect(temporary.listSync(), isEmpty);
      } finally {
        final child = File(p.join(project.path, 'child.pid'));
        childPid ??= child.existsSync()
            ? int.parse(child.readAsStringSync())
            : null;
        if (childPid != null) await _stopDescendant(childPid);
        await log.close();
        await peerLog.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'natural target exit bounds pipe drainage when a descendant remains alive',
    () async {
      final entry = write(
        'Main.java',
        _descendantProgram.replaceFirst('Thread.sleep(30000); // parent', ''),
      );
      final session = launch(entry);
      final log = _DebugLog(session);
      try {
        await session.ready;
        expect(await session.done.timeout(const Duration(seconds: 10)), 0);
        expect(log.stdout.join(), contains('parent-finished'));
        expect(temporary.listSync(), isEmpty);
      } finally {
        final child = File(p.join(project.path, 'child.pid'));
        if (child.existsSync()) {
          await _stopDescendant(int.parse(child.readAsStringSync()));
        }
        await log.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'raw byte cap stops unbroken target output and waits for both JVMs',
    () async {
      final entry = write(
        'Main.java',
        'public class Main { public static void main(String[] a) { System.out.print("x".repeat(2000000)); } }',
      );
      final session = launch(entry, maxOutputBytes: 32768);
      final log = _DebugLog(session);
      await session.ready;
      await session.done;
      expect(log.errors.join(), contains('byte limit'));
      expect(log.stdout.join().length, lessThanOrEqualTo(32768));
      expect(temporary.listSync(), isEmpty);
      await log.close();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

Future<void> _stopDescendant(int pid) async {
  if (!Process.killPid(pid, ProcessSignal.sigkill)) return;
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final result = Platform.isWindows
        ? await Process.run('tasklist.exe', [
            '/FI',
            'PID eq $pid',
            '/FO',
            'CSV',
            '/NH',
          ])
        : await Process.run('ps', ['-p', '$pid', '-o', 'pid=']);
    final alive = Platform.isWindows
        ? '${result.stdout}'.contains('"$pid"')
        : '${result.stdout}'.trim() == '$pid';
    if (!alive) return;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Test descendant $pid did not exit after kill');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _DebugLog {
  _DebugLog(JavaDebugSession session) {
    _subscription = session.events.listen((event) {
      events.add(event);
      if (event.kind == JavaDebugEventKind.paused) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(event);
        } else {
          _pauses.add(event);
        }
      }
    });
  }
  final events = <JavaDebugEvent>[];
  final _pauses = <JavaDebugEvent>[];
  final _waiters = <Completer<JavaDebugEvent>>[];
  late StreamSubscription<JavaDebugEvent> _subscription;
  List<String> get stdout => events
      .where((e) => e.kind == JavaDebugEventKind.output && !e.isErrorOutput)
      .map((e) => e.message)
      .toList();
  List<String> get errors => events
      .where((e) => e.kind == JavaDebugEventKind.error)
      .map((e) => e.message)
      .toList();
  Future<JavaDebugEvent> nextPause() {
    if (_pauses.isNotEmpty) return Future.value(_pauses.removeAt(0));
    final waiter = Completer<JavaDebugEvent>();
    _waiters.add(waiter);
    return waiter.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException(
        'No real pause; events: ${events.map((e) => '${e.kind}:${e.message}').join(' | ')}',
      ),
    );
  }

  Future<void> close() => _subscription.cancel();
}

const _steppingProgram = '''package demo;
public class Main {
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

const _descendantProgram = r'''
import java.nio.file.*;
public class Main {
  public static void main(String[] a) throws Exception {
    String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
    Process child = new ProcessBuilder(java, "-Xms16m", "-Xmx64m", "-XX:+UseSerialGC",
        "-classpath", System.getProperty("java.class.path"), "Main$Child").inheritIO().start();
    Files.writeString(Path.of("child.pid"), Long.toString(child.pid()));
    long deadline = System.nanoTime() + 5_000_000_000L;
    while (!Files.exists(Path.of("child.started"))) {
      if (System.nanoTime() > deadline) throw new AssertionError("child did not start");
      Thread.sleep(10);
    }
    System.out.println("parent-finished");
    Thread.sleep(30000); // parent
  }
  public static class Child {
    public static void main(String[] a) throws Exception {
      Files.writeString(Path.of("child.started"), "ready");
      System.out.println("descendant-ready");
      Thread.sleep(30000);
    }
  }
}
''';
