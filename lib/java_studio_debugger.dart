import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/services/debug_session.dart';

import 'java_debugger.dart';
import 'java_runner.dart';

/// The editor uses the same local JDI/JDWP transport as the direct Java tool.
/// Bounds: 2,000 sources / 16 MiB, 200 breakpoints, 64 threads, 32 frames,
/// 64 locals per frame / 200 total, 1,024 UTF-16 units per displayed value,
/// 4,096 per message, and a Unicode-safe rolling 64 Ki-unit tail per output.
/// Objects expose their real reference identity; fields are explicitly unavailable.
class JavaStudioDebugger implements StudioDebugger {
  const JavaStudioDebugger({this.debugger = const JavaDebugger()});

  final JavaDebugger debugger;

  @override
  String get displayName => 'Java JDI';

  @override
  DebugCapabilities get capabilities => const DebugCapabilities(
    breakpointUpdate: DebugBreakpointUpdate.paused,
    outputDelivery: DebugOutputDelivery.live,
    supportsPause: true,
    supportsStepInto: true,
    supportsStepOver: true,
    supportsStepOut: true,
    supportsDocumentSnapshots: true,
    supportsStopOnEntry: true,
    supportsStackFrames: true,
    supportsVariables: true,
  );

  @override
  bool supportsLanguage(String language) => language.toLowerCase() == 'java';

  @override
  Future<DebugSession> launch(DebugLaunchRequest request) async {
    if (!supportsLanguage(request.language)) {
      throw ArgumentError('Java debugging requires the Java language.');
    }
    // Freeze every captured source before creating a worker. Never use a saved
    // version for an unsupported or missing dirty document.
    final prepared = await _prepare(request);
    final raw = debugger.launch(
      projectPath: prepared.root,
      entryFile: prepared.entry,
      sourceFiles: prepared.text.keys.toList(),
      unsavedBuffers: prepared.text,
      breakpoints: _nativeBreakpoints(prepared, request.breakpoints),
      stopOnEntry: request.stopOnEntry,
    );
    return _JavaStudioSession(raw, prepared, request.breakpoints);
  }
}

class _PreparedJava {
  const _PreparedJava(this.root, this.entry, this.text);
  final String root;
  final String entry;
  final Map<String, String> text;
}

String _key(String path) => Platform.isWindows ? path.toLowerCase() : path;

void _absoluteCanonical(String path) {
  if (path.isEmpty ||
      path.length > 4096 ||
      !p.isAbsolute(path) ||
      path != p.normalize(path) ||
      !_validUtf16(path)) {
    throw ArgumentError('Use a canonical absolute project path: $path');
  }
}

Future<void> _ownedFile(String root, String path) async {
  _absoluteCanonical(path);
  if (!p.isWithin(root, path) ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file ||
      !p.equals(await File(path).resolveSymbolicLinks(), path)) {
    throw ArgumentError(
      'Source must be an existing physical project file: $path',
    );
  }
}

