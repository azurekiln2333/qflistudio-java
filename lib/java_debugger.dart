import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'java_runner.dart';
import 'mobile_jdk.dart';

class JavaBreakpoint {
  const JavaBreakpoint({
    required this.id,
    this.className = '',
    this.sourceFile,
    required this.line,
  });
  final String id;

  /// Binary class name, including package and `$` for nested classes.
  final String className;

  /// Original absolute source path. The trusted helper maps compiler SourceFile
  /// attributes to this path, including secondary and nested binary classes.
  final String? sourceFile;
  final int line;
}

enum JavaDebugEventKind {
  attached,
  breakpoint,
  paused,
  resumed,
  output,
  error,
  terminated,
}

class JavaDebugLocation {
  const JavaDebugLocation({
    required this.className,
    required this.sourceName,
    required this.line,
    this.sourcePath,
  });
  final String className;
  final String sourceName;
  final int line;
  final String? sourcePath;
}

class JavaDebugVariable {
  const JavaDebugVariable({
    required this.name,
    required this.type,
    required this.value,
    this.unavailableReason,
    this.truncated = false,
  });
  final String name;
  final String type;

  /// Primitive/String value or reference identity, never a user toString call.
  final String value;
  final String? unavailableReason;
  final bool truncated;
}

class JavaDebugFrame {
  const JavaDebugFrame({
    required this.index,
    required this.method,
    required this.location,
    this.threadId = '',
  });
  final int index;
  final String method;
  final JavaDebugLocation location;
  final String threadId;
}

class JavaDebugThread {
  const JavaDebugThread(this.id, this.name, this.isPaused);
  final String id;
  final String name;
  final bool isPaused;
}

class JavaDebugThreads {
  JavaDebugThreads(List<JavaDebugThread> threads, this.truncated)
    : threads = List.unmodifiable(threads);
  final List<JavaDebugThread> threads;
  final bool truncated;
}

class JavaDebugStack {
  JavaDebugStack(List<JavaDebugFrame> frames, this.truncated)
    : frames = List.unmodifiable(frames);
  final List<JavaDebugFrame> frames;
  final bool truncated;
}

class JavaDebugVariables {
  JavaDebugVariables(
    List<JavaDebugVariable> variables, {
    this.truncated = false,
    this.unavailableReason,
  }) : variables = List.unmodifiable(variables);
  final List<JavaDebugVariable> variables;
  final bool truncated;
  final String? unavailableReason;
}

enum JavaDebugOutputOrigin { target, backend }

class JavaDebugVmInfo {
  const JavaDebugVmInfo({
    required this.name,
    required this.version,
    required this.description,
    required this.canPopFrames,
    required this.canForceEarlyReturn,
  });
  final String name;
  final String version;
  final String description;
  final bool canPopFrames;
  final bool canForceEarlyReturn;
}

class JavaDebugEvent {
  const JavaDebugEvent(
    this.kind, {
    this.message = '',
    this.location,
    this.breakpointId,
    this.verified = false,
    this.isErrorOutput = false,
    this.exitCode,
    this.threadId,
    this.threadName,
    this.outputOrigin = JavaDebugOutputOrigin.target,
    this.truncated = false,
  });
  final JavaDebugEventKind kind;
  final String message;
  final JavaDebugLocation? location;
  final String? breakpointId;
  final bool verified;
  final bool isErrorOutput;
  final int? exitCode;
  final String? threadId;
  final String? threadName;
  final JavaDebugOutputOrigin outputOrigin;
  final bool truncated;
}

/// Actual local JDI/JDWP backend. No UI availability claim is made here.
class JavaDebugger {
  const JavaDebugger({
    this.runner = const JavaProgramRunner(),
    this.startupTimeout = const Duration(seconds: 45),
    this.commandTimeout = const Duration(seconds: 10),
    this.sessionTimeout = const Duration(minutes: 20),
    this.maxOutputBytes = 1024 * 1024,
    this.temporaryDirectory,
  });
  final JavaProgramRunner runner;
  final Duration startupTimeout;
  final Duration commandTimeout;
  final Duration sessionTimeout;
  final int maxOutputBytes;
  final String? temporaryDirectory;

  /// Returns immediately so Stop is available during compilation and attach.
  JavaDebugSession launch({
    required String projectPath,
    required String entryFile,
    Map<String, String> unsavedBuffers = const {},
    List<JavaBreakpoint> breakpoints = const [],
    List<String> arguments = const [],
    List<String>? sourceFiles,
    bool stopOnEntry = false,
  }) => JavaDebugSession._(
    this,
    projectPath,
    entryFile,
    Map.of(unsavedBuffers),
    List.of(breakpoints),
    List.of(arguments),
    sourceFiles == null ? null : List.of(sourceFiles),
    stopOnEntry,
  );
}

class JavaDebugSession {
  JavaDebugSession._(
    this._debugger,
    this._projectPath,
    this._entryFile,
    this._buffers,
    this._breakpoints,
    this._arguments,
    this._sourceFiles,
    this._stopOnEntry,
  ) {
    _ready.future.ignore();
    _port.future.ignore();
    _initializing = Future<void>.microtask(_initialize);
  }

  final JavaDebugger _debugger;
  final String _projectPath;
  final String _entryFile;
  final Map<String, String> _buffers;
  final List<JavaBreakpoint> _breakpoints;
  final List<String> _arguments;
  final List<String>? _sourceFiles;
  final bool _stopOnEntry;
  final _events = StreamController<JavaDebugEvent>.broadcast();
  final _ready = Completer<void>();
  final _port = Completer<int>();
  final _done = Completer<int>();
  final _processes = <JavaToolchainProcess>{};
  final _lateStartDrains = <JavaToolchainProcess, Future<void>>{};
  final _pending = <int, _DebugReply>{};
  late final Future<void> _initializing;
  Directory? _directory;
  JavaToolchainProcess? _target;
  JavaToolchainProcess? _helper;
  Future<int>? _targetDone;
  Future<int>? _helperDone;
  Future<void>? _stoppingFuture;
  Timer? _lifetime;
  bool _stopping = false;
  bool _helperDisconnected = false;
  int _bytes = 0;
  int _sequence = 0;
  int? _targetExit;
  final _breakpointStates = <String, JavaDebugEvent>{};
  bool _stdoutTruncated = false;
  bool _stderrTruncated = false;
  bool _consoleTruncated = false;
  bool _cleanupConfirmed = false;
  String? _mainClass;
  JavaDebugVmInfo? _vmInfo;

  Stream<JavaDebugEvent> get events => _events.stream;
  Future<void> get ready => _ready.future;
  Future<int> get done => _done.future;
  JavaDebugVmInfo? get vmInfo => _vmInfo;
  int? get targetExitCode => _targetExit;
  bool get stdoutTruncated => _stdoutTruncated;
  bool get stderrTruncated => _stderrTruncated;
  bool get consoleTruncated => _consoleTruncated;
  bool get cleanupConfirmed => _cleanupConfirmed;
  bool get isStopping => _stopping && !_done.isCompleted;
  List<JavaDebugEvent> get breakpointResults =>
      List.unmodifiable(_breakpointStates.values);

  void _check() {
    if (_stopping) throw StateError('Debug session has stopped');
  }

