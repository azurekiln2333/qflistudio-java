import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qfli_java/java_debugger.dart';
import 'package:qfli_java/java_studio_debugger.dart';
import 'package:qfli_studio_core/services/code_analysis.dart';
import 'package:qfli_studio_core/services/debug_session.dart';

/// Reused by the real-runtime entry and host tests. It does not claim an OHOS
/// gate; the enclosing acceptance report supplies actual runtime/ABI identity.
Future<Map<String, Object?>> runJavaStudioDebugSmoke({
  required String temporaryDirectory,
}) async {
  final project = await Directory(
    temporaryDirectory,
  ).createTemp('java_editor_probe_');
  final scratch = await Directory(
    temporaryDirectory,
  ).createTemp('java_editor_jdi_');
  final sessions = <DebugSession>[];
  final observers = <JavaStudioObservation>[];
  final checks = <String, bool>{};
  final report = <String, Object?>{
    'kind': 'java-studio-debugger',
    'checks': checks,
    'ok': false,
    'cleanupConfirmed': false,
  };
  void require(String name, bool value) {
    checks[name] = value;
    if (!value) throw StateError('Java editor debug acceptance failed: $name');
  }

  try {
    final entry = File(p.join(project.path, 'Main.java'));
    final helper = File(p.join(project.path, 'Helper.java'));
    const savedMain = 'invalid saved main';
    const savedHelper = 'invalid saved helper';
    await entry.writeAsString(savedMain);
    await helper.writeAsString(savedHelper);
    final debugger = JavaStudioDebugger(
      debugger: JavaDebugger(
        temporaryDirectory: scratch.path,
        startupTimeout: const Duration(seconds: 90),
      ),
    );
    final session = await debugger.launch(
      DebugLaunchRequest(
        projectPath: project.path,
        entryFilePath: entry.path,
        language: 'Java',
        documents: [
          CodeDocumentSnapshot(
            path: entry.path,
            text: javaStudioProbeProgram.replaceAll('\n', '\r\n'),
            revision: 8,
          ),
          CodeDocumentSnapshot(
            path: helper.path,
            text:
                'package demo;\r\nclass Helper { static int value() { return 1; } }\r\n',
            revision: 12,
          ),
        ],
        breakpoints: [DebugBreakpoint(filePath: entry.path, line: 9)],
      ),
    );
    sessions.add(session);
    final observed = JavaStudioObservation(session);
    observers.add(observed);
    require(
      'promptStartingSession',
      session.snapshot.phase == DebugPhase.starting,
    );
    var pause = await observed.paused();
    final original = pause;
    final firstToken = pause.pauseToken!;
    require(
      'entryBreakpoint',
      pause.frames.first.location?.filePath == entry.path &&
          pause.frames.first.location?.line == 9 &&
          pause.breakpoints.single.status == DebugBreakpointStatus.verified,
    );
    require(
      'realThread',
      pause.frames.every(
            (frame) => pause.threads.any(
              (thread) => thread.id == frame.threadId && thread.isPaused,
            ),
          ) &&
          pause.threads.any((thread) => thread.name == 'main'),
    );
    require(
      'dirtyMultifileLocals',
      pause.frames.first.locals.any(
        (v) => v.name == 'counter' && v.value == '1',
      ),
    );
    var rejected = false;
    try {
      await session.command(
        DebugCommand.stepOver,
        pauseToken: firstToken,
        threadId: 'unknown-thread',
      );
    } on ArgumentError {
      rejected = true;
    }
    require(
      'unknownThreadRejected',
      rejected && session.snapshot.pauseToken == firstToken,
    );
    final points = [
      DebugBreakpoint(filePath: entry.path, line: 11),
      DebugBreakpoint(filePath: entry.path, line: 25),
      DebugBreakpoint(filePath: entry.path, line: 18),
      DebugBreakpoint(filePath: entry.path, line: 50),
    ];
    final replaced = await session.setBreakpoints(points);
    require(
      'atomicReplacement',
      replaced.length == 4 &&
          replaced.last.status == DebugBreakpointStatus.rejected &&
          replaced.last.reason!.contains('executable'),
    );
    rejected = false;
    try {
      await session.setBreakpoints([points.first, points.first]);
    } on ArgumentError {
      rejected = true;
    }
    require(
      'failedReplacementPreservesSet',
      rejected && session.snapshot.breakpoints.length == 4,
    );
    await session.command(DebugCommand.stepOver, pauseToken: firstToken);
    pause = await observed.paused(after: firstToken.generation);
    require(
      'stepOver',
      pause.frames.first.location?.line == 10 &&
          pause.frames.first.locals.any(
            (v) => v.name == 'counter' && v.value == '3',
          ),
    );
    require(
      'copiedLocals',
      original.frames.first.locals.any(
        (v) => v.name == 'counter' && v.value == '1',
      ),
    );
    rejected = false;
    try {
      await session.command(DebugCommand.resume, pauseToken: firstToken);
    } on StateError {
      rejected = true;
    }
    require(
      'staleTokenRejected',
      rejected && session.snapshot.pauseToken == pause.pauseToken,
    );
    var generation = pause.pauseToken!.generation;
    await session.command(DebugCommand.stepInto, pauseToken: pause.pauseToken);
    pause = await observed.paused(after: generation);
    require(
      'stepInto',
      pause.frames.first.location?.line == 4 &&
          pause.frames.length == 2 &&
          pause.frames.first.locals.any(
            (v) => v.name == 'value' && v.value == '3',
          ),
    );
    generation = pause.pauseToken!.generation;
    await session.command(DebugCommand.stepOver, pauseToken: pause.pauseToken);
    pause = await observed.paused(after: generation);
    require(
      'stepValue',
      pause.frames.first.location?.line == 5 &&
          pause.frames.first.locals.any(
            (v) => v.name == 'doubled' && v.value == '6',
          ),
    );
    generation = pause.pauseToken!.generation;
    await session.command(DebugCommand.stepOut, pauseToken: pause.pauseToken);
    pause = await observed.paused(after: generation);
    require('stepOut', pause.frames.first.name == 'demo.Main.main');
    if (pause.frames.first.location?.line != 11) {
      generation = pause.pauseToken!.generation;
      await session.command(DebugCommand.resume, pauseToken: pause.pauseToken);
      pause = await observed.paused(after: generation);
    }
    require('actualMainLocation', pause.frames.first.location?.line == 11);
    generation = pause.pauseToken!.generation;
    await session.command(DebugCommand.resume, pauseToken: pause.pauseToken);
    pause = await observed.paused(after: generation);
    require(
      'secondaryClassSourceBreakpoint',
      pause.frames.first.name == 'demo.Secondary.run' &&
          pause.frames.first.location?.filePath == entry.path &&
          pause.frames.first.location?.line == 25 &&
          pause.frames.first.locals.any(
            (v) => v.name == 'secondary' && v.value == '17',
          ),
    );
    require(
      'liveUnicodeOutput',
      pause.stdout.replaceAll('\r\n', '\n') == '😀中文:6\n' &&
          pause.stderr.isEmpty &&
          pause.console.isEmpty,
    );
    generation = pause.pauseToken!.generation;
    await session.command(DebugCommand.resume, pauseToken: pause.pauseToken);
    pause = await observed.paused(after: generation);
    require(
      'nestedClassSourceBreakpoint',
      pause.frames.first.name == r'demo.Main$Nested.run' &&
          pause.frames.first.location?.filePath == entry.path &&
          pause.frames.first.location?.line == 18 &&
          pause.frames.first.locals.any(
            (v) => v.name == 'nested' && v.value == '19',
          ),
    );
    await session.setBreakpoints([]);
    await session.command(DebugCommand.resume, pauseToken: pause.pauseToken);
    await session.done.timeout(const Duration(seconds: 45));
    require(
      'actualTargetExit',
      session.snapshot.phase == DebugPhase.terminated &&
          session.snapshot.exitCode == 0 &&
          session.snapshot.stdout.replaceAll('\r\n', '\n') ==
              '😀中文:6\nsecondary=17\nnested=19\n',
    );
    require(
      'revisionedOutput',
      observed.snapshots.indexed.every(
        (entry) =>
            entry.$1 == 0 ||
            entry.$2.revision > observed.snapshots[entry.$1 - 1].revision,
      ),
    );
    require(
      'sourcesUnchanged',
      await entry.readAsString() == savedMain &&
          await helper.readAsString() == savedHelper &&
          (await project.list(recursive: true).toList())
                  .whereType<File>()
                  .length ==
              2,
    );
    require('terminalAfterCleanup', await scratch.list().isEmpty);
    report['observedPauses'] = [
      for (final snapshot in observed.snapshots)
        if (snapshot.phase == DebugPhase.paused)
          {
            'generation': snapshot.pauseToken!.generation,
            'thread': snapshot.frames.first.threadId,
            'frame': snapshot.frames.first.name,
            'path': snapshot.frames.first.location?.filePath,
            'line': snapshot.frames.first.location?.line,
          },
    ];
    report['finalExitCode'] = session.snapshot.exitCode;
    report['ok'] = true;
  } catch (error, stack) {
    report.addAll({'error': '$error', 'stack': '$stack'});
  } finally {
    for (final session in sessions) {
      await session.dispose();
    }
    for (final observed in observers) {
      await observed.close();
    }
    report['cleanupConfirmed'] = await scratch.list().isEmpty;
    await scratch.delete(recursive: true);
    await project.delete(recursive: true);
    if (report['cleanupConfirmed'] != true) report['ok'] = false;
  }
  return report;
}

