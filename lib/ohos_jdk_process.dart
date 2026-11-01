import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'mobile_jvm_launch.dart';

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
  int? _nativeExit;
  Object? _monitorFailure;
  RandomAccessFile? _outputFile;
  RandomAccessFile? _errorFile;
  Future<void>? _monitoring;
  Future<void>? _cancelling;

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
    final launchArguments = await MobileJvmLaunch.arguments(
      home: home,
      arguments: arguments,
    );
    final directory = await Directory(
      MobileJvmLaunch.temporaryDirectory(home),
    ).createTemp('jvm-');
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
        'args': ['java', ...launchArguments],
      });
      if (pid == null) throw const FormatException('JVM child PID is missing');
      final process = OhosJdkProcess._(pid, directory);
      // A failed cleanup attempt retains the owned child for an explicit retry.
      unawaited(process._ensureMonitoring().catchError((Object _) {}));
      return process;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> cancel() =>
      _cancelling ??= _cancel().catchError((Object failure, StackTrace stack) {
        _cancelling = null;
        Error.throwWithStackTrace(failure, stack);
      });

  Future<void> _cancel() async {
    if (_running && _monitoring != null) {
      await _channel.invokeMethod<void>('cancel', {'pid': _pid});
    }
    await _ensureMonitoring().timeout(const Duration(seconds: 5));
    await exitCode;
  }

  Future<void> _ensureMonitoring() =>
      _monitoring ??= _monitor().catchError((Object failure, StackTrace stack) {
        _monitoring = null;
        Error.throwWithStackTrace(failure, stack);
      });

  void _reportFailure(Object failure, StackTrace stack) {
    if (_monitorFailure != null) return;
    _monitorFailure = failure;
    // Keep the original transport failure observable without turning a failed
    // poll/cancel into an invented terminal status for an unconfirmed child.
    _stderr.addError(failure, stack);
  }

  void _read(RandomAccessFile? file, StreamController<List<int>> stream) {
    if (file == null) return;
    while (true) {
      final bytes = file.readSync(65536);
      if (bytes.isEmpty) break;
      stream.add(bytes);
    }
  }

  Future<void> _poll() async {
    final code = await _channel.invokeMethod<int>('poll', {'pid': _pid});
    if (code != null) {
      _nativeExit = code;
      _running = false;
    }
  }

  Future<void> _monitor() async {
    if (_monitorFailure == null && _running) {
      try {
        _outputFile ??= await File(p.join(_directory.path, 'stdout')).open();
        _errorFile ??= await File(p.join(_directory.path, 'stderr')).open();
        while (true) {
          await _poll();
          _read(_outputFile, _stdout);
          _read(_errorFile, _stderr);
          if (!_running) break;
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      } catch (failure, stack) {
        _reportFailure(failure, stack);
      }
    }
    try {
      if (_running) {
        await _channel.invokeMethod<void>('cancel', {'pid': _pid});
        while (_running) {
          await _poll();
          if (!_running) break;
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
      try {
        _read(_outputFile, _stdout);
        _read(_errorFile, _stderr);
      } catch (failure, stack) {
        _reportFailure(failure, stack);
      }
      await _outputFile?.close();
      _outputFile = null;
      await _errorFile?.close();
      _errorFile = null;
      if (await _directory.exists()) await _directory.delete(recursive: true);
      unawaited(_stdout.close());
      unawaited(_stderr.close());
      _exit.complete(_nativeExit!);
    } catch (failure, stack) {
      _reportFailure(failure, stack);
      rethrow;
    }
  }
}