  void _emit(JavaDebugEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _error(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    if (!_port.isCompleted) _port.completeError(error);
    _emit(JavaDebugEvent(JavaDebugEventKind.error, message: '$error'));
  }

  void _requestStop() {
    // Automatic stop has no caller to observe a cleanup failure. The failure
    // is emitted by _stop, while done and ownership stay pending for a retry.
    unawaited(stop().catchError((Object _) {}));
  }

  Stream<List<int>> _bounded(
    Stream<List<int>> stream, {
    bool backend = true,
    bool stderr = false,
  }) async* {
    var incomplete = <int>[];
    var dropped = false;
    await for (final bytes in stream) {
      final remaining = (_debugger.maxOutputBytes - _bytes).clamp(
        0,
        bytes.length,
      );
      _bytes += bytes.length;
      if (remaining > 0) {
        final payload = [...incomplete, ...bytes.take(remaining)];
        final end = _completeUtf8Prefix(payload);
        if (end > 0) yield payload.sublist(0, end);
        incomplete = payload.sublist(end);
      }
      if (remaining < bytes.length) {
        dropped = true;
        incomplete = [];
        if (backend) {
          _consoleTruncated = true;
        } else if (stderr) {
          _stderrTruncated = true;
        } else {
          _stdoutTruncated = true;
        }
        if (!_stopping) {
          _error(StateError('Java debug output exceeded the byte limit'));
          _requestStop();
        }
      }
    }
    // An actual malformed final sequence remains observable. Only a partial
    // codepoint omitted by our own byte cap is discarded rather than corrupted.
    if (!dropped && incomplete.isNotEmpty) yield incomplete;
  }

  static int _completeUtf8Prefix(List<int> bytes) {
    if (bytes.isEmpty) return 0;
    var start = bytes.length - 1;
    while (start > 0 &&
        bytes[start] & 0xc0 == 0x80 &&
        bytes.length - start < 4) {
      start--;
    }
    final lead = bytes[start];
    final length = lead >= 0xf0 && lead <= 0xf4
        ? 4
        : lead >= 0xe0 && lead <= 0xef
        ? 3
        : lead >= 0xc2 && lead <= 0xdf
        ? 2
        : 1;
    return bytes.length - start < length ? start : bytes.length;
  }

  Future<JavaToolchainProcess> _start(
    String directory,
    List<String> arguments, {
    String? inputFile,
  }) async {
    _check();
    final process = await _debugger.runner.startToolchainProcess(
      workingDirectory: directory,
      arguments: arguments,
      isolatedEnvironment: true,
      inputFile: inputFile,
    );
    if (process == null) throw StateError('Java toolchain is unavailable');
    _processes.add(process);
    if (_stopping) {
      // A Stop may arrive while the native bridge is starting this child.
      final stdout = process.stdout.drain<void>();
      final stderr = process.stderr.drain<void>();
      // A failed cancellation can unwind _start before either pipe reaches
      // EOF. Keep their joint owner for a later Stop retry; a reported stream
      // error still waits for the other pipe instead of poisoning that retry.
      final drained = Future.wait<void>([
        stdout,
        stderr,
      ]).then<void>((_) {}, onError: (Object error) => _error(error));
      drained.ignore();
      _lateStartDrains[process] = drained;
      try {
        await process.cancel();
      } catch (error) {
        _cleanupConfirmed = false;
        _error(StateError('Java debugger worker cleanup failed: $error'));
        rethrow;
      }
      await process.exitCode;
      await drained;
      _lateStartDrains.remove(process);
      _processes.remove(process);
      _check();
    }
    return process;
  }

  Future<void> _compile(String directory, List<String> arguments) async {
    final process = await _start(directory, [
      arguments.first,
      '-J-Dfile.encoding=UTF-8',
      '-J-Dstdout.encoding=UTF-8',
      '-J-Dstderr.encoding=UTF-8',
      '-J-Dsun.stdout.encoding=UTF-8',
      '-J-Dsun.stderr.encoding=UTF-8',
      '-J-Duser.language=en',
      '-J-Duser.country=US',
      ...arguments.skip(1),
    ]);
    final output = _bounded(
      process.stdout,
    ).transform(const Utf8Decoder(allowMalformed: true)).join();
    final error = _bounded(
      process.stderr,
    ).transform(const Utf8Decoder(allowMalformed: true)).join();
    // Native transport failures can reach a stream before the child is reaped.
    // Observe them immediately, then propagate them from the awaits below.
    output.ignore();
    error.ignore();
    final timer = Timer(_debugger.startupTimeout, () {
      _error(TimeoutException('Java debug compilation timed out'));
      _requestStop();
    });
    try {
      final code = await process.exitCode;
      final text = (await Future.wait<String>([output, error])).join();
      if (text.isNotEmpty) {
        _emit(
          JavaDebugEvent(
            JavaDebugEventKind.output,
            message: text,
            outputOrigin: JavaDebugOutputOrigin.backend,
          ),
        );
      }
      _check();
      if (code != 0) throw StateError('javac failed ($code): $text');
    } finally {
      timer.cancel();
      _processes.remove(process);
    }
  }

  Future<void> _initialize() async {
    try {
      _check();
      final project = p.normalize(p.absolute(_projectPath));
      final entry = p.normalize(
        p.isAbsolute(_entryFile) ? _entryFile : p.join(project, _entryFile),
      );
      if (!p.isWithin(project, entry) ||
          p.extension(entry).toLowerCase() != '.java') {
        throw ArgumentError('Java entry must belong to the project');
      }
      final buffers = <String, String>{};
      for (final buffer in _buffers.entries) {
        final path = p.normalize(
          p.isAbsolute(buffer.key) ? buffer.key : p.join(project, buffer.key),
        );
        if (!p.isWithin(project, path)) {
          throw ArgumentError('Unsaved file outside project');
        }
        if (p.extension(path).toLowerCase() == '.java') {
          buffers[path] = buffer.value;
        }
      }
      final sources = {
        ...?_sourceFiles,
        if (_sourceFiles == null)
          ...JavaProgramRunner.collectProjectJavaFiles(Directory(project)),
        ...buffers.keys,
      }.toList()..sort();
      if (!sources.contains(entry) || sources.length > 2000) {
        throw ArgumentError('Missing entry or too many Java sources');
      }
      for (final breakpoint in _breakpoints) {
        _validateBreakpoint(breakpoint);
        if (breakpoint.sourceFile != null &&
            !sources.contains(breakpoint.sourceFile)) {
          throw ArgumentError('Breakpoint source is not in this snapshot');
        }
      }
      if (_breakpoints.length > 200) {
        throw ArgumentError('Too many breakpoints');
      }
      final mobile = MobileJdk.isMobile
          ? p.join((await MobileJdk.prepare()).home, 'tmp')
          : null;
      _check();
      _directory = await Directory(
        _debugger.temporaryDirectory ?? mobile ?? Directory.systemTemp.path,
      ).createTemp('qfli_java_debug_');
      final root = _directory!.path;
      final classes = Directory(p.join(root, 'classes'));
      final helper = Directory(p.join(root, 'helper'));
      await classes.create();
      await helper.create();
      final copied = <String>[];
      final manifest = <String>[];
      var sourceBytes = 0;
      for (final path in sources) {
        _check();
        if (!p.isWithin(project, path) ||
            !p.equals(await File(path).resolveSymbolicLinks(), path)) {
          throw ArgumentError(
            'Java source must be physically owned by project',
          );
        }
        final buffer = buffers[path];
        sourceBytes += buffer == null
            ? await File(path).length()
            : utf8.encode(buffer).length;
        if (sourceBytes > 16 * 1024 * 1024) {
          throw StateError('Java source snapshot exceeded 16 MiB');
        }
        final text = buffer ?? await File(path).readAsString();
        final destination = File(
          p.join(root, 'sources', p.relative(path, from: project)),
        );
        await destination.parent.create(recursive: true);
        await destination.writeAsString(text);
        copied.add(destination.path);
        manifest.add('${_encode(path)}\t${_encode(destination.path)}');
      }
      final jars = <String>[];
      var jarBytes = 0;
      for (final jar in [
        ...JavaProgramRunner.collectProjectJars(
          Directory(p.join(project, 'lib')),
        ),
        ...JavaProgramRunner.collectProjectJars(
          Directory(p.join(project, 'libs')),
        ),
      ]) {
        _check();
        jarBytes += await File(jar).length();
        if (jarBytes > 128 * 1024 * 1024) {
          throw StateError('Java JAR snapshot exceeded 128 MiB');
        }
        final destination = p.join(root, 'jars', '${jars.length}.jar');
        await Directory(p.dirname(destination)).create(recursive: true);
        await File(jar).copy(destination);
        jars.add(destination);
      }
      final classpath = [
        classes.path,
        ...jars,
      ].join(Platform.isWindows ? ';' : ':');
      // An argsfile avoids the Windows command line limit for real projects.
      final argsFile = File(p.join(root, 'sources.args'));
      await argsFile.writeAsString(
        copied
            .map(
              (s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"',
            )
            .join('\n'),
      );
      await _compile(root, [
        'javac',
        '-J-Xms16m',
        '-J-Xmx256m',
        '-J-XX:+UseSerialGC',
        '--release',
        '17',
        '-g',
        '-proc:none',
        '-encoding',
        'UTF-8',
        '-classpath',
        classpath,
        '-d',
        classes.path,
        '@${argsFile.path}',
      ]);
      await File(
        p.join(root, 'sources.manifest'),
      ).writeAsString(manifest.join('\n'));
      await File(p.join(root, 'entry')).writeAsString(_encode(entry));
      await File(p.join(root, 'stop-on-entry')).writeAsString('$_stopOnEntry');
      final helperSource = File(p.join(helper.path, 'QfliJavaDebugger.java'));
      await helperSource.writeAsString(_jdiHelper);
      await _compile(root, [
        'javac',
        '-J-Xms16m',
        '-J-Xmx256m',
        '-J-XX:+UseSerialGC',
        '--release',
        '17',
        '--add-modules',
        'jdk.jdi,jdk.compiler',
        '-proc:none',
        '-encoding',
        'UTF-8',
        '-classpath',
        helper.path,
        '-d',
        helper.path,
        helperSource.path,
      ]);
      await File(
        p.join(root, 'breakpoints'),
      ).writeAsString(_breakpoints.map(_encodeBreakpoint).join('\n'));
      _helper = await _start(root, [
        'java',
        '-Xms16m',
        '-Xmx256m',
        '-XX:+UseSerialGC',
        '--add-modules',
        'jdk.jdi,jdk.compiler',
        '-classpath',
        helper.path,
        'QfliJavaDebugger',
        root,
      ]);
      _helperDone = _watch(_helper!, helper: true);
      _helperDone!.then(
        (code) {
          if (!_stopping && !_helperDisconnected) {
            _error(StateError('JDI helper exited ($code)'));
            _requestStop();
          }
        },
        onError: (Object e) {
          if (!_stopping) {
            _error(e);
            _requestStop();
          }
        },
      );
      final port = await _port.future.timeout(_debugger.startupTimeout);
      _check();
      final mainClass = _mainClass;
      if (mainClass == null) {
        throw StateError('JDI source entry mapping missing');
      }
      _target = await _start(project, [
        'java',
        '-Xms16m',
        '-Xmx256m',
        '-XX:+UseSerialGC',
        '-Dfile.encoding=UTF-8',
        '-Dstdout.encoding=UTF-8',
        '-Dstderr.encoding=UTF-8',
        '-Dsun.stdout.encoding=UTF-8',
        '-Dsun.stderr.encoding=UTF-8',
        '-agentlib:jdwp=transport=dt_socket,server=n,suspend=y,address=127.0.0.1:$port,timeout=${_debugger.startupTimeout.inMilliseconds.clamp(1, 120000)}',
        '-classpath',
        classpath,
        mainClass,
        ..._arguments,
      ], inputFile: p.join(project, 'input.txt'));
      _targetDone = _watch(_target!, helper: false);
      _targetDone!.then(
        (code) {
          _targetExit = code;
          if (!_stopping) _requestStop();
        },
        onError: (Object e) {
          if (!_stopping) {
            _error(e);
            _requestStop();
          }
        },
      );
      await ready.timeout(_debugger.startupTimeout);
      _check();
      _lifetime = Timer(_debugger.sessionTimeout, () {
        _error(TimeoutException('Java debug session timed out'));
        _requestStop();
      });
    } catch (error) {
      if (!_stopping) _error(error);
      _requestStop();
    }
  }

  Future<int> _watch(
    JavaToolchainProcess process, {
    required bool helper,
  }) async {
    final stdout = helper
        ? _bounded(process.stdout)
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .forEach(_decode)
        : _bounded(process.stdout, backend: false)
              .transform(const Utf8Decoder(allowMalformed: true))
              .forEach(
                (text) => _emit(
                  JavaDebugEvent(JavaDebugEventKind.output, message: text),
                ),
              );
    final stderr = _bounded(process.stderr, backend: helper, stderr: true)
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(
          (text) => _emit(
            JavaDebugEvent(
              JavaDebugEventKind.output,
              message: text,
              isErrorOutput: true,
              outputOrigin: helper
                  ? JavaDebugOutputOrigin.backend
                  : JavaDebugOutputOrigin.target,
            ),
          ),
        );
    final values = await Future.wait<Object?>([
      process.exitCode,
      stdout,
      stderr,
    ]);
    _processes.remove(process);
    return values[0] as int;
  }

  void _decode(String line) {
    try {
      final fields = line.split('\t');
      if (fields.length < 2 || fields[0] != 'DBG') {
        throw const FormatException('Unexpected JDI helper output');
      }
      switch (fields[1]) {
        case 'ENTRY':
          _mainClass = _decodeField(fields[2]);
        case 'READY':
          final port = int.parse(fields[2]);
          if (port < 1 || port > 65535 || _port.isCompleted) {
            throw const FormatException('Invalid debug listener');
          }
          _port.complete(port);
        case 'ATTACHED':
          if (!_ready.isCompleted) _ready.complete();
          _emit(const JavaDebugEvent(JavaDebugEventKind.attached));
        case 'VM':
          _vmInfo = JavaDebugVmInfo(
            name: _decodeField(fields[2]),
            version: _decodeField(fields[3]),
            description: _decodeField(fields[4]),
            canPopFrames: fields[5] == 'true',
            canForceEarlyReturn: fields[6] == 'true',
          );
        case 'BREAKPOINT':
          final event = JavaDebugEvent(
            JavaDebugEventKind.breakpoint,
            breakpointId: _decodeField(fields[2]),
            verified: fields[3] == 'verified',
            message: fields[3],
            location: fields[3] == 'verified' ? _location(fields, 4) : null,
          );
          _breakpointStates[event.breakpointId!] = event;
          _emit(event);
        case 'REPLACED':
          _breakpointStates.clear();
        case 'PAUSED':
          _emit(
            JavaDebugEvent(
              JavaDebugEventKind.paused,
              message: fields[2],
              location: _location(fields, 3),
              threadId: fields[7],
              threadName: _decodeField(fields[8]),
            ),
          );
        case 'RESUMED':
          _emit(const JavaDebugEvent(JavaDebugEventKind.resumed));
        case 'VAR':
          _pending[int.parse(fields[2])]?.variables.add(
            JavaDebugVariable(
              name: _decodeField(fields[3]),
              type: _decodeField(fields[4]),
              value: _decodeField(fields[5]),
              truncated: fields[6] == 'true',
              unavailableReason: fields[7].isEmpty
                  ? null
                  : _decodeField(fields[7]),
            ),
          );
        case 'VARS':
          final reply = _pending[int.parse(fields[2])];
          reply?.variablesTruncated = fields[3] == 'true';
          reply?.variablesUnavailableReason = fields[4].isEmpty
              ? null
              : _decodeField(fields[4]);
        case 'FRAME':
          _pending[int.parse(fields[2])]?.frames.add(
            JavaDebugFrame(
              index: int.parse(fields[3]),
              method: _decodeField(fields[5]),
              location: JavaDebugLocation(
                className: _decodeField(fields[4]),
                sourceName: _decodeField(fields[6]),
                line: int.parse(fields[7]),
                sourcePath: fields[8].isEmpty ? null : _decodeField(fields[8]),
              ),
              threadId: fields[9],
            ),
          );
        case 'STACK':
          _pending[int.parse(fields[2])]?.framesTruncated = fields[3] == 'true';
        case 'THREAD':
          _pending[int.parse(fields[2])]?.threads.add(
            JavaDebugThread(
              fields[3],
              _decodeField(fields[4]),
              fields[5] == 'true',
            ),
          );
        case 'THREADS':
          _pending[int.parse(fields[2])]?.threadsTruncated =
              fields[3] == 'true';
        case 'DONE':
          final reply = _pending.remove(int.parse(fields[2]));
          if (reply != null && !reply.done.isCompleted) {
            reply.done.complete(reply);
          }
        case 'ERROR':
          final reply = _pending.remove(int.parse(fields[2]));
          final error = StateError(_decodeField(fields[3]));
          if (reply != null) {
            reply.done.completeError(error);
          } else {
            _error(error);
          }
        case 'DISCONNECTED':
          _helperDisconnected = true;
          break; // Target process exit, rather than a protocol guess, closes it.
        default:
          throw const FormatException('Unknown JDI helper event');
      }
    } catch (error) {
      _error(error);
      _requestStop();
    }
  }

  static void _validateBreakpoint(JavaBreakpoint breakpoint) {
    if (breakpoint.id.isEmpty ||
        breakpoint.id.length > 200 ||
        breakpoint.line < 1 ||
        (breakpoint.sourceFile == null &&
            !RegExp(
              r'^[\w$\u0080-\uFFFF]+(?:\.[\w$\u0080-\uFFFF]+)*$',
            ).hasMatch(breakpoint.className)) ||
        (breakpoint.sourceFile != null &&
            (!p.isAbsolute(breakpoint.sourceFile!) ||
                breakpoint.className.isNotEmpty))) {
      throw ArgumentError('Invalid Java breakpoint');
    }
  }

  static JavaDebugLocation _location(List<String> fields, int start) =>
      JavaDebugLocation(
        className: _decodeField(fields[start]),
        sourceName: _decodeField(fields[start + 1]),
        line: int.parse(fields[start + 2]),
        sourcePath: fields[start + 3].isEmpty
            ? null
            : _decodeField(fields[start + 3]),
      );

  Future<_DebugReply> _command(
    String operation, [
    List<String> fields = const [],
  ]) async {
    await ready;
    _check();
    final id = ++_sequence;
    final reply = _DebugReply();
    _pending[id] = reply;
    try {
      final command = File(p.join(_directory!.path, '$id.cmd.part'));
      await command.writeAsString(
        [id.toString(), operation, ...fields].join('\t'),
      );
      await command.rename(p.join(_directory!.path, '$id.cmd'));
      return await reply.done.future.timeout(
        _debugger.commandTimeout,
        onTimeout: () {
          _requestStop();
          throw TimeoutException('JDI command $operation timed out');
        },
      );
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> setBreakpoint(JavaBreakpoint breakpoint) async {
    _validateBreakpoint(breakpoint);
    await _command('breakpoint', [_encodeBreakpoint(breakpoint)]);
  }

  /// One helper command constructs every replacement request while the VM is
  /// paused, then commits the set. A failed construction retains the old set.
  Future<List<JavaDebugEvent>> replaceBreakpoints(
    List<JavaBreakpoint> points,
  ) async {
    if (points.length > 200 ||
        points.map((b) => b.id).toSet().length != points.length) {
      throw ArgumentError('Too many or duplicate Java breakpoints');
    }
    for (final point in points) {
      _validateBreakpoint(point);
    }
    await _command('replace', [
      '${points.length}',
      ...points.map(_encodeBreakpoint),
    ]);
    return breakpointResults;
  }

  Future<void> removeBreakpoint(String id) async {
    await _command('remove', [_encode(id)]);
    _breakpointStates.remove(id);
  }

  Future<void> resume() async {
    await _command('resume');
  }

  Future<void> pause() async {
    await _command('pause');
  }

  Future<void> stepOver() async {
    await _command('over');
  }

  Future<void> stepInto() async {
    await _command('into');
  }

  Future<void> stepOut() async {
    await _command('out');
  }

  Future<JavaDebugVariables> variableSnapshot({
    int frame = 0,
    int limit = 200,
  }) async {
    if (frame < 0 || frame > 31) throw ArgumentError('Invalid frame');
    if (limit < 0 || limit > 200) throw ArgumentError('Invalid variable limit');
    final reply = await _command('variables', ['$frame', '$limit']);
    return JavaDebugVariables(
      reply.variables,
      truncated: reply.variablesTruncated,
      unavailableReason: reply.variablesUnavailableReason,
    );
  }

  Future<List<JavaDebugVariable>> variables({int frame = 0}) async {
    final snapshot = await variableSnapshot(frame: frame);
    if (snapshot.unavailableReason != null) {
      throw StateError(snapshot.unavailableReason!);
    }
    return snapshot.variables;
  }

  Future<JavaDebugStack> stackSnapshot() async {
    final reply = await _command('stack');
    return JavaDebugStack(reply.frames, reply.framesTruncated);
  }

  Future<JavaDebugThreads> threadSnapshot() async {
    final reply = await _command('threads');
    return JavaDebugThreads(reply.threads, reply.threadsTruncated);
  }

  Future<List<JavaDebugFrame>> stackTrace() async =>
      (await stackSnapshot()).frames;
  Future<void> terminate() async {
    await _command('terminate');
    await done.timeout(_debugger.commandTimeout);
  }

  Future<void> stop() =>
      _stoppingFuture ??= _stop().catchError((Object error, StackTrace stack) {
        _stoppingFuture = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _stop() async {
    _stopping = true;
    _lifetime?.cancel();
    if (!_ready.isCompleted) {
      _ready.completeError(
        StateError('Java debug session stopped before attach'),
      );
    }
    if (!_port.isCompleted) {
      _port.completeError(
        StateError('Java debug session stopped before listening'),
      );
    }
    for (final reply in _pending.values) {
      if (!reply.done.isCompleted) {
        reply.done.completeError(StateError('Java debug session stopped'));
      }
    }
    _pending.clear();
    Future<void> cancel(JavaToolchainProcess? process) async {
      if (process == null) return;
      try {
        await process.cancel();
        // A cancellation acknowledgement alone does not prove worker exit,
        // especially for a child returned after Stop began during native start.
        await process.exitCode;
        final drained = _lateStartDrains[process];
        if (drained != null) {
          await drained;
          _lateStartDrains.remove(process);
          _processes.remove(process);
        }
      } catch (error) {
        _cleanupConfirmed = false;
        _error(StateError('Java debugger worker cleanup failed: $error'));
        // Retain the scratch state and runtime lane so the caller can retry.
        rethrow;
      }
    }

    await cancel(_target);
    for (final process in _processes.toList()) {
      if (!identical(process, _helper)) await cancel(process);
    }
    await cancel(_helper);
    await _initializing;
    // Native starts may have completed while the first cancellation ran.
    await cancel(_target);
    for (final process in _processes.toList()) {
      await cancel(process);
    }
    try {
      if (_targetDone != null) _targetExit = await _targetDone!;
    } catch (_) {
      /* Already reported. */
    }
    try {
      await _helperDone;
    } catch (_) {
      /* Already reported. */
    }
    try {
      if (_directory != null && await _directory!.exists()) {
        await _directory!.delete(recursive: true);
      }
      _cleanupConfirmed = _directory == null || !await _directory!.exists();
      if (!_cleanupConfirmed) {
        throw FileSystemException(
          'Java debugger scratch directory still exists',
          _directory?.path,
        );
      }
    } catch (error) {
      _cleanupConfirmed = false;
      _error(StateError('Java debugger scratch cleanup failed: $error'));
      // Keep the event stream and done open. Callers must retain the runtime
      // lane and can retry stop after the actual cleanup error is resolved.
      rethrow;
    }
    _emit(JavaDebugEvent(JavaDebugEventKind.terminated, exitCode: _targetExit));
    if (!_done.isCompleted) _done.complete(_targetExit ?? -1);
    unawaited(_events.close());
  }
}

class _DebugReply {
  _DebugReply() {
    done.future.ignore();
  }
  final done = Completer<_DebugReply>();
  final variables = <JavaDebugVariable>[];
  final frames = <JavaDebugFrame>[];
  final threads = <JavaDebugThread>[];
  bool variablesTruncated = false;
  String? variablesUnavailableReason;
  bool framesTruncated = false;
  bool threadsTruncated = false;
}

String _encode(String text) => base64.encode(utf8.encode(text));
String _decodeField(String text) => utf8.decode(base64.decode(text));
String _encodeBreakpoint(JavaBreakpoint point) =>
    '${_encode(point.id)}\t${point.sourceFile == null ? 'class' : 'source'}\t'
    '${_encode(point.sourceFile ?? point.className)}\t${point.line}';

const _jdiHelper = r'''

import com.sun.jdi.*;
import com.sun.jdi.connect.*;
import com.sun.jdi.event.*;
import com.sun.jdi.request.*;
import com.sun.source.tree.CompilationUnitTree;
import com.sun.source.util.JavacTask;
import javax.tools.*;
import java.nio.charset.StandardCharsets;
import java.nio.ByteOrder;
import java.nio.file.*;
import java.io.*;
import java.util.*;
import java.util.stream.*;

public final class QfliJavaDebugger {
  final Path root;
  final PrintWriter out = new PrintWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8), true);
  final Map<String, Spec> specs = new LinkedHashMap<>();
  final Map<String, String> sourceByClass = new HashMap<>();
  final Map<String, ClassData> classes = new HashMap<>();
  final Set<String> sources = new HashSet<>();
  VirtualMachine vm;
  ThreadReference paused;
  EventSet held;
  MethodEntryRequest entryRequest;
  String entryClass;
  int next = 1;
  static final class Spec {
    final String id, kind, target; final int line;
    final Set<String> types = new HashSet<>();
    final List<BreakpointRequest> requests = new ArrayList<>();
    final Set<ReferenceType> installed = new HashSet<>();
    final List<Location> locations = new ArrayList<>();
    Spec(String id, String kind, String target, int line) {
      this.id=id; this.kind=kind; this.target=target; this.line=line;
    }
  }
  static final class ClassData {
    String name, source;
    final Set<Integer> lines = new HashSet<>();
  }
  static final class SafeText {
    final String text, unavailable; final boolean truncated;
    SafeText(String text, boolean truncated, String unavailable) {
      this.text=text; this.truncated=truncated; this.unavailable=unavailable;
    }
  }
  QfliJavaDebugger(Path root) { this.root=root; }
  static String enc(String s) { return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8)); }
  static String dec(String s) { return new String(Base64.getDecoder().decode(s), StandardCharsets.UTF_8); }
  static String bounded(String s, int limit) {
    if (s.length()<=limit) return s;
    int end=limit;
    if (end>0 && Character.isHighSurrogate(s.charAt(end-1))) end--;
    return s.substring(0,end);
  }
  void emit(String text) { out.println("DBG\t"+text); }
  // Read javac's emitted SourceFile and LineNumberTable attributes, rather than
  // guessing a binary name from a source basename or relocating a requested line.
  static ClassData readClass(Path file) throws IOException {
    try (DataInputStream in=new DataInputStream(Files.newInputStream(file))) {
      if (in.readInt()!=0xcafebabe) throw new IOException("Invalid compiled class");
      in.readUnsignedShort(); in.readUnsignedShort();
      Object[] cp=new Object[in.readUnsignedShort()];
      for (int i=1;i<cp.length;i++) {
        int tag=in.readUnsignedByte();
        switch (tag) {
          case 1: cp[i]=in.readUTF(); break;
          case 7: cp[i]=in.readUnsignedShort(); break;
          case 3: case 4: case 9: case 10: case 11: case 12: case 17: case 18: in.skipNBytes(4); break;
          case 5: case 6: in.skipNBytes(8); i++; break;
          case 8: case 16: case 19: case 20: in.skipNBytes(2); break;
          case 15: in.skipNBytes(3); break;
          default: throw new IOException("Unknown class constant "+tag);
        }
      }
      ClassData data=new ClassData();
      in.readUnsignedShort();
      data.name=((String)cp[(Integer)cp[in.readUnsignedShort()]]).replace('/','.');
      in.readUnsignedShort();
      in.skipNBytes(2L*in.readUnsignedShort());
      int fields=in.readUnsignedShort();
      for (int i=0;i<fields;i++) {
        in.skipNBytes(6);
        for (int a=in.readUnsignedShort();a>0;a--) { in.readUnsignedShort(); in.skipNBytes(Integer.toUnsignedLong(in.readInt())); }
      }
      int methods=in.readUnsignedShort();
      for (int i=0;i<methods;i++) {
        in.skipNBytes(6);
        for (int a=in.readUnsignedShort();a>0;a--) {
          String name=(String)cp[in.readUnsignedShort()];
          long length=Integer.toUnsignedLong(in.readInt());
          if (!name.equals("Code")) { in.skipNBytes(length); continue; }
          in.skipNBytes(4);
          in.skipNBytes(Integer.toUnsignedLong(in.readInt()));
          in.skipNBytes(8L*in.readUnsignedShort());
          for (int n=in.readUnsignedShort();n>0;n--) {
            String attr=(String)cp[in.readUnsignedShort()];
            long size=Integer.toUnsignedLong(in.readInt());
            if (attr.equals("LineNumberTable")) {
              int entries=in.readUnsignedShort();
              for (int e=0;e<entries;e++) { in.readUnsignedShort(); data.lines.add(in.readUnsignedShort()); }
            } else in.skipNBytes(size);
          }
        }
      }
      for (int n=in.readUnsignedShort();n>0;n--) {
        String attr=(String)cp[in.readUnsignedShort()];
        long size=Integer.toUnsignedLong(in.readInt());
        if (attr.equals("SourceFile") && size==2) data.source=(String)cp[in.readUnsignedShort()];
        else in.skipNBytes(size);
      }
      return data;
    }
  }
  void indexSources() throws Exception {
    Map<String,String> originalByCopy=new HashMap<>(), originalByKey=new HashMap<>();
    List<File> copies=new ArrayList<>();
    for (String line: Files.readAllLines(root.resolve("sources.manifest"),StandardCharsets.UTF_8)) {
      String[] f=line.split("\t",-1);
      String original=dec(f[0]), copy=dec(f[1]);
      originalByCopy.put(Path.of(copy).toUri().toString(),original); copies.add(new File(copy)); sources.add(original);
    }
    String entry=dec(Files.readString(root.resolve("entry"),StandardCharsets.UTF_8));
    JavaCompiler compiler=ToolProvider.getSystemJavaCompiler();
    if (compiler==null) throw new IllegalStateException("JDK source indexer unavailable");
    try (StandardJavaFileManager manager=compiler.getStandardFileManager(null,null,StandardCharsets.UTF_8)) {
      JavacTask task=(JavacTask)compiler.getTask(new StringWriter(),manager,null,List.of("-proc:none"),null,manager.getJavaFileObjectsFromFiles(copies));
      for (CompilationUnitTree unit: task.parse()) {
        String original=originalByCopy.get(unit.getSourceFile().toUri().toString());
        if (original==null) throw new IllegalStateException("Unknown compiler source URI");
        String name=Path.of(original).getFileName().toString();
        String pkg=unit.getPackageName()==null ? "" : unit.getPackageName().toString();
        String key=pkg+"/"+name;
        if (originalByKey.put(key,original)!=null) throw new IllegalArgumentException("Ambiguous SourceFile identity: "+key);
        if (original.equals(entry)) entryClass=(pkg.isEmpty()?"":pkg+".")+name.substring(0,name.length()-5);
      }
    }
    try (Stream<Path> files=Files.walk(root.resolve("classes"))) {
      for (Path file: files.filter(f->f.toString().endsWith(".class")).collect(Collectors.toList())) {
        ClassData data=readClass(file); classes.put(data.name,data);
        int dot=data.name.lastIndexOf('.');
        String pkg=dot<0?"":data.name.substring(0,dot);
        String original=originalByKey.get(pkg+"/"+data.source);
        if (original!=null) sourceByClass.put(data.name,original);
      }
    }
    if (entryClass==null || !classes.containsKey(entryClass)) throw new IllegalArgumentException("Entry file has no matching compiled class");
    emit("ENTRY\t"+enc(entryClass));
  }
  Spec parseSpec(String[] f, int offset) {
    Spec spec=new Spec(dec(f[offset]),f[offset+1],dec(f[offset+2]),Integer.parseInt(f[offset+3]));
    if (spec.id.isEmpty() || spec.id.length()>200 || spec.line<1) throw new IllegalArgumentException("Invalid breakpoint");
    if (spec.kind.equals("source")) {
      if (!sources.contains(spec.target)) throw new IllegalArgumentException("Unknown breakpoint source");
      for (ClassData data: classes.values()) {
        if (spec.target.equals(sourceByClass.get(data.name)) && data.lines.contains(spec.line)) spec.types.add(data.name);
      }
    } else if (spec.kind.equals("class")) spec.types.add(spec.target);
    else throw new IllegalArgumentException("Unknown breakpoint kind");
    return spec;
  }
  String source(Location l) { try { return l.sourceName(); } catch (AbsentInformationException e) { return ""; } }
  String location(Location l) {
    String path=sourceByClass.get(l.declaringType().name());
    return enc(l.declaringType().name())+"\t"+enc(source(l))+"\t"+l.lineNumber()+"\t"+(path==null?"":enc(path));
  }
  void breakpointState(Spec spec) {
    String state=!spec.locations.isEmpty()?"verified":spec.types.isEmpty() || (!spec.installed.isEmpty() && spec.kind.equals("class"))?"no-executable-code":"pending-class";
    emit("BREAKPOINT\t"+enc(spec.id)+"\t"+state+(spec.locations.isEmpty()?"":("\t"+location(spec.locations.get(0)))));
  }
  void install(Spec spec, ReferenceType type, boolean enable) throws Exception {
    if (!spec.types.contains(type.name()) || !type.isPrepared() || !spec.installed.add(type)) return;
    List<Location> locations;
    try { locations=type.locationsOfLine(spec.line); } catch (AbsentInformationException e) { locations=List.of(); }
    for (Location location: locations) {
      BreakpointRequest r=vm.eventRequestManager().createBreakpointRequest(location);
      r.setSuspendPolicy(EventRequest.SUSPEND_ALL); spec.requests.add(r);
      spec.locations.add(location);
      if (enable) r.enable();
    }
  }
  void delete(Spec spec) { vm.eventRequestManager().deleteEventRequests(spec.requests); }
  void replace(List<Spec> replacements, boolean requirePause) throws Exception {
    if (requirePause && paused==null) throw new IllegalStateException("Breakpoint replacement requires a paused target");
    if (replacements.size()>200) throw new IllegalArgumentException("Too many breakpoints");
    Set<String> ids=new HashSet<>();
    for (Spec spec: replacements) if (!ids.add(spec.id)) throw new IllegalArgumentException("Duplicate breakpoint id");
    try {
      List<ReferenceType> loaded=vm.allClasses();
      for (Spec spec: replacements) for (ReferenceType type: loaded) install(spec,type,false);
      // All target threads are suspended while new requests are enabled. If any
      // construction/enable fails, old requests remain and every new one is deleted.
      for (Spec spec: replacements) for (BreakpointRequest request: spec.requests) request.enable();
    } catch (Exception e) {
      for (Spec spec: replacements) delete(spec);
      throw e;
    }
    for (Spec old: specs.values()) delete(old);
    specs.clear();
    for (Spec spec: replacements) specs.put(spec.id,spec);
    emit("REPLACED");
    for (Spec spec: replacements) breakpointState(spec);
  }
  void add(Spec spec) throws Exception {
    if (specs.size()>=200 && !specs.containsKey(spec.id)) throw new IllegalStateException("Too many breakpoints");
    try { for (ReferenceType type: vm.allClasses()) install(spec,type,true); }
    catch (Exception e) { delete(spec); throw e; }
    remove(spec.id); specs.put(spec.id,spec); breakpointState(spec);
  }
  void remove(String id) { Spec previous=specs.remove(id); if (previous!=null) delete(previous); }
  void pauseAt(ThreadReference thread, EventSet set, String reason) throws Exception {
    paused=thread; held=set;
    emit("PAUSED\t"+reason+"\t"+location(thread.frame(0).location())+"\t"+thread.uniqueID()+"\t"+enc(threadName(thread).text));
  }
  void clearSteps() {
    vm.eventRequestManager().deleteEventRequests(new ArrayList<>(vm.eventRequestManager().stepRequests()));
  }
  void resume() {
    if (paused==null) throw new IllegalStateException("Target is not paused");
    clearSteps(); resumeHeld();
  }
  void resumeHeld() {
    EventSet set=held; held=null; paused=null;
    if (set!=null) set.resume(); else vm.resume();
    emit("RESUMED");
  }
  void step(int depth) {
    if (paused==null) throw new IllegalStateException("Target is not paused");
    clearSteps();
    StepRequest request=vm.eventRequestManager().createStepRequest(paused,StepRequest.STEP_LINE,depth);
    request.addCountFilter(1);
    // Exclude only classes outside this compilation. User packages resembling
    // platform namespaces must retain real step behavior.
    for (String filter: List.of("java.*","javax.*","jdk.*","sun.*","com.sun.*")) {
      boolean owned=false;
      String prefix=filter.substring(0,filter.length()-1);
      for (String name: classes.keySet()) if (name.startsWith(prefix)) { owned=true; break; }
      if (!owned) request.addClassExclusionFilter(filter);
    }
    request.setSuspendPolicy(EventRequest.SUSPEND_ALL); request.enable(); resumeHeld();
  }
  // StringReference.value() copies the complete target string through JDWP.
  // Inspect the known JDK String backing array instead, with a native read cap.
  // Unknown VM layouts are explicit unavailable values, never user-code calls.
  SafeText stringValue(StringReference string, int limit) {
    try {
      Field field=string.referenceType().fieldByName("value");
      if (field==null) throw new IllegalStateException("No String backing field");
      Value data=string.getValue(field);
      if (!(data instanceof ArrayReference)) throw new IllegalStateException("Unknown String backing array");
      ArrayReference array=(ArrayReference)data;
      String kind=((ArrayType)array.referenceType()).componentTypeName();
      String text;
      boolean truncated;
      if (kind.equals("byte")) {
        Field coderField=string.referenceType().fieldByName("coder");
        if (coderField==null) throw new IllegalStateException("No String encoding field");
        Value coderValue=string.getValue(coderField);
        if (!(coderValue instanceof ByteValue)) throw new IllegalStateException("Unknown String encoding");
        int coder=((ByteValue)coderValue).value();
        if (coder!=0 && coder!=1) throw new IllegalStateException("Unknown String encoding");
        int count=Math.min(array.length(),limit*(coder+1));
        byte[] bytes=new byte[count];
        List<Value> values=array.getValues(0,count);
        for (int i=0;i<count;i++) bytes[i]=((ByteValue)values.get(i)).value();
        if (coder==0) text=new String(bytes,StandardCharsets.ISO_8859_1);
        else {
          char[] chars=new char[count/2];
          boolean little=ByteOrder.nativeOrder()==ByteOrder.LITTLE_ENDIAN;
          for (int i=0;i<chars.length;i++) {
            int first=bytes[2*i]&255, second=bytes[2*i+1]&255;
            chars[i]=(char)(little?(second<<8)|first:(first<<8)|second);
          }
          // Construct from UTF-16 units so a bound in the middle of a surrogate
          // pair can be removed without the charset decoder inventing U+FFFD.
          text=new String(chars);
        }
        truncated=array.length()>count;
      } else if (kind.equals("char")) {
        int count=Math.min(array.length(),limit);
        char[] chars=new char[count];
        List<Value> values=array.getValues(0,count);
        for (int i=0;i<count;i++) chars[i]=((CharValue)values.get(i)).value();
        text=new String(chars); truncated=array.length()>count;
      } else throw new IllegalStateException("Unknown String array type");
      String clipped=bounded(text,limit);
      if (truncated && !clipped.isEmpty() && Character.isHighSurrogate(clipped.charAt(clipped.length()-1))) {
        clipped=clipped.substring(0,clipped.length()-1);
      }
      for (int i=0;i<clipped.length();i++) {
        char c=clipped.charAt(i);
        if (Character.isHighSurrogate(c)) {
          if (++i>=clipped.length() || !Character.isLowSurrogate(clipped.charAt(i))) {
            throw new IllegalStateException("Unpaired UTF-16 string");
          }
        } else if (Character.isLowSurrogate(c)) throw new IllegalStateException("Unpaired UTF-16 string");
      }
      return new SafeText(clipped,truncated || clipped.length()!=text.length(),"");
    } catch (RuntimeException e) {
      return new SafeText("java.lang.String@"+Long.toHexString(string.uniqueID()),false,
        "String contents unavailable: "+e.getMessage()+" ("+e.getClass().getSimpleName()+")");
    }
  }
  SafeText threadName(ThreadReference thread) {
    for (ReferenceType type: vm.classesByName("java.lang.Thread")) {
      Field name=type.fieldByName("name");
      if (name!=null) {
        Value value=thread.getValue(name);
        if (value instanceof StringReference) return stringValue((StringReference)value,1024);
      }
    }
    return new SafeText("(thread name unavailable)",true,"Thread name field unavailable");
  }
  SafeText value(Value v) {
    if (v==null) return new SafeText("null",false,"");
    if (v instanceof StringReference) return stringValue((StringReference)v,4096);
    String text;
    String unavailable="";
    if (v instanceof ArrayReference) text=v.type().name()+"[length="+((ArrayReference)v).length()+"]";
    else if (v instanceof ObjectReference) text=v.type().name()+"@"+Long.toHexString(((ObjectReference)v).uniqueID());
    else text=v.toString();
    if (v instanceof ObjectReference) unavailable="Only reference identity is available; object fields are not inspected.";
    return new SafeText(bounded(text,4096),text.length()>4096,unavailable);
  }
  void variable(String id, String name, String type, Value v) {
    SafeText value=value(v);
    boolean truncated=name.length()>1024 || type.length()>1024 || value.truncated;
    emit("VAR\t"+id+"\t"+enc(bounded(name,1024))+"\t"+enc(bounded(type,1024))+"\t"+enc(value.text)+"\t"+truncated+"\t"+enc(value.unavailable));
  }
  void command(String[] f) throws Exception {
    String id=f[0], operation=f[1];
    try {
      switch (operation) {
        case "breakpoint": add(parseSpec(f,2)); break;
        case "replace":
          int size=Integer.parseInt(f[2]);
          if (size<0 || size>200 || f.length!=3+4*size) throw new IllegalArgumentException("Invalid breakpoint set");
          List<Spec> replacements=new ArrayList<>();
          for (int i=0;i<size;i++) replacements.add(parseSpec(f,3+4*i));
          replace(replacements,true); break;
        case "remove": remove(dec(f[2])); break;
        case "resume": resume(); break;
        case "over": step(StepRequest.STEP_OVER); break;
        case "into": step(StepRequest.STEP_INTO); break;
        case "out": step(StepRequest.STEP_OUT); break;
        case "pause":
          if (paused!=null) throw new IllegalStateException("Target is already paused");
          vm.suspend();
          ThreadReference selected=null;
          for (ThreadReference t: vm.allThreads()) {
            SafeText name=threadName(t);
            if (name.unavailable.isEmpty() && !name.truncated && name.text.equals("main") && t.frameCount()>0) { selected=t; break; }
          }
          if (selected==null) { vm.resume(); throw new IllegalStateException("No suspendable main thread"); }
          pauseAt(selected,null,"pause"); break;
        case "threads":
          List<ThreadReference> threads=vm.allThreads();
          boolean threadTruncated=threads.size()>64;
          for (ThreadReference t: threads.subList(0,Math.min(64,threads.size()))) {
            SafeText name=threadName(t); threadTruncated|=name.truncated || !name.unavailable.isEmpty();
            emit("THREAD\t"+id+"\t"+t.uniqueID()+"\t"+enc(name.text)+"\t"+t.isSuspended());
          }
          emit("THREADS\t"+id+"\t"+threadTruncated); break;
        case "variables":
          if (paused==null) throw new IllegalStateException("Target is not paused");
          StackFrame frame=paused.frame(Integer.parseInt(f[2]));
          int limit=Integer.parseInt(f[3]);
          if (limit<0 || limit>200) throw new IllegalArgumentException("Invalid variable limit");
          try {
            List<LocalVariable> variables=frame.visibleVariables();
            int count=0;
            for (LocalVariable variable: variables) {
              if (count>=limit) break;
              variable(id,variable.name(),variable.typeName(),frame.getValue(variable)); count++;
            }
            ObjectReference self=frame.thisObject();
            if (self!=null && count<limit) { variable(id,"this",self.type().name(),self); count++; }
            emit("VARS\t"+id+"\t"+(variables.size()+(self==null?0:1)>count)+"\t");
          } catch (AbsentInformationException | NativeMethodException e) {
            emit("VARS\t"+id+"\tfalse\t"+enc("Local-variable metadata unavailable: "+e));
          }
          break;
        case "stack":
          if (paused==null) throw new IllegalStateException("Target is not paused");
          int index=0, frameCount=paused.frameCount();
          for (StackFrame sf: paused.frames(0,Math.min(32,frameCount))) {
            Location l=sf.location();
            emit("FRAME\t"+id+"\t"+(index++)+"\t"+enc(l.declaringType().name())+"\t"+enc(l.method().name())+"\t"+enc(source(l))+"\t"+l.lineNumber()+"\t"+(sourceByClass.containsKey(l.declaringType().name())?enc(sourceByClass.get(l.declaringType().name())):"")+"\t"+paused.uniqueID());
          }
          emit("STACK\t"+id+"\t"+(frameCount>32)); break;
        case "terminate": emit("DONE\t"+id); vm.exit(0); return;
        default: throw new IllegalArgumentException("Unknown debug command");
      }
      emit("DONE\t"+id);
    } catch (VMDisconnectedException e) { throw e; }
    catch (Exception e) { emit("ERROR\t"+id+"\t"+enc(e.toString())); }
  }
  void run() throws Exception {
    indexSources();
    ListeningConnector connector=null;
    for (ListeningConnector c: Bootstrap.virtualMachineManager().listeningConnectors()) if (c.name().equals("com.sun.jdi.SocketListen")) connector=c;
    if (connector==null) throw new IllegalStateException("JDI SocketListen is unavailable");
    Map<String,Connector.Argument> args=connector.defaultArguments();
    args.get("localAddress").setValue("127.0.0.1"); args.get("port").setValue("0"); args.get("timeout").setValue("30000");
    String address=connector.startListening(args);
    int port=Integer.parseInt(address.substring(address.lastIndexOf(':')+1)); emit("READY\t"+port);
    try { vm=connector.accept(args); } finally { connector.stopListening(args); }
    try {
      ClassPrepareRequest prepare=vm.eventRequestManager().createClassPrepareRequest();
      prepare.setSuspendPolicy(EventRequest.SUSPEND_ALL); prepare.enable();
      List<Spec> initial=new ArrayList<>();
      for (String line: Files.readAllLines(root.resolve("breakpoints"),StandardCharsets.UTF_8)) if (!line.isEmpty()) initial.add(parseSpec(line.split("\t",-1),0));
      replace(initial,false);
      if (Files.readString(root.resolve("stop-on-entry")).equals("true")) {
        entryRequest=vm.eventRequestManager().createMethodEntryRequest();
        entryRequest.addClassFilter(entryClass); entryRequest.setSuspendPolicy(EventRequest.SUSPEND_ALL); entryRequest.enable();
      }
      emit("VM\t"+enc(vm.name())+"\t"+enc(vm.version())+"\t"+enc(vm.description())+"\t"+vm.canPopFrames()+"\t"+vm.canForceEarlyReturn()); emit("ATTACHED");
      while (true) {
        for (int count=0;count<32;count++) {
          Path command=root.resolve(next+".cmd");
          if (!Files.exists(command)) break;
          String text=Files.readString(command,StandardCharsets.UTF_8); Files.delete(command); next++;
          command(text.split("\t",-1));
        }
        EventSet set=vm.eventQueue().remove(40);
        if (set==null) continue;
        boolean stopped=false;
        for (Event event: set) {
          if (event instanceof VMDeathEvent || event instanceof VMDisconnectEvent) return;
          if (event instanceof ClassPrepareEvent) {
            ReferenceType type=((ClassPrepareEvent)event).referenceType();
            for (Spec spec: specs.values()) if (spec.types.contains(type.name())) { install(spec,type,true); breakpointState(spec); }
          } else if (event instanceof BreakpointEvent && !stopped && paused==null) {
            pauseAt(((BreakpointEvent)event).thread(),set,"breakpoint"); stopped=true;
          } else if (event instanceof StepEvent && !stopped && paused==null) {
            clearSteps(); pauseAt(((StepEvent)event).thread(),set,"step"); stopped=true;
          } else if (event instanceof MethodEntryEvent && !stopped && paused==null) {
            MethodEntryEvent entry=(MethodEntryEvent)event;
            if (entry.method().name().equals("main") && entry.method().signature().equals("([Ljava/lang/String;)V")) {
              vm.eventRequestManager().deleteEventRequest(entryRequest); entryRequest=null;
              pauseAt(entry.thread(),set,"entry"); stopped=true;
            }
          }
        }
        if (!stopped) set.resume();
      }
    } catch (VMDisconnectedException expected) {
      // The owned target's actual process exit is reported separately by Dart.
    } finally {
      emit("DISCONNECTED"); try { vm.dispose(); } catch (VMDisconnectedException ignored) {}
    }
  }
  public static void main(String[] args) throws Exception { new QfliJavaDebugger(Path.of(args[0])).run(); }
}
''';