/// A subscribe-then-read observation: it cannot lose an already published pause.
class JavaStudioObservation {
  JavaStudioObservation(this.session) {
    _subscription = session.updates.listen((snapshot) {
      snapshots.add(snapshot);
      _changes.add(null);
    });
    snapshots.add(session.snapshot);
  }
  final DebugSession session;
  final snapshots = <DebugSnapshot>[];
  final _changes = StreamController<void>.broadcast();
  late final StreamSubscription<DebugSnapshot> _subscription;
  Future<DebugSnapshot> paused({int after = 0}) => until(
    (snapshot) =>
        snapshot.phase == DebugPhase.paused &&
        snapshot.pauseToken!.generation > after,
  );
  Future<DebugSnapshot> until(bool Function(DebugSnapshot) matches) async {
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      final state = session.snapshot;
      if (matches(state)) return state;
      if (state.isTerminal) {
        throw StateError(
          'Unexpected terminal debug state: ${state.phase.name}: ${state.message ?? ''}',
        );
      }
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('Java debugger observation timed out.');
      }
      await _changes.stream.first.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () {},
      );
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _changes.close();
  }
}

const javaStudioProbeProgram = '''package demo;
public class Main {
  static int twice(int value) {
    int doubled = value * 2;
    return doubled;
  }
  public static void main(String[] args) throws Exception {
    int counter = Helper.value();
    counter += 2;
    int answer = twice(counter);
    System.out.println("😀中文:" + answer);
    Secondary.run();
    new Nested().run();
  }
  static class Nested {
    void run() {
      int nested = 19;
      System.out.println("nested=" + nested);
    }
  }
}
class Secondary {
  static void run() {
    int secondary = 17;
    System.out.println("secondary=" + secondary);
  }
}
''';
