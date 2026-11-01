import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/ohos_jdk_process.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qfli_jvmx/jdk');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('qfli_jvm_transport_');
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    // The monitor removes its child directory after closing the output streams.
    // On Windows that can race recursive deletion of this fixture's parent.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        if (await home.exists()) await home.delete(recursive: true);
        return;
      } on PathNotFoundException {
        if (!await home.exists()) return;
        if (attempt == 9) rethrow;
      }
    }
  });

  test(
    'drains final output and preserves UTF-8 across partial writes',
    () async {
      late File output;
      late File error;
      int polls = 0;
      final bytes = utf8.encode('\u4f60\u597d');
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'start') {
          expect(args['args'], [
            'java',
            '-Djava.io.tmpdir=${p.join(home.path, 'tmp')}',
            '-version',
          ]);
          expect(Directory(p.join(home.path, 'tmp')).existsSync(), isTrue);
          expect(args['input'], '/dev/null');
          output = File(args['output'] as String)..writeAsBytesSync([]);
          error = File(args['error'] as String)..writeAsBytesSync([]);
          return 100;
        }
        if (++polls == 1) {
          output.writeAsBytesSync(bytes.take(1).toList());
          return null;
        }
        output.writeAsBytesSync(bytes.skip(1).toList(), mode: FileMode.append);
        error.writeAsStringSync('diagnostic\n');
        return 7;
      });
      final process = await OhosJdkProcess.start(
        home: home.path,
        libraryDirectory: home.path,
        arguments: ['-version'],
        workingDirectory: home.path,
      );
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      expect(await process.exitCode, 7);
      expect(await stdout, '\u4f60\u597d');
      expect(await stderr, 'diagnostic\n');
    },
  );

  test(
    'all JVM entry modes receive sandbox temp before caller options',
    () async {
      final invocations = <List<String>>[
        ['Main'],
        ['-m', 'jdk.compiler/com.sun.tools.javac.Main', '-version'],
        ['--add-modules', 'jdk.jdi', 'DebugHelper'],
        ['-Djava.io.tmpdir=/explicit/caller/value', 'Main'],
      ];
      var started = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        switch (call.method) {
          case 'start':
            expect(args['args'], [
              'java',
              '-Djava.io.tmpdir=${p.join(home.path, 'tmp')}',
              ...invocations[started++],
            ]);
            expect(Directory(p.join(home.path, 'tmp')).existsSync(), isTrue);
            File(args['output'] as String).writeAsStringSync('');
            File(args['error'] as String).writeAsStringSync('');
            return 100 + started;
          case 'poll':
            return 0;
          default:
            throw StateError(call.method);
        }
      });
      for (final arguments in invocations) {
        final process = await OhosJdkProcess.start(
          home: home.path,
          libraryDirectory: home.path,
          arguments: arguments,
          workingDirectory: home.path,
        );
        final stdout = process.stdout.drain<void>();
        final stderr = process.stderr.drain<void>();
        expect(await process.exitCode, 0);
        await Future.wait([stdout, stderr]);
      }
      expect(started, invocations.length);
    },
  );

  test('cancel waits for termination while output remains readable', () async {
    bool canceled = false;
    final input = File(p.join(home.path, 'input.txt'))
      ..writeAsStringSync('21\n');
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      switch (call.method) {
        case 'start':
          expect(args['input'], input.path);
          File(args['output'] as String).writeAsStringSync('running\n');
          File(args['error'] as String).writeAsStringSync('');
          return 101;
        case 'cancel':
          canceled = true;
          return null;
        case 'poll':
          return canceled ? 137 : null;
        default:
          throw StateError(call.method);
      }
    });
    final process = await OhosJdkProcess.start(
      home: home.path,
      libraryDirectory: home.path,
      arguments: ['Main'],
      workingDirectory: home.path,
      inputFile: input.path,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    await process.cancel();
    expect(await process.exitCode, 137);
    expect(await stdout, 'running\n');
    expect(await stderr, isEmpty);
  });

  for (final failedMethod in ['cancel', 'poll']) {
    test(
      'failed native $failedMethod retains ownership for a real exit retry',
      () async {
        final cleanupFailed = Completer<void>();
        final retryPolled = Completer<void>();
        late File output;
        late Directory child;
        var polls = 0;
        var cancellations = 0;
        var allowExit = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          if (call.method == 'start') {
            output = File(args['output'] as String)
              ..writeAsStringSync('before\n');
            File(
              args['error'] as String,
            ).writeAsStringSync('native diagnostic\n');
            child = output.parent;
            return 102;
          }
          expect(args['pid'], 102);
          switch (call.method) {
            case 'cancel':
              cancellations++;
              if (failedMethod == 'cancel' && cancellations <= 2) {
                if (!cleanupFailed.isCompleted) cleanupFailed.complete();
                throw PlatformException(code: 'CONTROLLED_CANCEL_FAILURE');
              }
              return null;
            case 'poll':
              polls++;
              if (polls == 1) {
                throw PlatformException(code: 'ORIGINAL_MONITOR_FAILURE');
              }
              if (failedMethod == 'poll' && cancellations <= 2) {
                if (!cleanupFailed.isCompleted) cleanupFailed.complete();
                throw PlatformException(
                  code: 'CONTROLLED_CLEANUP_POLL_FAILURE',
                );
              }
              if (!retryPolled.isCompleted) retryPolled.complete();
              if (!allowExit) return null;
              output.writeAsStringSync('after\n', mode: FileMode.append);
              return 137;
            default:
              throw StateError(call.method);
          }
        });
        final process = await OhosJdkProcess.start(
          home: home.path,
          libraryDirectory: home.path,
          arguments: ['Main'],
          workingDirectory: home.path,
        );
        var stdoutClosed = false;
        final stdout = process.stdout.transform(utf8.decoder).join().then((
          text,
        ) {
          stdoutClosed = true;
          return text;
        });
        stdout.ignore();
        final failures = <Object>[];
        final errorText = StringBuffer();
        final stderrClosed = Completer<void>();
        process.stderr
            .transform(utf8.decoder)
            .listen(
              errorText.write,
              onError: (Object failure) => failures.add(failure),
              onDone: stderrClosed.complete,
            );
        var exitObserved = false;
        unawaited(
          process.exitCode.then<void>(
            (_) => exitObserved = true,
            onError: (Object _) => exitObserved = true,
          ),
        );

        await cleanupFailed.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);
        expect(child.existsSync(), isTrue);
        expect(exitObserved, isFalse);
        expect(stdoutClosed, isFalse);
        expect(stderrClosed.isCompleted, isFalse);
        expect(failures, hasLength(1));
        expect(
          (failures.single as PlatformException).code,
          'ORIGINAL_MONITOR_FAILURE',
        );

        await expectLater(
          process.cancel(),
          throwsA(
            isA<PlatformException>().having(
              (failure) => failure.code,
              'code',
              failedMethod == 'cancel'
                  ? 'CONTROLLED_CANCEL_FAILURE'
                  : 'CONTROLLED_CLEANUP_POLL_FAILURE',
            ),
          ),
        );
        expect(cancellations, 2);
        expect(exitObserved, isFalse);
        expect(child.existsSync(), isTrue);
        expect(stderrClosed.isCompleted, isFalse);
        final retry = process.cancel();
        expect(identical(process.cancel(), retry), isTrue);
        await retryPolled.future.timeout(const Duration(seconds: 2));
        expect(cancellations, 3);
        expect(exitObserved, isFalse);
        expect(child.existsSync(), isTrue);
        allowExit = true;
        await retry.timeout(const Duration(seconds: 2));
        expect(await process.exitCode, 137);
        expect(await stdout, 'before\nafter\n');
        await stderrClosed.future;
        expect(errorText.toString(), 'native diagnostic\n');
        expect(failures, hasLength(1));
        expect(child.existsSync(), isFalse);
        await process.cancel();
        expect(cancellations, 3);
      },
    );
  }

  test(
    'native exit stays pending until retryable local cleanup succeeds',
    () async {
      final cleanup = _FailCleanupOverrides(p.join(home.path, 'tmp'));
      var polls = 0;
      var cancellations = 0;
      late Directory child;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        switch (call.method) {
          case 'start':
            final output = File(args['output'] as String)
              ..writeAsStringSync('finished\n');
            File(args['error'] as String).writeAsStringSync('');
            child = output.parent;
            return 103;
          case 'poll':
            polls++;
            return 23;
          case 'cancel':
            cancellations++;
            return null;
          default:
            throw StateError(call.method);
        }
      });
      await IOOverrides.runWithIOOverrides(() async {
        final process = await OhosJdkProcess.start(
          home: home.path,
          libraryDirectory: home.path,
          arguments: ['Main'],
          workingDirectory: home.path,
        );
        final stdout = process.stdout.transform(utf8.decoder).join();
        stdout.ignore();
        final failures = <Object>[];
        final stderrClosed = Completer<void>();
        process.stderr.listen(
          (_) {},
          onError: (Object failure) => failures.add(failure),
          onDone: stderrClosed.complete,
        );
        var exitObserved = false;
        unawaited(process.exitCode.then<void>((_) => exitObserved = true));
        await cleanup.failed.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);
        expect(exitObserved, isFalse);
        expect(child.existsSync(), isTrue);
        expect(stderrClosed.isCompleted, isFalse);
        await expectLater(
          process.cancel(),
          throwsA(isA<FileSystemException>()),
        );
        expect(exitObserved, isFalse);
        expect(child.existsSync(), isTrue);
        expect(cleanup.attempts, 2);

        await process.cancel();
        expect(await process.exitCode, 23);
        expect(await stdout, 'finished\n');
        await stderrClosed.future;
        expect(failures, hasLength(1));
        expect(
          (failures.single as FileSystemException).message,
          'controlled cleanup failure',
        );
        expect(child.existsSync(), isFalse);
        expect(cleanup.attempts, 3);
        expect(polls, 1);
        expect(cancellations, 0);
      }, cleanup);
    },
  );
}

final class _FailCleanupOverrides extends IOOverrides {
  _FailCleanupOverrides(this.temporaryPath);
  final String temporaryPath;
  final failed = Completer<void>();
  int attempts = 0;

  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    return p.equals(path, temporaryPath)
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
  Future<Directory> create({bool recursive = false}) async {
    await directory.create(recursive: recursive);
    return this;
  }

  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _FailCleanupDirectory(await directory.createTemp(prefix), cleanup);

  @override
  Future<bool> exists() => directory.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (++cleanup.attempts <= 2) {
      if (!cleanup.failed.isCompleted) cleanup.failed.complete();
      throw FileSystemException('controlled cleanup failure', path);
    }
    return directory.delete(recursive: recursive);
  }
}