Future<_PreparedJava> _prepare(DebugLaunchRequest request) async {
  final root = request.projectPath;
  _absoluteCanonical(root);
  if (await FileSystemEntity.type(root, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.equals(await Directory(root).resolveSymbolicLinks(), root)) {
    throw ArgumentError(
      'Project root must be an existing canonical directory.',
    );
  }
  await _ownedFile(root, request.entryFilePath);
  if (p.extension(request.entryFilePath) != '.java') {
    throw ArgumentError('Java entry must have the .java extension.');
  }
  if (request.documents.length > 2000) {
    throw ArgumentError('Java source capture exceeds 2,000 documents.');
  }
  final documents = <String, String>{};
  final seen = <String>{};
  for (final document in request.documents) {
    await _ownedFile(root, document.path);
    if (p.extension(document.path) != '.java' ||
        document.revision < 0 ||
        !_validUtf16(document.text) ||
        !seen.add(_key(document.path))) {
      throw ArgumentError(
        'Unsupported, duplicate or invalid Java document: ${document.path}',
      );
    }
    documents[_key(document.path)] = document.text;
  }
  final sources = JavaProgramRunner.collectProjectJavaFiles(Directory(root));
  final paths = <String, String>{for (final path in sources) _key(path): path};
  for (final document in request.documents) {
    // Windows captures may use another case spelling for the same file. Keep
    // the saved filename's case so public Main is still compiled as Main.java.
    paths.putIfAbsent(_key(document.path), () => document.path);
  }
  if (paths.length > 2000) {
    throw ArgumentError('Java project exceeds 2,000 source files.');
  }
  final text = <String, String>{};
  var bytes = 0;
  for (final path in paths.values.toList()..sort()) {
    await _ownedFile(root, path);
    if (p.extension(path) != '.java') {
      throw ArgumentError('Unsupported Java source extension: $path');
    }
    final captured = documents[_key(path)];
    bytes += captured == null
        ? await File(path).length()
        : utf8.encode(captured).length;
    if (bytes > 16 * 1024 * 1024) {
      throw ArgumentError('Java source capture exceeds 16 MiB.');
    }
    text[path] = captured ?? await File(path).readAsString();
  }
  final entry = paths[_key(request.entryFilePath)];
  if (entry == null) {
    throw ArgumentError('Java entry is missing from the source capture.');
  }
  for (final directory in ['lib', 'libs']) {
    for (final jar in JavaProgramRunner.collectProjectJars(
      Directory(p.join(root, directory)),
    )) {
      await _ownedFile(root, jar);
    }
  }
  final prepared = _PreparedJava(root, entry, Map.unmodifiable(text));
  await _validateBreakpoints(prepared, request.breakpoints);
  return prepared;
}

Future<void> _validateBreakpoints(
  _PreparedJava prepared,
  List<DebugBreakpoint> points,
) async {
  if (points.length > 200) {
    throw ArgumentError('At most 200 breakpoints are supported.');
  }
  final seen = <String>{};
  for (final point in points) {
    await _ownedFile(prepared.root, point.filePath);
    if (!prepared.text.keys.any((path) => p.equals(path, point.filePath)) ||
        point.line < 1 ||
        point.line > 0x7fffffff ||
        !seen.add('${_key(point.filePath)}:${point.line}')) {
      throw ArgumentError('Invalid, duplicate or uncaptured Java breakpoint.');
    }
  }
}

List<JavaBreakpoint> _nativeBreakpoints(
  _PreparedJava prepared,
  List<DebugBreakpoint> points,
) => [
  for (var i = 0; i < points.length; i++)
    JavaBreakpoint(
      id: 'source-$i',
      sourceFile: prepared.text.keys.singleWhere(
        (path) => p.equals(path, points[i].filePath),
      ),
      line: points[i].line,
    ),
];

class _JavaStudioSession implements DebugSession {
  _JavaStudioSession(this._raw, this._prepared, List<DebugBreakpoint> points)
    : _requested = List.unmodifiable(points) {
    _state = DebugSnapshot(
      sessionId: id,
      revision: 0,
      phase: DebugPhase.starting,
      breakpoints: _results(),
    );
    _subscription = _raw.events.listen(
      _event,
      onDone: () {
        if (!_eventsEnded.isCompleted) _eventsEnded.complete();
      },
    );
    unawaited(_finish());
  }

  static int _serial = 0;
  @override
  final String id =
      'java-${DateTime.now().microsecondsSinceEpoch}-${++_serial}';
  final JavaDebugSession _raw;
  final _PreparedJava _prepared;
  List<DebugBreakpoint> _requested;
  final _native = <String, JavaDebugEvent>{};
  Map<String, JavaDebugEvent>? _replacing;
  final _updates = StreamController<DebugSnapshot>.broadcast();
  final _done = Completer<void>();
  final _eventsEnded = Completer<void>();
  late final StreamSubscription<JavaDebugEvent> _subscription;
  late DebugSnapshot _state;
  Future<void> _transport = Future.value();
  Future<void>? _stopFuture;
  Future<void>? _disposeFuture;
  final _stdout = _OutputTail();
  final _stderr = _OutputTail();
  final _console = _OutputTail();
  JavaDebugEvent? _pause;
  int _captureGeneration = 0;
  int _pauseGeneration = 0;
  bool _stopping = false;
  String? _failure;

  @override
  DebugSnapshot get snapshot => _state;
  @override
  Stream<DebugSnapshot> get updates => _updates.stream;
  @override
  Future<void> get done => _done.future;

  Future<T> _serially<T>(Future<T> Function() work) {
    final result = _transport.then((_) => work());
    _transport = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  List<DebugBreakpointResult> _results() => [
    for (var i = 0; i < _requested.length; i++)
      _breakpointResult(_requested[i], _native['source-$i']),
  ];

  DebugSourceLocation? _location(JavaDebugLocation? raw) {
    if (raw == null || raw.line < 1 || raw.sourcePath == null) return null;
    final original = _prepared.text.keys.where(
      (path) => p.equals(path, raw.sourcePath!),
    );
    if (original.length != 1) return null;
    return DebugSourceLocation(filePath: original.single, line: raw.line);
  }

  DebugBreakpointResult _breakpointResult(
    DebugBreakpoint requested,
    JavaDebugEvent? raw,
  ) {
    final location = _location(raw?.location);
    if (raw?.verified == true &&
        location != null &&
        p.equals(location.filePath, requested.filePath) &&
        location.line == requested.line) {
      return DebugBreakpointResult(
        requested: requested,
        status: DebugBreakpointStatus.verified,
        actualLocation: location,
      );
    }
    if (raw?.message == 'no-executable-code' || raw?.verified == true) {
      return DebugBreakpointResult(
        requested: requested,
        status: DebugBreakpointStatus.rejected,
        reason: raw?.verified == true
            ? 'JDI returned an unowned or mismatched source location.'
            : 'No executable bytecode exists at this exact source line.',
      );
    }
    return DebugBreakpointResult(
      requested: requested,
      status: DebugBreakpointStatus.pending,
    );
  }

  void _publish({
    DebugPhase? phase,
    DebugPauseToken? token,
    List<DebugThread>? threads,
    List<DebugFrame>? frames,
    bool? threadsTruncated,
    bool? framesTruncated,
    String? message,
    int? exitCode,
  }) {
    if (_state.isTerminal) return;
    final nextPhase = phase ?? _state.phase;
    _state = DebugSnapshot(
      sessionId: id,
      revision: _state.revision + 1,
      phase: nextPhase,
      pauseToken: nextPhase == DebugPhase.paused
          ? token ?? _state.pauseToken
          : null,
      threads: threads ?? _state.threads,
      frames: nextPhase == DebugPhase.paused
          ? frames ?? _state.frames
          : const [],
      breakpoints: _results(),
      threadsTruncated: threadsTruncated ?? _state.threadsTruncated,
      framesTruncated:
          nextPhase == DebugPhase.paused &&
          (framesTruncated ?? _state.framesTruncated),
      stdout: _stdout.text,
      stderr: _stderr.text,
      console: _console.text,
      stdoutTruncated: _stdout.truncated || _raw.stdoutTruncated,
      stderrTruncated: _stderr.truncated || _raw.stderrTruncated,
      consoleTruncated: _console.truncated || _raw.consoleTruncated,
      message: message == null ? _state.message : _clip(message, 4096),
      exitCode: exitCode,
    );
    if (!_updates.isClosed) _updates.add(_state);
  }

  void _event(JavaDebugEvent event) {
    if (_state.isTerminal) return;
    switch (event.kind) {
      case JavaDebugEventKind.attached:
        if (!_stopping && _pause == null) _publish(phase: DebugPhase.running);
      case JavaDebugEventKind.breakpoint:
        final target = _replacing ?? _native;
        target[event.breakpointId!] = event;
        if (_replacing == null) _publish();
      case JavaDebugEventKind.output:
        final output = event.outputOrigin == JavaDebugOutputOrigin.backend
            ? _console
            : event.isErrorOutput
            ? _stderr
            : _stdout;
        output.add(event.message);
        output.truncated |= event.truncated;
        _publish();
      case JavaDebugEventKind.error:
        _failure ??= _clip(event.message, 4096);
        _console.add('${event.message}\n');
        if (_raw.isStopping) {
          _stopping = true;
          _pause = null;
          _captureGeneration++;
          _publish(
            phase: DebugPhase.stopping,
            threads: const [],
            threadsTruncated: false,
            message: _failure,
          );
        } else {
          _publish(message: _failure);
        }
      case JavaDebugEventKind.paused:
        if (_stopping) return;
        _pause = event;
        final generation = ++_captureGeneration;
        unawaited(
          _serially(() => _capture(event, generation)).catchError((
            Object error,
          ) {
            if (!_stopping) {
              _failure ??= 'Java frame capture failed: $error';
              _console.add('$_failure\n');
              unawaited(stop().catchError((Object _) {}));
            }
          }),
        );
      case JavaDebugEventKind.resumed:
        _pause = null;
        _captureGeneration++;
        if (!_stopping) {
          _publish(
            phase: DebugPhase.running,
            threads: const [],
            threadsTruncated: false,
          );
        }
      case JavaDebugEventKind.terminated:
        // Only _finish publishes terminal state after raw.done and cleanup.
        break;
    }
  }

  Future<void> _capture(JavaDebugEvent pause, int capture) async {
    if (_stopping || capture != _captureGeneration) return;
    final rawThreads = await _raw.threadSnapshot();
    final stack = await _raw.stackSnapshot();
    if (pause.threadId == null ||
        pause.threadName == null ||
        stack.frames.any((frame) => frame.threadId != pause.threadId)) {
      throw StateError('JDI did not return the actual paused thread identity.');
    }
    final threads = [
      for (final thread in rawThreads.threads)
        DebugThread(
          id: thread.id,
          name: thread.name,
          isPaused: thread.isPaused,
        ),
    ];
    var threadsTruncated = rawThreads.truncated;
    if (!threads.any((thread) => thread.id == pause.threadId)) {
      if (threads.length == 64) threads.removeLast();
      threads.add(
        DebugThread(
          id: pause.threadId!,
          name: pause.threadName!,
          isPaused: true,
        ),
      );
      threadsTruncated = true;
    }
    final frames = <DebugFrame>[];
    var variableBudget = 200;
    for (final frame in stack.frames) {
      if (_stopping || capture != _captureGeneration) return;
      final limit = variableBudget.clamp(0, 64);
      final variables = await _raw.variableSnapshot(
        frame: frame.index,
        limit: limit,
      );
      variableBudget -= variables.variables.length;
      final name = '${frame.location.className}.${frame.method}';
      frames.add(
        DebugFrame(
          id: '${pause.threadId!}:${frame.index}',
          threadId: pause.threadId!,
          name: _clip(name, 1024),
          location: _location(frame.location),
          locals: [
            for (final variable in variables.variables)
              DebugVariable(
                name: _clip(variable.name, 1024),
                type: _clip(variable.type, 1024),
                value: _clip(variable.value, 1024),
                unavailableReason: variable.unavailableReason == null
                    ? null
                    : _clip(variable.unavailableReason!, 1024),
                truncated:
                    variable.truncated ||
                    variable.value.length > 1024 ||
                    variable.name.length > 1024 ||
                    variable.type.length > 1024 ||
                    (variable.unavailableReason?.length ?? 0) > 1024,
              ),
          ],
          localsUnavailableReason: variables.unavailableReason == null
              ? null
              : _clip(variables.unavailableReason!, 1024),
          localsTruncated:
              variables.truncated ||
              (variables.unavailableReason?.length ?? 0) > 1024,
        ),
      );
    }
    if (_stopping || capture != _captureGeneration) return;
    _publish(
      phase: DebugPhase.paused,
      token: DebugPauseToken(sessionId: id, generation: ++_pauseGeneration),
      threads: threads,
      frames: frames,
      threadsTruncated: threadsTruncated,
      framesTruncated:
          stack.truncated ||
          stack.frames.any(
            (f) => ('${f.location.className}.${f.method}').length > 1024,
          ),
      message: pause.message,
    );
  }

  @override
  Future<List<DebugBreakpointResult>> setBreakpoints(
    List<DebugBreakpoint> breakpoints,
  ) {
    final points = List<DebugBreakpoint>.unmodifiable(breakpoints);
    return _serially(() async {
      if (_stopping || _state.phase != DebugPhase.paused) {
        throw StateError(
          'Java breakpoint replacement requires a paused session.',
        );
      }
      await _validateBreakpoints(_prepared, points);
      if (_stopping || _state.phase != DebugPhase.paused) {
        throw StateError('Java session is no longer paused.');
      }
      _replacing = {};
      try {
        final states = await _raw.replaceBreakpoints(
          _nativeBreakpoints(_prepared, points),
        );
        _requested = points;
        _native
          ..clear()
          ..addEntries(
            states.map((event) => MapEntry(event.breakpointId!, event)),
          );
      } finally {
        _replacing = null;
      }
      _publish();
      return _state.breakpoints;
    });
  }

  @override
  Future<void> command(
    DebugCommand command, {
    DebugPauseToken? pauseToken,
    String? threadId,
  }) => _serially(() async {
    if (_stopping || _state.isTerminal) {
      throw StateError('Java session has stopped.');
    }
    if (threadId != null &&
        !_state.threads.any((thread) => thread.id == threadId)) {
      throw ArgumentError('Unknown Java debug thread.');
    }
    if (command == DebugCommand.pause) {
      if (_state.phase != DebugPhase.running ||
          _pause != null ||
          pauseToken != null) {
        throw StateError('Pause requires a running Java session.');
      }
      await _raw.pause();
      return;
    }
    if (_state.phase != DebugPhase.paused ||
        pauseToken == null ||
        pauseToken != _state.pauseToken) {
      throw StateError('The Java pause token is missing, foreign or stale.');
    }
    if (threadId != null && threadId != _pause?.threadId) {
      throw ArgumentError(
        'Only the observed stopped thread supports stepping/resume.',
      );
    }
    final previousPause = _pause!;
    _pause = null;
    _captureGeneration++;
    _publish(
      phase: DebugPhase.running,
      threads: const [],
      threadsTruncated: false,
    );
    try {
      switch (command) {
        case DebugCommand.resume:
          await _raw.resume();
        case DebugCommand.stepInto:
          await _raw.stepInto();
        case DebugCommand.stepOver:
          await _raw.stepOver();
        case DebugCommand.stepOut:
          await _raw.stepOut();
        case DebugCommand.pause:
          throw StateError('Unreachable pause command.');
      }
    } catch (error) {
      if (!_stopping && !_state.isTerminal) {
        _pause = previousPause;
        await _capture(previousPause, ++_captureGeneration);
      }
      rethrow;
    }
  });

  Future<void> _finish() async {
    await _raw.done;
    await _eventsEnded.future;
    await _transport;
    if (!_raw.cleanupConfirmed) {
      _failure ??= 'Java debugger scratch cleanup did not complete.';
    }
    final code = _raw.targetExitCode;
    if (!_stopping && code != null && code != 0) {
      _failure ??= 'Java program exited with status $code.';
    }
    _publish(
      phase: _failure == null ? DebugPhase.terminated : DebugPhase.failed,
      threads: const [],
      threadsTruncated: false,
      exitCode: code,
      message: _failure ?? (_stopping ? 'Stopped' : 'Java program exited'),
    );
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> stop() =>
      _stopFuture ??= _stop().catchError((Object error, StackTrace stack) {
        _stopFuture = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _stop() async {
    if (!_state.isTerminal) {
      _stopping = true;
      _pause = null;
      _captureGeneration++;
      _publish(phase: DebugPhase.stopping, threads: const []);
      await _raw.stop(); // Bypass the inspection/command queue.
    }
    await done;
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose().catchError((
    Object error,
    StackTrace stack,
  ) {
    _disposeFuture = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _dispose() async {
    await stop();
    await _subscription.cancel();
    await _updates.close();
  }
}

class _OutputTail {
  static const limit = 64 * 1024;
  String text = '';
  bool truncated = false;
  void add(String value) {
    text += value;
    if (text.length <= limit) return;
    var start = text.length - limit;
    if (start > 0 &&
        _low(text.codeUnitAt(start)) &&
        _high(text.codeUnitAt(start - 1))) {
      start++;
    }
    text = text.substring(start);
    truncated = true;
  }
}

bool _high(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool _low(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
bool _validUtf16(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (_high(unit)) {
      if (++i == text.length || !_low(text.codeUnitAt(i))) return false;
    } else if (_low(unit)) {
      return false;
    }
  }
  return true;
}

String _clip(String text, int limit) {
  if (text.length <= limit) return text;
  var end = limit;
  if (end > 0 && _high(text.codeUnitAt(end - 1))) end--;
  return text.substring(0, end);
}
