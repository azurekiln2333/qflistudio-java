import 'dart:async';
import 'dart:io';

/// Shares one in-flight cancellation, but lets cleanup be retried after failure.
/// A termination request alone is not proof that the owned worker has exited.
Future<void> Function() javaProcessCancellation(
  Process process,
  Future<void> Function() requestTermination,
) {
  Future<void>? cancelling;
  Future<void> cancel() async {
    await requestTermination();
    await process.exitCode.timeout(const Duration(seconds: 5));
  }

  return () =>
      cancelling ??= cancel().catchError((Object error, StackTrace stack) {
        cancelling = null;
        Error.throwWithStackTrace(error, stack);
      });
}
