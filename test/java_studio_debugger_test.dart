import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_debugger.dart';
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_java/java_studio_debugger.dart';
import 'package:qfli_java/main.dart' show javaProfile;
import 'package:qfli_studio_core/services/code_analysis.dart';
import 'package:qfli_studio_core/services/debug_session.dart';

import '../tools/java_studio_debug_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory project;
  late Directory scratch;
  final sessions = <DebugSession>[];
  final observers = <JavaStudioObservation>[];

  setUp(() {
    project = Directory.systemTemp.createTempSync('java studio project ');
    scratch = Directory.systemTemp.createTempSync('java_studio_scratch_');
  });
  tearDown(() async {
    for (final session in sessions) {
      await session.dispose();
    }
    sessions.clear();
    for (final observer in observers) {
      await observer.close();
    }
    observers.clear();
    project.deleteSync(recursive: true);
    scratch.deleteSync(recursive: true);
  });
  File write(String name, String source) {
    final file = File(p.join(project.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
    return file;
  }

  Future<DebugSession> launch(
    File entry, {
    List<DebugBreakpoint> breakpoints = const [],
    List<CodeDocumentSnapshot> documents = const [],
    bool stopOnEntry = false,
    JavaProgramRunner runner = const JavaProgramRunner(),
  }) async {
    final debugger = JavaStudioDebugger(
      debugger: JavaDebugger(temporaryDirectory: scratch.path, runner: runner),
    );
    final session = await debugger.launch(
      DebugLaunchRequest(
        projectPath: project.path,
        entryFilePath: entry.path,
        language: 'Java',
        documents: documents,
        breakpoints: breakpoints,
        stopOnEntry: stopOnEntry,
      ),
    );
    sessions.add(session);
    return session;
  }

  JavaStudioObservation observe(DebugSession session) {
    final result = JavaStudioObservation(session);
    observers.add(result);
    return result;
  }

  test(
    'product registers the actual offline provider and truthful capabilities',
    () {
      final debugger = javaProfile.debugger!;
      expect(debugger, isA<JavaStudioDebugger>());
      expect(debugger.supportsLanguage('Java'), isTrue);
      expect(debugger.supportsLanguage('java'), isTrue);
      expect(debugger.supportsLanguage('Kotlin'), isFalse);
      final capabilities = debugger.capabilities;
      expect(capabilities.breakpointUpdate, DebugBreakpointUpdate.paused);
      expect(capabilities.outputDelivery, DebugOutputDelivery.live);
      expect(capabilities.supportsDocumentSnapshots, isTrue);
      expect(capabilities.supportsStopOnEntry, isTrue);
      expect(capabilities.supportsPause, isTrue);
      expect(
        capabilities.supportsStepInto &&
            capabilities.supportsStepOver &&
            capabilities.supportsStepOut &&
            capabilities.supportsStackFrames &&
            capabilities.supportsVariables,
        isTrue,
      );
      expect(javaProfile.isOffline, isTrue);
    },
  );

  test(
    'real shared-provider dirty multi-file CRLF, exact secondary/nested source breakpoints and all steps',
    () async {
      final result = await runJavaStudioDebugSmoke(
        temporaryDirectory: scratch.path,
      );
      expect(result['ok'], isTrue, reason: jsonEncode(result));
      expect((result['checks'] as Map).length, greaterThanOrEqualTo(20));
      expect((result['checks'] as Map).values, everyElement(true));
      expect(result['cleanupConfirmed'], isTrue);
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'stop on entry is an actual JDI main method location and foreign tokens are rejected',
    () async {
      final entry = write('Main.java', '''package demo;
public class Main {
 public static void main(String[] args) {
  int value = 7;
  System.out.println(value);
 }
}
''');
      final session = await launch(entry, stopOnEntry: true);
      final observed = observe(session);
      final pause = await observed.paused();
      expect(pause.message, 'entry');
      expect(pause.frames.first.name, 'demo.Main.main');
      expect(pause.frames.first.location!.filePath, entry.path);
      expect(pause.frames.first.location!.line, 4);
      expect(pause.stdout, isEmpty);
      await expectLater(
        session.command(
          DebugCommand.resume,
          pauseToken: DebugPauseToken(
            sessionId: 'foreign',
            generation: pause.pauseToken!.generation,
          ),
        ),
        throwsStateError,
      );
      expect(session.snapshot.pauseToken, pause.pauseToken);
      expect(() => pause.frames.clear(), throwsUnsupportedError);
      expect(() => pause.threads.clear(), throwsUnsupportedError);
      await session.command(DebugCommand.resume, pauseToken: pause.pauseToken);
      await session.done;
      expect(session.snapshot.exitCode, 0);
      expect(session.snapshot.stdout.trim(), '7');
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'Windows case-alias captures retain the actual compiler filename and source breakpoint',
    () async {
      const saved = 'invalid saved source';
      final entry = write('Main.java', saved);
      final alias = p.join(project.path, 'mAIN.java');
      final debugger = JavaStudioDebugger(
        debugger: JavaDebugger(temporaryDirectory: scratch.path),
      );
      final session = await debugger.launch(
        DebugLaunchRequest(
          projectPath: project.path,
          entryFilePath: alias,
          language: 'Java',
          documents: [
            CodeDocumentSnapshot(
              path: alias,
              text: '''public class Main {
 public static void main(String[] args) {
  int value = 13;
  System.out.println(value);
 }
}
''',
              revision: 3,
            ),
          ],
          breakpoints: [DebugBreakpoint(filePath: alias, line: 4)],
        ),
      );
      sessions.add(session);
      final pause = await observe(session).paused();
      expect(pause.breakpoints.single.status, DebugBreakpointStatus.verified);
      expect(pause.frames.first.location!.filePath, entry.path);
      expect(pause.frames.first.location!.line, 4);
      expect(
        pause.frames.first.locals.singleWhere((v) => v.name == 'value').value,
        '13',
      );
      await session.setBreakpoints([]);
      await session.command(DebugCommand.resume, pauseToken: pause.pauseToken);
      await session.done;
      expect(session.snapshot.exitCode, 0);
      expect(session.snapshot.stdout.trim(), '13');
      expect(entry.readAsStringSync(), saved);
      expect(scratch.listSync(), isEmpty);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'live output remains observable before pause; running replacement rejects and stop drains cleanup',
    () async {
      final entry = write('Main.java', '''public class Main {
 public static void main(String[] args) throws Exception {
  System.out.println("running😀");
  int counter = 1;
  while (true) { counter++; Thread.sleep(20); }
 }
}
''');
      final session = await launch(entry);
      final observed = observe(session);
      final output = await observed.until(
        (s) => s.phase == DebugPhase.running && s.stdout.contains('running😀'),
      );
      expect(output.pauseToken, isNull);
      await expectLater(
        session.setBreakpoints([
          DebugBreakpoint(filePath: entry.path, line: 5),
        ]),
        throwsStateError,
      );
      await session.command(DebugCommand.pause);
      final pause = await observed.paused();
      expect(pause.frames, isNotEmpty);
      expect(pause.frames.any((frame) => frame.name == 'Main.main'), isTrue);
      expect(
        pause.frames.every(
          (frame) =>
              frame.location == null || frame.location!.filePath == entry.path,
        ),
        isTrue,
      );
      expect(
        pause.frames
            .where((f) => f.location == null)
            .every(
              (f) => f.localsUnavailableReason != null || f.locals.isNotEmpty,
            ),
        isTrue,
      );
      await session.command(DebugCommand.resume, pauseToken: pause.pauseToken);
      expect(session.snapshot.pauseToken, isNull);
      expect(session.snapshot.frames, isEmpty);
      await session.stop();
      expect(session.snapshot.phase, DebugPhase.terminated);
      expect(session.snapshot.exitCode, isNotNull);
      expect(session.snapshot.stdout, output.stdout);
      expect(scratch.listSync(), isEmpty);
      await session.stop();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'stop during startup stays stopping until the actual delayed child and scratch are gone',
    () async {
      final entry = write(
        'Main.java',
        'public class Main { public static void main(String[] a) {} }',
      );
      final runner = _DelayedRunner();
      final session = await launch(entry, runner: runner);
      await runner.started.future;
      expect(session.snapshot.isTerminal, isFalse);
      final stopping = session.stop();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(session.snapshot.phase, DebugPhase.stopping);
      expect(scratch.listSync(), isNotEmpty);
      runner.release.complete();
      await stopping.timeout(const Duration(seconds: 15));
      expect(session.snapshot.phase, DebugPhase.terminated);
      expect(session.snapshot.exitCode, isNull);
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'startup stop and compile failure never fabricate a target exit code',
    () async {
      final entry = write('Main.java', 'public class Main { invalid }');
      final cancelled = await launch(entry);
      await cancelled.stop();
      expect(cancelled.snapshot.phase, DebugPhase.terminated);
      expect(cancelled.snapshot.exitCode, isNull);
      final broken = await launch(entry);
      await broken.done;
      expect(broken.snapshot.phase, DebugPhase.failed);
      expect(broken.snapshot.message, contains('javac failed'));
      expect(broken.snapshot.exitCode, isNull);
      expect(broken.snapshot.console, contains('error:'));
      expect(broken.snapshot.stdout, isEmpty);
      expect(broken.snapshot.stderr, isEmpty);
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'failed worker cancellation remains retryable and an acknowledgement does not release ownership',
    () async {
      final entry = write(
        'Main.java',
        'public class Main { public static void main(String[] a) {} }',
      );
      final runner = _ControlledCancellationRunner();
      final session = await launch(entry, runner: runner);
      final observed = observe(session);
      await runner.started.future;
      await Future<void>.delayed(Duration.zero);
      var done = false;
      unawaited(session.done.then((_) => done = true));
      try {
        await expectLater(session.stop(), throwsStateError);
        final failure = await observed.until(
          (s) =>
              s.phase == DebugPhase.stopping &&
              s.console.contains('controlled worker cancellation failure'),
        );
        expect(failure.isTerminal, isFalse);
        expect(failure.pauseToken, isNull);
        expect(done, isFalse);
        expect(runner.cancelCalls, 1);
        expect(scratch.listSync(), isNotEmpty);

        final retry = session.stop();
        await Future<void>.delayed(Duration.zero);
        expect(runner.cancelCalls, 2);
        expect(done, isFalse);
        expect(session.snapshot.phase, DebugPhase.stopping);
        expect(scratch.listSync(), isNotEmpty);

        // The second cancel acknowledged the request, but only this actual
        // terminal result permits the debugger to delete its scratch state.
        await runner.exit();
        await retry;
        expect(done, isTrue);
        expect(session.snapshot.phase, DebugPhase.failed);
        expect(session.snapshot.exitCode, isNull);
        expect(scratch.listSync(), isEmpty);
      } finally {
        await runner.exit();
        await session.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'compiler stdout failure waits for stderr EOF before terminal cleanup',
    () async {
      final entry = write(
        'Main.java',
        'public class Main { public static void main(String[] a) {} }',
      );
      final runner = _LateDrainCancellationRunner();
      runner.release.complete();
      final session = await launch(entry, runner: runner);
      await runner.started.future;
      var done = false;
      unawaited(session.done.then((_) => done = true));
      try {
        runner.stdout.addError(
          const FileSystemException('compiler stdout transport failed'),
        );
        await runner.stdout.close();
        runner.exit.complete(137);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(done, isFalse);
        expect(session.snapshot.isTerminal, isFalse);
        expect(scratch.listSync(), isNotEmpty);

        await runner.stderr.close();
        await session.done;
        expect(done, isTrue);
        expect(session.snapshot.phase, DebugPhase.failed);
        expect(session.snapshot.console, contains('stdout transport failed'));
        expect(session.snapshot.exitCode, isNull);
        expect(scratch.listSync(), isEmpty);
      } finally {
        if (!runner.exit.isCompleted) runner.exit.complete(137);
        await Future.wait([runner.stdout.close(), runner.stderr.close()]);
        await session.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'late native start retains both drains after the first cancellation fails',
    () async {
      final entry = write(
        'Main.java',
        'public class Main { public static void main(String[] a) {} }',
      );
      final runner = _LateDrainCancellationRunner();
      final session = await launch(entry, runner: runner);
      await runner.started.future;
      var done = false;
      unawaited(session.done.then((_) => done = true));
      final stopping = session.stop();
      stopping.ignore();
      try {
        runner.release.complete();
        await runner.retryStarted.future.timeout(const Duration(seconds: 2));
        expect(runner.cancelCalls, 2);
        runner.exit.complete(137);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(done, isFalse);
        expect(session.snapshot.isTerminal, isFalse);
        expect(scratch.listSync(), isNotEmpty);

        await runner.stdout.close();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(done, isFalse);
        expect(session.snapshot.phase, DebugPhase.stopping);
        expect(scratch.listSync(), isNotEmpty);

        await runner.stderr.close();
        await stopping;
        expect(done, isTrue);
        expect(session.snapshot.phase, DebugPhase.failed);
        expect(
          session.snapshot.console,
          contains('first late-start cancellation failed'),
        );
        expect(session.snapshot.exitCode, isNull);
        expect(scratch.listSync(), isEmpty);
      } finally {
        if (!runner.release.isCompleted) runner.release.complete();
        if (!runner.exit.isCompleted) runner.exit.complete(137);
        await Future.wait([runner.stdout.close(), runner.stderr.close()]);
        await stopping;
        await session.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'automatic cleanup failure retains ownership and failed stop/dispose can retry',
    () async {
      final entry = write('Main.java', '''public class Main {
 public static void main(String[] args) { System.out.print("exited"); }
}
''');
      final cleanup = _FailCleanupOverrides(scratch.path, failures: 3);
      await IOOverrides.runWithIOOverrides(() async {
        final session = await launch(entry);
        var done = false;
        unawaited(
          session.done.then((_) {
            done = true;
          }),
        );
        final state = await observe(session).until(
          (s) =>
              s.phase == DebugPhase.stopping &&
              s.console.contains('controlled cleanup failure'),
        );
        expect(state.isTerminal, isFalse);
        expect(state.pauseToken, isNull);
        expect(state.frames, isEmpty);
        expect(state.exitCode, isNull);
        expect(done, isFalse);
        expect(cleanup.attempts, 1);
        expect(scratch.listSync(), isNotEmpty);

        final failure = throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('controlled cleanup failure'),
          ),
        );
        // Each attempt returns its actual failure promptly, while done remains
        // pending. Neither retry is allowed to reuse a cached failed Future.
        await expectLater(
          session.stop().timeout(const Duration(seconds: 10)),
          failure,
        );
        expect(cleanup.attempts, 2);
        expect(done, isFalse);
        await expectLater(
          session.dispose().timeout(const Duration(seconds: 10)),
          failure,
        );
        expect(cleanup.attempts, 3);
        expect(session.snapshot.phase, DebugPhase.stopping);
        expect(done, isFalse);
        expect(scratch.listSync(), isNotEmpty);

        await session.dispose().timeout(const Duration(seconds: 10));
        await session.done;
        expect(cleanup.attempts, 4);
        expect(done, isTrue);
        expect(session.snapshot.phase, DebugPhase.failed);
        expect(session.snapshot.exitCode, 0);
        expect(session.snapshot.stdout, 'exited');
        expect(session.snapshot.console, contains('scratch cleanup failed'));
        expect(scratch.listSync(), isEmpty);
        await session.stop();
        await session.dispose();
      }, cleanup);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'rolling output is cumulative, independently bounded, Unicode-safe and revisioned while running',
    () async {
      final entry = write('Main.java', '''public class Main {
 public static void main(String[] args) throws Exception {
  System.out.print("😀中".repeat(30000));
  System.err.print("错😀".repeat(25000));
  System.out.print("尾");
  Thread.sleep(30000);
 }
}
''');
      final session = await launch(entry);
      final observed = observe(session);
      final state = await observed.until(
        (s) => s.stdout.endsWith('尾') && s.stderr.endsWith('😀'),
      );
      expect(state.phase, DebugPhase.running);
      expect(state.stdout.length, lessThanOrEqualTo(65536));
      expect(state.stderr.length, lessThanOrEqualTo(65536));
      expect(state.stdoutTruncated, isTrue);
      expect(state.stderrTruncated, isTrue);
      expect(state.consoleTruncated, isFalse);
      expect(utf8.decode(utf8.encode(state.stdout)), state.stdout);
      expect(utf8.decode(utf8.encode(state.stderr)), state.stderr);
      expect(
        state.stdout.contains('\ufffd') || state.stderr.contains('\ufffd'),
        isFalse,
      );
      final outputOnly = observed.snapshots
          .where((s) => s.phase == DebugPhase.running && s.stdout.isNotEmpty)
          .toList();
      expect(outputOnly.length, greaterThan(1));
      expect(outputOnly.last.revision, greaterThan(outputOnly.first.revision));
      await session.stop();
      expect(session.snapshot.stdout, state.stdout);
      expect(session.snapshot.stderr, state.stderr);
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'native byte cap preserves complete Unicode and marks omitted target output',
    () async {
      final entry = write('Main.java', '''public class Main {
 public static void main(String[] args) { System.out.print("😀".repeat(200000)); }
}
''');
      final debugger = JavaStudioDebugger(
        debugger: JavaDebugger(
          temporaryDirectory: scratch.path,
          maxOutputBytes: 32769,
        ),
      );
      final session = await debugger.launch(
        DebugLaunchRequest(
          projectPath: project.path,
          entryFilePath: entry.path,
          language: 'Java',
          documents: [],
        ),
      );
      sessions.add(session);
      await session.done;
      expect(session.snapshot.phase, DebugPhase.failed);
      expect(session.snapshot.message, contains('byte limit'));
      expect(session.snapshot.stdoutTruncated, isTrue);
      expect(session.snapshot.stdout, isNotEmpty);
      expect(session.snapshot.stdout.replaceAll('😀', ''), isEmpty);
      expect(session.snapshot.stdout.contains('\ufffd'), isFalse);
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'nonzero actual program exit is distinct from a never-launched target',
    () async {
      final entry = write('Main.java', '''public class Main {
 public static void main(String[] args) { System.err.print("expected😀"); System.exit(7); }
}
''');
      final session = await launch(entry);
      await session.done;
      expect(session.snapshot.phase, DebugPhase.failed);
      expect(session.snapshot.exitCode, 7);
      expect(session.snapshot.message, contains('status 7'));
      expect(session.snapshot.stderr, 'expected😀');
      expect(session.snapshot.stdout, isEmpty);
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'bounded copied locals expose truncation and unavailable object fields without calling user code',
    () async {
      final lines = [
        'public class Main {',
        ' static class Dangerous { public String toString() { throw new AssertionError("invoked"); } }',
        ' public static void main(String[] args) {',
        '  Dangerous object = new Dangerous();',
        '  String text = "😀".repeat(1000);',
        '  String huge = "a" + "😀".repeat(50000);',
        '  String lone = new String(new char[] { (char)0xd800 });',
        for (var i = 0; i < 70; i++) '  int v$i = $i;',
        '  System.out.print("safe");',
        ' }',
        '}',
      ];
      final entry = write('Main.java', lines.join('\n'));
      final session = await launch(
        entry,
        breakpoints: [
          DebugBreakpoint(filePath: entry.path, line: lines.length - 2),
        ],
      );
      final observed = observe(session);
      final state = await observed.paused();
      final locals = state.frames.first.locals;
      expect(locals.length, 64);
      expect(state.frames.first.localsTruncated, isTrue);
      final object = locals.singleWhere((v) => v.name == 'object');
      expect(object.value, startsWith(r'Main$Dangerous@'));
      expect(object.unavailableReason, contains('not inspected'));
      final text = locals.singleWhere((v) => v.name == 'text');
      expect(text.truncated, isTrue);
      expect(text.value.length, 1024);
      expect(text.value, '😀' * 512);
      final huge = locals.singleWhere((v) => v.name == 'huge');
      expect(huge.truncated, isTrue);
      expect(huge.value, 'a${'😀' * 511}');
      final lone = locals.singleWhere((v) => v.name == 'lone');
      expect(lone.value, startsWith('java.lang.String@'));
      expect(lone.unavailableReason, contains('Unpaired UTF-16'));
      expect(() => locals.clear(), throwsUnsupportedError);
      expect(() => object.children.add(text), throwsUnsupportedError);
      await session.setBreakpoints([]);
      await session.command(DebugCommand.resume, pauseToken: state.pauseToken);
      await session.done;
      expect(session.snapshot.exitCode, 0);
      expect(session.snapshot.stdout, 'safe');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'actual recursive stack omission is explicitly marked and total locals stay bounded',
    () async {
      final entry = write('Main.java', '''public class Main {
 static void descend(int n) {
  if (n > 0) {
   descend(n - 1);
  } else {
   int value = 3;
   System.out.print(value);
  }
 }
 public static void main(String[] a) { descend(40); }
}
''');
      final session = await launch(
        entry,
        breakpoints: [DebugBreakpoint(filePath: entry.path, line: 7)],
      );
      final state = await observe(session).paused();
      expect(state.frames.length, 32);
      expect(state.framesTruncated, isTrue);
      expect(
        state.frames.fold<int>(0, (n, f) => n + f.locals.length),
        lessThanOrEqualTo(200),
      );
      expect(
        state.frames.first.locals.any(
          (v) => v.name == 'value' && v.value == '3',
        ),
        isTrue,
      );
      await session.stop();
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'separate roots have isolated real targets, buffers, tokens and stop',
    () async {
      final firstEntry = write('Main.java', _isolationSource(11));
      final peer = Directory(p.join(project.path, 'peer'))..createSync();
      final secondEntry = File(p.join(peer.path, 'Main.java'))
        ..writeAsStringSync(_isolationSource(22));
      // The root's Java compilation intentionally excludes the peer workspace.
      final firstRoot = Directory(p.join(project.path, 'first'))..createSync();
      final firstFile = firstEntry.copySync(
        p.join(firstRoot.path, 'Main.java'),
      );
      firstEntry.deleteSync();
      final debugger = JavaStudioDebugger(
        debugger: JavaDebugger(temporaryDirectory: scratch.path),
      );
      Future<DebugSession> isolated(Directory root, File entry) async {
        final session = await debugger.launch(
          DebugLaunchRequest(
            projectPath: root.path,
            entryFilePath: entry.path,
            language: 'Java',
            documents: [],
            breakpoints: [DebugBreakpoint(filePath: entry.path, line: 4)],
          ),
        );
        sessions.add(session);
        return session;
      }

      final first = await isolated(firstRoot, firstFile);
      final second = await isolated(peer, secondEntry);
      final firstState = await observe(first).paused();
      final secondState = await observe(second).paused();
      expect(
        firstState.frames.first.locals
            .singleWhere((v) => v.name == 'value')
            .value,
        '11',
      );
      expect(
        secondState.frames.first.locals
            .singleWhere((v) => v.name == 'value')
            .value,
        '22',
      );
      await expectLater(
        second.command(DebugCommand.resume, pauseToken: firstState.pauseToken),
        throwsStateError,
      );
      await first.stop();
      expect(second.snapshot.pauseToken, secondState.pauseToken);
      await second.setBreakpoints([]);
      await second.command(
        DebugCommand.resume,
        pauseToken: secondState.pauseToken,
      );
      await second.done;
      expect(second.snapshot.stdout.trim(), '22');
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'invalid captures, foreign/duplicate/aliased/missing paths and unsupported language never launch',
    () async {
      final entry = write(
        'Main.java',
        'public class Main { public static void main(String[] a) {} }',
      );
      final other = Directory.systemTemp.createTempSync('foreign_java_root_');
      final foreign = File(p.join(other.path, 'Foreign.java'))
        ..writeAsStringSync('class Foreign {}');
      final text = write('notes.txt', 'unsupported');
      final counting = _CountingDebugger();
      final debugger = JavaStudioDebugger(debugger: counting);
      Future<void> reject({
        String? projectPath,
        String? entryPath,
        String language = 'Java',
        List<CodeDocumentSnapshot> documents = const [],
        List<DebugBreakpoint> breakpoints = const [],
      }) async {
        await expectLater(
          debugger.launch(
            DebugLaunchRequest(
              projectPath: projectPath ?? project.path,
              entryFilePath: entryPath ?? entry.path,
              language: language,
              documents: documents,
              breakpoints: breakpoints,
            ),
          ),
          throwsArgumentError,
        );
        expect(counting.launches, 0);
      }

      try {
        await reject(language: 'Kotlin');
        await reject(entryPath: foreign.path);
        await reject(entryPath: 'Main.java');
        await reject(entryPath: p.join(project.path, 'missing.java'));
        await reject(
          documents: [
            CodeDocumentSnapshot(path: text.path, text: 'dirty', revision: 1),
          ],
        );
        await reject(
          documents: [
            CodeDocumentSnapshot(
              path: foreign.path,
              text: 'dirty',
              revision: 1,
            ),
          ],
        );
        await reject(
          documents: [
            CodeDocumentSnapshot(path: entry.path, text: 'first', revision: 1),
            CodeDocumentSnapshot(path: entry.path, text: 'last', revision: 2),
          ],
        );
        await reject(
          documents: [
            CodeDocumentSnapshot(path: entry.path, text: '\ud800', revision: 1),
          ],
        );
        await reject(
          breakpoints: [DebugBreakpoint(filePath: foreign.path, line: 1)],
        );
        await reject(
          breakpoints: [
            DebugBreakpoint(filePath: entry.path, line: 1),
            DebugBreakpoint(filePath: entry.path, line: 1),
          ],
        );
        final alias = Link(p.join(project.path, 'foreign-link'));
        await alias.create(other.path);
        await reject(
          documents: [
            CodeDocumentSnapshot(
              path: p.join(alias.path, 'Foreign.java'),
              text: 'dirty',
              revision: 1,
            ),
          ],
        );
        await reject(
          projectPath: alias.path,
          entryPath: p.join(alias.path, 'Foreign.java'),
        );
        await alias.delete();
        expect(scratch.listSync(), isEmpty);
      } finally {
        other.deleteSync(recursive: true);
      }
    },
  );

  test(
    'ambiguous compiler SourceFile identities fail before a user target is launched',
    () async {
      final entry = write(
        'Main.java',
        'package demo; public class Main { public static void main(String[] a) { System.out.print("must not execute"); } }',
      );
      write('a/Unit.java', 'package demo; class Alpha {}');
      write('b/Unit.java', 'package demo; class Beta {}');
      final session = await launch(entry);
      await session.done;
      expect(session.snapshot.phase, DebugPhase.failed);
      expect(
        session.snapshot.console,
        contains('Ambiguous SourceFile identity'),
      );
      expect(session.snapshot.exitCode, isNull);
      expect(session.snapshot.stdout, isEmpty);
      expect(scratch.listSync(), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

String _isolationSource(int value) =>
    '''public class Main {
 public static void main(String[] args) {
  int value = $value;
  System.out.println(value);
 }
}
''';

class _ControlledCancellationRunner extends JavaProgramRunner {
  final started = Completer<void>();
  final _exit = Completer<int>();
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  int cancelCalls = 0;
  Future<void>? _exiting;

  Future<void> exit() => _exiting ??= _finish();

  Future<void> _finish() async {
    _exit.complete(137);
    await Future.wait([_stdout.close(), _stderr.close()]);
  }

  @override
  Future<JavaToolchainProcess?> startToolchainProcess({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
    String? inputFile,
  }) async {
    started.complete();
    return JavaToolchainProcess(
      title: 'controlled compiler',
      stdout: _stdout.stream,
      stderr: _stderr.stream,
      exitCode: _exit.future,
      cancel: () async {
        if (++cancelCalls == 1) {
          throw StateError('controlled worker cancellation failure');
        }
      },
    );
  }
}

class _LateDrainCancellationRunner extends JavaProgramRunner {
  final started = Completer<void>();
  final release = Completer<void>();
  final retryStarted = Completer<void>();
  final exit = Completer<int>();
  final stdout = StreamController<List<int>>();
  final stderr = StreamController<List<int>>();
  int cancelCalls = 0;

  @override
  Future<JavaToolchainProcess?> startToolchainProcess({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
    String? inputFile,
  }) async {
    started.complete();
    await release.future;
    return JavaToolchainProcess(
      title: 'late compiler with separate pipe EOF',
      stdout: stdout.stream,
      stderr: stderr.stream,
      exitCode: exit.future,
      cancel: () async {
        if (++cancelCalls == 1) {
          throw StateError('first late-start cancellation failed');
        }
        if (!retryStarted.isCompleted) retryStarted.complete();
      },
    );
  }
}

class _DelayedRunner extends JavaProgramRunner {
  final started = Completer<void>();
  final release = Completer<void>();
  bool _first = true;
  @override
  Future<JavaToolchainProcess?> startToolchainProcess({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
    String? inputFile,
  }) async {
    final process = await super.startToolchainProcess(
      workingDirectory: workingDirectory,
      arguments: arguments,
      isolatedEnvironment: isolatedEnvironment,
      inputFile: inputFile,
    );
    if (_first) {
      _first = false;
      started.complete();
      await release.future;
    }
    return process;
  }
}

class _CountingDebugger extends JavaDebugger {
  int launches = 0;
  @override
  JavaDebugSession launch({
    required String projectPath,
    required String entryFile,
    Map<String, String> unsavedBuffers = const {},
    List<JavaBreakpoint> breakpoints = const [],
    List<String> arguments = const [],
    List<String>? sourceFiles,
    bool stopOnEntry = false,
  }) {
    launches++;
    throw StateError('Validation must reject before launching any worker.');
  }
}

/// Real directories and real JVM workers, with only deletion of the backend's
/// own scratch directory faulted. This also exercises the unobserved automatic
/// stop path after actual target exit, rather than faking a completed session.
final class _FailCleanupOverrides extends IOOverrides {
  _FailCleanupOverrides(this.scratchPath, {required this.failures});
  final String scratchPath;
  final int failures;
  int attempts = 0;

  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    return p.equals(path, scratchPath)
        ? _FailCleanupDirectory(directory, this)
        : directory;
  }
}

class _FailCleanupDirectory extends Fake implements Directory {
  _FailCleanupDirectory(this.directory, this.cleanup);
  final Directory directory;
  final _FailCleanupOverrides cleanup;

  @override
  String get path => directory.path;

  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _FailCleanupDirectory(await directory.createTemp(prefix), cleanup);

  @override
  Future<bool> exists() => directory.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (++cleanup.attempts <= cleanup.failures) {
      throw FileSystemException('controlled cleanup failure', path);
    }
    return directory.delete(recursive: recursive);
  }
}
