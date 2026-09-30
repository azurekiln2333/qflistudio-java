import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Streams a native JVM child without executing an ELF launcher in the sandbox.
class OhosJdkProcess {
  OhosJdkProcess._(this._pid, this._directory);

  static const _channel = MethodChannel('qfli_jvmx/jdk');
  final int _pid;
  final Directory _directory;
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool _running = true;

  Stream<List<int>> get stdout => _stdout.stream;
  Stream<List<int>> get stderr => _stderr.stream;
  Future<int> get exitCode => _exit.future;

  static Future<OhosJdkProcess> start({
    required String home,
    required String libraryDirectory,
    required List<String> arguments,
    required String workingDirectory,
    String? inputFile,
  }) async {
    final directory = await Directory(p.join(home, 'tmp')).createTemp('jvm-');
    try {
      final input = inputFile != null && await File(inputFile).exists()
          ? inputFile
          : '/dev/null';
      final pid = await _channel.invokeMethod<int>('start', {
        'home': home,
        'libraries': libraryDirectory,
        'cwd': workingDirectory,
        'input': input,
        'output': p.join(directory.path, 'stdout'),
        'error': p.join(directory.path, 'stderr'),
        'args': ['java', ...arguments],
      });
      if (pid == null) throw const FormatException('JVM child PID is missing');
      final process = OhosJdkProcess._(pid, directory);
      unawaited(process._monitor());
      return process;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> cancel() async {
    if (_running) await _channel.invokeMethod<void>('cancel', {'pid': _pid});
    await exitCode;
  }

  Future<void> _monitor() async {
    RandomAccessFile? output;
    RandomAccessFile? error;
    try {
      output = await File(p.join(_directory.path, 'stdout')).open();
      error = await File(p.join(_directory.path, 'stderr')).open();
      void read(RandomAccessFile file, StreamController<List<int>> stream) {
        while (true) {
          final bytes = file.readSync(65536);
          if (bytes.isEmpty) break;
          stream.add(bytes);
        }
      }

      while (true) {
        final code = await _channel.invokeMethod<int>('poll', {'pid': _pid});
        if (code != null) _running = false;
        read(output, _stdout);
        read(error, _stderr);
        if (code != null) {
          _exit.complete(code);
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    } catch (failure, stack) {
      if (_running) {
        try {
          await _channel.invokeMethod<void>('cancel', {'pid': _pid});
          while (await _channel.invokeMethod<int>('poll', {'pid': _pid}) ==
              null) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        } on Exception {
          // Preserve the stream or process failure that triggered cleanup.
        }
      }
      _running = false;
      _exit.completeError(failure, stack);
    } finally {
      await output?.close();
      await error?.close();
      unawaited(_stdout.close());
      unawaited(_stderr.close());
      try {
        await _directory.delete(recursive: true);
      } on FileSystemException {
        // Cleanup must not replace the JVM exit code.
      }
    }
  }
}
