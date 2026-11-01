import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/src/java_process_cancellation.dart';

void main() {
  test(
    'a failed termination request can be retried against the owned process',
    () async {
      final process = _ControlledProcess()..failures = 1;
      final cancel = javaProcessCancellation(process, () async {
        process.kill(ProcessSignal.sigkill);
      });

      await expectLater(cancel(), throwsA(isA<ProcessException>()));
      expect(process.killCalls, 1);
      expect(process.terminated, isFalse);

      final retry = cancel();
      expect(process.killCalls, 2);
      var cancellationComplete = false;
      unawaited(retry.then((_) => cancellationComplete = true));
      await Future<void>.delayed(Duration.zero);
      expect(cancellationComplete, isFalse);
      process.exit(137);
      await retry;
      expect(cancellationComplete, isTrue);
      await cancel();
      expect(process.killCalls, 2);
    },
  );

  test('concurrent cancellation waits for one real terminal result', () async {
    final process = _ControlledProcess();
    final cancel = javaProcessCancellation(process, () async {
      process.kill(ProcessSignal.sigkill);
    });

    final first = cancel();
    final second = cancel();
    expect(identical(first, second), isTrue);
    expect(process.killCalls, 1);
    process.exit(137);
    await Future.wait([first, second]);
    expect(identical(cancel(), first), isTrue);
    expect(process.killCalls, 1);
  });

  testWidgets(
    'a timed-out cancellation can succeed after the same worker later exits',
    (tester) async {
      final process = _ControlledProcess();
      final cancel = javaProcessCancellation(process, () async {
        if (!process.terminated) process.kill(ProcessSignal.sigkill);
      });

      final first = cancel();
      final failed = expectLater(first, throwsA(isA<TimeoutException>()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await failed;
      expect(process.terminated, isFalse);
      expect(process.killCalls, 1);

      process.exit(137);
      await tester.pump();
      final retry = cancel();
      await tester.pump();
      await retry;
      expect(identical(first, retry), isFalse);
      expect(process.killCalls, 1);
    },
  );
}

class _ControlledProcess extends Fake implements Process {
  final _exit = Completer<int>();
  int failures = 0;
  int killCalls = 0;
  bool get terminated => _exit.isCompleted;

  void exit(int code) => _exit.complete(code);

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls++;
    if (failures > 0) {
      failures--;
      throw ProcessException(
        'owned-worker',
        const [],
        'controlled kill failure',
      );
    }
    return true;
  }
}
